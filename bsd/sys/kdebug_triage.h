/*
 * Copyright (c) 2000-2020 Apple Inc. All rights reserved.
 *
 * @Apple_LICENSE_HEADER_START@
 *
 * The contents of this file constitute Original Code as defined in and
 * are subject to the Apple Public Source License Version 1.1 (the
 * "License").  You may not use this file except in compliance with the
 * License.  Please obtain a copy of the License at
 * http://www.apple.com/publicsource and read it before using this file.
 *
 * This Original Code and all software distributed under the License are
 * distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT.  Please see the
 * License for the specific language governing rights and limitations
 * under the License.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_END@
 */

#ifndef BSD_SYS_KDEBUG_TRIAGE_H
#define BSD_SYS_KDEBUG_TRIAGE_H

void delete_buffers_triage(void);

#define KDBG_TRIAGE_CLASS_MASK   (0xff000000)
#define KDBG_TRIAGE_CLASS_OFFSET (24)
#define KDBG_TRIAGE_CLASS_MAX    (0xff)

/* Unused but reserved for future use (possibly for payload encoding) */
#define KDBG_TRIAGE_RESERVED (0)
#define KDBG_TRIAGE_RESERVED_MASK   (0x00ff0000)
#define KDBG_TRIAGE_RESERVED_OFFSET (16)
#define KDBG_TRIAGE_RESERVED_MAX    (0xff)

#define KDBG_TRIAGE_CODE_MASK   (0x0000fffc)
#define KDBG_TRIAGE_CODE_OFFSET (2)
#define KDBG_TRIAGE_CODE_MAX    (0x3fff)

#define KDBG_TRIAGE_EVENTID(Class, Reserved, Code)                \
	(((unsigned)((Class)    &   0xff) << KDBG_TRIAGE_CLASS_OFFSET)    | \
	 ((unsigned)((Reserved) &   0xff) << KDBG_TRIAGE_RESERVED_OFFSET) | \
	 ((unsigned)((Code)     & 0x3fff) << KDBG_TRIAGE_CODE_OFFSET))

#define KDBG_TRIAGE_EXTRACT_CLASS(Debugid) \
	((uint8_t)(((Debugid) & KDBG_TRIAGE_CLASS_MASK) >> KDBG_TRIAGE_CLASS_OFFSET))
#define KDBG_TRIAGE_EXTRACT_CODE(Debugid) \
	((uint16_t)(((Debugid) & KDBG_TRIAGE_CODE_MASK) >> KDBG_TRIAGE_CODE_OFFSET))

#define KDBG_TRIAGE_MAX_STRINGS (5)
#define KDBG_TRIAGE_MAX_STRLEN  (128)

/****** VM Codes Begin ******/
#define KDBG_TRIAGE_SUBSYS_VM   (1)

