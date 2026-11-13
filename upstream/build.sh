#!/bin/sh

# Build the dummynet and ipfw(8) proposed to FreeBSD: dummynet with the
# patches in upstream/patches and the CAKE scheduler as upstream/resolve.sh
# generates it, and ipfw (which is also dnctl) with CAKE's parameters. Run
# on FreeBSD; SRCDIR is the source tree of the running kernel (its dummynet
# stock), whose headers the module is built against. With CAKE_DEBUG=1 the
# consistency checker and the net.inet.ip.dummynet.cake debug sysctls are
# built in.
#
#	upstream/build.sh [output directory]

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "${HERE}/.." && pwd)
SRCDIR=${SRCDIR:-/usr/src}
OUT=$(mkdir -p "${1:-.}" && cd "${1:-.}" && pwd)
WRK=/tmp/dummynet-cake.build	# fixed, as dummynet-subtick/build.sh
rm -rf "${WRK}" && mkdir -p "${WRK}"
trap 'rm -rf "${WRK}"' EXIT

if grep -q DN_WIRE_LEN "${SRCDIR}/sys/netpfil/ipfw/dn_sched.h"; then
	echo ">>> ${SRCDIR} has a patched dummynet; the patches are for the stock one" >&2
	exit 1
fi

mkdir -p "${WRK}/src/sys/netpfil" "${WRK}/src/sys/modules" \
    "${WRK}/src/sys/conf" "${WRK}/src/sbin"
cp -R "${SRCDIR}/sys/netpfil/ipfw" "${WRK}/src/sys/netpfil/"
cp -R "${SRCDIR}/sys/modules/dummynet" "${WRK}/src/sys/modules/"
cp "${SRCDIR}/sys/conf/files" "${WRK}/src/sys/conf/"
cp -R "${SRCDIR}/sbin/ipfw" "${WRK}/src/sbin/"
# 0006 is the test suite's, not built here
for P in "${HERE}"/patches/000[1-5]-*.diff; do
	patch -s -d "${WRK}/src" -p1 < "${P}"
done
if [ -n "${CAKE_DEBUG:-}" ]; then
	sh "${HERE}/resolve.sh" upstream "${WRK}/src/sys/netpfil/ipfw"
else
	sh "${HERE}/resolve.sh" freebsd "${WRK}/src/sys/netpfil/ipfw"
fi

echo ">>> Building dummynet.ko"
# its own headers first, so that it builds against another tree's
M=${WRK}/src/sys/modules/dummynet/Makefile
sed 's|^\.include <bsd.kmod.mk>|CFLAGS+= -I${SRCTOP}/sys\
&|' "${M}" > "${M}.new" && mv "${M}.new" "${M}"
make -C "${WRK}/src/sys/modules/dummynet" \
    SRCTOP="${WRK}/src" SYSDIR="${SRCDIR}/sys" \
    $([ -n "${CAKE_DEBUG:-}" ] && echo DEBUG_FLAGS=-DCAKE_DEBUG) \
    > "${WRK}/build.log" 2>&1 || { tail -30 "${WRK}/build.log"; exit 1; }
KO=${WRK}/src/sys/modules/dummynet/dummynet.ko
for S in cake_enqueue cake_wire_len; do
	if ! nm "${KO}" | awk '{print $NF}' | grep -qx "${S}"; then
		echo ">>> dummynet.ko has no ${S}" >&2
		exit 1
	fi
done
install -m 555 "${KO}" "${OUT}/dummynet.ko"

echo ">>> Building ipfw"
make -C "${WRK}/src/sbin/ipfw" -m "${SRCDIR}/share/mk" SRCTOP="${SRCDIR}" \
    MK_TESTS=no MK_MAN=no MK_DEBUG_FILES=no MAKEOBJDIRPREFIX="${WRK}/obj" \
    obj all > "${WRK}/ipfw.log" 2>&1 || { tail -30 "${WRK}/ipfw.log"; exit 1; }
install -m 555 "$(find "${WRK}/obj" "${WRK}/src/sbin/ipfw" -type f -name ipfw | head -1)" \
    "${OUT}/ipfw"
echo ">>> ${OUT}/dummynet.ko ${OUT}/ipfw"
