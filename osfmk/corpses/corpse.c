/*
 * Copyright (c) 2012-2013, 2015 Apple Inc. All rights reserved.
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
 * Corpses Overview
 * ================
 *
 * A corpse is a state of process that is past the point of its death. This means that process has
 * completed all its termination operations like releasing file descriptors, mach ports, sockets and
 * other constructs used to identify a process. For all the processes this mimics the behavior as if
 * the process has died and no longer available by any means.
 *
 * Why do we need Corpses?
 * -----------------------
 * For crash inspection we need to inspect the state and data that is associated with process so that
 * crash reporting infrastructure can build backtraces, find leaks etc. For example a crash
 *
 * Corpses functionality in kernel
 * ===============================
 * The corpse functionality is an extension of existing exception reporting mechanisms we have. The
 * exception_triage calls will try to deliver the first round of exceptions allowing
 * task/debugger/ReportCrash/launchd level exception handlers to  respond to exception. If even after
 * notification the exception is not handled, then the process begins the death operations and during
 * proc_prepareexit, we decide to create a corpse for inspection. Following is a sample run through
 * of events and data shuffling that happens when corpses is enabled.
 *
 *   * a process causes an exception during normal execution of threads.
 *   * The exception generated by either mach(e.g GUARDED_MARCHPORT) or bsd(eg SIGABORT, GUARDED_FD
 *     etc) side is passed through the exception_triage() function to follow the thread -> task -> host
 *     level exception handling system. This set of steps are same as before and allow for existing
 *     crash reporting systems (both internal and 3rd party) to catch and create reports as required.
 *   * If above exception handling returns failed (when nobody handles the notification), then the
 *     proc_prepareexit path has logic to decide to create corpse.
 *   * The task_mark_corpse function allocates userspace vm memory and attaches the information
 *     kcdata_descriptor_t to task->corpse_info field of task.
 *     - All the task's threads are marked with the "inspection" flag which signals the termination
 *       daemon to not reap them but hold until they are being inspected.
 *     - task flags t_flags reflect the corpse bit and also a PENDING_CORPSE bit. PENDING_CORPSE
 *       prevents task_terminate from stripping important data from task.
 *     - It marks all the threads to terminate and return to AST for termination.
 *     - The allocation logic takes into account the rate limiting policy of allowing only
 *       TOTAL_CORPSES_ALLOWED in flight.
 *   * The proc exit threads continues and collects required information in the allocated vm region.
 *     Once complete it marks itself for termination.
 *   * In the thread_terminate_self(), the last thread to enter will do a call to proc_exit().
 *     Following this is a check to see if task is marked for corpse notification and will
 *     invoke the the task_deliver_crash_notification().
 *   * Once EXC_CORPSE_NOTIFY is delivered, it removes the PENDING_CORPSE flag from task (and
 *     inspection flag from all its threads) and allows task_terminate to go ahead and continue
 *     the mach task termination process.
 *   * ASIDE: The rest of the threads that are reaching the thread_terminate_daemon() with the
 *     inspection flag set are just bounced to another holding queue (crashed_threads_queue).
 *     Only after the corpse notification these are pulled out from holding queue and enqueued
 *     back to termination queue
 *
 *
 * Corpse info format
 * ==================
 * The kernel (task_mark_corpse()) makes a vm allocation in the dead task's vm space (with tag
 *     VM_MEMORY_CORPSEINFO (80)). Within this memory all corpse information is saved by various
 *     subsystems like
 *   * bsd proc exit path may write down pid, parent pid, number of file descriptors etc
 *   * mach side may append data regarding ledger usage, memory stats etc
 * See detailed info about the memory structure and format in kern_cdata.h documentation.
 *
 * Configuring Corpses functionality
 * =================================
 *   boot-arg: -no_corpses disables the corpse generation. This can be added/removed without affecting
 *     any other subsystem.
 *   TOTAL_CORPSES_ALLOWED : (recompilation required) - Changing this number allows for controlling
 *     the number of corpse instances to be held for inspection before allowing memory to be reclaimed
 *     by system.
 *   CORPSEINFO_ALLOCATION_SIZE: is the default size of vm allocation. If in future there is much more
 *     data to be put in, then please re-tune this parameter.
 *
 * Debugging/Visibility
 * ====================
 *   * lldbmacros for thread and task summary are updated to show "C" flag for corpse task/threads.
 *   * there are macros to see list of threads in termination queue (dumpthread_terminate_queue)
 *     and holding queue (dumpcrashed_thread_queue).
 *   * In case of corpse creation is disabled of ignored then the system log is updated with
 *     printf data with reason.
 *
 * Limitations of Corpses
 * ======================
 *   With holding off memory for inspection, it creates vm pressure which might not be desirable
 *   on low memory devices. There are limits to max corpses being inspected at a time which is
 *   marked by TOTAL_CORPSES_ALLOWED.
 *
 */


