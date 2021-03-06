#include <darwintest.h>
#include <pthread.h>
#include <stdatomic.h>

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_page_size.h>

#include <sys/sysctl.h>

#include "hvtest_x86_guest.h"

#include <Foundation/Foundation.h>
#include <Hypervisor/hv.h>
#include <Hypervisor/hv_vmx.h>

T_GLOBAL_META(
	T_META_NAMESPACE("xnu.intel.hv"),
	T_META_RUN_CONCURRENTLY(true),
	T_META_REQUIRES_SYSCTL_NE("hw.optional.arm64", 1), // Don't run translated.
	T_META_RADAR_COMPONENT_NAME("xnu"),
	T_META_RADAR_COMPONENT_VERSION("intel"),
	T_META_OWNER("joster")
	);

/*
 * We want every hypervisor test to run multiple times:
 *   - Using hv_vcpu_run()
 *   - Using hv_vcpu_run_until()
 *   - using hv_vcpu_run_until() with HV_VM_ACCEL_APIC
 *
 * darwintest has no means to run tests multiple
 * times with slightly different configuration,
 * so we have to bake it ourselves. (This can
 * be extended for other config variants of
 * course.)
 */
static bool hv_use_run_until;
static bool hv_use_accel_apic;
#define T_DECL_HV(name, ...)                         \
    static void hv_test_##name (void);               \
    T_DECL(name##_run, __VA_ARGS__) {                \
        hv_use_run_until = false;                    \
        hv_use_accel_apic = false;                   \
        hv_test_##name();                            \
    }                                                \
    T_DECL(name##_run_until, __VA_ARGS__) {          \
        hv_use_run_until = true;                     \
        hv_use_accel_apic = false;                   \
        hv_test_##name();                            \
    }                                                \
    T_DECL(name##_run_until_accel, __VA_ARGS__) {    \
        hv_use_run_until = true;                     \
        hv_use_accel_apic = true;                    \
        hv_test_##name();                            \
    }                                                \
    static void hv_test_##name (void)

static void
create_vm(hv_vm_options_t flags)
{
	if (hv_use_accel_apic) {
		flags |= HV_VM_ACCEL_APIC;
	}

	T_ASSERT_EQ(hv_vm_create(flags), HV_SUCCESS, "created vm");
}

static void
run_vcpu(hv_vcpuid_t vcpu)
{
	if (hv_use_run_until) {
		T_QUIET; T_ASSERT_EQ(hv_vcpu_run_until(vcpu, ~(uint64_t)0), HV_SUCCESS, "hv_vcpu_run_until");
	} else {
		T_QUIET; T_ASSERT_EQ(hv_vcpu_run(vcpu), HV_SUCCESS, "hv_vcpu_run");
	}
}

static bool
hv_support()
{
	int hv_support;
	size_t hv_support_size = sizeof(hv_support);

	int err = sysctlbyname("kern.hv_support", &hv_support, &hv_support_size, NULL, 0);
	if (err) {
		return false;
	} else {
		return hv_support != 0;
	}
}

static uint64_t get_reg(hv_vcpuid_t vcpu, hv_x86_reg_t reg)
{
	uint64_t val;
	T_QUIET; T_EXPECT_EQ(hv_vcpu_read_register(vcpu, reg, &val), HV_SUCCESS,
                         "get register");
	return val;
}

static void set_reg(hv_vcpuid_t vcpu, hv_x86_reg_t reg, uint64_t value)
{
	T_QUIET; T_EXPECT_EQ(hv_vcpu_write_register(vcpu, reg, value), HV_SUCCESS,
                         "set register");
}

static uint64_t get_vmcs(hv_vcpuid_t vcpu, uint32_t field)
{
	uint64_t val;
	T_QUIET; T_EXPECT_EQ(hv_vmx_vcpu_read_vmcs(vcpu, field, &val), HV_SUCCESS,
                         "get vmcs");
	return val;
}

static void set_vmcs(hv_vcpuid_t vcpu, uint32_t field, uint64_t value)
{
	T_QUIET; T_EXPECT_EQ(hv_vmx_vcpu_write_vmcs(vcpu, field, value), HV_SUCCESS,
                         "set vmcs");
}

static uint64_t get_cap(uint32_t field)
{
    uint64_t val;
    T_QUIET; T_ASSERT_EQ(hv_vmx_read_capability(field, &val), HV_SUCCESS,
                         "get capability");
    return val;
}



static NSMutableDictionary *page_cache;
static NSMutableSet *allocated_phys_pages;
static pthread_mutex_t page_table_lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t next_phys = 0x4000000;

/*
 * Map a page into guest's physical address space, return gpa of the
 * page.  If *host_uva is NULL, a new host user page is allocated.
 */
static hv_gpaddr_t
map_guest_phys_locked(void **host_uva)
{
    hv_gpaddr_t gpa = next_phys;
    next_phys += vm_page_size;

    if (*host_uva == NULL) {
        *host_uva = valloc(vm_page_size);
        memset(*host_uva, 0, vm_page_size);
        [allocated_phys_pages addObject:@((uintptr_t)*host_uva)];
    }

    T_QUIET; T_ASSERT_EQ(hv_vm_map(*host_uva, gpa, vm_page_size, HV_MEMORY_READ), HV_SUCCESS, "enter hv mapping");

    [page_cache setObject:@((uintptr_t)*host_uva) forKey:@(gpa)];

    return gpa;
}

static hv_gpaddr_t
map_guest_phys(void **host_uva)
{
	T_QUIET; T_ASSERT_POSIX_SUCCESS(pthread_mutex_lock(&page_table_lock),
	    "acquire page lock");

    hv_gpaddr_t gpa = map_guest_phys_locked(host_uva);

	T_QUIET; T_ASSERT_POSIX_SUCCESS(pthread_mutex_unlock(&page_table_lock),
	    "release page lock");

    return gpa;
}

static uint64_t *pml4;
static hv_gpaddr_t pml4_gpa;

/* Stolen from kern/bits.h, which cannot be included outside the kernel. */
#define BIT(b)                          (1ULL << (b))

#define mask(width)                     (width >= 64 ? (unsigned long long)-1 : (BIT(width) - 1))
#define extract(x, shift, width)        ((((uint64_t)(x)) >> (shift)) & mask(width))
#define bits(x, hi, lo)                 extract((x), (lo), (hi) - (lo) + 1)


/*
 * Enter a page in a level of long mode's PML4 paging structures.
 * Helper for fault_in_page.
 */
static void *
enter_level_locked(uint64_t *table, void *host_va, void *va, int hi, int lo) {
    uint64_t * const te = &table[bits(va, hi, lo)];

    const uint64_t present = 1;
    const uint64_t rw = 2;

    const uint64_t addr_mask = mask(47-12) << 12;

    if (!(*te & present)) {
        hv_gpaddr_t gpa = map_guest_phys_locked(&host_va);
        *te = (gpa & addr_mask) | rw | present;
    } else {
        NSNumber *num = [page_cache objectForKey:@(*te & addr_mask)];
        T_QUIET; T_ASSERT_NOTNULL(num, "existing page is backed");
        void *backing = (void*)[num unsignedLongValue];
        if (host_va != 0) {
            T_QUIET; T_ASSERT_EQ(va, backing, "backing page matches");
        } else {
            host_va = backing;
        }
    }

    return host_va;
}

/*
 * Enters a page both into the guest paging structures and the EPT
 * (long mode PML4 only, real mode and protected mode support running
 * without paging, and that's what they use instead.)
 */
static void *
map_page(void *host_va, void *va) {
	void *result;

	T_QUIET; T_ASSERT_POSIX_SUCCESS(pthread_mutex_lock(&page_table_lock),
	    "acquire page lock");

    uint64_t *pdpt = enter_level_locked(pml4, NULL, va, 47, 39);
    uint64_t *pd = enter_level_locked(pdpt, NULL, va, 38, 30);
    uint64_t *pt = enter_level_locked(pd, NULL, va, 29, 21);
    result = enter_level_locked(pt, host_va, va, 20, 12);

	T_QUIET; T_ASSERT_POSIX_SUCCESS(pthread_mutex_unlock(&page_table_lock),
	    "release page lock");

	return result;
}

static void
fault_in_page(void *va) {
	map_page(va, va);
}

static void free_page_cache(void)
{
	T_QUIET; T_ASSERT_POSIX_SUCCESS(pthread_mutex_lock(&page_table_lock),
	    "acquire page lock");

	for (NSNumber *uvaNumber in allocated_phys_pages) {
		uintptr_t va = [uvaNumber unsignedLongValue];
		free((void *)va);
	}
	[page_cache release];
    [allocated_phys_pages release];

	T_QUIET; T_ASSERT_POSIX_SUCCESS(pthread_mutex_unlock(&page_table_lock),
	    "release page lock");
}

