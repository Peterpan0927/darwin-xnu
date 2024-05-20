/*
 * Copyright (c) 2000-2021 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. The rights granted to you under the License
 * may not be used to create, or enable the creation or redistribution of,
 * unlawful or unlicensed copies of an Apple operating system, or to
 * circumvent, violate, or enable the circumvention or violation of, any
 * terms of an Apple operating system software license agreement.
 *
 * Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_END@
 */
/*
 * @OSF_FREE_COPYRIGHT@
 */

#include <pexpert/pexpert.h>
#include <pexpert/protos.h>
#include <pexpert/device_tree.h>
#include <kern/debug.h>

#include <libkern/section_keywords.h>

#if CONFIG_SPTM
#include <sptm/sptm_xnu.h>
#endif

#if defined(__arm64__)
SECURITY_READ_ONLY_LATE(static uint32_t) gPEKernelConfigurationBitmask;
#else
static uint32_t gPEKernelConfigurationBitmask;
#endif

int32_t gPESerialBaud = -1;

int debug_cpu_performance_degradation_factor = 1;

void
pe_init_debug(void)
{
	boolean_t boot_arg_value;

	gPEKernelConfigurationBitmask = 0;

	if (!PE_parse_boot_argn("assertions", &boot_arg_value, sizeof(boot_arg_value))) {
#if MACH_ASSERT
		boot_arg_value = TRUE;
#else
		boot_arg_value = FALSE;
#endif
	}
	gPEKernelConfigurationBitmask |= (boot_arg_value ? kPEICanHasAssertions : 0);

	if (!PE_parse_boot_argn("statistics", &boot_arg_value, sizeof(boot_arg_value))) {
#if DEVELOPMENT || DEBUG
		boot_arg_value = TRUE;
#else
		boot_arg_value = FALSE;
#endif
	}
	gPEKernelConfigurationBitmask |= (boot_arg_value ? kPEICanHasStatistics : 0);

#if SECURE_KERNEL
	boot_arg_value = FALSE;
#else
	if (!PE_i_can_has_debugger(NULL)) {
		boot_arg_value = FALSE;
	} else if (!PE_parse_boot_argn("diagnostic_api", &boot_arg_value, sizeof(boot_arg_value))) {
		boot_arg_value = TRUE;
	}
#endif
	gPEKernelConfigurationBitmask |= (boot_arg_value ? kPEICanHasDiagnosticAPI : 0);


	int factor = 1;
	boolean_t have_bootarg = PE_parse_boot_argn("cpu-factor", &factor, sizeof(factor));
	if (have_bootarg) {
		debug_cpu_performance_degradation_factor = factor;
	} else {
		DTEntry         root;
		if (SecureDTLookupEntry(NULL, "/", &root) == kSuccess) {
			void const *prop = NULL;
			uint32_t size = 0;
			if (SecureDTGetProperty(root, "target-is-fpga", &prop, &size) == kSuccess) {
				debug_cpu_performance_degradation_factor = 10;
			}
		}
	}
}

void
PE_enter_debugger(const char *cause)
{
	if (debug_boot_arg & DB_NMI) {
		Debugger(cause);
	}
}

uint32_t
PE_i_can_has_kernel_configuration(void)
{
	return gPEKernelConfigurationBitmask;
}

/* extern references */
extern void vcattach(void);

/* Globals */
typedef void (*PE_putc_t)(char);

#if XNU_TARGET_OS_OSX
PE_putc_t PE_putc;
#else
SECURITY_READ_ONLY_LATE(PE_putc_t) PE_putc;
#endif

extern void console_write_char(char);

void
PE_init_printf(boolean_t vm_initialized)
{
	if (!vm_initialized) {
		PE_putc = console_write_char;
	} else {
		vcattach();
	}
}