#include <stdatomic.h>
#include <kern/assert.h>
#include <mach/mach_types.h>
#include <mach/boolean.h>
#include <mach/vm_param.h>
#include <mach/task.h>
#include <mach/thread_act.h>
#include <mach/host_priv.h>
#include <kern/host.h>
#include <kern/kern_types.h>
#include <kern/mach_param.h>
#include <kern/policy_internal.h>
#include <kern/thread.h>
#include <kern/task.h>
#include <corpses/task_corpse.h>
#include <kern/kalloc.h>
#include <kern/kern_cdata.h>
#include <mach/mach_vm.h>
#include <kern/exc_guard.h>
#include <os/log.h>
#include <sys/kdebug_triage.h>

#if CONFIG_MACF
#include <security/mac_mach_internal.h>
#endif

/*
 * Exported interfaces
 */
#include <mach/task_server.h>

union corpse_creation_gate {
	struct {
		uint16_t user_faults;
		uint16_t corpses;
	};
	uint32_t value;
};

static _Atomic uint32_t inflight_corpses;
unsigned long  total_corpses_created = 0;

static TUNABLE(bool, corpses_disabled, "-no_corpses", false);

#if !XNU_TARGET_OS_OSX
/* Use lightweight corpse on embedded */
static TUNABLE(bool, lw_corpses_enabled, "lw_corpses", true);
#else
static TUNABLE(bool, lw_corpses_enabled, "lw_corpses", false);
#endif

#if DEBUG || DEVELOPMENT
/* bootarg to generate corpse with size up to max_footprint_mb */
TUNABLE(bool, corpse_threshold_system_limit, "corpse_threshold_system_limit", false);
#endif /* DEBUG || DEVELOPMENT */

/* bootarg to turn on corpse forking for EXC_RESOURCE */
TUNABLE(bool, exc_via_corpse_forking, "exc_via_corpse_forking", true);

/* bootarg to generate corpse for fatal high memory watermark violation */
TUNABLE(bool, corpse_for_fatal_memkill, "corpse_for_fatal_memkill", true);

extern int IS_64BIT_PROCESS(void *);
extern void gather_populate_corpse_crashinfo(void *p, task_t task,
    mach_exception_data_type_t code, mach_exception_data_type_t subcode,
    uint64_t *udata_buffer, int num_udata, void *reason, exception_type_t etype);
extern void *proc_find(int pid);
extern int proc_rele(void *p);
extern task_t proc_get_task_raw(void *proc);
extern char *proc_best_name(struct proc *proc);


/*
 * Routine: corpses_enabled
 * returns FALSE if not enabled
 */
boolean_t
corpses_enabled(void)
{
	return !corpses_disabled;
}

unsigned long
total_corpses_count(void)
{
	union corpse_creation_gate gate;

	gate.value = atomic_load_explicit(&inflight_corpses, memory_order_relaxed);
	return gate.corpses;
}

extern char *proc_best_name(struct proc *);
extern int proc_pid(struct proc *);

/*
 * Routine: task_crashinfo_get_ref()
 *          Grab a slot at creating a corpse.
 * Returns: KERN_SUCCESS if the policy allows for creating a corpse.
 */
