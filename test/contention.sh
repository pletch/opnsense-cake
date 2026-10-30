#!/bin/sh
# Bandwidth sharing between tins under contention (diffserv4, 50 Mbit/s
# download), on the lul-setup.sh bench or, for comparison, on Linux's own
# sch_cake: between two network namespaces on the client VM (linux), or on
# the bench's own path (path), shaping the client VM's interfaces with the
# router's pipes opened to 1 Gbit/s, so that both see the same TCP path:
#
#   voice+bulk     a 5 Mbit/s isochronous Voice flow (EF, irtt) against a
#                  greedy Bulk download (CS1): Voice should get all it
#                  offers with low delay, Bulk the rest
#   bulk+voice     the same with the classes swapped: a 5 Mbit/s Bulk flow,
#                  over Bulk's 3.1 Mbit/s threshold, against greedy Voice
#   voice+all      the Voice flow against greedy Video (AF41), Best Effort
#                  and Bulk downloads at once
#
#   test/contention.sh [bench|linux|path]
set -u

. "$(dirname "$0")/bench.sh"
. "$(dirname "$0")/ticks.sh"
TARGET=${1:-bench}
LEN=${LEN:-15}

case "$TARGET" in
bench)
	opn "cd /root/work && DOWN=50Mbit/s UP=50Mbit/s ./lul-setup.sh" 60
	opn "/root/work/lul-sched.sh cake diffserv4"
	C=cli S=srv H=10.10.2.2
	;;
path)
	opn "cd /root/work && DOWN=1Gbit/s UP=1Gbit/s ./lul-setup.sh" 60
	opn "/root/work/lul-sched.sh fifo"
	cli 'for x in cli:cli0 srv:srv0; do
		sudo ip netns exec ${x%%:*} /usr/sbin/tc qdisc replace dev ${x#*:} root cake bandwidth 50mbit diffserv4
	done'
	C=cli S=srv H=10.10.2.2
	;;
linux)
	# a veth pair between two namespaces, sch_cake at 50 Mbit/s each way
	cli 'N="sudo ip netns exec"; T=/usr/sbin/tc
	sudo ip netns del lca 2>/dev/null; sudo ip netns del lcb 2>/dev/null
	sudo ip netns add lca; sudo ip netns add lcb
	sudo ip link add va netns lca type veth peer name vb netns lcb
	$N lca ip addr add 10.99.0.1/24 dev va; $N lcb ip addr add 10.99.0.2/24 dev vb
	for x in lca:va lcb:vb; do
		$N ${x%%:*} ip link set ${x#*:} up; $N ${x%%:*} ip link set lo up
		$N ${x%%:*} $T qdisc replace dev ${x#*:} root cake bandwidth 50mbit diffserv4
	done
	$N lcb sh -c "netserver >/dev/null 2>&1"'
	C=lca S=lcb H=10.99.0.2
	;;
*)
	echo "usage: $0 [bench|linux|path]" >&2
	exit 1
	;;
esac

# an unrestricted irtt server for the 2 ms Voice flow
cli "N='sudo ip netns exec'; \$N $S ss -lun | grep -q ':2113 ' ||
    \$N $S sh -c 'nohup irtt server -b $H:2113 -i 0 -l 1500 >/dev/null 2>&1 &'; sleep 1"

# scenario: name, irtt DSCP (ToS), then the ToS of each greedy download
run() {
	name=$1 iq=$2
	shift 2
	[ "$TARGET" = linux ] || ticks_mark
	cli "N='sudo ip netns exec'; cd /tmp; sudo rm -f /tmp/cv.json.gz; rm -f /tmp/cv-*.txt
	\$N $C irtt client -i 2ms -l 1250 -d $((LEN + 2))s --dscp=$iq -Q -o /tmp/cv $H:2113 >/dev/null 2>&1 &
	sleep 1
	for t in $*; do
		\$N $C netperf -H $H -t TCP_MAERTS -l $LEN -P 0 -Y \$t,\$t -- -o THROUGHPUT >/tmp/cv-\$t.txt &
	done
	wait
	python3 - $name $LEN $* <<'EOF'
import gzip, json, sys
name, secs, tos = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
cls = {'0xb8': 'Voice', '0x88': 'Video', '0x00': 'Best Effort', '0x20': 'Bulk'}
s = json.load(gzip.open('/tmp/cv.json.gz'))['stats']
dur = s['send_call']['n'] * 0.002 if 'send_call' in s else secs + 2
got = s['packets_received'] * 1250 * 8 / dur / 1e6
sent = s['packets_sent'] * 1250 * 8 / dur / 1e6
greedy = ', '.join('%s %.1f' % (cls.get(t, t), float(open('/tmp/cv-%s.txt' % t).read() or 0)) for t in tos)
print('%-11s flow %.1f of %.1f Mbit/s (loss %.2f%%), RTT median %.2f ms; greedy: %s Mbit/s'
      % (name, got, sent, 100.0 * (1 - s['packets_received'] / max(s['packets_sent'], 1)),
         s['rtt']['median'] / 1e6, greedy))
EOF"
	[ "$TARGET" = linux ] || echo "            $(ticks_late)"
}

echo "$TARGET, diffserv4, 50 Mbit/s each way, ${LEN}s per scenario"
run voice+bulk 0xb8 0x20
run bulk+voice 0x20 0xb8
run voice+all 0xb8 0x88 0x00 0x20

[ "$TARGET" = path ] && cli 'for x in cli:cli0 srv:srv0; do
	sudo ip netns exec ${x%%:*} /usr/sbin/tc qdisc replace dev ${x#*:} root fq_codel
done'
[ "$TARGET" = linux ] && cli 'sudo pkill -f "irtt server -b 10.99"; sudo pkill -x netserver;
    sudo ip netns del lca; sudo ip netns del lcb'
exit 0
