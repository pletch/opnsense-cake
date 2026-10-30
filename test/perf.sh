#!/bin/sh
# Throughput, latency and router CPU per scheduler at a high rate, on the
# lul-setup.sh bench (both pipes at RATE). Run robustness.sh or copy
# opn-robust.sh and lul-sched.sh to /root/work on OPNsense first.
#
#   RATE=300Mbit/s test/perf.sh rrul
#
# RATE must stay below what the path forwards unshaped (both directions at
# once for rrul), or the pipes never fill and nothing is shaped.
#   test/perf.sh ndown 64          # tcp_ndown with 64 download flows
#
# PROF=1 times the scheduler's enqueue and dequeue calls with DTrace
# instead (opn-robust.sh prof); fifo rows are skipped then.
#
# Scheduler configurations come from CONFIGS, one per line:
#   label|lul-sched.sh arguments
set -u

. "$(dirname "$0")/bench.sh"
. "$(dirname "$0")/ticks.sh"
RATE=${RATE:-300Mbit/s}
LEN=${LEN:-40}
PROF=${PROF:-0}
CONFIGS=${CONFIGS:-"fifo|fifo
fq_codel|fq_codel
cake besteffort flows|cake besteffort flows
cake diffserv3 triple|cake diffserv3 triple-isolate
cake diffserv4 triple|cake diffserv4 triple-isolate"}

case "${1:-rrul}" in
rrul)	test="rrul" ;;
ndown)	test="tcp_ndown --test-parameter download_streams=${2:-64}" ;;
*)	echo "usage: $0 rrul | ndown N" >&2; exit 1 ;;
esac

# run a command on OPNsense, print its output (see robustness.sh)

opn "cd /root/work && DOWN=$RATE UP=$RATE ./lul-setup.sh" 60 | tail -1

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
echo "test: $test, $RATE both ways, ${LEN}s, measured over 20s at steady state"
if [ "$PROF" = 1 ]; then
	printf '%-24s %9s %9s %10s %9s %9s %10s %9s\n' config down \
	    enq/s enq-avg-ns enq-max-us deq/s deq-avg-ns deq-max-us
else
	printf '%-24s %9s %9s %10s %10s %7s %6s %6s\n' config down up \
	    ping-med ping-p99 cpu sys intr
fi
printf '%s\n' "$CONFIGS" | while IFS='|' read -r label args; do
	[ -n "$label" ] || continue
	[ "$PROF" = 1 ] && [ "${args%% *}" = fifo ] && continue
	opn "/root/work/lul-sched.sh $args >/dev/null" 30
	ticks_mark
	cli "sudo ip netns exec cli flent $test -l $LEN -H 10.10.2.2 -D /tmp \
	    -f summary 2>/dev/null" >"$tmp" &
	fl=$!
	sleep $((LEN / 4))
	if [ "$PROF" = 1 ]; then
		prof=$(opn "/root/work/opn-robust.sh prof ${args%% *} 20" 90)
		wait $fl
		down=$(awk '/TCP download sum/ { print $(NF-4) }' "$tmp")
		printf '%s\n' "$prof" | awk -v label="$label" -v down="$down" '
			/enqueue/ { ec = $4; ea = $6; em = $8 }
			/dequeue/ { dc = $4; da = $6; dm = $8 }
			END {
				printf "%-24s %9s %9d %10d %9.1f %9d %10d %9.1f ",
				    label, down, ec / 20, ea, em / 1000,
				    dc / 20, da, dm / 1000
			}'
		ticks_late
		continue
	fi
	cpu=$(opn '/root/work/opn-robust.sh cpu 20' 60 | sed -n 's/^cpu //p')
	wait $fl
	awk -v label="$label" -v cpu="$cpu" '
		# columns: avg median 99th unit points
		/Ping \(ms\) ICMP/ { med = $(NF-3); p99 = $(NF-2) }
		/TCP download sum/ { down = $(NF-4) }
		/TCP upload sum/ { up = $(NF-4) }
		END {
			split(cpu, c, " ")
			printf "%-24s %9s %9s %10s %10s %7s %6s %6s ", label,
			    down == "" ? "-" : down, up == "" ? "-" : up,
			    med, p99, c[2], c[4], c[6]
		}' "$tmp"
	ticks_late
done
