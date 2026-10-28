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

# Build both packages from scratch on FreeBSD (or OPNsense) of the series'
# release, as the CI does: opnsense/src and opnsense/plugins at the commits
# in build.conf, and the dummynet.ko of the kernel set it names, which must
# have the SHA256 it gives. Writes the packages, SHA256SUMS and CONTENTS
# (the SHA256 of every file in each package) to the output directory.
#
#	ci-build.sh output-directory [release tag to compare with]
#
# With a tag, the published packages of that release are fetched and their
# contents compared with the build's: any difference fails.

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "${HERE}/build.conf"
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
TAG=${2:-}
REPO=${REPO:-pletch/opnsense-cake}
if [ "$(pkg config abi)" != "${ABI}" ]; then
	echo ">>> This is $(pkg config abi), the ${SERIES} packages need ${ABI}" >&2
	exit 1
fi
SETS=https://pkg.opnsense.org/${ABI}/${SERIES}/sets
WRK=$(mktemp -d -t cake-ci)
trap 'rm -rf "${WRK}"' EXIT

echo ">>> dummynet.ko from ${SETS}/${KSET}"
fetch -qo "${WRK}/${KSET}" "${SETS}/${KSET}"
mkdir "${WRK}/kernel"
tar -xf "${WRK}/${KSET}" -C "${WRK}/kernel" ./boot/kernel/dummynet.ko ./boot/kernel/kernel
# the package records this dummynet.ko as the one the module matches, so it
# has to be the one the pinned sources are known to match
DIGEST=$(sha256 -q "${WRK}/kernel/boot/kernel/dummynet.ko")
if [ "${DIGEST}" != "${DUMMYNET_SHA256}" ]; then
	echo ">>> ${KSET} has dummynet.ko ${DIGEST}, build.conf expects ${DUMMYNET_SHA256}" >&2
	exit 1
fi

# the kernel the packages are built for, as its version string: "FreeBSD
# 15.1-RELEASE-p6 stable/26.7-n284176-c962f76493b6 SMP". The packages
# record it, and the commit it names must be SRC_COMMIT
KERNEL_VERSION=$(strings "${WRK}/kernel/boot/kernel/kernel" | grep -m 1 -E '^FreeBSD [0-9]+\.[0-9]+-[A-Z]+')
KCOMMIT=$(echo "${KERNEL_VERSION}" | sed -n 's/.*-n[0-9]*-\([0-9a-f]\{7,\}\) .*/\1/p')
echo ">>> ${KSET}: ${KERNEL_VERSION}"
case "${KCOMMIT:-none}" in
none)
	echo ">>> no source commit in ${KSET}'s kernel version" >&2
	exit 1
	;;
esac
case "${SRC_COMMIT}" in
"${KCOMMIT}"*)
	;;
*)
	echo ">>> ${KSET} is built from opnsense/src ${KCOMMIT}, build.conf pins ${SRC_COMMIT}" >&2
	exit 1
	;;
esac

echo ">>> opnsense/src ${SRC_COMMIT}"
git clone -q --filter=blob:none --no-checkout --sparse -b "stable/${SERIES}" \
    https://github.com/opnsense/src.git "${WRK}/src"
git -C "${WRK}/src" sparse-checkout set sys sbin/ipfw share/mk
git -C "${WRK}/src" checkout -q "${SRC_COMMIT}"

SRCDIR="${WRK}/src" DUMMYNET="${WRK}/kernel/boot/kernel/dummynet.ko" \
    KERNEL_VERSION="${KERNEL_VERSION}" \
    SERIES="${SERIES}" PLUGINS_COMMIT="${PLUGINS_COMMIT}" \
    PLUGINS_TREE="${WRK}/plugins" sh "${HERE}/build.sh" "${OUT}"

# the SHA256 of every file of each package in a directory
contents() {
	for P in "$1"/*.pkg; do
		rm -rf "${WRK}/x" && mkdir "${WRK}/x"
		tar -xf "${P}" -C "${WRK}/x"
		(cd "${WRK}/x" && find . -type f | sort | xargs sha256 -r) |
		    sed "s| \./| $(basename "${P}"):|"
	done
}

cd "${OUT}"
sha256 -r *.pkg | sed 's/ /  /' > SHA256SUMS
contents "${OUT}" > CONTENTS
echo ">>> Built from ${SERIES} src ${SRC_COMMIT} plugins ${PLUGINS_COMMIT} with ${KSET}:"
cat SHA256SUMS
grep -E 'dn_cake.ko|dummynet_st.ko|libexec/cake/dnctl' CONTENTS

if [ -n "${TAG}" ]; then
	mkdir "${WRK}/release"
	for P in *.pkg; do
		fetch -qo "${WRK}/release/${P}" \
		    "https://github.com/${REPO}/releases/download/${TAG}/${P}"
	done
	contents "${WRK}/release" > "${WRK}/release.contents"
	if diff -u "${WRK}/release.contents" CONTENTS; then
		echo ">>> Same contents as the ${TAG} release packages"
	else
		echo ">>> Contents differ from the ${TAG} release packages" >&2
		exit 1
	fi
fi
