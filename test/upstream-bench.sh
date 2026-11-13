#!/bin/sh
# The dummynet and ipfw proposed to FreeBSD (upstream/build.sh), on the
# bench (bench.sh), with a CAKE_DEBUG build in DIR on the router:
#
#   params   every CAKE parameter set with the new ipfw and shown back
#   rrul     30 s of RRUL through diffserv4: flent ends, the tins share as
#            sch_cake's (Bulk about 1/16 of the download)
#   stats    net.inet.ip.dummynet.sched_stats has a line for each of the
#            four tins of both schedulers, with the packets RRUL sent
#   idle     the instance, and dummynet's memory, are still there 5 s after
#            the traffic stops (DN_KEEP_IDLE)
#   overhead RRUL with pppoe-llcsnap: download goodput about 1500/1749 of
#            the uncompensated one (the wire_len method)
#   tso      a TCP stream from the router itself with TSO on its
#            interface and the ethernet overhead: packets to be segmented
#            reach CAKE, and the rate is that of 38 bytes charged for
#            each segment, not each packet (skipped if the interface
#            has no TSO)
#   churn    diffserv mode, isolation mode and pipe rate changed every
#            0.5 s for 20 s under RRUL
#   delete   schedulers and pipes deleted: dummynet's memory back to what
#            it was before any
#
# Each needs CAKE's check_errors at 0 and no new panic or cake_check line
# in dmesg. Leaves the router on its stock dummynet.
#
#   DIR=/tmp/up/out-debug test/upstream-bench.sh
set -u

. "$(dirname "$0")/bench.sh"
DIR=${DIR:?DIR: the directory of upstream/build.sh output on the router}
fails=0
I="PATH=$DIR:\$PATH"

rrul() { # seconds [test]
	cli "sudo ip netns exec cli flent ${2:-rrul} -l $1 -H 10.10.2.2 -D /tmp \
	    >/tmp/rrul.log 2>&1; echo flent-exit \$?"
}
# a row of flent's summary: its average
row() { cli "grep -E '$1' /tmp/rrul.log | head -1" | awk -F: '{ print $2 + 0 }'; }
bad() { opn 'dmesg | grep -ci -e panic -e cake_check -e witness -e lock.order'; }
errs() { opn 'sysctl -n net.inet.ip.dummynet.cake.check_errors'; }
# dummynet's malloc types (two of that name): allocations and bytes in use
mem() { opn "vmstat -m | awk '\$1 == \"dummynet\" { n += \$2; b += \$3 } END { print n, b }'"; }
result() { # name ok detail
	if [ "$2" = 1 ]; then
		echo "PASS  $1  $3"
	else
		echo "FAIL  $1  $3"
		fails=$((fails + 1))
	fi
}

put "$(dirname "$0")/lul-setup.sh" "$(dirname "$0")/lul-sched.sh" /root/work/
opn "sh /root/work/subtick-swap.sh fork $DIR/dummynet.ko" 120 | grep subtick-swap
m0=$(mem)
opn "cd /root/work && $I DOWN=50Mbit/s UP=10Mbit/s ./lul-setup.sh" 60 | grep lul-setup
base=$(bad)

echo "== params"
p=$(opn "$I ipfw -q sched 1 config pipe 1 type cake target 7ms interval 120ms noecn \
    diffserv8 dual-dsthost flows 64 memlimit 2m wash ack-filter-aggressive \
    docsis overhead 22 mpu 70 ptm && $I ipfw sched show | grep '^ CAKE ' | head -1")
want=' CAKE diffserv8 dual-dsthost target 7ms interval 120ms flows 64 NoECN wash ack-filter-aggressive memlimit 2048K overhead 22 mpu 70 ptm'
d=$(opn "$I ipfw -q sched 1 config pipe 1 type cake && $I ipfw sched show | grep '^ CAKE ' | head -1")
dwant=' CAKE diffserv3 triple-isolate target 5ms interval 100ms flows 1024 ECN'
[ "$p" = "$want" ] && [ "$d" = "$dwant" ] && ok=1 || ok=0
result params $ok "'$p'; defaults '$d'"

echo "== rrul"
opn "$I /root/work/lul-sched.sh cake diffserv4" >/dev/null
r=$(rrul 30)
sum=$(row 'TCP download sum') bk=$(row 'TCP download BK')
icmp=$(cli "grep 'Ping (ms) ICMP' /tmp/rrul.log" | awk '{ print $6 }')
[ "$r" = "flent-exit 0" ] && [ "$(errs)" = 0 ] && [ "$(bad)" = "$base" ] &&
    awk -v s="$sum" -v b="$bk" 'BEGIN { exit !(s > 40 && b / s > 0.045 && b / s < 0.08) }' &&
    ok=1 || ok=0
result rrul $ok "$r, download $sum Mbit/s, Bulk $bk, ICMP median $icmp ms, check_errors $(errs)"

echo "== stats"
st=$(opn 'sysctl -n net.inet.ip.dummynet.sched_stats')
n=$(printf '%s\n' "$st" | grep -c '^sched [12] diffserv 2 tin [0-3] rate ')
pk=$(printf '%s\n' "$st" | awk '$2 == 1 { for (i = 1; i < NF; i++) if ($i == "pkts") n += $(i + 1) } END { print n + 0 }')
[ "$n" = 8 ] && [ "$pk" -gt 50000 ] && ok=1 || ok=0
result stats $ok "$n tin lines of 8, $pk packets sent by scheduler 1's tins"