static uint64_t
run_to_next_vm_fault(hv_vcpuid_t vcpu, bool on_demand_paging)
{
	bool retry;
    uint64_t exit_reason, qual, gpa, gla, info, vector_info, error_code;
	uint64_t last_spurious_qual = 0, last_spurious_gpa = 0, last_spurious_gla = 0;
	int spurious_ept_count = 0;
	do {
        retry = false;
		do {
			run_vcpu(vcpu);
			exit_reason = get_vmcs(vcpu, VMCS_RO_EXIT_REASON);
		} while (exit_reason == VMX_REASON_IRQ);

        qual = get_vmcs(vcpu, VMCS_RO_EXIT_QUALIFIC);
        gpa = get_vmcs(vcpu, VMCS_GUEST_PHYSICAL_ADDRESS);
        gla = get_vmcs(vcpu, VMCS_RO_GUEST_LIN_ADDR);
        info = get_vmcs(vcpu, VMCS_RO_VMEXIT_IRQ_INFO);
        vector_info = get_vmcs(vcpu, VMCS_RO_IDT_VECTOR_INFO);
        error_code = get_vmcs(vcpu, VMCS_RO_VMEXIT_IRQ_ERROR);

        if (on_demand_paging) {
            if (exit_reason == VMX_REASON_EXC_NMI &&
                (info & 0x800003ff) == 0x8000030e &&
                (error_code & 0x1) == 0) {
                // guest paging fault
                fault_in_page((void*)qual);
                retry = true;
            }
            else if (exit_reason == VMX_REASON_EPT_VIOLATION) {
                if ((qual & 0x86) == 0x82) {
                    // EPT write fault
                    T_QUIET; T_ASSERT_EQ(hv_vm_protect(gpa & ~(hv_gpaddr_t)PAGE_MASK, vm_page_size,
                                                       HV_MEMORY_READ | HV_MEMORY_WRITE),
                                         HV_SUCCESS, "make page writable");
                    retry = true;
                }
                else if ((qual & 0x86) == 0x84) {
                    // EPT exec fault
                    T_QUIET; T_ASSERT_EQ(hv_vm_protect(gpa & ~(hv_gpaddr_t)PAGE_MASK, vm_page_size,
                                                       HV_MEMORY_READ | HV_MEMORY_EXEC),
                                         HV_SUCCESS, "make page executable");
                    retry = true;
                }
            }
        }

		if (!hv_use_run_until && !retry && exit_reason == VMX_REASON_EPT_VIOLATION &&
			spurious_ept_count++ < 128) {
			/*
			 * When using hv_vcpu_run() instead of
			 * hv_vcpu_run_until(), the Hypervisor kext bubbles up
			 * spurious EPT violations that it actually handled
			 * itself.
			 *
			 * It is hard to assess whether the EPT violation is
			 * spurious or not (a good reason never to use this
			 * interface in practice) without knowledge of the
			 * specific test, so we just retry here, unless we
			 * encounter what seems to be the same fault again.
			 *
			 * To guard against cycling faults that we do not detect
			 * here, we also put a maximum on the number of
			 * retries. Yes, this is all very shoddy, but so is
			 * hv_vcpu_run().
			 *
			 * Every test will also be run with hv_vcpu_run_until()
			 * which employs no such hackery, so this should not mask
			 * any unexpected EPT violations.
			 */

			retry = !((last_spurious_qual == qual) && (last_spurious_gpa == gpa) && (last_spurious_gla == gla));

			if (retry) {
				last_spurious_qual = qual;
				last_spurious_gpa = gpa;
				last_spurious_gla = gla;
			}
		}
	} while (retry);

    // printf("reason: %lld, qualification: %llx\n", exit_reason, qual);
    // printf("gpa: %llx, gla: %llx\n", gpa, gla);
    // printf("RIP: %llx\n", get_reg(vcpu, HV_X86_RIP));
    // printf("CR3: %llx\n", get_reg(vcpu, HV_X86_CR3));
    // printf("info: %llx\n", info);
    // printf("vector_info: %llx\n", vector_info);
    // printf("error_code: %llx\n", error_code);

    return exit_reason;
}

static uint64_t
expect_vmcall(hv_vcpuid_t vcpu, bool on_demand_paging)
{
	uint64_t reason = run_to_next_vm_fault(vcpu, on_demand_paging);
	T_ASSERT_EQ(reason, (uint64_t)VMX_REASON_VMCALL, "expect vmcall exit");

    // advance RIP to after VMCALL
    set_vmcs(vcpu, VMCS_GUEST_RIP, get_reg(vcpu, HV_X86_RIP)+get_vmcs(vcpu, VMCS_RO_VMEXIT_INSTR_LEN));

    return get_reg(vcpu, HV_X86_RAX);
}

static uint64_t
expect_vmcall_with_value(hv_vcpuid_t vcpu, uint64_t rax, bool on_demand_paging)
{
	uint64_t reason = run_to_next_vm_fault(vcpu, on_demand_paging);
	T_QUIET; T_ASSERT_EQ(reason, (uint64_t)VMX_REASON_VMCALL, "check for vmcall exit");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RAX), rax, "vmcall exit with expected RAX value %llx", rax);

    // advance RIP to after VMCALL
    set_vmcs(vcpu, VMCS_GUEST_RIP, get_reg(vcpu, HV_X86_RIP)+get_vmcs(vcpu, VMCS_RO_VMEXIT_INSTR_LEN));

    return reason;
}

typedef void (*vcpu_entry_function)(uint64_t);
typedef void *(*vcpu_monitor_function)(void *, hv_vcpuid_t);

struct test_vcpu {
	hv_vcpuid_t vcpu;
	vcpu_entry_function guest_func;
	uint64_t guest_param;
	vcpu_monitor_function monitor_func;
	void *monitor_param;
};

static uint64_t
canonicalize(uint64_t ctrl, uint64_t mask)
{
	return (ctrl | (mask & 0xffffffff)) & (mask >> 32);
}

static void
setup_real_mode(hv_vcpuid_t vcpu)
{
    uint64_t pin_cap, proc_cap, proc2_cap, entry_cap, exit_cap;

    pin_cap = get_cap(HV_VMX_CAP_PINBASED);
    proc_cap = get_cap(HV_VMX_CAP_PROCBASED);
    proc2_cap = get_cap(HV_VMX_CAP_PROCBASED2);
    entry_cap = get_cap(HV_VMX_CAP_ENTRY);
    exit_cap = get_cap(HV_VMX_CAP_EXIT);

    set_vmcs(vcpu, VMCS_CTRL_PIN_BASED, canonicalize(0, pin_cap));
	set_vmcs(vcpu, VMCS_CTRL_CPU_BASED,
             canonicalize(CPU_BASED_HLT | CPU_BASED_CR8_LOAD | CPU_BASED_CR8_STORE, proc_cap));
	set_vmcs(vcpu, VMCS_CTRL_CPU_BASED2, canonicalize(0, proc2_cap));
    set_vmcs(vcpu, VMCS_CTRL_VMENTRY_CONTROLS, canonicalize(0, entry_cap));
	set_vmcs(vcpu, VMCS_CTRL_VMEXIT_CONTROLS, canonicalize(0, exit_cap));

    set_vmcs(vcpu, VMCS_GUEST_CR0, 0x20);
	set_vmcs(vcpu, VMCS_CTRL_CR0_MASK, ~0u);
	set_vmcs(vcpu, VMCS_CTRL_CR0_SHADOW, 0x20);
	set_vmcs(vcpu, VMCS_GUEST_CR4, 0x2000);
	set_vmcs(vcpu, VMCS_CTRL_CR4_MASK, ~0u);
	set_vmcs(vcpu, VMCS_CTRL_CR4_SHADOW, 0x0000);
	set_vmcs(vcpu, VMCS_GUEST_TR_AR, 0x83);
	set_vmcs(vcpu, VMCS_GUEST_LDTR_AR, 0x10000);
	set_vmcs(vcpu, VMCS_GUEST_SS, 0);
	set_vmcs(vcpu, VMCS_GUEST_SS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_SS_LIMIT, 0xffff);
	set_vmcs(vcpu, VMCS_GUEST_SS_AR, 0x93);
	set_vmcs(vcpu, VMCS_GUEST_CS, 0);
	set_vmcs(vcpu, VMCS_GUEST_CS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_CS_LIMIT, 0xffff);
	set_vmcs(vcpu, VMCS_GUEST_CS_AR, 0x9b);
	set_vmcs(vcpu, VMCS_GUEST_DS, 0);
	set_vmcs(vcpu, VMCS_GUEST_DS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_DS_LIMIT, 0xffff);
	set_vmcs(vcpu, VMCS_GUEST_DS_AR, 0x93);
	set_vmcs(vcpu, VMCS_GUEST_ES, 0);
	set_vmcs(vcpu, VMCS_GUEST_ES_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_ES_LIMIT, 0xffff);
	set_vmcs(vcpu, VMCS_GUEST_ES_AR, 0x93);
	set_vmcs(vcpu, VMCS_GUEST_FS, 0);
	set_vmcs(vcpu, VMCS_GUEST_FS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_FS_LIMIT, 0xffff);
	set_vmcs(vcpu, VMCS_GUEST_FS_AR, 0x93);
	set_vmcs(vcpu, VMCS_GUEST_GS, 0);
	set_vmcs(vcpu, VMCS_GUEST_GS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_GS_LIMIT, 0xffff);
	set_vmcs(vcpu, VMCS_GUEST_GS_AR, 0x93);

    set_vmcs(vcpu, VMCS_GUEST_GDTR_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_GDTR_LIMIT, 0);
    set_vmcs(vcpu, VMCS_GUEST_IDTR_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_IDTR_LIMIT, 0);

    set_vmcs(vcpu, VMCS_GUEST_RFLAGS, 0x2);

	set_vmcs(vcpu, VMCS_CTRL_EXC_BITMAP, 0xffffffff);
}

