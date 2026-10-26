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

# Build cake-kmod and os-cake on an OPNsense machine of the target series:
# cake-kmod with kmod/build.sh, then os-cake with the opnsense/plugins
# framework, which needs cake-kmod installed to record the dependency.
#
#	build.sh [output directory]

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mkdir -p "${1:-.}" && cd "${1:-.}" && pwd)
# not PLUGINS: pkg(8) reads that from the environment as its own setting
PLUGINS_TREE=${PLUGINS_TREE:-$(mktemp -d -t cake-plugins)/plugins}
# a commit of opnsense/plugins to build with, for a reproducible build
PLUGINS_COMMIT=${PLUGINS_COMMIT:-}

# reproducible packages: every file gets the time of the sources' commit,
# from git, or from the times git archive gives the files
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
	SOURCE_DATE_EPOCH=$(git -C "${HERE}" log -1 --format=%ct 2>/dev/null ||
	    stat -f %m "${HERE}/build.sh")
fi
export SOURCE_DATE_EPOCH

sh "${HERE}/kmod/build.sh" "${OUT}"
pkg add -f "${OUT}"/cake-kmod-*.pkg

# the series, e.g. 26.7: the running OPNsense's, or SERIES on another
# FreeBSD of the same release (as in CI)
SERIES=${SERIES:-$(opnsense-version -a 2>/dev/null || true)}
if [ -z "${SERIES}" ]; then
	echo ">>> Not on OPNsense: set SERIES to the OPNsense series, e.g. 26.7" >&2
	exit 1
fi
# the stable branch of the series, the main branch builds -devel packages
if [ ! -d "${PLUGINS_TREE}/Mk" ]; then
	git clone -q -b "stable/${SERIES}" \
	    https://github.com/opnsense/plugins.git "${PLUGINS_TREE}"
fi
if [ -n "${PLUGINS_COMMIT}" ]; then
	git -C "${PLUGINS_TREE}" checkout -q "${PLUGINS_COMMIT}"
fi
echo ">>> Building os-cake with opnsense/plugins $(git -C "${PLUGINS_TREE}" rev-parse HEAD)"
rm -rf "${PLUGINS_TREE}/net/cake"
cp -R "${HERE}/net/cake" "${PLUGINS_TREE}/net/cake"
make -C "${PLUGINS_TREE}/net/cake" PLUGIN_ABI="${SERIES}" \
    PKG="${HERE}/pkg-epoch.sh" package
cp "${PLUGINS_TREE}"/net/cake/work/pkg/*.pkg "${OUT}/"
ls -l "${OUT}"/*.pkg
