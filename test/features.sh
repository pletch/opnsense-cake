#!/bin/sh
# Checks for the CAKE options beyond scheduling, on the lul-setup.sh bench
# (run with a CAKE_DEBUG module loaded to also count consistency errors):
#
#   wash        DSCP cleared at the server, ECN kept, IPv4 checksum valid
#   ecn         with ECN negotiated, COBALT marks CE instead of dropping
#   ack-filter  TCP download over a 0.2 Mbit/s upload, narrower than the
#               ~0.43 Mbit/s of ACKs a 50 Mbit/s download sends: goodput without
#               the filter, with it, and aggressive
#   ack-collision
#               the same with two downloads in one queue (flowblind, so
#               every flow collides): the filter must only replace an ACK
#               with a later one of the same connection, so both downloads
#               gain and neither stalls
#   memlimit    bytes queued under a UDP flood stay below a 32 KB limit
#   ingress     under a UDP flood, drops are charged to the rate, so less
#               is delivered than in egress mode, and the pipe passes
#               traffic again right after (the debt is bounded)
#   ingress-recovery
#               three rounds of a 10 s UDP flood and 5 s without, under a
#               10 Hz ping: each flood still gets through at a steady rate
#               near 2/3 of egress mode's (sch_cake's failsafe, no decay
#               from round to round), the ping gets through during them,
#               and right after each one it is lossless and fast again
#   rate        a pipe rate changed on its own, without reconfiguring the
#               scheduler, reaches CAKE's tin parameters
#   diffserv8, precedence
#               RRUL runs; fairness between tins is not checked, as these
#               experimental modes can starve a tin (see README)
#
#   test/features.sh
set -u

. "$(dirname "$0")/bench.sh"
fails=0
. "$(dirname "$0")/ticks.sh"

# each result with how late dummynet's tick ran since the previous one
result() { # name ok detail
	if [ "$2" = 1 ]; then
		echo "PASS  $1  $3; $(ticks_late)"
	else
		echo "FAIL  $1  $3; $(ticks_late)"
		fails=$((fails + 1))
	fi
	ticks_mark
}

sched() { opn "/root/work/lul-sched.sh cake $* >/dev/null" 30 >/dev/null; }

# delivered packets per second at the server during a 1472 byte UDP flood
flood_pps() {
	cli 'N="sudo ip netns exec"
	$N cli netperf -H 10.10.2.2 -t UDP_STREAM -l 12 -P 0 -- -m 1472 -R 1 >/dev/null 2>&1 &
	sleep 3
	f=/sys/class/net/srv0/statistics/rx_packets
	a=$($N srv cat $f); sleep 6; b=$($N srv cat $f)
	wait
	echo $(( (b - a) / 6 ))'
}

opn "cd /root/work && DOWN=50Mbit/s UP=10Mbit/s ./lul-setup.sh" 60 | tail -1
ticks_mark