echo "== idle"
sleep 5
a=$(opn "$I ipfw sched show | grep -c 'type CAKE.* 1 active'")
i1=$(mem | cut -d' ' -f2)
sleep 3
i2=$(mem | cut -d' ' -f2)
[ "$a" = 2 ] && [ "$i1" = "$i2" ] && [ "$i1" -gt 100000 ] && ok=1 || ok=0
result idle $ok "$a of 2 schedulers with an instance 5 s after the load, dummynet memory $i1 then $i2"

echo "== overhead"
opn "$I /root/work/lul-sched.sh cake besteffort" >/dev/null
r0=$(rrul 20 rrul_be); s0=$(row 'TCP download sum')
opn "$I /root/work/lul-sched.sh cake besteffort pppoe-llcsnap" >/dev/null
r1=$(rrul 20 rrul_be); s1=$(row 'TCP download sum')
[ "$r0" = "flent-exit 0" ] && [ "$r1" = "flent-exit 0" ] && [ "$(errs)" = 0 ] &&
    awk -v a="$s0" -v b="$s1" 'BEGIN { r = b / a; exit !(r > 0.82 && r < 0.90) }' &&
    ok=1 || ok=0
result overhead $ok "download $s0 Mbit/s, with pppoe-llcsnap $s1 (1500/1749 is 0.858), check_errors $(errs)"

echo "== tso"
# an AQM that does not signal: the stream then keeps the pipe busy, where
# COBALT at 5 ms, dropping packets of 30 KB, keeps it below its rate
opn "ifconfig vtnet2 txcsum tso
    $I /root/work/lul-sched.sh cake besteffort ethernet target 500ms interval 5s noecn >/dev/null
    $I ipfw -q add 90 queue 1 tcp from me to 10.10.1.0/24 out xmit vtnet2
    (nc -l 5999 </dev/zero >/dev/null 2>&1 &)" >/dev/null
cap=$(opn 'ifconfig vtnet2 | grep -c "options=.*TSO4"')
cli "sudo ip netns exec cli timeout 14 nc 10.10.1.1 5999 >/dev/null 2>&1 </dev/null &" >/dev/null 2>&1 &
sleep 4
# packets and bytes scheduler 1 has sent, 8 s apart
t=$(opn 'c() { sysctl -n net.inet.ip.dummynet.sched_stats |
    awk "\$2 == 1 { for (i = 1; i < NF; i++) { if (\$i == \"pkts\") p = \$(i + 1); if (\$i == \"bytes\") b = \$(i + 1) } } END { print p, b }"; }
    a=$(c); sleep 8; b=$(c); echo $a $b' 30)
wait
opn "pkill -f 'nc -l 5999'; $I ipfw -q delete 90; ifconfig vtnet2 -tso -txcsum" >/dev/null
# bytes a second, and bytes a packet as CAKE sent them
bps=$(echo "$t" | awk '{ printf "%d", ($4 - $2) / 8 }')
avg=$(echo "$t" | awk '{ printf "%d", ($3 - $1) ? ($4 - $2) / ($3 - $1) : 0 }')
if [ "$cap" != 1 ]; then
	echo "SKIP  tso  vtnet2 has no TSO4 (hw.vtnet.csum_disable)"
else
	[ "$avg" -gt 3000 ] && [ "$bps" -gt 5800000 ] && [ "$bps" -lt 5970000 ] &&
	    [ "$(errs)" = 0 ] && [ "$(bad)" = "$base" ] && ok=1 || ok=0
	result tso $ok "$avg bytes a packet from CAKE, $bps bytes/s through 50 Mbit/s with ethernet (headers and 38 bytes a segment: 5.88 MB/s; a packet: 6.24), check_errors $(errs)"
fi

echo "== churn"
opn "( i=0; while [ \$i -lt 40 ]; do
	set -- 'diffserv3 triple-isolate' 'diffserv4 flows' 'diffserv8 dual-srchost' \
	    'precedence dual-srchost' 'besteffort flows 64' 'diffserv4 flows 256 ack-filter'
	shift \$((i % 6))
	for n in 1 2; do $I ipfw -q sched \$n config pipe \$n type cake \$1; done
	[ \$((i % 4)) = 3 ] && $I ipfw -q pipe 1 config bw \$((30 + i % 3 * 10))Mbit/s
	i=\$((i + 1)); sleep 0.5
done; $I ipfw -q pipe 1 config bw 50Mbit/s ) >/dev/null 2>&1 &" >/dev/null
r=$(rrul 25)
sleep 2
sum=$(row 'TCP download sum')
[ "$r" = "flent-exit 0" ] && [ "$(errs)" = 0 ] && [ "$(bad)" = "$base" ] &&
    awk -v s="$sum" 'BEGIN { exit !(s > 20) }' && ok=1 || ok=0
result churn $ok "$r, 40 reconfigurations, download $sum Mbit/s, check_errors $(errs)"

echo "== delete"
opn "$I ipfw -q flush; $I ipfw -q queue flush; $I ipfw -q sched flush; $I ipfw -q pipe flush" >/dev/null
sleep 2
m1=$(mem)
[ "$m1" = "$m0" ] && [ "$(bad)" = "$base" ] && ok=1 || ok=0
result delete $ok "dummynet memory $m0 before, $m1 after"

opn "sh /root/work/subtick-swap.sh stock" 120 | grep subtick-swap
echo
[ $fails = 0 ] && echo "all tests passed" || echo "$fails test(s) failed"
exit $fails