static void
setup_protected_mode(hv_vcpuid_t vcpu)
{
    uint64_t pin_cap, proc_cap, proc2_cap, entry_cap, exit_cap;

    pin_cap = get_cap(HV_VMX_CAP_PINBASED);
    proc_cap = get_cap(HV_VMX_CAP_PROCBASED);
    proc2_cap = get_cap(HV_VMX_CAP_PROCBASED2);
    entry_cap = get_cap(HV_VMX_CAP_ENTRY);
    exit_cap = get_cap(HV_VMX_CAP_EXIT);

    set_vmcs(vcpu, VMCS_CTRL_PIN_BASED, canonicalize(0, pin_cap));
	set_vmcs(vcpu, VMCS_CTRL_CPU_BASED,
             canonicalize(CPU_BASED_HLT | CPU_BASED_CR8_LOAD | CPU_BASED_CR8_STORE, proc_cap));
	set_vmcs(vcpu, VMCS_CTRL_CPU_BASED2, canonicalize(0, proc2_cap));
    set_vmcs(vcpu, VMCS_CTRL_VMENTRY_CONTROLS, canonicalize(0, entry_cap));
	set_vmcs(vcpu, VMCS_CTRL_VMEXIT_CONTROLS, canonicalize(0, exit_cap));

    set_vmcs(vcpu, VMCS_GUEST_CR0, 0x21);
	set_vmcs(vcpu, VMCS_CTRL_CR0_MASK, ~0u);
	set_vmcs(vcpu, VMCS_CTRL_CR0_SHADOW, 0x21);
	set_vmcs(vcpu, VMCS_GUEST_CR3, 0);
	set_vmcs(vcpu, VMCS_GUEST_CR4, 0x2000);
	set_vmcs(vcpu, VMCS_CTRL_CR4_MASK, ~0u);
	set_vmcs(vcpu, VMCS_CTRL_CR4_SHADOW, 0x0000);

    set_vmcs(vcpu, VMCS_GUEST_TR, 0);
    set_vmcs(vcpu, VMCS_GUEST_TR_AR, 0x8b);
    
	set_vmcs(vcpu, VMCS_GUEST_LDTR, 0x0);
	set_vmcs(vcpu, VMCS_GUEST_LDTR_AR, 0x10000);

	set_vmcs(vcpu, VMCS_GUEST_SS, 0x8);
	set_vmcs(vcpu, VMCS_GUEST_SS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_SS_LIMIT, 0xffffffff);
	set_vmcs(vcpu, VMCS_GUEST_SS_AR, 0xc093);

	set_vmcs(vcpu, VMCS_GUEST_CS, 0x10);
	set_vmcs(vcpu, VMCS_GUEST_CS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_CS_LIMIT, 0xffffffff);
	set_vmcs(vcpu, VMCS_GUEST_CS_AR, 0xc09b);

	set_vmcs(vcpu, VMCS_GUEST_DS, 0x8);
	set_vmcs(vcpu, VMCS_GUEST_DS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_DS_LIMIT, 0xffffffff);
	set_vmcs(vcpu, VMCS_GUEST_DS_AR, 0xc093);

	set_vmcs(vcpu, VMCS_GUEST_ES, 0x8);
	set_vmcs(vcpu, VMCS_GUEST_ES_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_ES_LIMIT, 0xffffffff);
	set_vmcs(vcpu, VMCS_GUEST_ES_AR, 0xc093);

	set_vmcs(vcpu, VMCS_GUEST_FS, 0x8);
	set_vmcs(vcpu, VMCS_GUEST_FS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_FS_LIMIT, 0xffffffff);
	set_vmcs(vcpu, VMCS_GUEST_FS_AR, 0xc093);

	set_vmcs(vcpu, VMCS_GUEST_GS, 0x8);
	set_vmcs(vcpu, VMCS_GUEST_GS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_GS_LIMIT, 0xffffffff);
	set_vmcs(vcpu, VMCS_GUEST_GS_AR, 0xc093);

    set_vmcs(vcpu, VMCS_GUEST_GDTR_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_GDTR_LIMIT, 0);

    set_vmcs(vcpu, VMCS_GUEST_IDTR_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_IDTR_LIMIT, 0);

    set_vmcs(vcpu, VMCS_GUEST_RFLAGS, 0x2);

	set_vmcs(vcpu, VMCS_CTRL_EXC_BITMAP, 0xffffffff);
}

static void
setup_long_mode(hv_vcpuid_t vcpu)
{
    uint64_t pin_cap, proc_cap, proc2_cap, entry_cap, exit_cap;

    pin_cap = get_cap(HV_VMX_CAP_PINBASED);
    proc_cap = get_cap(HV_VMX_CAP_PROCBASED);
    proc2_cap = get_cap(HV_VMX_CAP_PROCBASED2);
    entry_cap = get_cap(HV_VMX_CAP_ENTRY);
    exit_cap = get_cap(HV_VMX_CAP_EXIT);

    set_vmcs(vcpu, VMCS_CTRL_PIN_BASED, canonicalize(0, pin_cap));
	set_vmcs(vcpu, VMCS_CTRL_CPU_BASED,
             canonicalize(CPU_BASED_HLT | CPU_BASED_CR8_LOAD | CPU_BASED_CR8_STORE, proc_cap));
	set_vmcs(vcpu, VMCS_CTRL_CPU_BASED2, canonicalize(0, proc2_cap));
    set_vmcs(vcpu, VMCS_CTRL_VMENTRY_CONTROLS, canonicalize(VMENTRY_GUEST_IA32E, entry_cap));
	set_vmcs(vcpu, VMCS_CTRL_VMEXIT_CONTROLS, canonicalize(0, exit_cap));

    set_vmcs(vcpu, VMCS_GUEST_CR0, 0x80000021L);
	set_vmcs(vcpu, VMCS_CTRL_CR0_MASK, ~0u);
	set_vmcs(vcpu, VMCS_CTRL_CR0_SHADOW, 0x80000021L);
	set_vmcs(vcpu, VMCS_GUEST_CR4, 0x2020);
	set_vmcs(vcpu, VMCS_CTRL_CR4_MASK, ~0u);
	set_vmcs(vcpu, VMCS_CTRL_CR4_SHADOW, 0x2020);

    set_vmcs(vcpu, VMCS_GUEST_IA32_EFER, 0x500);

    T_QUIET; T_ASSERT_EQ(hv_vcpu_enable_native_msr(vcpu, MSR_IA32_KERNEL_GS_BASE, true), HV_SUCCESS, "enable native GS_BASE");
    
    set_vmcs(vcpu, VMCS_GUEST_TR, 0);
    set_vmcs(vcpu, VMCS_GUEST_TR_AR, 0x8b);
    
	set_vmcs(vcpu, VMCS_GUEST_LDTR, 0x0);
	set_vmcs(vcpu, VMCS_GUEST_LDTR_AR, 0x10000);

	set_vmcs(vcpu, VMCS_GUEST_SS, 0x8);
	set_vmcs(vcpu, VMCS_GUEST_SS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_SS_LIMIT, 0xffffffff);
	set_vmcs(vcpu, VMCS_GUEST_SS_AR, 0xa093);

	set_vmcs(vcpu, VMCS_GUEST_CS, 0x10);
	set_vmcs(vcpu, VMCS_GUEST_CS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_CS_LIMIT, 0xffffffff);
	set_vmcs(vcpu, VMCS_GUEST_CS_AR, 0xa09b);

	set_vmcs(vcpu, VMCS_GUEST_DS, 0x8);
	set_vmcs(vcpu, VMCS_GUEST_DS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_DS_LIMIT, 0xffffffff);
	set_vmcs(vcpu, VMCS_GUEST_DS_AR, 0xa093);

	set_vmcs(vcpu, VMCS_GUEST_ES, 0x8);
	set_vmcs(vcpu, VMCS_GUEST_ES_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_ES_LIMIT, 0xffffffff);
	set_vmcs(vcpu, VMCS_GUEST_ES_AR, 0xa093);

	set_vmcs(vcpu, VMCS_GUEST_FS, 0x8);
	set_vmcs(vcpu, VMCS_GUEST_FS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_FS_LIMIT, 0xffffffff);
	set_vmcs(vcpu, VMCS_GUEST_FS_AR, 0xa093);

	set_vmcs(vcpu, VMCS_GUEST_GS, 0x8);
	set_vmcs(vcpu, VMCS_GUEST_GS_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_GS_LIMIT, 0xffffffff);
	set_vmcs(vcpu, VMCS_GUEST_GS_AR, 0xa093);

    set_vmcs(vcpu, VMCS_GUEST_RFLAGS, 0x2);

    set_vmcs(vcpu, VMCS_CTRL_EXC_BITMAP, 0xffffffff);

    set_vmcs(vcpu, VMCS_GUEST_CR3, pml4_gpa);

    set_vmcs(vcpu, VMCS_GUEST_GDTR_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_GDTR_LIMIT, 0);

    set_vmcs(vcpu, VMCS_GUEST_IDTR_BASE, 0);
	set_vmcs(vcpu, VMCS_GUEST_IDTR_LIMIT, 0);
}

static void *
wrap_monitor(void *param)
{
	struct test_vcpu *test = (struct test_vcpu *)param;

    T_QUIET; T_ASSERT_EQ(hv_vcpu_create(&test->vcpu, HV_VCPU_DEFAULT), HV_SUCCESS,
	    "created vcpu");

	const size_t stack_size = 0x4000;
	void *stack_bottom = valloc(stack_size);
	T_QUIET; T_ASSERT_NOTNULL(stack_bottom, "allocate VCPU stack");
	vcpu_entry_function entry = test->guest_func;

    set_vmcs(test->vcpu, VMCS_GUEST_RIP, (uintptr_t)entry);
	set_vmcs(test->vcpu, VMCS_GUEST_RSP, (uintptr_t)stack_bottom + stack_size);
	set_reg(test->vcpu, HV_X86_RDI, test->guest_param);

	void *result = test->monitor_func(test->monitor_param, test->vcpu);

	T_QUIET; T_ASSERT_EQ(hv_vcpu_destroy(test->vcpu), HV_SUCCESS, "Destroyed vcpu");
	free(stack_bottom);
	free(test);
	return result;
}

static pthread_t
create_vcpu_thread(
    vcpu_entry_function guest_function, uint64_t guest_param,
    vcpu_monitor_function monitor_func, void *monitor_param)
{

	pthread_t thread;
	struct test_vcpu *test = malloc(sizeof(*test));
    T_QUIET; T_ASSERT_NOTNULL(test, "malloc test params");
	test->guest_func = guest_function;
	test->guest_param = guest_param;
	test->monitor_func = monitor_func;
	test->monitor_param = monitor_param;
	T_ASSERT_POSIX_SUCCESS(pthread_create(&thread, NULL, wrap_monitor, test),
	    "create vcpu pthread");
	// ownership of test struct moves to the thread
	test = NULL;

	return thread;
}

