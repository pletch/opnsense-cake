#!/bin/sh
# Many scheduler instances at once (SUBTICK.md, phase 5): the download
# pipe at RATE with an FQ-CoDel scheduler masked by destination port, so
# that each of FLOWS greedy TCP downloads gets an instance of its own at
# RATE, with its own events in dummynet's heap. Reports each flow's share
# of RATE, the router's CPU, how late the ticks ran and, on the forked
# dummynet, its releases between ticks. (CAKE is not used with masks, see
# README.md.)
#
#   RATE=10Mbit/s FLOWS=32 LEN=25 test/subtick-pipes.sh
set -u

. "$(dirname "$0")/bench.sh"
. "$(dirname "$0")/ticks.sh"
RATE=${RATE:-10Mbit/s}
FLOWS=${FLOWS:-32}
LEN=${LEN:-25}

# the fork's release counters (wakeups, packets), or nothing
rel() {
	opn 'sysctl -n net.inet.ip.dummynet.release_wakeups net.inet.ip.dummynet.release_pkts 2>/dev/null' |
	    tr '\n' ' '
}

opn "cd /root/work && DOWN=$RATE UP=1Gbit/s ./lul-setup.sh" 60 | grep lul-setup
opn "ipfw -q sched 1 config pipe 1 mask dst-port 0xffff type fq_codel &&
    ipfw -q queue 1 config sched 1 queue 1000 &&
    sysctl -n net.inet.ip.dummynet.release_us 2>/dev/null" >/dev/null

r0=$(rel)
cli "cd /tmp; rm -f /tmp/mp-*.txt; for i in \$(seq 1 $FLOWS); do
	sudo ip netns exec cli netperf -H 10.10.2.2 -t TCP_MAERTS -l $LEN -P 0 \
	    -- -o THROUGHPUT >/tmp/mp-\$i.txt &
done; wait" &
NP=$!
sleep 5
ticks_mark
cpu=$(opn 'sh /root/work/subtick-burst.sh cpu 10' 30)
late=$(ticks_late)
wait $NP
r1=$(rel)
echo "$FLOWS flows; $cpu; $late"
cli 'cat /tmp/mp-*.txt' | sort -n | awk -v rate="$RATE" -v len="$LEN" '
	{ v[NR] = $1; s += $1 }
	END {
		r = rate + 0
		printf "per flow: min %.2f, median %.2f, max %.2f Mbit/s (sum %.0f; rate %s each)\n",
		    v[1], v[int(NR / 2) + 1], v[NR], s, rate
	}'
if [ -n "$r0" ]; then
	echo "$r0 $r1" | awk -v len="$LEN" '{
		w = $3 - $1; p = $4 - $2
		printf "releases between ticks: %.0f/s, %.1f packets each\n",
		    w / len, w ? p / w : 0 }'
fi