enum vm_subsys_error_codes {
	KDBG_TRIAGE_VM_PREFIX = 0,
	KDBG_TRIAGE_VM_NO_DATA,
	KDBG_TRIAGE_VM_TEXT_CORRUPTION,
	KDBG_TRIAGE_VM_ADDRESS_NOT_FOUND,
	KDBG_TRIAGE_VM_PROTECTION_FAILURE,
	KDBG_TRIAGE_VM_FAULT_MEMORY_SHORTAGE,
	KDBG_TRIAGE_VM_FAULT_COPY_MEMORY_SHORTAGE,
	KDBG_TRIAGE_VM_FAULT_OBJCOPYSLOWLY_MEMORY_SHORTAGE,
	KDBG_TRIAGE_VM_FAULT_OBJIOPLREQ_MEMORY_SHORTAGE,
	KDBG_TRIAGE_VM_FAULT_INTERRUPTED,
	KDBG_TRIAGE_VM_SUCCESS_NO_PAGE,
	KDBG_TRIAGE_VM_GUARDPAGE_FAULT,
	KDBG_TRIAGE_VM_NONZERO_PREEMPTION_LEVEL,
	KDBG_TRIAGE_VM_BUSYPAGE_WAIT_INTERRUPTED,
	KDBG_TRIAGE_VM_PURGEABLE_FAULT_ERROR,
	KDBG_TRIAGE_VM_OBJECT_SHADOW_SEVERED,
	KDBG_TRIAGE_VM_OBJECT_NOT_ALIVE,
	KDBG_TRIAGE_VM_OBJECT_NO_PAGER,
	KDBG_TRIAGE_VM_OBJECT_NO_PAGER_FORCED_UNMOUNT,
	KDBG_TRIAGE_VM_OBJECT_NO_PAGER_UNGRAFT,
	KDBG_TRIAGE_VM_PAGE_HAS_ERROR,
	KDBG_TRIAGE_VM_PAGE_HAS_RESTART,
	KDBG_TRIAGE_VM_FAILED_IMMUTABLE_PAGE_WRITE,
	KDBG_TRIAGE_VM_FAILED_NX_PAGE_EXEC_MAPPING,
	KDBG_TRIAGE_VM_PMAP_ENTER_RESOURCE_SHORTAGE,
	KDBG_TRIAGE_VM_COMPRESSOR_GET_OUT_OF_RANGE,
	KDBG_TRIAGE_VM_COMPRESSOR_GET_NO_PAGE,
	KDBG_TRIAGE_VM_COMPRESSOR_DECOMPRESS_FAILED,
	KDBG_TRIAGE_VM_SUBMAP_NO_COW_ON_EXECUTABLE,
	KDBG_TRIAGE_VM_SUBMAP_COPY_SLOWLY_FAILED,
	KDBG_TRIAGE_VM_SUBMAP_COPY_STRAT_FAILED,
	KDBG_TRIAGE_VM_VNODEPAGER_CLREAD_NO_UPL,
	KDBG_TRIAGE_VM_VNODEPAGEIN_NO_UBCINFO,
	KDBG_TRIAGE_VM_VNODEPAGEIN_FSPAGEIN_FAIL,
	KDBG_TRIAGE_VM_VNODEPAGEIN_NO_UPL,
	KDBG_TRIAGE_VM_ECC_DIRTY,
	KDBG_TRIAGE_VM_ECC_CLEAN,
	KDBG_TRIAGE_VM_COPYOUTMAP_SAMEMAP_ERROR,
	KDBG_TRIAGE_VM_COPYOUTMAP_DIFFERENTMAP_ERROR,
	KDBG_TRIAGE_VM_COPYOVERWRITE_FULL_NESTED_ERROR,
	KDBG_TRIAGE_VM_COPYOVERWRITE_PARTIAL_NESTED_ERROR,
	KDBG_TRIAGE_VM_COPYOVERWRITE_PARTIAL_HEAD_NESTED_ERROR,
	KDBG_TRIAGE_VM_COPYOVERWRITE_PARTIAL_TAIL_NESTED_ERROR,
	KDBG_TRIAGE_VM_COPYOUT_INTERNAL_SIZE_ERROR,
	KDBG_TRIAGE_VM_COPYOUT_KERNEL_BUFFER_ERROR,
	KDBG_TRIAGE_VM_COPYOUT_INTERNAL_ADJUSTING_ERROR,
	KDBG_TRIAGE_VM_COPYOUT_INTERNAL_SPACE_ERROR,
	KDBG_TRIAGE_VM_ALLOCATE_KERNEL_BADFLAGS_ERROR,
	KDBG_TRIAGE_VM_ALLOCATE_KERNEL_BADMAP_ERROR,
	KDBG_TRIAGE_VM_ALLOCATE_KERNEL_BADSIZE_ERROR,
	KDBG_TRIAGE_VM_ALLOCATE_KERNEL_VMMAPENTER_ERROR,
	KDBG_TRIAGE_VM_MAX
};
#define VM_MAX_TRIAGE_STRINGS (KDBG_TRIAGE_VM_MAX)

/****** VM Codes End ******/

/****** Cluster Codes Begin ******/
#define KDBG_TRIAGE_SUBSYS_CLUSTER   (2)

enum cluster_subsys_error_codes {
	KDBG_TRIAGE_CL_PREFIX = 0,
	KDBG_TRIAGE_CL_PGIN_PAST_EOF,
	KDBG_TRIAGE_CL_MAX
};
#define CLUSTER_MAX_TRIAGE_STRINGS (KDBG_TRIAGE_CL_MAX)

/****** Cluster Codes End ******/

/****** Shared Region Codes Begin ******/
#define KDBG_TRIAGE_SUBSYS_SHARED_REGION   (3)

enum shared_region_subsys_error_codes {
	KDBG_TRIAGE_SHARED_REGION_PREFIX = 0,
	KDBG_TRIAGE_SHARED_REGION_NO_UPL,
	KDBG_TRIAGE_SHARED_REGION_SLIDE_ERROR,
	KDBG_TRIAGE_SHARED_REGION_PAGER_MEMORY_SHORTAGE,
	KDBG_TRIAGE_SHARED_REGION_MAX
};
#define SHARED_REGION_MAX_TRIAGE_STRINGS (KDBG_TRIAGE_SHARED_REGION_MAX)

/****** Shared Region Codes End ******/

/****** DYLD pager Codes Begin ******/
#define KDBG_TRIAGE_SUBSYS_DYLD_PAGER   (4)