static void
vm_setup()
{
	T_SETUPBEGIN;

	if (hv_support() < 1) {
		T_SKIP("Running on non-HV target, skipping...");
		return;
	}

	page_cache = [[NSMutableDictionary alloc] init];
	allocated_phys_pages = [[NSMutableSet alloc] init];

	create_vm(HV_VM_DEFAULT);

    // Set up root paging structures for long mode,
    // where paging is mandatory.

    pml4_gpa = map_guest_phys((void**)&pml4);
    memset(pml4, 0, vm_page_size);

    T_SETUPEND;
}

static void
vm_cleanup()
{
	T_ASSERT_EQ(hv_vm_destroy(), HV_SUCCESS, "Destroyed vm");
	free_page_cache();

	pml4 = NULL;
	pml4_gpa = 0;
}

static pthread_cond_t ready_cond = PTHREAD_COND_INITIALIZER;
static pthread_mutex_t vcpus_ready_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t vcpus_initializing;
static pthread_mutex_t vcpus_hang_lock = PTHREAD_MUTEX_INITIALIZER;

static void *
multikill_vcpu_thread_function(void __unused *arg)
{
 	hv_vcpuid_t *vcpu = (hv_vcpuid_t*)arg;

    T_QUIET; T_ASSERT_EQ(hv_vcpu_create(vcpu, HV_VCPU_DEFAULT), HV_SUCCESS,
                         "created vcpu");

	T_QUIET; T_ASSERT_POSIX_SUCCESS(pthread_mutex_lock(&vcpus_ready_lock),
	    "acquire vcpus_ready_lock");
	T_QUIET; T_ASSERT_NE(vcpus_initializing, 0, "check for vcpus_ready underflow");
	vcpus_initializing--;
	if (vcpus_initializing == 0) {
		T_QUIET; T_ASSERT_POSIX_SUCCESS(pthread_cond_signal(&ready_cond),
		    "signaling all VCPUs ready");
	}
	T_QUIET; T_ASSERT_POSIX_SUCCESS(pthread_mutex_unlock(&vcpus_ready_lock),
	    "release vcpus_ready_lock");

	// To cause the VCPU pointer to be cleared from the wrong thread, we need
	// to get threads onto the thread deallocate queue. One way to accomplish
	// this is to die while waiting for a lock.
	T_ASSERT_POSIX_SUCCESS(pthread_mutex_lock(&vcpus_hang_lock),
	    "acquire vcpus_hang_lock");

	// Do not allow the thread to terminate. Exactly one thread will acquire
	// the above lock successfully.
	while (true) {
		pause();
	}

	return NULL;
}

T_DECL_HV(regression_55524541,
	"kill task with multiple VCPU threads waiting for lock")
{
	if (!hv_support()) {
		T_SKIP("no HV support");
	}

	int pipedesc[2];
	T_ASSERT_POSIX_SUCCESS(pipe(pipedesc), "create pipe");

	pid_t child = fork();
	if (child == 0) {
		const uint32_t vcpu_count = 8;
		pthread_t vcpu_threads[8];
		create_vm(HV_VM_DEFAULT);
		vcpus_initializing = vcpu_count;
		for (uint32_t i = 0; i < vcpu_count; i++) {
            hv_vcpuid_t vcpu;

			T_ASSERT_POSIX_SUCCESS(pthread_create(&vcpu_threads[i], NULL,
			    multikill_vcpu_thread_function, (void *)&vcpu),
				"create vcpu_threads[%u]", i);
		}

		T_ASSERT_POSIX_SUCCESS(pthread_mutex_lock(&vcpus_ready_lock),
		    "acquire vcpus_ready_lock");
		while (vcpus_initializing != 0) {
			T_ASSERT_POSIX_SUCCESS(pthread_cond_wait(&ready_cond,
			    &vcpus_ready_lock), "wait for all threads ready");
		}
		T_ASSERT_POSIX_SUCCESS(pthread_mutex_unlock(&vcpus_ready_lock),
		    "release vcpus_ready_lock");

		// Indicate readiness to die, meditiate peacefully.
		uint8_t byte = 0;
		T_ASSERT_EQ_LONG(write(pipedesc[1], &byte, 1), 1L, "notifying on pipe");
		while (true) {
			pause();
		}
	} else {
		T_ASSERT_GT(child, 0, "successful fork");
		// Wait for child to prepare.
		uint8_t byte;
		T_ASSERT_EQ_LONG(read(pipedesc[0], &byte, 1), 1L, "waiting on pipe");
		T_ASSERT_POSIX_SUCCESS(kill(child, SIGTERM), "kill child");
		// Hope for no panic...
		T_ASSERT_POSIX_SUCCESS(wait(NULL), "reap child");
	}
	T_ASSERT_POSIX_SUCCESS(close(pipedesc[0]), "close pipedesc[0]");
	T_ASSERT_POSIX_SUCCESS(close(pipedesc[1]), "close pipedesc[1]");
}

static void *
simple_long_mode_monitor(void *arg __unused, hv_vcpuid_t vcpu)
{
    setup_long_mode(vcpu);

    expect_vmcall_with_value(vcpu, 0x33456, true);

    return NULL;
}

T_DECL_HV(simple_long_mode_guest, "simple long mode guest")
{
    vm_setup();

    pthread_t vcpu_thread = create_vcpu_thread(simple_long_mode_vcpu_entry, 0x10000, simple_long_mode_monitor, 0);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	vm_cleanup();
}

static void *
smp_test_monitor(void *arg __unused, hv_vcpuid_t vcpu)
{
    setup_long_mode(vcpu);

	uint64_t value = expect_vmcall(vcpu, true);
	return (void *)(uintptr_t)value;
}

T_DECL_HV(smp_sanity, "Multiple VCPUs in the same VM")
{
	vm_setup();

	// Use this region as shared memory between the VCPUs.
	void *shared = NULL;
    map_guest_phys((void**)&shared);

	atomic_uint *count_word = (atomic_uint *)shared;
	atomic_init(count_word, 0);

	pthread_t vcpu1_thread = create_vcpu_thread(smp_vcpu_entry,
	    (uintptr_t)count_word, smp_test_monitor, count_word);
	pthread_t vcpu2_thread = create_vcpu_thread(smp_vcpu_entry,
	    (uintptr_t)count_word, smp_test_monitor, count_word);

	void *r1, *r2;
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu1_thread, &r1), "join vcpu1");
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu2_thread, &r2), "join vcpu2");
	uint64_t v1 = (uint64_t)r1;
	uint64_t v2 = (uint64_t)r2;
	if (v1 == 0) {
		T_ASSERT_EQ_ULLONG(v2, 1ULL, "check count");
	} else if (v1 == 1) {
		T_ASSERT_EQ_ULLONG(v2, 0ULL, "check count");
	} else {
		T_FAIL("unexpected count: %llu", v1);
	}

	vm_cleanup();
}


extern void *hvtest_begin;
extern void *hvtest_end;

static void *
simple_protected_mode_test_monitor(void *arg __unused, hv_vcpuid_t vcpu)
{
    setup_protected_mode(vcpu);

    size_t guest_pages_size = round_page((uintptr_t)&hvtest_end - (uintptr_t)&hvtest_begin);

    const size_t mem_size = 1 * 1024 * 1024;
    uint8_t *guest_pages_shadow = valloc(mem_size);

    bzero(guest_pages_shadow, mem_size);
    memcpy(guest_pages_shadow+0x1000, &hvtest_begin, guest_pages_size);

    T_ASSERT_EQ(hv_vm_map(guest_pages_shadow, 0x40000000, mem_size, HV_MEMORY_READ | HV_MEMORY_EXEC),
                HV_SUCCESS, "map guest memory");

    expect_vmcall_with_value(vcpu, 0x23456, false);

    free(guest_pages_shadow);

    return NULL;
}

T_DECL_HV(simple_protected_mode_guest, "simple protected mode guest")
{
    vm_setup();

    pthread_t vcpu_thread = create_vcpu_thread((vcpu_entry_function)
                                               (((uintptr_t)simple_protected_mode_vcpu_entry & PAGE_MASK) +
                                                0x40000000 + 0x1000),
                                               0, simple_protected_mode_test_monitor, 0);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	vm_cleanup();
}

static void *
simple_real_mode_monitor(void *arg __unused, hv_vcpuid_t vcpu)
{
    setup_real_mode(vcpu);

    size_t guest_pages_size = round_page((uintptr_t)&hvtest_end - (uintptr_t)&hvtest_begin);

    const size_t mem_size = 1 * 1024 * 1024;
    uint8_t *guest_pages_shadow = valloc(mem_size);

    bzero(guest_pages_shadow, mem_size);
    memcpy(guest_pages_shadow+0x1000, &hvtest_begin, guest_pages_size);

    T_ASSERT_EQ(hv_vm_map(guest_pages_shadow, 0x0, mem_size, HV_MEMORY_READ | HV_MEMORY_EXEC), HV_SUCCESS,
                "map guest memory");

    expect_vmcall_with_value(vcpu, 0x23456, false);

    free(guest_pages_shadow);

    return NULL;
}

T_DECL_HV(simple_real_mode_guest, "simple real mode guest")
{
    vm_setup();

    pthread_t vcpu_thread = create_vcpu_thread((vcpu_entry_function)
                                               (((uintptr_t)simple_real_mode_vcpu_entry & PAGE_MASK) +
                                                0x1000),
                                               0, simple_real_mode_monitor, 0);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	vm_cleanup();
}