static kern_return_t
task_crashinfo_get_ref(corpse_flags_t kcd_u_flags)
{
	union corpse_creation_gate oldgate, newgate;
	struct proc *p = (void *)current_proc();

	assert(kcd_u_flags & CORPSE_CRASHINFO_HAS_REF);

	oldgate.value = atomic_load_explicit(&inflight_corpses, memory_order_relaxed);
	for (;;) {
		newgate = oldgate;
		if (kcd_u_flags & CORPSE_CRASHINFO_USER_FAULT) {
			if (newgate.user_faults++ >= TOTAL_USER_FAULTS_ALLOWED) {
				os_log(OS_LOG_DEFAULT, "%s[%d] Corpse failure, too many faults %d\n",
				    proc_best_name(p), proc_pid(p), newgate.user_faults);
				return KERN_RESOURCE_SHORTAGE;
			}
		}
		if (newgate.corpses++ >= TOTAL_CORPSES_ALLOWED) {
			os_log(OS_LOG_DEFAULT, "%s[%d] Corpse failure, too many %d\n",
			    proc_best_name(p), proc_pid(p), newgate.corpses);
			return KERN_RESOURCE_SHORTAGE;
		}

		// this reloads the value in oldgate
		if (atomic_compare_exchange_strong_explicit(&inflight_corpses,
		    &oldgate.value, newgate.value, memory_order_relaxed,
		    memory_order_relaxed)) {
			os_log(OS_LOG_DEFAULT, "%s[%d] Corpse allowed %d of %d\n",
			    proc_best_name(p), proc_pid(p), newgate.corpses, TOTAL_CORPSES_ALLOWED);
			return KERN_SUCCESS;
		}
	}
}

/*
 * Routine: task_crashinfo_release_ref
 *          release the slot for corpse being used.
 */
static kern_return_t
task_crashinfo_release_ref(corpse_flags_t kcd_u_flags)
{
	union corpse_creation_gate oldgate, newgate;

	assert(kcd_u_flags & CORPSE_CRASHINFO_HAS_REF);

	oldgate.value = atomic_load_explicit(&inflight_corpses, memory_order_relaxed);
	for (;;) {
		newgate = oldgate;
		if (kcd_u_flags & CORPSE_CRASHINFO_USER_FAULT) {
			if (newgate.user_faults-- == 0) {
				panic("corpse in flight count over-release");
			}
		}
		if (newgate.corpses-- == 0) {
			panic("corpse in flight count over-release");
		}
		// this reloads the value in oldgate
		if (atomic_compare_exchange_strong_explicit(&inflight_corpses,
		    &oldgate.value, newgate.value, memory_order_relaxed,
		    memory_order_relaxed)) {
			os_log(OS_LOG_DEFAULT, "Corpse released, count at %d\n", newgate.corpses);
			return KERN_SUCCESS;
		}
	}
}


kcdata_descriptor_t
task_crashinfo_alloc_init(mach_vm_address_t crash_data_p, unsigned size,
    corpse_flags_t kc_u_flags, unsigned kc_flags)
{
	kcdata_descriptor_t kcdata;

	if (kc_u_flags & CORPSE_CRASHINFO_HAS_REF) {
		if (KERN_SUCCESS != task_crashinfo_get_ref(kc_u_flags)) {
			return NULL;
		}
	}

	kcdata = kcdata_memory_alloc_init(crash_data_p, TASK_CRASHINFO_BEGIN, size,
	    kc_flags);
	if (kcdata) {
		kcdata->kcd_user_flags = kc_u_flags;
	} else if (kc_u_flags & CORPSE_CRASHINFO_HAS_REF) {
		task_crashinfo_release_ref(kc_u_flags);
	}
	return kcdata;
}

kcdata_descriptor_t
task_btinfo_alloc_init(mach_vm_address_t addr, unsigned size)
{
	kcdata_descriptor_t kcdata;

	kcdata = kcdata_memory_alloc_init(addr, TASK_BTINFO_BEGIN, size, KCFLAG_USE_MEMCOPY);

	return kcdata;
}


/*
 * Free up the memory associated with task_crashinfo_data
 */
kern_return_t
task_crashinfo_destroy(kcdata_descriptor_t data)
{
	if (!data) {
		return KERN_INVALID_ARGUMENT;
	}
	if (data->kcd_user_flags & CORPSE_CRASHINFO_HAS_REF) {
		task_crashinfo_release_ref(data->kcd_user_flags);
	}
	return kcdata_memory_destroy(data);
}

/*
 * Routine: task_get_corpseinfo
 * params: task - task which has corpse info setup.
 * returns: crash info data attached to task.
 *          NULL if task is null or has no corpse info
 */
kcdata_descriptor_t
task_get_corpseinfo(task_t task)
{
	kcdata_descriptor_t retval = NULL;
	if (task != NULL) {
		retval = task->corpse_info;
	}
	return retval;
}

/*
 * Routine: task_add_to_corpse_task_list
 * params: task - task to be added to corpse task list
 * returns: None.
 */
void
task_add_to_corpse_task_list(task_t corpse_task)
{
	lck_mtx_lock(&tasks_corpse_lock);
	queue_enter(&corpse_tasks, corpse_task, task_t, corpse_tasks);
	lck_mtx_unlock(&tasks_corpse_lock);
}

