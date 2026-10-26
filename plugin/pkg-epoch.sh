#!/bin/sh
# pkg(8) for the opnsense/plugins package target, for reproducible packages:
# before "pkg create ... -r root", give every file under root the time
# SOURCE_DATE_EPOCH, as pkg records the files' own times in the manifest.
# Anything else goes to pkg unchanged.

PKG=/usr/local/sbin/pkg

if [ "$1" = create ] && [ -n "${SOURCE_DATE_EPOCH}" ]; then
	root= prev=
	for arg; do
		[ "${prev}" = -r ] && root=${arg}
		prev=${arg}
	done
	if [ -n "${root}" ]; then
		find "${root}" -exec env TZ=UTC touch -h \
		    -t "$(TZ=UTC date -r "${SOURCE_DATE_EPOCH}" +%Y%m%d%H%M.%S)" {} +
	fi
	shift
	exec ${PKG} create -t "${SOURCE_DATE_EPOCH}" "$@"
fi
exec ${PKG} "$@"
