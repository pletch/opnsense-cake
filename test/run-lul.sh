#!/bin/sh
# Latency under load: flent RRUL (4 up + 4 down TCP + ping/UDP RTT) from
# the client netns through the OPNsense shaper, once per scheduler.
#
#   run-lul.sh [scheduler ...]          default: fifo fq_codel cake
#   LEN=60 OPN=~/VMs/opnsense-cake CLI=~/VMs/lul-client run-lul.sh
#
# Results (flent data, per-test plots, combined ping CDF, summary) land in
# $OUT, default ~/VMs/lul-results/<timestamp>.
set -e

OPN=${OPN:-$HOME/VMs/opnsense-cake}
CLI=${CLI:-$HOME/VMs/lul-client}
. "$(dirname "$0")/ticks.sh"
LEN=${LEN:-60}
OUT=${OUT:-$HOME/VMs/lul-results/$(date +%Y%m%d-%H%M%S)}
[ $# -gt 0 ] || set -- fifo fq_codel cake

ssh_cli() {
	ssh -q -i "$CLI/id_lul" -p 2223 -o BatchMode=yes \
	    -o StrictHostKeyChecking=accept-new \
	    -o UserKnownHostsFile="$CLI/known_hosts" debian@127.0.0.1 "$@"
}

# the marker is assembled at run time so the echoed command never matches
opn() {
	"$OPN/sercmd.py" -t "${2:-60}" -e 'LUL-(OK|FAIL)' \
	    "$1 >/tmp/lul.log 2>&1 && r=OK || r=FAIL; printf 'LUL-%s\\\\n' \$r" |
	    grep -q 'LUL-OK' || { echo "OPNsense: '$1' failed" >&2; exit 1; }
}

ssh_cli 'test -e /var/lib/lul-ready' ||
	{ echo "client VM not ready (cloud-init still running?)" >&2; exit 1; }
ssh_cli 'sudo rm -rf /tmp/lul && mkdir -p /tmp/lul'

for s in "$@"; do
	echo "== $s"
	opn "/root/work/lul-sched.sh $s"
	ticks_mark
	ssh_cli "sudo ip netns exec cli flent rrul -l $LEN -H 10.10.2.2 \
	    -t $s -D /tmp/lul -o /tmp/lul/rrul-$s.png >/tmp/lul/flent-$s.log 2>&1" ||
		echo "   flent reported an error, see flent-$s.log" >&2
	echo "   $(ticks_late)"
done

ssh_cli 'cd /tmp/lul && flent -p ping_cdf -o ping-cdf.png *.flent.gz \
	>/dev/null 2>&1; flent -f summary *.flent.gz > summary.txt 2>&1; true'

mkdir -p "$OUT"
scp -q -i "$CLI/id_lul" -P 2223 -o BatchMode=yes \
    -o UserKnownHostsFile="$CLI/known_hosts" \
    'debian@127.0.0.1:/tmp/lul/*' "$OUT/"
echo "results: $OUT"
cat "$OUT/summary.txt"