/*
 * Routine: task_remove_from_corpse_task_list
 * params: task - task to be removed from corpse task list
 * returns: None.
 */
void
task_remove_from_corpse_task_list(task_t corpse_task)
{
	lck_mtx_lock(&tasks_corpse_lock);
	queue_remove(&corpse_tasks, corpse_task, task_t, corpse_tasks);
	lck_mtx_unlock(&tasks_corpse_lock);
}

/*
 * Routine: task_purge_all_corpses
 * params: None.
 * returns: None.
 */
void
task_purge_all_corpses(void)
{
	task_t task;

	lck_mtx_lock(&tasks_corpse_lock);
	/* Iterate through all the corpse tasks and clear all map entries */
	queue_iterate(&corpse_tasks, task, task_t, corpse_tasks) {
		os_log(OS_LOG_DEFAULT, "Memory pressure corpse purge for pid %d.\n", task_pid(task));
		vm_map_terminate(task->map);
	}
	lck_mtx_unlock(&tasks_corpse_lock);
}

/*
 * Routine: find_corpse_task_by_uniqueid_grp
 * params: task_uniqueid - uniqueid of the corpse
 *         target - target task [Out Param]
 *         grp - task reference group
 * returns:
 *         KERN_SUCCESS if a matching corpse if found, gives a ref.
 *         KERN_FAILURE corpse with given uniqueid is not found.
 */
kern_return_t
find_corpse_task_by_uniqueid_grp(
	uint64_t   task_uniqueid,
	task_t     *target,
	task_grp_t grp)
{
	task_t task;

	lck_mtx_lock(&tasks_corpse_lock);

	queue_iterate(&corpse_tasks, task, task_t, corpse_tasks) {
		if (task->task_uniqueid == task_uniqueid) {
			task_reference_grp(task, grp);
			lck_mtx_unlock(&tasks_corpse_lock);
			*target = task;
			return KERN_SUCCESS;
		}
	}

	lck_mtx_unlock(&tasks_corpse_lock);
	return KERN_FAILURE;
}

/*
 * Routine: task_generate_corpse
 * params: task - task to fork a corpse
 *         corpse_task - task port of the generated corpse
 * returns: KERN_SUCCESS on Success.
 *          KERN_FAILURE on Failure.
 *          KERN_NOT_SUPPORTED on corpse disabled.
 *          KERN_RESOURCE_SHORTAGE on memory alloc failure or reaching max corpse.
 */
kern_return_t
task_generate_corpse(
	task_t task,
	ipc_port_t *corpse_task_port)
{
	task_t new_task;
	kern_return_t kr;
	thread_t thread, th_iter;
	ipc_port_t corpse_port;

	if (task == kernel_task || task == TASK_NULL) {
		return KERN_INVALID_ARGUMENT;
	}

	task_lock(task);
	if (task_is_a_corpse_fork(task)) {
		task_unlock(task);
		return KERN_INVALID_ARGUMENT;
	}
	task_unlock(task);

	thread_set_exec_promotion(current_thread());
	/* Generate a corpse for the given task, will return with a ref on corpse task */
	kr = task_generate_corpse_internal(task, &new_task, &thread, 0, 0, 0, NULL);
	thread_clear_exec_promotion(current_thread());
	if (kr != KERN_SUCCESS) {
		return kr;
	}
	if (thread != THREAD_NULL) {
		thread_deallocate(thread);
	}

	/* wait for all the threads in the task to terminate */
	task_lock(new_task);
	task_wait_till_threads_terminate_locked(new_task);

	/* Reset thread ports of all the threads in task */
	queue_iterate(&new_task->threads, th_iter, thread_t, task_threads)
	{
		/* Do not reset the thread port for inactive threads */
		if (th_iter->corpse_dup == FALSE) {
			ipc_thread_reset(th_iter);
		}
	}
	task_unlock(new_task);

	/* transfer the task ref to port and arm the no-senders notification */
	corpse_port = convert_corpse_to_port_and_nsrequest(new_task);
	assert(IP_NULL != corpse_port);

	*corpse_task_port = corpse_port;
	return KERN_SUCCESS;
}

/*
 * Only generate lightweight corpse if any of thread, task, or host level registers
 * EXC_CORPSE_NOTIFY with behavior EXCEPTION_BACKTRACE.
 *
 * Save a send right and behavior of those ports on out param EXC_PORTS.
 */
