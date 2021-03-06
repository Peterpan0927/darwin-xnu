// Copyright (c) 2018-2020 Apple Inc.  All rights reserved.

#include "kperf_helpers.h"

#include <darwintest.h>
#include <kperf/kperf.h>
#include <unistd.h>

void
configure_kperf_stacks_timer(pid_t pid, unsigned int period_ms, bool quiet)
{
	kperf_reset();

	(void)kperf_action_count_set(1);
	(void)kperf_timer_count_set(1);

	if (quiet) {
		T_QUIET;
	}
	T_ASSERT_POSIX_SUCCESS(kperf_action_samplers_set(1,
	    KPERF_SAMPLER_USTACK | KPERF_SAMPLER_KSTACK), NULL);

	if (pid != -1) {
		if (quiet) {
			T_QUIET;
		}
		T_ASSERT_POSIX_SUCCESS(kperf_action_filter_set_by_pid(1, pid), NULL);
	}

	if (quiet) {
		T_QUIET;
	}
	T_ASSERT_POSIX_SUCCESS(kperf_timer_action_set(0, 1), NULL);
	if (quiet) {
		T_QUIET;
	}
	T_ASSERT_POSIX_SUCCESS(kperf_timer_period_set(0,
	    kperf_ns_to_ticks(period_ms * NSEC_PER_MSEC)), NULL);
}