static void *
radar61961809_monitor(void *gpaddr, hv_vcpuid_t vcpu)
{
	uint32_t const gdt_template[] = {
		0, 0,                         /* Empty */
		0x0000ffff, 0x00cf9200,       /* 0x08 CPL0 4GB writable data, 32bit */
		0x0000ffff, 0x00cf9a00,       /* 0x10 CPL0 4GB readable code, 32bit */
		0x0000ffff, 0x00af9200,       /* 0x18 CPL0 4GB writable data, 64bit */
		0x0000ffff, 0x00af9a00,       /* 0x20 CPL0 4GB readable code, 64bit */
	};

	// We start the test in protected mode.
    setup_protected_mode(vcpu);

	// SAVE_EFER makes untrapped CR0.PG work.
    uint64_t exit_cap = get_cap(HV_VMX_CAP_EXIT);
	set_vmcs(vcpu, VMCS_CTRL_VMEXIT_CONTROLS, canonicalize(VMEXIT_SAVE_EFER, exit_cap));

	// Start with CR0.PG disabled.
	set_vmcs(vcpu, VMCS_GUEST_CR0, 0x00000021);
	set_vmcs(vcpu, VMCS_CTRL_CR0_SHADOW, 0x00000021);
	/*
	 * Don't trap on modifying CR0.PG to reproduce the problem.
	 * Otherwise, we'd have to handle the switch ourselves, and would
	 * just do it right.
	 */
	set_vmcs(vcpu, VMCS_CTRL_CR0_MASK, ~0x80000000UL);

	// PAE must be enabled for a switch into long mode to work.
	set_vmcs(vcpu, VMCS_GUEST_CR4, 0x2020);
	set_vmcs(vcpu, VMCS_CTRL_CR4_MASK, ~0u);
	set_vmcs(vcpu, VMCS_CTRL_CR4_SHADOW, 0x2020);

	// Will use the harness managed page tables in long mode.
	set_vmcs(vcpu, VMCS_GUEST_CR3, pml4_gpa);

	// Hypervisor fw wants this (for good, but unrelated reason).
	T_QUIET; T_ASSERT_EQ(hv_vcpu_enable_native_msr(vcpu, MSR_IA32_KERNEL_GS_BASE, true), HV_SUCCESS, "enable native GS_BASE");

	// Far pointer array for our far jumps.
	uint32_t *far_ptr = NULL;
	hv_gpaddr_t far_ptr_gpaddr = map_guest_phys((void**)&far_ptr);
	map_page(far_ptr, (void*)far_ptr_gpaddr);

	far_ptr[0] = (uint32_t)(((uintptr_t)&radar61961809_prepare - (uintptr_t)&hvtest_begin) + (uintptr_t)gpaddr);
	far_ptr[1] = 0x0010; // 32bit CS
	far_ptr[2] = (uint32_t)(((uintptr_t)&radar61961809_loop64 - (uintptr_t)&hvtest_begin) + (uintptr_t)gpaddr);
	far_ptr[3] = 0x0020; // 64bit CS

	set_reg(vcpu, HV_X86_RDI, far_ptr_gpaddr);

	// Setup GDT.
	uint32_t *gdt = valloc(vm_page_size);
	hv_gpaddr_t gdt_gpaddr = 0x70000000;
	map_page(gdt, (void*)gdt_gpaddr);
	bzero(gdt, vm_page_size);
	memcpy(gdt, gdt_template, sizeof(gdt_template));

	set_vmcs(vcpu, VMCS_GUEST_GDTR_BASE, gdt_gpaddr);
	set_vmcs(vcpu, VMCS_GUEST_GDTR_LIMIT, sizeof(gdt_template)+1);

	// Map test code (because we start in protected mode without
	// paging, we cannot use the harness's fault management yet.)
	size_t guest_pages_size = round_page((uintptr_t)&hvtest_end - (uintptr_t)&hvtest_begin);

	const size_t mem_size = 1 * 1024 * 1024;
	uint8_t *guest_pages_shadow = valloc(mem_size);

	bzero(guest_pages_shadow, mem_size);
	memcpy(guest_pages_shadow, &hvtest_begin, guest_pages_size);

	T_ASSERT_EQ(hv_vm_map(guest_pages_shadow, (hv_gpaddr_t)gpaddr, mem_size, HV_MEMORY_READ | HV_MEMORY_EXEC),
		HV_SUCCESS, "map guest memory");

	// Create entries in PML4.
	uint8_t *host_va = guest_pages_shadow;
	uint8_t *va = (uint8_t*)gpaddr;
	for (unsigned long i = 0; i < guest_pages_size / vm_page_size; i++, va += vm_page_size, host_va += vm_page_size) {
		map_page(host_va, va);
	}

	uint64_t reason = run_to_next_vm_fault(vcpu, false);
	T_ASSERT_EQ(reason, (uint64_t)VMX_REASON_RDMSR, "check for rdmsr");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RCX), 0xc0000080LL, "expected EFER rdmsr");

	set_reg(vcpu, HV_X86_RDX, 0);
	set_reg(vcpu, HV_X86_RAX, 0);
    set_vmcs(vcpu, VMCS_GUEST_RIP, get_reg(vcpu, HV_X86_RIP)+get_vmcs(vcpu, VMCS_RO_VMEXIT_INSTR_LEN));

	reason = run_to_next_vm_fault(vcpu, false);
	T_ASSERT_EQ(reason, (uint64_t)VMX_REASON_WRMSR, "check for wrmsr");
	T_ASSERT_EQ(get_reg(vcpu, HV_X86_RCX), 0xc0000080LL, "expected EFER wrmsr");
	T_ASSERT_EQ(get_reg(vcpu, HV_X86_RDX), 0x0LL, "expected EFER wrmsr higher bits 0");
	T_ASSERT_EQ(get_reg(vcpu, HV_X86_RAX), 0x100LL, "expected EFER wrmsr lower bits LME");

	set_vmcs(vcpu, VMCS_GUEST_IA32_EFER, 0x100);
	set_vmcs(vcpu, VMCS_GUEST_RIP, get_reg(vcpu, HV_X86_RIP)+get_vmcs(vcpu, VMCS_RO_VMEXIT_INSTR_LEN));

	// See assembly part of the test for checkpoints.
	expect_vmcall_with_value(vcpu, 0x100, false /* PG disabled =>
												 * no PFs expected */);
	expect_vmcall_with_value(vcpu, 0x1111, true /* PG now enabled */);
	expect_vmcall_with_value(vcpu, 0x2222, true);

	free(guest_pages_shadow);
	free(gdt);

    return NULL;
}

T_DECL_HV(radar61961809_guest,
	"rdar://61961809 (Unexpected guest faults with hv_vcpu_run_until, dropping out of long mode)")
{
    vm_setup();

	hv_gpaddr_t gpaddr = 0x80000000;
    pthread_t vcpu_thread = create_vcpu_thread((vcpu_entry_function)
		(((uintptr_t)radar61961809_entry & PAGE_MASK) +
			gpaddr),
		0, radar61961809_monitor, (void*)gpaddr);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	vm_cleanup();
}

static void *
superpage_2mb_backed_guest_monitor(void *arg __unused, hv_vcpuid_t vcpu)
{
    setup_protected_mode(vcpu);

    size_t guest_pages_size = round_page((uintptr_t)&hvtest_end - (uintptr_t)&hvtest_begin);

    const size_t mem_size = 2 * 1024 * 1024;

    uint8_t *guest_pages_shadow = mmap(NULL, mem_size,
                                       PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE,
                                       VM_FLAGS_SUPERPAGE_SIZE_2MB, 0);

    if (guest_pages_shadow == MAP_FAILED) {
        /* Getting a 2MB superpage is hard in practice, because memory gets fragmented
         * easily.
         * T_META_REQUIRES_REBOOT in the T_DECL helps a lot in actually getting a page,
         * but in the case that it still fails, we don't want the test to fail through
         * no fault of the hypervisor.
         */
        T_SKIP("Unable to attain a 2MB superpage. Skipping.");
    }

    bzero(guest_pages_shadow, mem_size);
    memcpy(guest_pages_shadow+0x1000, &hvtest_begin, guest_pages_size);

    T_ASSERT_EQ(hv_vm_map(guest_pages_shadow, 0x40000000, mem_size, HV_MEMORY_READ | HV_MEMORY_EXEC),
                HV_SUCCESS, "map guest memory");

    expect_vmcall_with_value(vcpu, 0x23456, false);

    munmap(guest_pages_shadow, mem_size);

    return NULL;
}

T_DECL_HV(superpage_2mb_backed_guest, "guest backed by a 2MB superpage",
       T_META_REQUIRES_REBOOT(true)) // Helps actually getting a superpage
{
    vm_setup();

    pthread_t vcpu_thread = create_vcpu_thread((vcpu_entry_function)
                                               (((uintptr_t)simple_protected_mode_vcpu_entry & PAGE_MASK) +
                                                0x40000000 + 0x1000),
                                               0, superpage_2mb_backed_guest_monitor, 0);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	vm_cleanup();
}

