#!/bin/sh
# dn_sched_cake.c and .h with their build conditionals resolved
# (upstream/unifdef.py), into a directory:
#
#   upstream/resolve.sh plugin|upstream|freebsd OUTDIR
#
#   plugin    the module the OPNsense plugin ships; CAKE_DEBUG and the
#             stock-dummynet conditionals are left as they are
#   upstream  the build proposed to FreeBSD (CAKE_UPSTREAM), with its
#             CAKE_DEBUG code still in: what the tests build
#   freebsd   the same without CAKE_DEBUG: the files for the FreeBSD tree
set -eu

TOP=$(cd "$(dirname "$0")/.." && pwd)
variant=$1
out=$2
case "$variant" in
plugin)   flags="-UCAKE_UPSTREAM -DCAKE_KNOBS" ;;
upstream) flags="-DCAKE_UPSTREAM -DCAKE_KNOBS -D_KERNEL -DDN_WIRE_LEN
	    -UDN_CREDIT_HZ -UDN_RELEASE_GRAIN_NS" ;;
freebsd)  flags="-DCAKE_UPSTREAM -UCAKE_KNOBS -UCAKE_DEBUG -D_KERNEL
	    -DDN_WIRE_LEN -UDN_CREDIT_HZ -UDN_RELEASE_GRAIN_NS
	    -UCAKE_ACK_SCAN" ;;
*) echo "usage: $0 plugin|upstream|freebsd OUTDIR" >&2; exit 1 ;;
esac
mkdir -p "$out"
for f in dn_sched_cake.c dn_sched_cake.h; do
	# shellcheck disable=SC2086
	python3 -I "$TOP/upstream/unifdef.py" $flags \
	    "$TOP/sys/netpfil/ipfw/$f" > "$out/$f"
done