static boolean_t
task_should_generate_lightweight_corpse(
	task_t task,
	ipc_port_t exc_ports[static BT_EXC_PORTS_COUNT])
{
	kern_return_t kr;
	boolean_t should_generate = FALSE;

	exception_mask_t mask;
	mach_msg_type_number_t nmasks;
	exception_port_t exc_port = IP_NULL;
	exception_behavior_t behavior;
	thread_state_flavor_t flavor;

	if (task != current_task()) {
		return FALSE;
	}

	if (!lw_corpses_enabled) {
		return FALSE;
	}

	for (unsigned int i = 0; i < BT_EXC_PORTS_COUNT; i++) {
		nmasks = 1;

		/* thread, task, and host level, in this order */
		if (i == 0) {
			kr = thread_get_exception_ports(current_thread(), EXC_MASK_CORPSE_NOTIFY,
			    &mask, &nmasks, &exc_port, &behavior, &flavor);
		} else if (i == 1) {
			kr = task_get_exception_ports(current_task(), EXC_MASK_CORPSE_NOTIFY,
			    &mask, &nmasks, &exc_port, &behavior, &flavor);
		} else {
			kr = host_get_exception_ports(host_priv_self(), EXC_MASK_CORPSE_NOTIFY,
			    &mask, &nmasks, &exc_port, &behavior, &flavor);
		}

		if (kr != KERN_SUCCESS || nmasks == 0) {
			exc_port = IP_NULL;
		}

		/* thread level can return KERN_SUCCESS && nmasks 0 */
		assert(nmasks == 1 || i == 0);

		if (IP_VALID(exc_port) && (behavior & MACH_EXCEPTION_BACKTRACE_PREFERRED)) {
			assert(behavior & MACH_EXCEPTION_CODES);
			exc_ports[i] = exc_port; /* transfers right to array */
			exc_port = NULL;
			should_generate = TRUE;
		} else {
			exc_ports[i] = IP_NULL;
		}

		ipc_port_release_send(exc_port);
	}

	return should_generate;
}

/*
 * Routine: task_enqueue_exception_with_corpse
 * params: task - task to generate a corpse and enqueue it
 *         etype - EXC_RESOURCE or EXC_GUARD
 *         code - exception code to be enqueued
 *         codeCnt - code array count - code and subcode
 *
 * returns: KERN_SUCCESS on Success.
 *          KERN_FAILURE on Failure.
 *          KERN_INVALID_ARGUMENT on invalid arguments passed.
 *          KERN_NOT_SUPPORTED on corpse disabled.
 *          KERN_RESOURCE_SHORTAGE on memory alloc failure or reaching max corpse.
 */
kern_return_t
task_enqueue_exception_with_corpse(
	task_t task,
	exception_type_t etype,
	mach_exception_data_t code,
	mach_msg_type_number_t codeCnt,
	void *reason,
	boolean_t lightweight)
{
	kern_return_t kr;
	ipc_port_t exc_ports[BT_EXC_PORTS_COUNT]; /* send rights in thread, task, host order */
	const char *procname = proc_best_name(get_bsdtask_info(task));

	if (codeCnt < 2) {
		return KERN_INVALID_ARGUMENT;
	}

	if (lightweight && task_should_generate_lightweight_corpse(task, exc_ports)) {
		/* port rights captured in exc_ports */
		kcdata_descriptor_t desc = NULL;
		kcdata_object_t obj = KCDATA_OBJECT_NULL;
		bool lw_corpse_enqueued = false;

		assert(task == current_task());
		assert(etype == EXC_GUARD);

		kr = kcdata_object_throttle_get(KCDATA_OBJECT_TYPE_LW_CORPSE);
		if (kr != KERN_SUCCESS) {
			goto out;
		}

		kr = current_thread_collect_backtrace_info(&desc, etype, code, codeCnt, reason);
		if (kr != KERN_SUCCESS) {
			kcdata_object_throttle_release(KCDATA_OBJECT_TYPE_LW_CORPSE);
			goto out;
		}

		kr = kcdata_create_object(desc, KCDATA_OBJECT_TYPE_LW_CORPSE, BTINFO_ALLOCATION_SIZE, &obj);
		assert(kr == KERN_SUCCESS);
		/* desc ref and throttle slot captured in obj ref */

		thread_backtrace_enqueue(obj, exc_ports, etype);
		os_log(OS_LOG_DEFAULT, "Lightweight corpse enqueued for %s\n", procname);
		/* obj ref and exc_ports send rights consumed */
		lw_corpse_enqueued = true;

out:
		if (!lw_corpse_enqueued) {
			for (unsigned int i = 0; i < BT_EXC_PORTS_COUNT; i++) {
				ipc_port_release_send(exc_ports[i]);
			}
		}
	} else {
		task_t corpse = TASK_NULL;
		thread_t thread = THREAD_NULL;

		thread_set_exec_promotion(current_thread());
		/* Generate a corpse for the given task, will return with a ref on corpse task */
		kr = task_generate_corpse_internal(task, &corpse, &thread, etype,
		    code[0], code[1], reason);
		thread_clear_exec_promotion(current_thread());
		if (kr == KERN_SUCCESS) {
			if (thread == THREAD_NULL) {
				return KERN_FAILURE;
			}
			assert(corpse != TASK_NULL);
			assert(etype == EXC_RESOURCE || etype == EXC_GUARD);
			thread_exception_enqueue(corpse, thread, etype);
			os_log(OS_LOG_DEFAULT, "Full corpse enqueued for %s\n", procname);
		}
	}

	return kr;
}

