#!/bin/sh

# Copyright (c) 2026 Tim Pletcher
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
# AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
# OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# Build the cake-kmod package on an OPNsense machine of the target series.
# SRCDIR must hold the opnsense/src tree of that series with sys, sbin/ipfw
# and share/mk; its dummynet must be the stock one.
#
#	build.sh [output directory]

set -e

VERSION=1.0
# where the sources of the package are published
WWW=${WWW:-https://github.com/pletch/opnsense-cake}
SRCDIR=${SRCDIR:-/usr/src}
TOP=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mkdir -p "${1:-.}" && cd "${1:-.}" && pwd)
WRK=$(mktemp -d -t cake-kmod)
STAGE=${WRK}/stage
trap 'rm -rf "${WRK}"' EXIT

for FILE in sys/netpfil/ipfw/ip_dn_private.h sbin/ipfw/Makefile share/mk/src.opts.mk; do
	if [ ! -f "${SRCDIR}/${FILE}" ]; then
		echo ">>> ${SRCDIR}/${FILE} is missing" >&2
		exit 1
	fi
done
if grep -q DN_WIRE_LEN "${SRCDIR}/sys/netpfil/ipfw/dn_sched.h"; then
	echo ">>> ${SRCDIR} has a patched dummynet, cake-kmod is for the stock one" >&2
	exit 1
fi

echo ">>> Building dn_cake.ko"
cp -R "${TOP}/sys" "${WRK}/kmod"
make -C "${WRK}/kmod/modules/dn_sched_cake" SYSDIR="${SRCDIR}/sys" \
    > "${WRK}/kmod.log" 2>&1 || { tail -20 "${WRK}/kmod.log"; exit 1; }

echo ">>> Building dnctl"
mkdir -p "${WRK}/src/sbin"
cp -R "${SRCDIR}/sbin/ipfw" "${SRCDIR}/sbin/Makefile.inc" "${WRK}/src/sbin/"
patch -s -d "${WRK}/src" -p1 < "${TOP}/patches/ipfw-cake.patch"
IPFW_MAKE="make -C ${WRK}/src/sbin/ipfw -m ${SRCDIR}/share/mk SRCTOP=${SRCDIR} MK_TESTS=no"
${IPFW_MAKE} > "${WRK}/ipfw.log" 2>&1 || { tail -20 "${WRK}/ipfw.log"; exit 1; }

echo ">>> Staging files"
mkdir -p "${STAGE}/boot/modules" "${STAGE}/usr/local/libexec/cake" \
    "${STAGE}/usr/local/share/licenses/cake-kmod"
install -m 555 "${WRK}/kmod/modules/dn_sched_cake/dn_cake.ko" \
    "${STAGE}/boot/modules/dn_cake.ko"
install -m 555 "$(${IPFW_MAKE} -V .OBJDIR)/ipfw" \
    "${STAGE}/usr/local/libexec/cake/dnctl"
# the FreeBSD release the module is built for, checked before it is loaded
uname -r | cut -d- -f1 > "${STAGE}/usr/local/libexec/cake/kernel"
sed -n '/^\/\*-/,/^ \*\//p' "${TOP}/sys/netpfil/ipfw/dn_sched_cake.c" \
    > "${STAGE}/usr/local/share/licenses/cake-kmod/LICENSE"

cat > "${WRK}/+MANIFEST" <<EOM
name: cake-kmod
version: "${VERSION}"
origin: net/cake-kmod
comment: "CAKE scheduler kernel module for dummynet"
maintainer: "Tim Pletcher"
www: "${WWW}"
prefix: "/"
abi: "$(pkg config abi)"
arch: "$(pkg config abi | tr '[:upper:]' '[:lower:]')"
licenselogic: "single"
licenses: [ "BSD3CLAUSE" ]
desc: <<EOD
$(cat "$(dirname "$0")/pkg-descr")
EOD
scripts: {
  post-install: "kldxref /boot/modules"
  post-deinstall: "kldunload -n dn_cake.ko 2> /dev/null; kldxref /boot/modules"
}
EOM
(cd "${STAGE}" && find . -type f | sed 's,^\./,/,' | sort) > "${WRK}/plist"

pkg create -M "${WRK}/+MANIFEST" -r "${STAGE}" -p "${WRK}/plist" -o "${OUT}"
echo ">>> Created ${OUT}/cake-kmod-${VERSION}.pkg for FreeBSD $(cat "${STAGE}/usr/local/libexec/cake/kernel")"
