# cake_kfuzz.ko, test/kfuzz.sh's packet source: make KERNBUILDDIR=<the
# KASAN kernel's object directory> builds it with that kernel's options

KMOD=	cake_kfuzz
SRCS=	cake_kfuzz.c opt_inet.h opt_inet6.h opt_ipfw.h
CFLAGS+=	-I${.CURDIR}/../fuzz

.include <bsd.kmod.mk>