static void *
save_restore_regs_monitor(void *arg __unused, hv_vcpuid_t vcpu)
{

    setup_long_mode(vcpu);

    uint64_t rsp = get_reg(vcpu, HV_X86_RSP);

    set_reg(vcpu, HV_X86_RAX, 0x0101010101010101);
    set_reg(vcpu, HV_X86_RBX, 0x0202020202020202);
    set_reg(vcpu, HV_X86_RCX, 0x0303030303030303);
    set_reg(vcpu, HV_X86_RDX, 0x0404040404040404);
    set_reg(vcpu, HV_X86_RSI, 0x0505050505050505);
    set_reg(vcpu, HV_X86_RDI, 0x0606060606060606);

    set_reg(vcpu, HV_X86_RBP, 0x0707070707070707);

    set_reg(vcpu, HV_X86_R8, 0x0808080808080808);
    set_reg(vcpu, HV_X86_R9, 0x0909090909090909);
    set_reg(vcpu, HV_X86_R10, 0x0a0a0a0a0a0a0a0a);
    set_reg(vcpu, HV_X86_R11, 0x0b0b0b0b0b0b0b0b);
    set_reg(vcpu, HV_X86_R12, 0x0c0c0c0c0c0c0c0c);
    set_reg(vcpu, HV_X86_R13, 0x0d0d0d0d0d0d0d0d);
    set_reg(vcpu, HV_X86_R14, 0x0e0e0e0e0e0e0e0e);
    set_reg(vcpu, HV_X86_R15, 0x0f0f0f0f0f0f0f0f);

    // invalid selectors: ok as long as we don't try to use them
    set_reg(vcpu, HV_X86_DS, 0x1010);
    set_reg(vcpu, HV_X86_ES, 0x2020);
    set_reg(vcpu, HV_X86_FS, 0x3030);
    set_reg(vcpu, HV_X86_GS, 0x4040);

    expect_vmcall_with_value(vcpu, (uint64_t)~0x0101010101010101LL, true);

    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RSP), rsp-8, "check if push happened");

    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RAX), (uint64_t)~0x0101010101010101LL, "check if RAX negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RBX), (uint64_t)~0x0202020202020202LL, "check if RBX negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RCX), (uint64_t)~0x0303030303030303LL, "check if RCX negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RDX), (uint64_t)~0x0404040404040404LL, "check if RDX negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RSI), (uint64_t)~0x0505050505050505LL, "check if RSI negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RDI), (uint64_t)~0x0606060606060606LL, "check if RDI negated");

    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RBP), (uint64_t)~0x0707070707070707LL, "check if RBP negated");

    T_ASSERT_EQ(get_reg(vcpu, HV_X86_R8), (uint64_t)~0x0808080808080808LL, "check if R8 negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_R9), (uint64_t)~0x0909090909090909LL, "check if R9 negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_R10), (uint64_t)~0x0a0a0a0a0a0a0a0aLL, "check if R10 negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_R11), (uint64_t)~0x0b0b0b0b0b0b0b0bLL, "check if R11 negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_R12), (uint64_t)~0x0c0c0c0c0c0c0c0cLL, "check if R12 negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_R13), (uint64_t)~0x0d0d0d0d0d0d0d0dLL, "check if R13 negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_R14), (uint64_t)~0x0e0e0e0e0e0e0e0eLL, "check if R14 negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_R15), (uint64_t)~0x0f0f0f0f0f0f0f0fLL, "check if R15 negated");

    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RAX), (uint64_t)~0x0101010101010101LL, "check if RAX negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RBX), (uint64_t)~0x0202020202020202LL, "check if RBX negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RCX), (uint64_t)~0x0303030303030303LL, "check if RCX negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RDX), (uint64_t)~0x0404040404040404LL, "check if RDX negated");

    // Cannot set selector to arbitrary value from the VM, but we have the RPL field to play with
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_DS), 1ULL, "check if DS == 1");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_ES), 2ULL, "check if ES == 2");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_FS), 3ULL, "check if FS == 3");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_GS), 1ULL, "check if GS == 1");

    expect_vmcall_with_value(vcpu, (uint64_t)~0x0101010101010101LL, true);

    T_ASSERT_EQ(get_reg(vcpu, HV_X86_RSP), rsp-16, "check if push happened again");

    return NULL;
}

T_DECL_HV(save_restore_regs, "check if general purpose and segment registers are properly saved and restored")
{
    vm_setup();

    pthread_t vcpu_thread = create_vcpu_thread(save_restore_regs_entry, 0x10000, save_restore_regs_monitor, 0);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	vm_cleanup();
}

static void *
save_restore_debug_regs_monitor(void *arg __unused, hv_vcpuid_t vcpu)
{

    setup_long_mode(vcpu);

    set_reg(vcpu, HV_X86_RAX, 0x0101010101010101);

    set_reg(vcpu, HV_X86_DR0, 0x1111111111111111);
    set_reg(vcpu, HV_X86_DR1, 0x2222222222222222);
    set_reg(vcpu, HV_X86_DR2, 0x3333333333333333);
    set_reg(vcpu, HV_X86_DR3, 0x4444444444444444);

    // debug status and control regs (some bits are reserved, one other bit would generate an exception)
    const uint64_t dr6_force_clear = 0xffffffff00001000ULL;
    const uint64_t dr6_force_set = 0xffff0ff0ULL;
    const uint64_t dr7_force_clear = 0xffffffff0000f000ULL;
    const uint64_t dr7_force_set = 0x0400ULL;

    set_reg(vcpu, HV_X86_DR6, (0x5555555555555555ULL | dr6_force_set) & ~(dr6_force_clear));
    set_reg(vcpu, HV_X86_DR7, (0x5555555555555555ULL | dr7_force_set) & ~(dr7_force_clear));

    expect_vmcall_with_value(vcpu, ~0x0101010101010101ULL, true);

    T_ASSERT_EQ(get_reg(vcpu, HV_X86_DR0), (uint64_t)~0x1111111111111111LL, "check if DR0 negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_DR1), (uint64_t)~0x2222222222222222LL, "check if DR1 negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_DR2), (uint64_t)~0x3333333333333333LL, "check if DR2 negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_DR3), (uint64_t)~0x4444444444444444LL, "check if DR3 negated");

    T_ASSERT_EQ(get_reg(vcpu, HV_X86_DR6), (0xaaaaaaaaaaaaaaaaULL | dr6_force_set) & ~(dr6_force_clear), "check if DR6 negated");
    T_ASSERT_EQ(get_reg(vcpu, HV_X86_DR7), (0xaaaaaaaaaaaaaaaaULL | dr7_force_set) & ~(dr7_force_clear), "check if DR7 negated");

    expect_vmcall_with_value(vcpu, 0x0101010101010101LL, true);

    return NULL;
}

T_DECL_HV(save_restore_debug_regs, "check if debug registers are properly saved and restored")
{
    vm_setup();

    pthread_t vcpu_thread = create_vcpu_thread(save_restore_debug_regs_entry, 0x10000, save_restore_debug_regs_monitor, 0);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	vm_cleanup();
}

#define T_NATIVE_MSR(msr)

static void *
native_msr_monitor(void *arg __unused, hv_vcpuid_t vcpu)
{
    const uint32_t msrs[] = {
        MSR_IA32_STAR,
        MSR_IA32_LSTAR,
        MSR_IA32_CSTAR,
        MSR_IA32_FMASK,
        MSR_IA32_KERNEL_GS_BASE,
        MSR_IA32_TSC,
        MSR_IA32_TSC_AUX,

        MSR_IA32_SYSENTER_CS,
        MSR_IA32_SYSENTER_ESP,
        MSR_IA32_SYSENTER_EIP,
        MSR_IA32_FS_BASE,
        MSR_IA32_GS_BASE,
    };
    const int msr_count = sizeof(msrs)/sizeof(uint32_t);

    setup_long_mode(vcpu);

    for (int i = 0; i < msr_count; i++) {
        T_ASSERT_EQ(hv_vcpu_enable_native_msr(vcpu, msrs[i], true), HV_SUCCESS, "enable native MSR %x", msrs[i]);
    }

    expect_vmcall_with_value(vcpu, 0x23456, true);

    return NULL;
}

T_DECL_HV(native_msr_clobber, "enable and clobber native MSRs in the guest")
{
    vm_setup();

    pthread_t vcpu_thread = create_vcpu_thread(native_msr_vcpu_entry, 0x10000, native_msr_monitor, 0);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	vm_cleanup();
}

static void *
radar60691363_monitor(void *arg __unused, hv_vcpuid_t vcpu)
{
    setup_long_mode(vcpu);

    uint64_t proc2_cap = get_cap(HV_VMX_CAP_PROCBASED2);
	set_vmcs(vcpu, VMCS_CTRL_CPU_BASED2, canonicalize(CPU_BASED2_VMCS_SHADOW, proc2_cap));

	T_ASSERT_EQ(hv_vmx_vcpu_set_shadow_access(vcpu, VMCS_GUEST_ES,
			HV_SHADOW_VMCS_READ | HV_SHADOW_VMCS_WRITE), HV_SUCCESS,
		"enable VMCS_GUEST_ES shadow access");
	T_ASSERT_EQ(hv_vmx_vcpu_write_shadow_vmcs(vcpu, VMCS_GUEST_ES, 0x1234), HV_SUCCESS,
		"set VMCS_GUEST_ES in shadow");

	T_ASSERT_EQ(hv_vmx_vcpu_set_shadow_access(vcpu, VMCS_RO_EXIT_QUALIFIC,
			HV_SHADOW_VMCS_READ | HV_SHADOW_VMCS_WRITE), HV_SUCCESS,
		"enable VMCS_RO_EXIT_QUALIFIC shadow access");
	T_ASSERT_EQ(hv_vmx_vcpu_write_shadow_vmcs(vcpu, VMCS_RO_EXIT_QUALIFIC, 0x111), HV_SUCCESS,
		"set VMCS_RO_EXIT_QUALIFIC in shadow");

	T_ASSERT_EQ(hv_vmx_vcpu_set_shadow_access(vcpu, VMCS_RO_IO_RCX,
			HV_SHADOW_VMCS_READ | HV_SHADOW_VMCS_WRITE), HV_SUCCESS,
		"enable VMCS_RO_IO_RCX shadow access");
	T_ASSERT_EQ(hv_vmx_vcpu_write_shadow_vmcs(vcpu, VMCS_RO_IO_RCX, 0x2323), HV_SUCCESS,
		"set VMCS_RO_IO_RCX in shadow");

    expect_vmcall_with_value(vcpu, 0x1234, true);
	expect_vmcall_with_value(vcpu, 0x111, true);
	expect_vmcall_with_value(vcpu, 0x2323, true);

	expect_vmcall_with_value(vcpu, 0x4567, true);

	uint64_t value;
	T_ASSERT_EQ(hv_vmx_vcpu_read_shadow_vmcs(vcpu, VMCS_GUEST_ES, &value), HV_SUCCESS,
		"read updated VMCS_GUEST_ES in shadow");
	T_ASSERT_EQ(value, 0x9191LL, "VMCS_GUEST_ES value is updated");
	T_ASSERT_EQ(hv_vmx_vcpu_read_shadow_vmcs(vcpu, VMCS_RO_EXIT_QUALIFIC, &value), HV_SUCCESS,
		"read updated VMCS_RO_EXIT_QUALIFIC in shadow");
	T_ASSERT_EQ(value, 0x9898LL, "VMCS_RO_EXIT_QUALIFIC value is updated");
	T_ASSERT_EQ(hv_vmx_vcpu_read_shadow_vmcs(vcpu, VMCS_RO_IO_RCX, &value), HV_SUCCESS,
		"read updated VMCS_RO_IO_RCX in shadow");
	T_ASSERT_EQ(value, 0x7979LL, "VMCS_RO_IO_RCX value is updated");

	// This must not work.
	T_ASSERT_EQ(hv_vmx_vcpu_set_shadow_access(vcpu, VMCS_CTRL_EPTP,
			HV_SHADOW_VMCS_READ | HV_SHADOW_VMCS_WRITE), HV_SUCCESS,
		"enable VMCS_CTRL_EPTP shadow access");
	T_ASSERT_EQ(hv_vmx_vcpu_read_vmcs(vcpu, VMCS_CTRL_EPTP, &value), HV_BAD_ARGUMENT,
		"accessing EPTP in ordinary VMCS fails");

    return NULL;
}

