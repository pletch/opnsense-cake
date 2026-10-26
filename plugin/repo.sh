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

# Make the signed pkg(8) repository firewalls install os-cake and cake-kmod
# from, out of a release's packages, on FreeBSD or OPNsense, where the
# signing key is. The key signs the repository's catalogue, which lists
# every package's SHA256, and SHA256SUMS, for those who download the
# packages by hand. The result goes to the gh-pages branch as it is.
#
#	repo.sh key.pem output-directory package ...
#
# The layout is ${SERIES}/ under the output directory (the series fixes the
# ABI), with the packages in All/, so one site can serve several series. A
# new release's packages replace the old ones of the series; pkg(8) only
# offers the newest anyway.
#
# The key: openssl genrsa -out cake-repo.key 4096, kept offline;
# openssl rsa -in cake-repo.key -pubout -out plugin/keys/cake-repo.pub.

set -e

if [ $# -lt 3 ]; then
	echo "usage: $0 key.pem output-directory package ..." >&2
	exit 1
fi
HERE=$(cd "$(dirname "$0")" && pwd)
. "${HERE}/build.conf"
KEY=$1
OUT=$2
shift 2
DIR=${OUT}/${SERIES}

for P in "$@"; do
	ABI_P=$(pkg query -F "${P}" %q)
	if [ "${ABI_P}" != "${ABI}" ]; then
		echo ">>> ${P} is for ${ABI_P}, the ${SERIES} repository is ${ABI}" >&2
		exit 1
	fi
done

rm -rf "${DIR}"
mkdir -p "${DIR}/All"
cp "$@" "${DIR}/All/"
pkg repo -q "${DIR}" "${KEY}"
(cd "${DIR}/All" && sha256 -r *.pkg | sed 's/ /  /') > "${DIR}/SHA256SUMS"
openssl dgst -sha256 -sign "${KEY}" -out "${DIR}/SHA256SUMS.sig" "${DIR}/SHA256SUMS"
# GitHub Pages: serve files and directories as they are
touch "${OUT}/.nojekyll"

echo ">>> ${DIR}:"
ls -l "${DIR}" "${DIR}/All"
echo ">>> Public key fingerprint (SHA256 of the DER key):"
openssl rsa -in "${KEY}" -pubout -outform DER 2>/dev/null | sha256
