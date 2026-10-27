#!/bin/sh

# Build dummynet_st.ko, the dummynet of SUBTICK.md: opnsense/src's
# dummynet with CAKE built in (patches/opnsense-src-cake.patch) and the
# patches listed in series, in order. Run on FreeBSD; SRCDIR is the
# opnsense/src tree of the running kernel (its dummynet stock), whose
# headers the module is built against. With CAKE_DEBUG=1, the CAKE
# consistency checks are built in.
#
#	patches/dummynet-subtick/build.sh [output directory]

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "${HERE}/../.." && pwd)
SRCDIR=${SRCDIR:-/usr/src}
OUT=$(mkdir -p "${1:-.}" && cd "${1:-.}" && pwd)
WRK=$(mktemp -d -t dummynet-st)
trap 'rm -rf "${WRK}"' EXIT

if grep -q DN_WIRE_LEN "${SRCDIR}/sys/netpfil/ipfw/dn_sched.h"; then
	echo ">>> ${SRCDIR} has a patched dummynet; the series is for the stock one" >&2
	exit 1
fi

# the parts of the tree the patches touch
mkdir -p "${WRK}/src/sys/netpfil" "${WRK}/src/sys/modules" \
    "${WRK}/src/sys/conf" "${WRK}/src/sbin"
cp -R "${SRCDIR}/sys/netpfil/ipfw" "${WRK}/src/sys/netpfil/"
cp -R "${SRCDIR}/sys/modules/dummynet" "${WRK}/src/sys/modules/"
cp "${SRCDIR}/sys/conf/files" "${WRK}/src/sys/conf/"
cp -R "${SRCDIR}/sbin/ipfw" "${WRK}/src/sbin/"
patch -s -d "${WRK}/src" -p1 < "${TOP}/patches/opnsense-src-cake.patch"
for P in $(cat "${HERE}/series"); do
	patch -s -d "${WRK}/src" -p1 < "${HERE}/${P}"
done

echo ">>> Building dummynet_st.ko"
make -C "${WRK}/src/sys/modules/dummynet_st" \
    SRCTOP="${WRK}/src" SYSDIR="${SRCDIR}/sys" \
    $([ -n "${CAKE_DEBUG:-}" ] && echo DEBUG_FLAGS=-DCAKE_DEBUG) \
    > "${WRK}/build.log" 2>&1 || { tail -20 "${WRK}/build.log"; exit 1; }
KO=${WRK}/src/sys/modules/dummynet_st/dummynet_st.ko

# built from the patched sources and headers, not SRCDIR's
for S in cake_enqueue cake_wire_len sysctl_release_us dummynet_fine_task; do
	if ! nm "${KO}" | awk '{print $NF}' | grep -qx "${S}"; then
		echo ">>> dummynet_st.ko has no ${S}" >&2
		exit 1
	fi
done
install -m 555 "${KO}" "${OUT}/dummynet_st.ko"
echo ">>> ${OUT}/dummynet_st.ko"