uint32_t
PE_get_random_seed(unsigned char *dst_random_seed, uint32_t request_size)
{
	uint32_t        size = 0;
	uint8_t         *random_seed;

#if CONFIG_SPTM
	char const prefix[] = "randseed";
	size_t const prefix_len = sizeof(prefix) - 1;

	extern const sptm_bootstrap_args_xnu_t *SPTMArgs;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcast-qual"
	/* Legal, because we are not locked down yet. */
	random_seed = (uint8_t*)&SPTMArgs->random_seed;
#pragma GCC diagnostic pop

	size = (uint32_t)SPTMArgs->random_seed_length;

	if (size < prefix_len) {
		panic("random seed field too short");
	}

	if (memcmp(random_seed, prefix, prefix_len) != 0) {
		panic("random seed corrupted");
	}

	random_seed += prefix_len;
	size -= prefix_len;
#else /* CONFIG_SPTM */
	DTEntry         entryP;

	if ((SecureDTLookupEntry(NULL, "/chosen", &entryP) != kSuccess)
	    || (SecureDTGetProperty(entryP, "random-seed",
	    /* casting away the const is permissible here, since
	     * this function runs before lockdown. */
	    (const void **)(uintptr_t)&random_seed, &size) != kSuccess)) {
		random_seed = NULL;
		size = 0;
	}
#endif /* CONFIG_SPTM */

	if (random_seed == NULL || size == 0) {
		panic("no random seed");
	}

	unsigned char *src_random_seed;
	unsigned int i;
	unsigned int null_count = 0;

	src_random_seed = (unsigned char *)random_seed;

	if (size > request_size) {
		size = request_size;
	}

	/*
	 * Copy from the device tree into the destination buffer,
	 * count the number of null bytes and null out the device tree.
	 */
	for (i = 0; i < size; i++, src_random_seed++, dst_random_seed++) {
		*dst_random_seed = *src_random_seed;
		null_count += *src_random_seed == (unsigned char)0;
		*src_random_seed = (unsigned char)0;
	}
	if (null_count == size) {
		/* All nulls is no seed - return 0 */
		size = 0;
	}

	return size;
}