echo "== wash"
opn '/root/work/opn-robust.sh v6up' 30 >/dev/null
cli 'N="sudo ip netns exec"
for x in cli:1 srv:2; do ns=${x%%:*}; n=${x#*:}
	dev=$($N $ns ip -o link | awk "!/lo:/ { sub(\":\", \"\", \$2); print \$2; exit }")
	$N $ns ip -6 addr replace fd00:$n::2/64 dev $dev nodad
	$N $ns ip -6 route replace default via fd00:$n::1
done'
sched diffserv4 wash
r=$(cli 'N="sudo ip netns exec"
$N srv timeout 8 tcpdump -l -n -v -i srv0 "icmp or icmp6" 2>/dev/null >/tmp/wash.txt &
sleep 2
$N cli ping -q -c 2 -Q 0xb9 10.10.2.2 >/dev/null
$N cli ping -6 -q -c 2 -Q 0xb9 fd00:2::2 >/dev/null
wait
grep -c "tos 0x1," /tmp/wash.txt; grep -c "class 0x01" /tmp/wash.txt
grep -c "tos 0xb9\\|class 0xb9\\|bad cksum" /tmp/wash.txt')
set -- $r 0 0 1
[ "${1:-0}" -ge 2 ] && [ "${2:-0}" -ge 2 ] && [ "${3:-1}" = 0 ] && ok=1 || ok=0
result wash $ok "EF+ECT(1) in, IPv4 tos 0x1 seen ${1:-?}x, IPv6 class 0x01 ${2:-?}x, unwashed or bad checksum ${3:-?}x"

echo "== ecn"
# both ends negotiate ECN (Linux only answers it by default), so COBALT
# marks the download instead of dropping it; count CE packets at the client
sched besteffort
r=$(cli 'N="sudo ip netns exec"
for ns in cli srv; do $N $ns sysctl -qw net.ipv4.tcp_ecn=1; done
dev=$($N cli ip -o link | awk "!/lo:/ { sub(\":\", \"\", \$2); print \$2; exit }")
$N cli timeout 14 tcpdump -l -n -i $dev "src 10.10.2.2 and ip[1] & 3 == 3" 2>/dev/null |
    wc -l > /tmp/ce.txt &
sleep 1
d=$($N cli netperf -H 10.10.2.2 -t TCP_MAERTS -l 10 -P 0 -- -o THROUGHPUT)
wait
for ns in cli srv; do $N $ns sysctl -qw net.ipv4.tcp_ecn=2; done
echo $(cat /tmp/ce.txt) ${d%%.*}')
set -- $r 0 0
[ "${1:-0}" -gt 0 ] && [ "${2:-0}" -gt 40 ] && ok=1 || ok=0
result ecn $ok "CE-marked packets at the client ${1:-?}, download ${2:-?} Mbit/s"

echo "== ack-filter"
opn "cd /root/work && DOWN=50Mbit/s UP=200Kbit/s ./lul-setup.sh" 60 >/dev/null
for mode in no-ack-filter ack-filter ack-filter-aggressive; do
	sched besteffort $mode
	d=$(cli 'sudo ip netns exec cli netperf -H 10.10.2.2 -t TCP_MAERTS -l 15 -P 0 -- -o THROUGHPUT')
	eval "down_$(echo $mode | tr - _)=\${d%%.*}"
	echo "   $mode: download $d Mbit/s"
done
# the filter must help, and aggressive mode must not do worse beyond the
# run-to-run noise (about 2 Mbit/s either way)
[ "${down_ack_filter:-0}" -gt "${down_no_ack_filter:-0}" ] &&
    [ $(( ${down_ack_filter_aggressive:-0} * 10 )) -ge $(( ${down_ack_filter:-0} * 9 )) ] &&
    ok=1 || ok=0
result ack-filter $ok "download ${down_no_ack_filter:-?} -> ${down_ack_filter:-?} -> ${down_ack_filter_aggressive:-?} Mbit/s"

echo "== ack-collision"
cli 'N="sudo ip netns exec"; $N srv ss -ltn | grep -q "0.0.0.0:12869 " ||
    $N srv netserver -L 0.0.0.0 -p 12869 >/dev/null'
for mode in no-ack-filter ack-filter; do
	sched besteffort flowblind $mode
	k0=$(opn 'sysctl -n net.inet.ip.dummynet.cake.stats | grep "^sched 2 .* tin 0 " | cut -d" " -f24' 30)
	r=$(cli 'N="sudo ip netns exec"
	$N cli netperf -H 10.10.2.11 -p 12869 -t TCP_MAERTS -l 15 -P 0 -- -o THROUGHPUT >/tmp/a.txt &
	$N cli netperf -H 10.10.2.12 -p 12869 -t TCP_MAERTS -l 15 -P 0 -- -o THROUGHPUT >/tmp/b.txt &
	wait; echo $(cat /tmp/a.txt) $(cat /tmp/b.txt)')
	k1=$(opn 'sysctl -n net.inet.ip.dummynet.cake.stats | grep "^sched 2 .* tin 0 " | cut -d" " -f24' 30)
	set -- $r 0 0
	eval "a_$(echo $mode | tr - _)=\${1%%.*} b_$(echo $mode | tr - _)=\${2%%.*}"
	eval "k_$(echo $mode | tr - _)=$(( ${k1:-0} - ${k0:-0} ))"
	echo "   $mode: downloads $1 and $2 Mbit/s, $(( ${k1:-0} - ${k0:-0} )) ACKs filtered"
done
# with the filter each download must beat the unfiltered pair's better one
[ "${k_ack_filter:-0}" -gt 0 ] &&
    [ "${a_ack_filter:-0}" -gt "${a_no_ack_filter:-0}" ] && [ "${a_ack_filter:-0}" -gt "${b_no_ack_filter:-0}" ] &&
    [ "${b_ack_filter:-0}" -gt "${a_no_ack_filter:-0}" ] && [ "${b_ack_filter:-0}" -gt "${b_no_ack_filter:-0}" ] &&
    ok=1 || ok=0
result ack-collision $ok "two downloads in one queue: ${a_no_ack_filter:-?} + ${b_no_ack_filter:-?} -> ${a_ack_filter:-?} + ${b_ack_filter:-?} Mbit/s, ${k_ack_filter:-?} ACKs filtered"

echo "== memlimit"
opn "cd /root/work && DOWN=50Mbit/s UP=10Mbit/s ./lul-setup.sh" 60 >/dev/null
sched besteffort memlimit 32k
cli 'sudo ip netns exec cli netperf -H 10.10.2.2 -t UDP_STREAM -l 10 -P 0 -- -m 1472 -R 1 >/dev/null 2>&1' &
sleep 4
q=$(opn 'for i in 1 2 3 4 5; do dnctl sched 2 show | awk "\$1 == 0 && NF >= 9 { print \$(NF-1) }"; sleep 0.5; done' 30 |
    sort -n | tail -1)
wait
[ -n "$q" ] && [ "$q" -le $((32768 + 1514)) ] && ok=1 || ok=0
result memlimit $ok "largest queued backlog ${q:-?} bytes, limit 32768"

echo "== ingress"
sched besteffort egress
e=$(flood_pps)
sched besteffort ingress
i=$(flood_pps)
sleep 1
rec=$(cli 'sudo ip netns exec cli ping -q -c 5 -i 0.2 10.10.2.2 | sed -n "s/.* \([0-9]*\)% packet loss.*/\1/p"')
[ "${i:-0}" -lt "${e:-0}" ] && [ "${rec:-100}" = 0 ] && ok=1 || ok=0
result ingress $ok "flood delivered $e pps in egress mode, $i pps in ingress mode; ping loss right after ${rec:-?}%"

echo "== ingress-recovery"
sched besteffort ingress
out=$(cli 'N="sudo ip netns exec"; f=/sys/class/net/srv0/statistics/rx_packets
rm -f /tmp/ir-ping.txt
$N cli ping -D -n -i 0.1 -w 50 10.10.2.2 >/tmp/ir-ping.txt 2>&1 &
p=$!
t0=$(date +%s.%N); sleep 2
for r in 1 2 3; do
	echo "flood $r $(date +%s.%N)"
	$N cli netperf -H 10.10.2.2 -t UDP_STREAM -l 10 -P 0 -- -m 1472 -R 1 >/dev/null 2>&1 &
	sleep 2; a=$($N srv cat $f); sleep 6; b=$($N srv cat $f); wait $!
	echo "pps $r $(( (b - a) / 6 ))"
	echo "idle $r $(date +%s.%N)"; sleep 5
done
echo "end $(date +%s.%N)"; wait $p
echo t0 $t0; cat /tmp/ir-ping.txt' 2>/dev/null)
res=$(printf '%s\n' "$out" | python3 -c '
import re, sys
lines = sys.stdin.read().split("\n")
t0 = [float(l.split()[1]) for l in lines if l.startswith("t0 ")][0]
marks = [(l.split()[0], int(l.split()[1]), float(l.split()[2])) for l in lines
         if l.split()[:1] in (["flood"], ["idle"])]
end = [float(l.split()[1]) for l in lines if l.startswith("end ")][0]
pps = [int(l.split()[2]) for l in lines if l.startswith("pps ")]
got = {}
for l in lines:
    m = re.match(r"\[([0-9.]+)\].*icmp_seq=([0-9]+).*time=([0-9.]+)", l)
    if m:
        got[int(m.group(2))] = float(m.group(3))
# ping n is sent at t0 + 0.1 * (n - 1); the phase it falls in (after the
# first second of each, so that a transition does not count)
phases = {"flood": [], "idle": []}
for i, (kind, r, t) in enumerate(marks):
    t1 = marks[i + 1][2] if i + 1 < len(marks) else end
    sent = [n for n in range(1, 501) if t + 1 <= t0 + 0.1 * (n - 1) < t1]
    phases[kind].append(sent)
def stat(seqs):
    rtt = sorted(got[n] for n in seqs if n in got)
    loss = 100.0 * (len(seqs) - len(rtt)) / max(len(seqs), 1)
    return loss, (rtt[len(rtt) // 2] if rtt else -1)
fl = [stat(x) for x in phases["flood"]]
idl = [stat(x) for x in phases["idle"]]
print(" ".join(map(str, pps)), "|", " ".join("%.1f/%.2f" % x for x in fl), "|",
      " ".join("%.1f/%.2f" % x for x in idl))
')
pps=${res%% |*}; rest=${res#* | }; fl=${rest%% |*}; idl=${rest#* | }
min=$(echo $pps | tr ' ' '\n' | sort -n | head -1); max=$(echo $pps | tr ' ' '\n' | sort -n | tail -1)
# steady (within 20%), at least half of egress mode's, ping through the
# floods with under 5% loss, and lossless below 5 ms right after each
ok=1
[ -n "$min" ] && [ "$min" -gt 0 ] && [ $((max * 10)) -le $((min * 12)) ] || ok=0
[ $((min * 2)) -ge "${e:-0}" ] || ok=0
for x in $fl; do awk "BEGIN { exit !(${x%/*} < 5) }" || ok=0; done
for x in $idl; do awk "BEGIN { exit !(${x%/*} == 0 && ${x#*/} >= 0 && ${x#*/} < 5) }" || ok=0; done
result ingress-recovery $ok "flood delivered $pps pps per round (egress mode $e); ping loss/median ms during floods $fl, right after $idl"

echo "== rate"
# dummynet does not tell the scheduler about a new pipe rate; at 1 Mbit/s
# the MTU time is 12.1 ms, so the target must rise to 1.5 times that
sched besteffort
opn 'ipfw -q pipe 1 config bw 1Mbit/s' 30 >/dev/null
cli 'sudo ip netns exec cli ping -q -c 3 -i 0.2 10.10.2.2 >/dev/null'
t=$(opn 'sysctl -n net.inet.ip.dummynet.cake.stats | grep "^sched 1 .* tin 0 " | cut -d" " -f12' 30)
opn 'ipfw -q pipe 1 config bw 50Mbit/s' 30 >/dev/null
[ "${t:-0}" -gt 15000 ] 2>/dev/null && ok=1 || ok=0
result rate $ok "tin 0 target ${t:-?} us after the pipe alone went to 1 Mbit/s (18168 expected)"

for mode in diffserv8 precedence; do
	echo "== $mode"
	sched $mode
	r=$(cli "sudo ip netns exec cli flent rrul -l 20 -H 10.10.2.2 -D /tmp -f summary 2>/dev/null" |
	    awk '/TCP download sum/ { d = $(NF-4) } /Ping \(ms\) ICMP/ { p = $(NF-3) }
		END { print d, p }')
	set -- $r 0 0
	[ "${1%%.*}" -gt 40 ] 2>/dev/null && ok=1 || ok=0
	result $mode $ok "RRUL download ${1:-?} Mbit/s, ICMP median ${2:-?} ms"
done

errs=$(opn 'sysctl -n net.inet.ip.dummynet.cake.check_errors 2>/dev/null || echo n/a' 30)
[ "$errs" = 0 ] || [ "$errs" = n/a ] && ok=1 || ok=0
result consistency $ok "check_errors $errs"

echo
[ $fails = 0 ] && echo "all tests passed" || echo "$fails test(s) failed"
exit $fails
