#!/bin/sh

# Compile every build of the scheduler against the opnsense/src commit in
# plugin/build.conf, on FreeBSD of the series' release (CI runs it in a
# FreeBSD VM): the out-of-tree dn_cake.ko as released and with CAKE_DEBUG,
# and, with patches/opnsense-src-cake.patch applied, dummynet.ko with CAKE
# built in (DN_WIRE_LEN), with and without CAKE_DEBUG, and the patched
# dnctl. Kernel modules build with -Werror, so a warning fails too. Each
# build is checked for the code it should and should not contain, so a
# variant that silently built as another fails.
#
#	test/build-variants.sh [opnsense/src checkout at the commit]
#
# Without a checkout, a sparse one is cloned (sys, sbin/ipfw, share/mk).
# The patch is applied to it and reverted at the end.

set -e

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "${TOP}/plugin/build.conf"
WRK=$(mktemp -d -t cake-variants)
SRC=${1:-}
PATCHED=
cleanup() {
	if [ -n "${PATCHED}" ]; then
		git -C "${SRC}" apply -R "${TOP}/patches/opnsense-src-cake.patch"
	fi
	rm -rf "${WRK}"
}
trap cleanup EXIT

if [ -z "${SRC}" ]; then
	SRC=${WRK}/src
	echo ">>> opnsense/src ${SRC_COMMIT}"
	git clone -q --filter=blob:none --no-checkout --sparse -b "stable/${SERIES}" \
	    https://github.com/opnsense/src.git "${SRC}"
	git -C "${SRC}" sparse-checkout set sys sbin/ipfw share/mk
	git -C "${SRC}" checkout -q "${SRC_COMMIT}"
fi

FAILED=0
# has FILE SYMBOL yes|no: whether the module defines the symbol (statics too)
has() {
	if nm "$1" | awk '{print $NF}' | grep -qx "$2"; then
		[ "$3" = yes ]
	else
		[ "$3" = no ]
	fi
}
# check NAME FILE SYMBOL=yes|no ...
check() {
	NAME=$1
	FILE=$2
	shift 2
	for S in "$@"; do
		if ! has "${FILE}" "${S%=*}" "${S#*=}"; then
			echo ">>> ${NAME}: ${S%=*} should be ${S#*=}" >&2
			FAILED=1
			return
		fi
	done
	echo ">>> ${NAME}: ok ($(ls -l "${FILE}" | awk '{print $5}') bytes)"
}
# build NAME command ...: run it, show the end of its output if it fails
build() {
	NAME=$1
	shift
	if ! "$@" > "${WRK}/build.log" 2>&1; then
		echo ">>> ${NAME}: build failed" >&2
		tail -20 "${WRK}/build.log" >&2
		exit 1
	fi
}

# out of tree, as cake-kmod (plugin/kmod/build.sh)
for V in release debug; do
	rm -rf "${WRK}/kmod"
	cp -R "${TOP}/sys" "${WRK}/kmod"
	build "dn_cake.ko ${V}" make -C "${WRK}/kmod/modules/dn_sched_cake" \
	    SYSDIR="${SRC}/sys" $([ ${V} = debug ] && echo CAKE_DEBUG=1)
	if [ ${V} = debug ]; then
		check "dn_cake.ko CAKE_DEBUG" "${WRK}/kmod/modules/dn_sched_cake/dn_cake.ko" \
		    cake_enqueue=yes cake_check=yes cake_wire_len=no
	else
		check "dn_cake.ko" "${WRK}/kmod/modules/dn_sched_cake/dn_cake.ko" \
		    cake_enqueue=yes cake_check=no cake_wire_len=no
	fi
done

# in the tree, with the dummynet patch (DN_WIRE_LEN)
git -C "${SRC}" apply "${TOP}/patches/opnsense-src-cake.patch"
PATCHED=1
for V in release debug; do
	OBJ=${WRK}/obj-${V}
	build "dummynet.ko ${V}" env MAKEOBJDIRPREFIX="${OBJ}" make -C "${SRC}/sys/modules/dummynet" \
	    SRCTOP="${SRC}" SYSDIR="${SRC}/sys" $([ ${V} = debug ] && echo DEBUG_FLAGS=-DCAKE_DEBUG)
	KO=$(find "${OBJ}" -name dummynet.ko | head -1)
	if [ ${V} = debug ]; then
		check "dummynet.ko with CAKE, CAKE_DEBUG" "${KO}" \
		    cake_enqueue=yes cake_check=yes cake_wire_len=yes
	else
		check "dummynet.ko with CAKE" "${KO}" \
		    cake_enqueue=yes cake_check=no cake_wire_len=yes
	fi
done
build "dnctl" env MAKEOBJDIRPREFIX="${WRK}/obj-ipfw" make -C "${SRC}/sbin/ipfw" \
    -m "${SRC}/share/mk" SRCTOP="${SRC}" MK_TESTS=no
echo ">>> dnctl (patched ipfw): ok"

exit ${FAILED}