enum dyld_pager_subsys_error_codes {
	KDBG_TRIAGE_DYLD_PAGER_PREFIX = 0,
	KDBG_TRIAGE_DYLD_PAGER_NO_UPL,
	KDBG_TRIAGE_DYLD_PAGER_MEMORY_SHORTAGE,
	KDBG_TRIAGE_DYLD_PAGER_SLIDE_ERROR,
	KDBG_TRIAGE_DYLD_PAGER_CHAIN_OUT_OF_RANGE,
	KDBG_TRIAGE_DYLD_PAGER_SEG_INFO_OUT_OF_RANGE,
	KDBG_TRIAGE_DYLD_PAGER_SEG_SIZE_OUT_OF_RANGE,
	KDBG_TRIAGE_DYLD_PAGER_SEG_PAGE_CNT_OUT_OF_RANGE,
	KDBG_TRIAGE_DYLD_PAGER_NO_SEG_FOR_VA,
	KDBG_TRIAGE_DYLD_PAGER_RANGE_NOT_FOUND,
	KDBG_TRIAGE_DYLD_PAGER_DELTA_TOO_LARGE,
	KDBG_TRIAGE_DYLD_PAGER_PAGE_START_OUT_OF_RANGE,
	KDBG_TRIAGE_DYLD_PAGER_BAD_POINTER_FMT,
	KDBG_TRIAGE_DYLD_PAGER_INVALID_AUTH_KEY,
	KDBG_TRIAGE_DYLD_PAGER_BIND_ORDINAL,
	KDBG_TRIAGE_DYLD_PAGER_MAX
};
#define DYLD_PAGER_MAX_TRIAGE_STRINGS (KDBG_TRIAGE_DYLD_PAGER_MAX)

/****** DYLD pager Codes End ******/

/****** APPLE_PROTECT_PAGER pager Codes Begin ******/
#define KDBG_TRIAGE_SUBSYS_APPLE_PROTECT_PAGER   (5)

enum apple_protect_pager_subsys_error_codes {
	KDBG_TRIAGE_APPLE_PROTECT_PAGER_PREFIX = 0,
	KDBG_TRIAGE_APPLE_PROTECT_PAGER_MEMORY_SHORTAGE,
	KDBG_TRIAGE_APPLE_PROTECT_PAGER_MAX
};
#define APPLE_PROTECT_PAGER_MAX_TRIAGE_STRINGS (KDBG_TRIAGE_APPLE_PROTECT_PAGER_MAX)

/****** APPLE_PROTECT pager Codes End ******/

/****** FOURK pager Codes Begin ******/
#define KDBG_TRIAGE_SUBSYS_FOURK_PAGER   (6)

enum fourk_pager_subsys_error_codes {
	KDBG_TRIAGE_FOURK_PAGER_PREFIX = 0,
	KDBG_TRIAGE_FOURK_PAGER_MEMORY_SHORTAGE,
	KDBG_TRIAGE_FOURK_PAGER_MAX
};
#define FOURK_PAGER_MAX_TRIAGE_STRINGS (KDBG_TRIAGE_FOURK_PAGER_MAX)

/****** FOURK pager Codes End ******/

/****** Kext ktriage Begin ******/
/*
 * kexts can define their own strings and augment them with an argument.
 * ktriage only needs to know the subsystem id, and expects that the first
 * string will be the subsystem prefix string.
 *
 * Right now we don't support dynamically adding or removing subsystems.
 */

#define KDBG_TRIAGE_SUBSYS_APFS    (7)
#define KDBG_TRIAGE_SUBSYS_DECMPFS (8)

/****** Kext ktriage End ******/

/****** Corpse pager Codes Begin ******/
#define KDBG_TRIAGE_SUBSYS_CORPSE   (9)

enum corpse_subsys_error_codes {
	KDBG_TRIAGE_CORPSE_PREFIX = 0,
	KDBG_TRIAGE_CORPSE_PROC_TOO_BIG,
	KDBG_TRIAGE_CORPSE_FAIL_LIBGMALLOC,
	KDBG_TRIAGE_CORPSE_BLOCKED_JETSAM,
	KDBG_TRIAGE_CORPSE_LIMIT,
	KDBG_TRIAGE_CORPSES_DISABLED,
	KDBG_TRIAGE_CORPSE_DISABLED_FOR_PROC,
	KDBG_TRIAGE_CORPSE_MAX
};
#define CORPSE_MAX_TRIAGE_STRINGS (KDBG_TRIAGE_CORPSE_MAX)

/****** Corpse pager Codes End ******/

/* please update KDBG_TRIAGE_SUBSYS_MAX when adding a new subsystem */

#define KDBG_TRIAGE_SUBSYS_MAX  KDBG_TRIAGE_SUBSYS_CORPSE

#endif /* BSD_SYS_KDEBUG_TRIAGE_H */
