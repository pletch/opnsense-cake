#!/bin/sh
# Run on the OPNsense VM: switch both shaper directions to one scheduler.
#   lul-sched.sh fifo|fq_codel|cake [extra scheduler parameters]
set -e

# a patched ipfw/dnctl in /root/work/bin, if the base one is stock
[ -x /root/work/bin/ipfw ] && PATH=/root/work/bin:$PATH

type=$1
shift || true
case "$type" in
fifo|fq_codel|cake) ;;
*) echo "usage: $0 fifo|fq_codel|cake [params]" >&2; exit 1 ;;
esac

for n in 1 2; do
	ipfw -q sched $n config pipe $n type "$type" "$@"
	ipfw -q queue $n config sched $n queue 1000
done
ipfw sched show | grep -E '^ sched|^000'