/*
 * Routine: task_generate_corpse_internal
 * params: task - task to fork a corpse
 *         corpse_task - task of the generated corpse
 *         exc_thread - equivalent thread in corpse enqueuing exception
 *         etype - EXC_RESOURCE or EXC_GUARD or 0
 *         code - mach exception code to be passed in corpse blob
 *         subcode - mach exception subcode to be passed in corpse blob
 * returns: KERN_SUCCESS on Success.
 *          KERN_FAILURE on Failure.
 *          KERN_NOT_SUPPORTED on corpse disabled.
 *          KERN_RESOURCE_SHORTAGE on memory alloc failure or reaching max corpse.
 */
kern_return_t
task_generate_corpse_internal(
	task_t task,
	task_t *corpse_task,
	thread_t *exc_thread,
	exception_type_t etype,
	mach_exception_data_type_t code,
	mach_exception_data_type_t subcode,
	void *reason)
{
	task_t new_task = TASK_NULL;
	thread_t thread = THREAD_NULL;
	thread_t thread_next = THREAD_NULL;
	kern_return_t kr;
	struct proc *p = NULL;
	int is_64bit_addr;
	int is_64bit_data;
	uint32_t t_flags;
	uint32_t t_flags_ro;
	uint64_t *udata_buffer = NULL;
	int size = 0;
	int num_udata = 0;
	corpse_flags_t kc_u_flags = CORPSE_CRASHINFO_HAS_REF;
	void *corpse_proc = NULL;
	thread_t self = current_thread();

#if CONFIG_MACF
	struct label *label = NULL;
#endif

	if (!corpses_enabled()) {
		ktriage_record(thread_tid(self), KDBG_TRIAGE_EVENTID(KDBG_TRIAGE_SUBSYS_CORPSE, KDBG_TRIAGE_RESERVED, KDBG_TRIAGE_CORPSES_DISABLED), 0 /* arg */);
		return KERN_NOT_SUPPORTED;
	}

	if (task_corpse_forking_disabled(task)) {
		os_log(OS_LOG_DEFAULT, "corpse for pid %d disabled via SPI\n", task_pid(task));
		ktriage_record(thread_tid(self), KDBG_TRIAGE_EVENTID(KDBG_TRIAGE_SUBSYS_CORPSE, KDBG_TRIAGE_RESERVED, KDBG_TRIAGE_CORPSE_DISABLED_FOR_PROC), 0 /* arg */);
		return KERN_FAILURE;
	}

	if (etype == EXC_GUARD && EXC_GUARD_DECODE_GUARD_TYPE(code) == GUARD_TYPE_USER) {
		kc_u_flags |= CORPSE_CRASHINFO_USER_FAULT;
	}

	kr = task_crashinfo_get_ref(kc_u_flags);
	if (kr != KERN_SUCCESS) {
		return kr;
	}

	/* Having a task reference does not guarantee a proc reference */
	p = proc_find(task_pid(task));
	if (p == NULL) {
		kr = KERN_INVALID_TASK;
		goto error_task_generate_corpse;
	}

	is_64bit_addr = IS_64BIT_PROCESS(p);
	is_64bit_data = (task == TASK_NULL) ? is_64bit_addr : task_get_64bit_data(task);
	t_flags = TF_CORPSE_FORK |
	    TF_PENDING_CORPSE |
	    (is_64bit_addr ? TF_64B_ADDR : TF_NONE) |
	    (is_64bit_data ? TF_64B_DATA : TF_NONE);
	t_flags_ro = TFRO_CORPSE;

#if CONFIG_MACF
	/* Create the corpse label credentials from the process. */
	label = mac_exc_create_label_for_proc(p);
#endif

	corpse_proc = zalloc_flags(proc_task_zone, Z_WAITOK | Z_ZERO);
	new_task = proc_get_task_raw(corpse_proc);

	/* Create a task for corpse */
	kr = task_create_internal(task,
	    NULL,
	    NULL,
	    TRUE,
	    is_64bit_addr,
	    is_64bit_data,
	    t_flags,
	    t_flags_ro,
	    TPF_NONE,
	    TWF_NONE,
	    new_task);
	if (kr != KERN_SUCCESS) {
		new_task = TASK_NULL;
		goto error_task_generate_corpse;
	}

	/* Enable IPC access to the corpse task */
	ipc_task_enable(new_task);

	/* new task is now referenced, do not free the struct in error case */
	corpse_proc = NULL;

	/* Create and copy threads from task, returns a ref to thread */
	kr = task_duplicate_map_and_threads(task, p, new_task, &thread,
	    &udata_buffer, &size, &num_udata, (etype != 0));
	if (kr != KERN_SUCCESS) {
		goto error_task_generate_corpse;
	}

	kr = task_collect_crash_info(new_task,
#if CONFIG_MACF
	    label,
#endif
	    TRUE);
	if (kr != KERN_SUCCESS) {
		goto error_task_generate_corpse;
	}

	/* transfer our references to the corpse info */
	assert(new_task->corpse_info->kcd_user_flags == 0);
	new_task->corpse_info->kcd_user_flags = kc_u_flags;
	kc_u_flags = 0;

	kr = task_start_halt(new_task);
	if (kr != KERN_SUCCESS) {
		goto error_task_generate_corpse;
	}

	/* terminate the ipc space */
	ipc_space_terminate(new_task->itk_space);

	/* Populate the corpse blob, use the proc struct of task instead of corpse task */
	gather_populate_corpse_crashinfo(p, new_task,
	    code, subcode, udata_buffer, num_udata, reason, etype);

	/* Add it to global corpse task list */
	task_add_to_corpse_task_list(new_task);

	*corpse_task = new_task;
	*exc_thread = thread;

error_task_generate_corpse:
#if CONFIG_MACF
	if (label) {
		mac_exc_free_label(label);
	}
#endif

	/* Release the proc reference */
	if (p != NULL) {
		proc_rele(p);
	}

	if (corpse_proc != NULL) {
		zfree(proc_task_zone, corpse_proc);
	}

	if (kr != KERN_SUCCESS) {
		if (thread != THREAD_NULL) {
			thread_deallocate(thread);
		}
		if (new_task != TASK_NULL) {
			task_lock(new_task);
			/* Terminate all the other threads in the task. */
			queue_iterate(&new_task->threads, thread_next, thread_t, task_threads)
			{
				thread_terminate_internal(thread_next);
			}
			/* wait for all the threads in the task to terminate */
			task_wait_till_threads_terminate_locked(new_task);
			task_unlock(new_task);

			task_clear_corpse(new_task);
			task_terminate_internal(new_task);
			task_deallocate(new_task);
		}
		if (kc_u_flags) {
			task_crashinfo_release_ref(kc_u_flags);
		}
	}
	/* Free the udata buffer allocated in task_duplicate_map_and_threads */
	kfree_data(udata_buffer, size);

	return kr;
}