T_DECL_HV(radar60691363, "rdar://60691363 (SEED: Web: Allow shadowing of read only VMCS fields)")
{
	vm_setup();

	uint64_t proc2_cap = get_cap(HV_VMX_CAP_PROCBASED2);

	if (!(proc2_cap & ((uint64_t)CPU_BASED2_VMCS_SHADOW << 32))) {
		T_SKIP("Device does not support shadow VMCS, skipping.");
	}

	pthread_t vcpu_thread = create_vcpu_thread(radar60691363_entry, 0x10000, radar60691363_monitor, 0);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	vm_cleanup();
}

T_DECL_HV(radar63641279, "rdar://63641279 (Evaluate \"no SMT\" scheduling option/sidechannel security mitigation for Hypervisor.framework VMs)",
    T_META_OWNER("mphalan"))
{
	const uint64_t ALL_MITIGATIONS =
	    HV_VM_MITIGATION_A_ENABLE |
	    HV_VM_MITIGATION_B_ENABLE |
	    HV_VM_MITIGATION_C_ENABLE |
	    HV_VM_MITIGATION_D_ENABLE |
	    HV_VM_MITIGATION_E_ENABLE; // NO_SMT

	T_SETUPBEGIN;

	if (hv_support() < 1) {
		T_SKIP("Running on non-HV target, skipping...");
		return;
	}

	create_vm(HV_VM_SPECIFY_MITIGATIONS | ALL_MITIGATIONS);

	T_SETUPEND;

	pthread_t vcpu_thread = create_vcpu_thread(
	    (vcpu_entry_function) (((uintptr_t)simple_real_mode_vcpu_entry & PAGE_MASK) + 0x1000),
	    0, simple_real_mode_monitor, 0);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	vm_cleanup();
}

// Get the number of  messages waiting for the specified port
static int
get_count(mach_port_t port)
{
	int count;

	count = 0;
	while (true) {
		hv_ion_message_t msg = {
			.header.msgh_size = sizeof (msg),
			.header.msgh_local_port = port,
		};

		kern_return_t ret = mach_msg(&msg.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
		    0, sizeof (msg), port, 0, MACH_PORT_NULL);

		if (ret != MACH_MSG_SUCCESS) {
			break;
		}

		T_QUIET; T_ASSERT_TRUE(msg.addr == 0xab || msg.addr == 0xcd || msg.addr == 0xef,
		    "address is 0xab, 0xcd or 0xef");
		T_QUIET; T_ASSERT_EQ(msg.value, 0xaaULL, "value written is 0xaa");
		T_QUIET; T_ASSERT_TRUE(msg.size == 1 || msg.size == 4, "size is 1 or 4");

		count++;
	}

	return count;
}

static void *
pio_monitor(void *arg, hv_vcpuid_t vcpu)
{

	size_t guest_pages_size = round_page((uintptr_t)&hvtest_end - (uintptr_t)&hvtest_begin);
	const size_t mem_size = 1 * 1024 * 1024;
	uint8_t *guest_pages_shadow = valloc(mem_size);
	int handle_io_count = 0;
	uint64_t exit_reason = 0;

	setup_real_mode(vcpu);

	bzero(guest_pages_shadow, mem_size);
	memcpy(guest_pages_shadow+0x1000, &hvtest_begin, guest_pages_size);

	T_ASSERT_EQ(hv_vm_map(guest_pages_shadow, 0x0, mem_size, HV_MEMORY_READ | HV_MEMORY_EXEC), HV_SUCCESS,
	    "map guest memory");

	while (true) {
		run_vcpu(vcpu);
		exit_reason = get_vmcs(vcpu, VMCS_RO_EXIT_REASON);

		if (exit_reason == VMX_REASON_VMCALL) {
			break;
		}

		if (exit_reason == VMX_REASON_IRQ) {
			continue;
		}

		if (exit_reason == VMX_REASON_EPT_VIOLATION && !hv_use_run_until) {
			continue;
		}

		T_QUIET; T_ASSERT_EQ(exit_reason, (uint64_t)VMX_REASON_IO, "exit reason is IO");

		union {
			struct {
				uint64_t io_size:3;
				uint64_t io_dirn:1;
				uint64_t io_string:1;
				uint64_t io_rep:1;
				uint64_t io_encoding:1;
				uint64_t __io_resvd0:9;
				uint64_t io_port:16;
				uint64_t __io_resvd1:32;
			} io;
			uint64_t reg64;
		} info = {
			.reg64 = get_vmcs(vcpu, VMCS_RO_EXIT_QUALIFIC),
		};

		T_QUIET; T_ASSERT_EQ(info.io.io_port, 0xefULL, "exit is a port IO on 0xef");

		handle_io_count++;

		set_vmcs(vcpu, VMCS_GUEST_RIP, get_reg(vcpu, HV_X86_RIP) + get_vmcs(vcpu, VMCS_RO_VMEXIT_INSTR_LEN));
	}

	free(guest_pages_shadow);

	*((int *)arg) = handle_io_count;

	return NULL;
}

T_DECL_HV(pio_notifier_arguments, "test adding and removing port IO notifiers", T_META_OWNER("mphalan"))
{
	mach_port_t notify_port = MACH_PORT_NULL;
	kern_return_t kret = KERN_FAILURE;
	hv_return_t hret = HV_ERROR;

	T_SETUPBEGIN;

	/* Setup notification port. */
	kret = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE,
	    &notify_port);
	T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "allocate mach port");

	kret = mach_port_insert_right(mach_task_self(), notify_port, notify_port,
	   MACH_MSG_TYPE_MAKE_SEND);
	T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "insert send right");

	/* Setup VM */
	vm_setup();

	T_SETUPEND;

	/* Add with bad size. */
	hret = hv_vm_add_pio_notifier(0xab, 7, 1, notify_port, HV_ION_NONE);
	T_ASSERT_NE(hret, HV_SUCCESS, "adding notifier with bad size");

	/* Add with bad data. */
	hret = hv_vm_add_pio_notifier(0xab, 1, UINT16_MAX, notify_port, HV_ION_NONE);
	T_ASSERT_NE(hret, HV_SUCCESS, "adding notifier with bad data");

	/* Add with bad mach port. */
	hret = hv_vm_add_pio_notifier(0xab, 1, UINT16_MAX, MACH_PORT_NULL, HV_ION_NONE);
	T_ASSERT_NE(hret, HV_SUCCESS, "adding notifier with bad port");

	/* Add with bad flags. */
	hret = hv_vm_add_pio_notifier(0xab, 1, 1, notify_port, 0xffff);
	T_ASSERT_NE(hret, HV_SUCCESS, "adding notifier with bad flags");

	/* Remove when none are installed. */
	hret = hv_vm_remove_pio_notifier(0xab, 1, 1, notify_port, HV_ION_NONE);
	T_ASSERT_NE(hret, HV_SUCCESS, "removing a non-existent notifier");

	/* Add duplicate. */
	hret = hv_vm_add_pio_notifier(0xab, 1, 1, notify_port, HV_ION_NONE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "adding notifier");
	hret = hv_vm_add_pio_notifier(0xab, 1, 1, notify_port, HV_ION_NONE);
	T_ASSERT_NE(hret, HV_SUCCESS, "adding duplicate notifier");
	hret = hv_vm_remove_pio_notifier(0xab, 1, 1, notify_port, HV_ION_NONE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "removing notifier");

	/* Add then remove. */
	hret = hv_vm_add_pio_notifier(0xab, 1, 1, notify_port, HV_ION_NONE);
	T_ASSERT_EQ(hret, HV_SUCCESS, "adding notifier");
	hret = hv_vm_remove_pio_notifier(0xab, 1, 1, notify_port, HV_ION_NONE);
	T_ASSERT_EQ(hret, HV_SUCCESS, "removing notifier");

	/* Add two, remove in reverse order. */
	hret = hv_vm_add_pio_notifier(0xab, 1, 1, notify_port, HV_ION_NONE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "adding 1st notifier");
	hret = hv_vm_add_pio_notifier(0xab, 2, 1, notify_port, HV_ION_NONE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "adding 2nd notifier");
	hret = hv_vm_remove_pio_notifier(0xab, 2, 1, notify_port, HV_ION_NONE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "removing 2nd notifier");
	hret = hv_vm_remove_pio_notifier(0xab, 1, 1, notify_port, HV_ION_NONE);
	T_ASSERT_EQ(hret, HV_SUCCESS, "removing notifier in reverse order");

	/* Add with ANY_SIZE and remove. */
	hret = hv_vm_add_pio_notifier(0xab, 0, 1, notify_port, HV_ION_ANY_SIZE);
	T_ASSERT_EQ(hret, HV_SUCCESS, "adding notifier with ANY_SIZE");
	hret = hv_vm_remove_pio_notifier(0xab, 0, 1, notify_port, HV_ION_ANY_SIZE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "removing notifier with ANY_SIZE");

	/* Add with ANY_VALUE and remove. */
	hret = hv_vm_add_pio_notifier(0xab, 1, 1, notify_port, HV_ION_ANY_VALUE);
	T_ASSERT_EQ(hret, HV_SUCCESS, "adding notifier with ANY_VALUE");
	hret = hv_vm_remove_pio_notifier(0xab, 1, 1, notify_port, HV_ION_ANY_VALUE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "removing notifier with ANY_VALUE");

	vm_cleanup();

	mach_port_mod_refs(mach_task_self(), notify_port, MACH_PORT_RIGHT_RECEIVE, -1);
}

