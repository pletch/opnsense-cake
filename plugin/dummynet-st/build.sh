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

# Build the dummynet-st package on an OPNsense machine of the target
# series: dummynet with CAKE built in and sub-tick release
# (patches/dummynet-subtick, SUBTICK.md), as /boot/modules/dummynet_st.ko,
# which os-cake loads instead of the stock dummynet.ko. SRCDIR must hold
# the opnsense/src tree of that series with sys, sbin/ipfw and share/mk; its
# dummynet must be the stock one.
#
#	build.sh [output directory]

set -e

VERSION=1.0.3
# where the sources of the package are published
WWW=${WWW:-https://github.com/pletch/opnsense-cake}
SRCDIR=${SRCDIR:-/usr/src}
TOP=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mkdir -p "${1:-.}" && cd "${1:-.}" && pwd)
WRK=$(mktemp -d -t dummynet-st)
STAGE=${WRK}/stage
trap 'rm -rf "${WRK}"' EXIT

mkdir -p "${STAGE}/boot/modules" "${STAGE}/usr/local/libexec/dummynet-st" \
    "${STAGE}/usr/local/share/licenses/dummynet-st"
SRCDIR="${SRCDIR}" sh "${TOP}/patches/dummynet-subtick/build.sh" "${WRK}"
install -m 555 "${WRK}/dummynet_st.ko" "${STAGE}/boot/modules/dummynet_st.ko"
# as cake-kmod (kmod/build.sh): the FreeBSD release and the stock
# dummynet.ko the module replaces, checked before it is loaded. One SHA256
# per line.
uname -r | cut -d- -f1 > "${STAGE}/usr/local/libexec/dummynet-st/kernel"
sha256 -q "${DUMMYNET:-/boot/kernel/dummynet.ko}" \
    > "${STAGE}/usr/local/libexec/dummynet-st/dummynet.sha256"
# dummynet's licence (its sources' first header) and CAKE's
{
	sed -n '/^\/\*-/,/^ \*\//p' "${SRCDIR}/sys/netpfil/ipfw/ip_dummynet.c"
	echo
	sed -n '/^\/\*-/,/^ \*\//p' "${TOP}/sys/netpfil/ipfw/dn_sched_cake.c"
} > "${STAGE}/usr/local/share/licenses/dummynet-st/LICENSE"

cat > "${WRK}/+MANIFEST" <<EOM
name: dummynet-st
version: "${VERSION}"
origin: net/dummynet-st
comment: "dummynet with CAKE and sub-tick release, for os-cake"
maintainer: "Tim Pletcher"
www: "${WWW}"
prefix: "/"
abi: "$(pkg config abi)"
arch: "$(pkg config abi | tr '[:upper:]' '[:lower:]')"
licenselogic: "multi"
licenses: [ "BSD2CLAUSE", "BSD3CLAUSE" ]
desc: <<EOD
$(cat "$(dirname "$0")/pkg-descr")
EOD
scripts: {
  post-install: "kldxref /boot/modules; if [ -f /usr/local/opnsense/scripts/cake/dnctl.py -a -x /usr/local/sbin/configctl ]; then echo Reloading traffic shaper; /usr/local/sbin/configctl shaper reload; fi"
  pre-deinstall: "if kldstat -q -n dummynet_st.ko; then ipfw -q pipe flush; ipfw -q sched flush; ipfw -q queue flush; kldunload -n dummynet_st.ko && kldload dummynet; fi"
  post-deinstall: "kldxref /boot/modules; if [ -x /usr/local/sbin/configctl ]; then echo Reloading traffic shaper; /usr/local/sbin/configctl shaper reload; fi"
}
EOM
(cd "${STAGE}" && find . -type f | sed 's,^\./,/,' | sort) > "${WRK}/plist"

# reproducible, as kmod/build.sh
EPOCH=
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	find "${STAGE}" -exec env TZ=UTC touch -h \
	    -t "$(TZ=UTC date -r "${SOURCE_DATE_EPOCH}" +%Y%m%d%H%M.%S)" {} +
	EPOCH="-t ${SOURCE_DATE_EPOCH}"
fi
pkg create ${EPOCH} -M "${WRK}/+MANIFEST" -r "${STAGE}" -p "${WRK}/plist" -o "${OUT}"
echo ">>> Created ${OUT}/dummynet-st-${VERSION}.pkg for FreeBSD $(cat "${STAGE}/usr/local/libexec/dummynet-st/kernel")"