static kern_return_t
task_map_kcdata_64(
	task_t task,
	void *kcdata_addr,
	mach_vm_address_t *uaddr,
	mach_vm_size_t kcd_size,
	vm_tag_t tag)
{
	kern_return_t kr;
	mach_vm_offset_t udata_ptr;

	kr = mach_vm_allocate_kernel(task->map, &udata_ptr, (size_t)kcd_size,
	    VM_FLAGS_ANYWHERE, tag);
	if (kr != KERN_SUCCESS) {
		return kr;
	}
	copyout(kcdata_addr, (user_addr_t)udata_ptr, (size_t)kcd_size);
	*uaddr = udata_ptr;

	return KERN_SUCCESS;
}

/*
 * Routine: task_map_corpse_info
 * params: task - Map the corpse info in task's address space
 *         corpse_task - task port of the corpse
 *         kcd_addr_begin - address of the mapped corpse info
 *         kcd_addr_begin - size of the mapped corpse info
 * returns: KERN_SUCCESS on Success.
 *          KERN_FAILURE on Failure.
 *          KERN_INVALID_ARGUMENT on invalid arguments.
 * Note: Temporary function, will be deleted soon.
 */
kern_return_t
task_map_corpse_info(
	task_t task,
	task_t corpse_task,
	vm_address_t *kcd_addr_begin,
	uint32_t *kcd_size)
{
	kern_return_t kr;
	mach_vm_address_t kcd_addr_begin_64;
	mach_vm_size_t size_64;

	kr = task_map_corpse_info_64(task, corpse_task, &kcd_addr_begin_64, &size_64);
	if (kr != KERN_SUCCESS) {
		return kr;
	}

	*kcd_addr_begin = (vm_address_t)kcd_addr_begin_64;
	*kcd_size = (uint32_t) size_64;
	return KERN_SUCCESS;
}