T_DECL_HV(pio_notifier_bad_port, "test port IO notifiers when the port is destroyed/deallocated/has no receive right",
    T_META_OWNER("mphalan"))
{
	pthread_t vcpu_thread;
	mach_port_t notify_port = MACH_PORT_NULL;
	int handle_io_count = 0;
	kern_return_t kret = KERN_FAILURE;
	hv_return_t hret = HV_ERROR;

	/* Setup VM */
	vm_setup();

	/*
	 * Test that nothing bad happens when the notification port is
	 * added and mach_port_destroy() is called.
	 */

	/* Add a notification port. */
	kret = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE,
	    &notify_port);
	T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "allocate mach port");

	/* Insert send right. */
	kret = mach_port_insert_right(mach_task_self(), notify_port, notify_port,
	   MACH_MSG_TYPE_MAKE_SEND);
	T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "insert send right");

	/* All port writes to 0xef. */
	hret = hv_vm_add_pio_notifier(0xef, 0, 0, notify_port,
	    HV_ION_ANY_VALUE | HV_ION_ANY_SIZE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "adding notifier for all writes "
	    "to port 0xef");

	/* After adding, destroy the port. */
	kret = mach_port_destroy(mach_task_self(), notify_port);
	T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "destroying notify port");

	vcpu_thread = create_vcpu_thread((vcpu_entry_function)
	    (((uintptr_t)pio_entry_basic & PAGE_MASK) + 0x1000), 0, pio_monitor,
	    &handle_io_count);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	/* Expect the messages to be lost. */
	T_ASSERT_EQ(0, handle_io_count, "0 expected IO exits when port destroyed");

	hret = hv_vm_remove_pio_notifier(0xef, 0, 0, notify_port, HV_ION_ANY_SIZE | HV_ION_ANY_VALUE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "removing notifier for all writes to port 0xef");

	vm_cleanup();


	vm_setup();
	/*
	 * Test that nothing bad happens when the notification port is added and
	 * mach_port_mod_refs() is called.
	 */

	/* Add a notification port. */
	kret = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE,
	    &notify_port);
	T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "allocate mach port");

	/* Insert send right. */
	kret = mach_port_insert_right(mach_task_self(), notify_port, notify_port,
	   MACH_MSG_TYPE_MAKE_SEND);
	T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "insert send right");

	/* All port writes to 0xef. */
	hret = hv_vm_add_pio_notifier(0xef, 0, 0, notify_port,
	    HV_ION_ANY_VALUE | HV_ION_ANY_SIZE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "adding notifier for all writes "
	    "to port 0xef");

	/* After adding, remove receive right. */
	mach_port_mod_refs(mach_task_self(), notify_port, MACH_PORT_RIGHT_RECEIVE, -1);
	T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "removing receive right");

	vcpu_thread = create_vcpu_thread((vcpu_entry_function)
	    (((uintptr_t)pio_entry_basic & PAGE_MASK) + 0x1000), 0, pio_monitor,
	    &handle_io_count);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	/* Expect messages to be lost. */
	T_ASSERT_EQ(0, handle_io_count, "0 expected IO exits when receive right removed");

	hret = hv_vm_remove_pio_notifier(0xef, 0, 0, notify_port, HV_ION_ANY_SIZE | HV_ION_ANY_VALUE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "removing notifier for all writes to port 0xef");

	vm_cleanup();


	vm_setup();
	/*
	 * Test that nothing bad happens when the notification port is added and
	 * mach_port_deallocate() is called.
	 */

	/* Add a notification port. */
	kret = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE,
	    &notify_port);
	T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "allocate mach port");

	/* Insert send right. */
	kret = mach_port_insert_right(mach_task_self(), notify_port, notify_port,
	   MACH_MSG_TYPE_MAKE_SEND);
	T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "insert send right");

	/* All port writes to 0xef. */
	hret = hv_vm_add_pio_notifier(0xef, 0, 0, notify_port,
	    HV_ION_ANY_VALUE | HV_ION_ANY_SIZE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "adding notifier for all writes "
	    "to port 0xef");

	/* After adding, call mach_port_deallocate(). */
	kret = mach_port_deallocate(mach_task_self(), notify_port);
	T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "destroying notify port");

	vcpu_thread = create_vcpu_thread((vcpu_entry_function)
	    (((uintptr_t)pio_entry_basic & PAGE_MASK) + 0x1000), 0, pio_monitor,
	    &handle_io_count);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	/* Expect messages to be lost. */
	T_ASSERT_EQ(0, handle_io_count, "0 expected IO exits when port deallocated");

	hret = hv_vm_remove_pio_notifier(0xef, 0, 0, notify_port, HV_ION_ANY_SIZE | HV_ION_ANY_VALUE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "removing notifier for all writes to port 0xef");

	vm_cleanup();
}

T_DECL_HV(pio_notifier, "test port IO notifiers", T_META_OWNER("mphalan"))
{
	#define MACH_PORT_COUNT 4
	mach_port_t notify_port[MACH_PORT_COUNT] = { MACH_PORT_NULL };
	int handle_io_count = 0;
	kern_return_t kret = KERN_FAILURE;
	hv_return_t hret = HV_ERROR;

	T_SETUPBEGIN;

	/* Setup notification ports. */
	for (int i = 0; i  < MACH_PORT_COUNT; i++) {
		kret = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE,
		    &notify_port[i]);
		T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "allocate mach port");

		kret = mach_port_insert_right(mach_task_self(), notify_port[i], notify_port[i],
		   MACH_MSG_TYPE_MAKE_SEND);
		T_QUIET; T_ASSERT_MACH_SUCCESS(kret, "insert send right");
	}
	/* Setup VM */
	vm_setup();

	T_SETUPEND;

	/* Test that messages are properly sent to mach port notifiers. */

	/* One for all port writes to 0xab. */
	hret = hv_vm_add_pio_notifier(0xab, 0, 0, notify_port[0],
	    HV_ION_ANY_VALUE | HV_ION_ANY_SIZE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "adding notifier for all writes "
	    "to port 0xab");

	/* One for for 4 byte writes of 0xaa. */
	hret = hv_vm_add_pio_notifier(0xab, 4, 0xaa, notify_port[1], HV_ION_NONE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "adding notifier for 4 byte writes "
	    "to port 0xab");

	/* One for all writes to 0xcd (ignoring queue full errors). */
	hret = hv_vm_add_pio_notifier(0xcd, 0, 0, notify_port[2],
	    HV_ION_ANY_SIZE | HV_ION_ANY_VALUE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "adding notifier for all writes "
	    "to port 0xcd, ignoring if the queue fills");

	/* One for writes to 0xef asking for exits when the queue is full. */
	hret = hv_vm_add_pio_notifier(0xef, 0, 0, notify_port[3],
	    HV_ION_ANY_SIZE | HV_ION_ANY_VALUE | HV_ION_EXIT_FULL);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "adding notifier for all writes "
	    "to port 0xef, not ignoring if the queue fills");

	pthread_t vcpu_thread = create_vcpu_thread((vcpu_entry_function)
	    (((uintptr_t)pio_entry & PAGE_MASK) + 0x1000), 0, pio_monitor,
	    &handle_io_count);
	T_ASSERT_POSIX_SUCCESS(pthread_join(vcpu_thread, NULL), "join vcpu");

	/* Expect messages to be waiting. */
	T_ASSERT_EQ(4, get_count(notify_port[0]), "expected 4 messages");
	T_ASSERT_EQ(1, get_count(notify_port[1]), "expected 1 messages");
	T_ASSERT_EQ(10, get_count(notify_port[2]) + handle_io_count, "expected IO exits");
	T_ASSERT_EQ(5, get_count(notify_port[3]), "expected 5 messages");

	hret = hv_vm_remove_pio_notifier(0xab, 0, 0, notify_port[0], HV_ION_ANY_SIZE | HV_ION_ANY_VALUE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "removing notifier for all writes to port 0xab");

	hret = hv_vm_remove_pio_notifier(0xab, 4, 0xaa, notify_port[1], HV_ION_NONE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "removing notifier for 4 byte writes "
	    "to port 0xab");

	hret = hv_vm_remove_pio_notifier(0xcd, 0, 0, notify_port[2], HV_ION_ANY_SIZE | HV_ION_ANY_VALUE);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "removing notifier for all writes "
	    "to port 0xcd, ignoring if the queue fills");

	hret = hv_vm_remove_pio_notifier(0xef, 0, 0, notify_port[3], HV_ION_ANY_SIZE | HV_ION_ANY_VALUE | HV_ION_EXIT_FULL);
	T_QUIET; T_ASSERT_EQ(hret, HV_SUCCESS, "removing notifier for all writes "
	    "to port 0xef, not ignoring if the queue fills");

	vm_cleanup();

	for (int i = 0; i < MACH_PORT_COUNT; i++) {
		mach_port_mod_refs(mach_task_self(), notify_port[i], MACH_PORT_RIGHT_RECEIVE, -1);
	}
}
