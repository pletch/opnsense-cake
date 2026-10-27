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

# pkg repo's signing_command (see pkg-repo(8)): read the SHA256 of a
# catalogue file on stdin, print its signature and the public key. Clients
# check the signature against the key's fingerprint (signature_type
# "fingerprints"), the SHA256 of plugin/keys/cake-repo.pub.
#
#	sign.sh key.pem repository-directory
#		with the key on this machine
#	sign.sh host:port repository-directory
#		through sign-server.py on the machine with the key (reached
#		with ssh -R, say), which is sent the catalogue file being
#		signed, and signs it only if it lists the release's packages

read -t 5 SUM || exit 1
case "${SUM}" in
*[!0-9a-f]* | "") exit 1 ;;
esac
[ ${#SUM} -eq 64 ] || exit 1
HERE=$(cd "$(dirname "$0")" && pwd)

if [ -f "$1" ]; then
	SIG=$(printf %s "${SUM}" | openssl dgst -sha256 -sign "$1" | openssl base64 -A)
else
	# pkg passes only the SHA256; the file is in the repository directory
	# while it waits (packagesite.yaml, then data)
	FILE=
	for NAME in packagesite.yaml data; do
		if [ -f "$2/${NAME}" ] && [ "$(sha256 -q "$2/${NAME}")" = "${SUM}" ]; then
			FILE=${NAME}
		fi
	done
	[ -n "${FILE}" ] || exit 1
	SIG=$({ echo "${SUM} ${FILE} $(stat -f %z "$2/${FILE}")"; cat "$2/${FILE}"; } |
	    nc -N "${1%:*}" "${1##*:}")
fi
[ -n "${SIG}" ] || exit 1
echo SIGNATURE
echo "${SIG}" | openssl base64 -d -A
echo
echo CERT
cat "${HERE}/keys/cake-repo.pub"
echo END
