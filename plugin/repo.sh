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
# from, out of a release's packages, on FreeBSD or OPNsense. The key signs
# the repository's catalogue, which lists every package's checksum, through
# sign.sh, so the key can stay on another machine; clients check the
# signature against the key's fingerprint. The result goes to the gh-pages
# branch as it is.
#
#	repo.sh key.pem release-directory output-directory
#	repo.sh host:port release-directory output-directory
#
# The release directory holds the release's packages and its SHA256SUMS,
# as gh release download vX.Y.Z leaves them: the repository gets exactly
# the packages SHA256SUMS lists, and only if each has its SHA256 there.
# With host:port, sign-server.py checks the same on the key's machine
# before it signs.
#
# With the key here, it also signs SHA256SUMS, for those who download the
# packages by hand, into SHA256SUMS.sig; with host:port (sign-server.py on
# the machine with the key), sign SHA256SUMS there:
#
#	openssl dgst -sha256 -sign key.pem -out SHA256SUMS.sig SHA256SUMS
#
# The layout is ${SERIES}/ under the output directory (the series fixes the
# ABI), with the packages in All/, so one site can serve several series. A
# new release's packages replace the old ones of the series; pkg(8) only
# offers the newest anyway.
#
# The key: openssl genrsa -out cake-repo.key 4096, kept offline;
# openssl rsa -in cake-repo.key -pubout -out plugin/keys/cake-repo.pub.
# sign.sh hands pkg that public key as the certificate.

set -e

if [ $# -ne 3 ]; then
	echo "usage: $0 key.pem|host:port release-directory output-directory" >&2
	exit 1
fi
HERE=$(cd "$(dirname "$0")" && pwd)
. "${HERE}/build.conf"
SIGNER=$1
RELEASE=$2
# absolute: pkg runs the signing command without a working directory
OUT=$(mkdir -p "$3" && cd "$3" && pwd)
DIR=${OUT}/${SERIES}

if [ ! -s "${RELEASE}/SHA256SUMS" ]; then
	echo ">>> ${RELEASE}/SHA256SUMS is missing" >&2
	exit 1
fi
PKGS=
while read -r DIGEST NAME; do
	case "${NAME}" in
	*/* | "" | *[!A-Za-z0-9._-]*)
		echo ">>> SHA256SUMS: unexpected entry '${NAME}'" >&2
		exit 1
		;;
	esac
	if [ "$(sha256 -q "${RELEASE}/${NAME}" 2>/dev/null)" != "${DIGEST}" ]; then
		echo ">>> ${RELEASE}/${NAME} does not have the SHA256 in SHA256SUMS" >&2
		exit 1
	fi
	ABI_P=$(pkg query -F "${RELEASE}/${NAME}" %q)
	if [ "${ABI_P}" != "${ABI}" ]; then
		echo ">>> ${NAME} is for ${ABI_P}, the ${SERIES} repository is ${ABI}" >&2
		exit 1
	fi
	PKGS="${PKGS} ${NAME}"
done < "${RELEASE}/SHA256SUMS"

rm -rf "${DIR}"
mkdir -p "${DIR}/All"
for NAME in ${PKGS}; do
	cp "${RELEASE}/${NAME}" "${DIR}/All/"
done
cp "${RELEASE}/SHA256SUMS" "${DIR}/SHA256SUMS"
pkg repo -q "${DIR}" signing_command: sh "${HERE}/sign.sh" "${SIGNER}" "${DIR}"
# pkg repo exits 0 even when the signing command fails, with an empty
# signature: check that both catalogue files are signed with the key
X=$(mktemp -d -t cake-repo)
for A in packagesite:packagesite.yaml data:data; do
	tar -xf "${DIR}/${A%%:*}.pkg" -C "${X}"
	F=${X}/${A#*:}
	if ! cmp -s "${F}.pub" "${HERE}/keys/cake-repo.pub" ||
	    ! printf %s "$(sha256 -q "${F}")" | openssl dgst -sha256 \
	    -verify "${HERE}/keys/cake-repo.pub" -signature "${F}.sig" > /dev/null 2>&1; then
		rm -rf "${X}"
		echo ">>> ${A%%:*}.pkg is not signed with plugin/keys/cake-repo.pub (signing refused?)" >&2
		exit 1
	fi
done
rm -rf "${X}"
if [ -f "${SIGNER}" ]; then
	openssl dgst -sha256 -sign "${SIGNER}" -out "${DIR}/SHA256SUMS.sig" "${DIR}/SHA256SUMS"
fi
# GitHub Pages: serve files and directories as they are
touch "${OUT}/.nojekyll"

echo ">>> ${DIR}:"
ls -l "${DIR}" "${DIR}/All"
echo ">>> Key fingerprint (SHA256 of plugin/keys/cake-repo.pub):"
sha256 -q "${HERE}/keys/cake-repo.pub"