unsigned char appleClut8[256 * 3] = {
// 00
	0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xCC, 0xFF, 0xFF, 0x99, 0xFF, 0xFF, 0x66,
	0xFF, 0xFF, 0x33, 0xFF, 0xFF, 0x00, 0xFF, 0xCC, 0xFF, 0xFF, 0xCC, 0xCC,
	0xFF, 0xCC, 0x99, 0xFF, 0xCC, 0x66, 0xFF, 0xCC, 0x33, 0xFF, 0xCC, 0x00,
	0xFF, 0x99, 0xFF, 0xFF, 0x99, 0xCC, 0xFF, 0x99, 0x99, 0xFF, 0x99, 0x66,
// 10
	0xFF, 0x99, 0x33, 0xFF, 0x99, 0x00, 0xFF, 0x66, 0xFF, 0xFF, 0x66, 0xCC,
	0xFF, 0x66, 0x99, 0xFF, 0x66, 0x66, 0xFF, 0x66, 0x33, 0xFF, 0x66, 0x00,
	0xFF, 0x33, 0xFF, 0xFF, 0x33, 0xCC, 0xFF, 0x33, 0x99, 0xFF, 0x33, 0x66,
	0xFF, 0x33, 0x33, 0xFF, 0x33, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0xCC,
// 20
	0xFF, 0x00, 0x99, 0xFF, 0x00, 0x66, 0xFF, 0x00, 0x33, 0xFF, 0x00, 0x00,
	0xCC, 0xFF, 0xFF, 0xCC, 0xFF, 0xCC, 0xCC, 0xFF, 0x99, 0xCC, 0xFF, 0x66,
	0xCC, 0xFF, 0x33, 0xCC, 0xFF, 0x00, 0xCC, 0xCC, 0xFF, 0xCC, 0xCC, 0xCC,
	0xCC, 0xCC, 0x99, 0xCC, 0xCC, 0x66, 0xCC, 0xCC, 0x33, 0xCC, 0xCC, 0x00,
// 30
	0xCC, 0x99, 0xFF, 0xCC, 0x99, 0xCC, 0xCC, 0x99, 0x99, 0xCC, 0x99, 0x66,
	0xCC, 0x99, 0x33, 0xCC, 0x99, 0x00, 0xCC, 0x66, 0xFF, 0xCC, 0x66, 0xCC,
	0xCC, 0x66, 0x99, 0xCC, 0x66, 0x66, 0xCC, 0x66, 0x33, 0xCC, 0x66, 0x00,
	0xCC, 0x33, 0xFF, 0xCC, 0x33, 0xCC, 0xCC, 0x33, 0x99, 0xCC, 0x33, 0x66,
// 40
	0xCC, 0x33, 0x33, 0xCC, 0x33, 0x00, 0xCC, 0x00, 0xFF, 0xCC, 0x00, 0xCC,
	0xCC, 0x00, 0x99, 0xCC, 0x00, 0x66, 0xCC, 0x00, 0x33, 0xCC, 0x00, 0x00,
	0x99, 0xFF, 0xFF, 0x99, 0xFF, 0xCC, 0x99, 0xFF, 0x99, 0x99, 0xFF, 0x66,
	0x99, 0xFF, 0x33, 0x99, 0xFF, 0x00, 0x99, 0xCC, 0xFF, 0x99, 0xCC, 0xCC,
// 50
	0x99, 0xCC, 0x99, 0x99, 0xCC, 0x66, 0x99, 0xCC, 0x33, 0x99, 0xCC, 0x00,
	0x99, 0x99, 0xFF, 0x99, 0x99, 0xCC, 0x99, 0x99, 0x99, 0x99, 0x99, 0x66,
	0x99, 0x99, 0x33, 0x99, 0x99, 0x00, 0x99, 0x66, 0xFF, 0x99, 0x66, 0xCC,
	0x99, 0x66, 0x99, 0x99, 0x66, 0x66, 0x99, 0x66, 0x33, 0x99, 0x66, 0x00,
// 60
	0x99, 0x33, 0xFF, 0x99, 0x33, 0xCC, 0x99, 0x33, 0x99, 0x99, 0x33, 0x66,
	0x99, 0x33, 0x33, 0x99, 0x33, 0x00, 0x99, 0x00, 0xFF, 0x99, 0x00, 0xCC,
	0x99, 0x00, 0x99, 0x99, 0x00, 0x66, 0x99, 0x00, 0x33, 0x99, 0x00, 0x00,
	0x66, 0xFF, 0xFF, 0x66, 0xFF, 0xCC, 0x66, 0xFF, 0x99, 0x66, 0xFF, 0x66,
// 70
	0x66, 0xFF, 0x33, 0x66, 0xFF, 0x00, 0x66, 0xCC, 0xFF, 0x66, 0xCC, 0xCC,
	0x66, 0xCC, 0x99, 0x66, 0xCC, 0x66, 0x66, 0xCC, 0x33, 0x66, 0xCC, 0x00,
	0x66, 0x99, 0xFF, 0x66, 0x99, 0xCC, 0x66, 0x99, 0x99, 0x66, 0x99, 0x66,
	0x66, 0x99, 0x33, 0x66, 0x99, 0x00, 0x66, 0x66, 0xFF, 0x66, 0x66, 0xCC,
// 80
	0x66, 0x66, 0x99, 0x66, 0x66, 0x66, 0x66, 0x66, 0x33, 0x66, 0x66, 0x00,
	0x66, 0x33, 0xFF, 0x66, 0x33, 0xCC, 0x66, 0x33, 0x99, 0x66, 0x33, 0x66,
	0x66, 0x33, 0x33, 0x66, 0x33, 0x00, 0x66, 0x00, 0xFF, 0x66, 0x00, 0xCC,
	0x66, 0x00, 0x99, 0x66, 0x00, 0x66, 0x66, 0x00, 0x33, 0x66, 0x00, 0x00,
// 90
	0x33, 0xFF, 0xFF, 0x33, 0xFF, 0xCC, 0x33, 0xFF, 0x99, 0x33, 0xFF, 0x66,
	0x33, 0xFF, 0x33, 0x33, 0xFF, 0x00, 0x33, 0xCC, 0xFF, 0x33, 0xCC, 0xCC,
	0x33, 0xCC, 0x99, 0x33, 0xCC, 0x66, 0x33, 0xCC, 0x33, 0x33, 0xCC, 0x00,
	0x33, 0x99, 0xFF, 0x33, 0x99, 0xCC, 0x33, 0x99, 0x99, 0x33, 0x99, 0x66,
// a0
	0x33, 0x99, 0x33, 0x33, 0x99, 0x00, 0x33, 0x66, 0xFF, 0x33, 0x66, 0xCC,
	0x33, 0x66, 0x99, 0x33, 0x66, 0x66, 0x33, 0x66, 0x33, 0x33, 0x66, 0x00,
	0x33, 0x33, 0xFF, 0x33, 0x33, 0xCC, 0x33, 0x33, 0x99, 0x33, 0x33, 0x66,
	0x33, 0x33, 0x33, 0x33, 0x33, 0x00, 0x33, 0x00, 0xFF, 0x33, 0x00, 0xCC,
// b0
	0x33, 0x00, 0x99, 0x33, 0x00, 0x66, 0x33, 0x00, 0x33, 0x33, 0x00, 0x00,
	0x00, 0xFF, 0xFF, 0x00, 0xFF, 0xCC, 0x00, 0xFF, 0x99, 0x00, 0xFF, 0x66,
	0x00, 0xFF, 0x33, 0x00, 0xFF, 0x00, 0x00, 0xCC, 0xFF, 0x00, 0xCC, 0xCC,
	0x00, 0xCC, 0x99, 0x00, 0xCC, 0x66, 0x00, 0xCC, 0x33, 0x00, 0xCC, 0x00,
// c0
	0x00, 0x99, 0xFF, 0x00, 0x99, 0xCC, 0x00, 0x99, 0x99, 0x00, 0x99, 0x66,
	0x00, 0x99, 0x33, 0x00, 0x99, 0x00, 0x00, 0x66, 0xFF, 0x00, 0x66, 0xCC,
	0x00, 0x66, 0x99, 0x00, 0x66, 0x66, 0x00, 0x66, 0x33, 0x00, 0x66, 0x00,
	0x00, 0x33, 0xFF, 0x00, 0x33, 0xCC, 0x00, 0x33, 0x99, 0x00, 0x33, 0x66,
// d0
	0x00, 0x33, 0x33, 0x00, 0x33, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xCC,
	0x00, 0x00, 0x99, 0x00, 0x00, 0x66, 0x00, 0x00, 0x33, 0xEE, 0x00, 0x00,
	0xDD, 0x00, 0x00, 0xBB, 0x00, 0x00, 0xAA, 0x00, 0x00, 0x88, 0x00, 0x00,
	0x77, 0x00, 0x00, 0x55, 0x00, 0x00, 0x44, 0x00, 0x00, 0x22, 0x00, 0x00,
// e0
	0x11, 0x00, 0x00, 0x00, 0xEE, 0x00, 0x00, 0xDD, 0x00, 0x00, 0xBB, 0x00,
	0x00, 0xAA, 0x00, 0x00, 0x88, 0x00, 0x00, 0x77, 0x00, 0x00, 0x55, 0x00,
	0x00, 0x44, 0x00, 0x00, 0x22, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0xEE,
	0x00, 0x00, 0xDD, 0x00, 0x00, 0xBB, 0x00, 0x00, 0xAA, 0x00, 0x00, 0x88,
// f0
	0x00, 0x00, 0x77, 0x00, 0x00, 0x55, 0x00, 0x00, 0x44, 0x00, 0x00, 0x22,
	0x00, 0x00, 0x11, 0xEE, 0xEE, 0xEE, 0xDD, 0xDD, 0xDD, 0xBB, 0xBB, 0xBB,
	0xAA, 0xAA, 0xAA, 0x88, 0x88, 0x88, 0x77, 0x77, 0x77, 0x55, 0x55, 0x55,
	0x44, 0x44, 0x44, 0x22, 0x22, 0x22, 0x11, 0x11, 0x11, 0x00, 0x00, 0x00
};