/*
 * Routine: task_map_corpse_info_64
 * params: task - Map the corpse info in task's address space
 *         corpse_task - task port of the corpse
 *         kcd_addr_begin - address of the mapped corpse info (takes mach_vm_addess_t *)
 *         kcd_size - size of the mapped corpse info (takes mach_vm_size_t *)
 * returns: KERN_SUCCESS on Success.
 *          KERN_FAILURE on Failure.
 *          KERN_INVALID_ARGUMENT on invalid arguments.
 */
kern_return_t
task_map_corpse_info_64(
	task_t task,
	task_t corpse_task,
	mach_vm_address_t *kcd_addr_begin,
	mach_vm_size_t *kcd_size)
{
	kern_return_t kr;
	mach_vm_offset_t crash_data_ptr = 0;
	const mach_vm_size_t size = CORPSEINFO_ALLOCATION_SIZE;
	void *corpse_info_kernel = NULL;

	if (task == TASK_NULL || task_is_a_corpse(task) ||
	    corpse_task == TASK_NULL || !task_is_a_corpse(corpse_task)) {
		return KERN_INVALID_ARGUMENT;
	}

	corpse_info_kernel = kcdata_memory_get_begin_addr(corpse_task->corpse_info);
	if (corpse_info_kernel == NULL) {
		return KERN_INVALID_ARGUMENT;
	}

	kr = task_map_kcdata_64(task, corpse_info_kernel, &crash_data_ptr, size,
	    VM_MEMORY_CORPSEINFO);

	if (kr == KERN_SUCCESS) {
		*kcd_addr_begin = crash_data_ptr;
		*kcd_size = size;
	}

	return kr;
}

/*
 * Routine: task_map_kcdata_object_64
 * params: task - Map the underlying kcdata in task's address space
 *         kcdata_obj - Object representing the data
 *         kcd_addr_begin - Address of the mapped kcdata
 *         kcd_size - Size of the mapped kcdata
 * returns: KERN_SUCCESS on Success.
 *          KERN_FAILURE on Failure.
 *          KERN_INVALID_ARGUMENT on invalid arguments.
 */
kern_return_t
task_map_kcdata_object_64(
	task_t task,
	kcdata_object_t kcdata_obj,
	mach_vm_address_t *kcd_addr_begin,
	mach_vm_size_t *kcd_size)
{
	kern_return_t kr;
	mach_vm_offset_t bt_data_ptr = 0;
	const mach_vm_size_t size = BTINFO_ALLOCATION_SIZE;
	void *bt_info_kernel = NULL;

	if (task == TASK_NULL || task_is_a_corpse(task) ||
	    kcdata_obj == KCDATA_OBJECT_NULL) {
		return KERN_INVALID_ARGUMENT;
	}

	bt_info_kernel = kcdata_memory_get_begin_addr(kcdata_obj->ko_data);
	if (bt_info_kernel == NULL) {
		return KERN_INVALID_ARGUMENT;
	}

	kr = task_map_kcdata_64(task, bt_info_kernel, &bt_data_ptr, size,
	    VM_MEMORY_BTINFO);

	if (kr == KERN_SUCCESS) {
		*kcd_addr_begin = bt_data_ptr;
		*kcd_size = size;
	}

	return kr;
}

uint64_t
task_corpse_get_crashed_thread_id(task_t corpse_task)
{
	return corpse_task->crashed_thread_id;
}
