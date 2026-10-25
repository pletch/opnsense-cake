# Out-of-tree build of the dummynet CAKE scheduler.
#
# Needs a kernel source tree matching the running kernel (for OPNsense,
# the opnsense/src branch of the release), as dummynet's private headers
# are not installed:
#
#	make SYSDIR=/usr/src/sys
#	kldload dummynet && kldload ./dn_cake.ko

.PATH:  ${.CURDIR}/../../netpfil/ipfw
KMOD=   dn_cake
SRCS=   dn_sched_cake.c
SRCS+=	opt_inet6.h

CFLAGS+= -I${.CURDIR}/../../netpfil/ipfw

# make CAKE_DEBUG=1: consistency checks on every enqueue/dequeue (slow),
# errors counted in net.inet.ip.dummynet.cake.check_errors
.if defined(CAKE_DEBUG)
CFLAGS+= -DCAKE_DEBUG
.endif

.include <bsd.kmod.mk>
