/*
 * Copyright (c) 1999-2009 Apple, Inc. All rights reserved.
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


#include <sys/param.h>
#include <sys/systm.h>
#include <sys/proc.h>
#include <sys/errno.h>
#include <sys/ioctl.h>
#include <sys/conf.h>
#include <sys/fcntl.h>
#include <string.h>
#include <miscfs/devfs/devfs.h>
#include <kern/locks.h>
#include <kern/clock.h>
#include <sys/time.h>
#include <sys/malloc.h>
#include <sys/sysproto.h>
#include <sys/uio_internal.h>

#include <dev/random/randomdev.h>

#include <libkern/OSByteOrder.h>
#include <libkern/OSAtomic.h>

#include <mach/mach_time.h>

#define RANDOM_MAJOR  -1 /* let the kernel pick the device number */
#define RANDOM_MINOR   0
#define URANDOM_MINOR  1

d_ioctl_t       random_ioctl;

static int
random_stop(__unused struct tty *tp, __unused int rw)
{
	return 0;
}

static int
random_reset(__unused int uban)
{
	return 0;
}

static int
random_select(__unused dev_t dev, __unused int which, __unused void *wql,
    __unused struct proc *p)
{
	return ENODEV;
}

static const struct cdevsw random_cdevsw =
{
	.d_open = random_open,
	.d_close = random_close,
	.d_read = random_read,
	.d_write = random_write,
	.d_ioctl = random_ioctl,
	.d_stop = random_stop,
	.d_reset = random_reset,
	.d_select = random_select,
	.d_mmap = eno_mmap,
	.d_strategy = eno_strat,
	.d_reserved_1 = eno_getc,
	.d_reserved_2 = eno_putc,
};


/*
 * Called to initialize our device,
 * and to register ourselves with devfs
 */
void
random_init(void)
{
	int ret;

	ret = cdevsw_add(RANDOM_MAJOR, &random_cdevsw);
	if (ret < 0) {
		panic("random_init: failed to allocate a major number!");
	}

	devfs_make_node(makedev(ret, RANDOM_MINOR), DEVFS_CHAR,
	    UID_ROOT, GID_WHEEL, 0666, "random");

	/*
	 * also make urandom
	 * (which is exactly the same thing in our context)
	 */
	devfs_make_node(makedev(ret, URANDOM_MINOR), DEVFS_CHAR,
	    UID_ROOT, GID_WHEEL, 0666, "urandom");
}

int
random_ioctl(   __unused dev_t dev, u_long cmd, __unused caddr_t data,
    __unused int flag, __unused struct proc *p  )
{
	switch (cmd) {
	case FIONBIO:
	case FIOASYNC:
		break;
	default:
		return ENODEV;
	}

	return 0;
}

/*
 * Open the device.  Make sure init happened, and make sure the caller is
 * authorized.
 */

int
random_open(__unused dev_t dev, int flags, __unused int devtype, __unused struct proc *p)
{
	/*
	 * if we are being opened for write,
	 * make sure that we have privledges do so
	 */
	if (flags & FWRITE) {
		if (securelevel >= 2) {
			return EPERM;
		}
#ifndef __APPLE__
		if ((securelevel >= 1) && proc_suser(p)) {
			return EPERM;
		}
#endif  /* !__APPLE__ */
	}

	return 0;
}


/*
 * close the device.
 */

int
random_close(__unused dev_t dev, __unused int flags, __unused int mode, __unused struct proc *p)
{
	return 0;
}


/*
 * Get entropic data from the Security Server, and use it to reseed the
 * prng.
 */
int
random_write(dev_t dev, struct uio *uio, __unused int ioflag)
{
	int retCode = 0;
	char rdBuffer[256];

	if (minor(dev) != RANDOM_MINOR) {
		return EPERM;
	}

	/* Security server is sending us entropy */

	while ((size_t)uio_resid(uio) > 0 && retCode == 0) {
		/* get the user's data */
		size_t bytesToInput = MIN((size_t)uio_resid(uio), sizeof(rdBuffer));
		retCode = uiomove(rdBuffer, (int)bytesToInput, uio);
		if (retCode != 0) {
			break;
		}
		retCode = write_random(rdBuffer, (u_int)bytesToInput);
		if (retCode != 0) {
			break;
		}
	}

	return retCode;
}

/*
 * return data to the caller.  Results unpredictable.
 */
int
random_read(__unused dev_t dev, struct uio *uio, __unused int ioflag)
{
	int retCode = 0;
	char buffer[512];

	size_t bytes_remaining = (size_t)uio_resid(uio);
	while (bytes_remaining > 0 && retCode == 0) {
		size_t bytesToRead = MIN(bytes_remaining, sizeof(buffer));
		read_random(buffer, (u_int)bytesToRead);

		retCode = uiomove(buffer, (int)bytesToRead, uio);
		if (retCode != 0) {
			break;
		}

		bytes_remaining = (size_t)uio_resid(uio);
	}

	return retCode;
}

/*
 * Return an u_int32_t pseudo-random number.
 */
u_int32_t
RandomULong(void)
{
	u_int32_t buf;
	read_random(&buf, sizeof(buf));
	return buf;
}


int
getentropy(__unused struct proc * p, struct getentropy_args *gap, __unused int * ret)
{
	user_addr_t user_addr;
	user_size_t user_size;
	char buffer[256];

	user_addr = (user_addr_t)gap->buffer;
	user_size = gap->size;
	/* Can't request more than 256 random bytes
	 * at once. Complying with openbsd getentropy()
	 */
	if (user_size > sizeof(buffer)) {
		return EINVAL;
	}
	read_random(buffer, (u_int)user_size);
	return copyout(buffer, user_addr, user_size);
}
