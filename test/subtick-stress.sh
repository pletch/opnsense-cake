#!/bin/sh
# Stress the forked dummynet of SUBTICK.md on the bench, beyond
# robustness.sh, with a CAKE_DEBUG dummynet_st.ko (KO, on the router):
#
#   toggle  release_us changed every 0.2 s (0, 50, 100, 250, 1000) for
#           30 s under RRUL through CAKE
#   swap    under RRUL, the fork swapped for the stock dummynet and back
#           (subtick-swap.sh), with packets queued and a release armed
#   cycles  the same eight times in a row under one RRUL run
#   bounds  a burst of 2^48 - 1 bytes, which overflowed before patch 0005,
#           and ipfw's largest delay (9999 ms; the kernel clamps larger ones
#           from other clients): the pipe keeps its rate, the delay its value
#   pause   the router VM suspended for 5 s under RRUL (vm_pause, bench.sh;
#           skipped without PROX), as
#           a suspended VM: the pipes pass traffic at their rate after
#   coalesce  each release between ticks held 2 ms before it runs
#           (release_task_delay_us, CAKE_DEBUG), at release_us 100 under
#           RRUL, so that wakeups queue behind it: they must merge
#           (release_merged), the lateness count from the earliest
#           (release_late_max at least the hold), and the pipes keep their
#           rate
#
# Each must keep RRUL running to its end (or, for swap, cycles and pause,
# let it finish once the pipes are back), CAKE's check_errors at 0 and
# dmesg free of panics and cake_check lines; the router must answer
# afterwards. bounds, cycles and pause also need 30 of the 50 Mbit/s down.
#
#   KO=/root/work/subtick/debug/dummynet_st.ko [TESTS='swap pause'] test/subtick-stress.sh
set -u

. "$(dirname "$0")/bench.sh"
KO=${KO:?KO: the CAKE_DEBUG dummynet_st.ko on the router}
TESTS=${TESTS:-toggle swap cycles bounds pause coalesce}
fails=0

want() { case " ${TESTS} " in *" $1 "*) return 0 ;; esac; return 1; }

rrul() { # seconds -> RRUL in the cli netns, prints flent's exit status
	cli "sudo ip netns exec cli flent rrul -l $1 -H 10.10.2.2 -D /tmp \
	    >/tmp/rrul.log 2>&1; echo flent-exit \$?"
}

setup() {
	opn "cd /root/work && DOWN=50Mbit/s UP=10Mbit/s ./lul-setup.sh &&
	    /root/work/lul-sched.sh cake >/dev/null" 60 | grep lul-setup
}

bad() { opn 'dmesg | grep -ci -e panic -e cake_check -e witness -e lock.order'; }
errs() { opn 'sysctl -n net.inet.ip.dummynet.cake.check_errors'; }
# a 5 s greedy download through pipe 1, in whole Mbit/s
downrate() {
	cli "sudo ip netns exec cli netperf -H 10.10.2.2 -t TCP_MAERTS -l 5 -P 0 -- -o THROUGHPUT" |
	    awk '{ printf "%d", $1 }'
}

result() { # name ok detail
	if [ "$2" = 1 ]; then
		echo "PASS  $1  $3"
	else
		echo "FAIL  $1  $3"
		fails=$((fails + 1))
	fi
}

opn "sh /root/work/subtick-swap.sh fork $KO" 120
setup
base=$(bad)

if want toggle; then
echo "== toggle"
opn '( i=0; while [ $i -lt 30 ]; do for v in 0 50 100 250 1000; do
	sysctl -q net.inet.ip.dummynet.release_us=$v; sleep 0.2; done;
	i=$((i + 1)); done ) >/dev/null 2>&1 &' >/dev/null
r=$(rrul 30)
sleep 2
w=$(opn 'sysctl -n net.inet.ip.dummynet.release_wakeups')
[ "$r" = "flent-exit 0" ] && [ "$(errs)" = 0 ] && [ "$(bad)" = "$base" ] &&
    ok=1 || ok=0
result toggle $ok "$r, release_wakeups $w, check_errors $(errs)"

fi

if want swap; then
echo "== swap"
opn 'sysctl -q net.inet.ip.dummynet.release_us=100' >/dev/null
rrul 40 >/tmp/subtick-stress.$$ &
rpid=$!
sleep 10
s1=$(opn "sh /root/work/subtick-swap.sh stock" 120 | grep subtick-swap)
setup >/dev/null
sleep 5
s2=$(opn "sh /root/work/subtick-swap.sh fork $KO && sysctl -q net.inet.ip.dummynet.release_us=100" 120 |
    grep subtick-swap)
setup >/dev/null
wait $rpid
r=$(cat /tmp/subtick-stress.$$)
rm -f /tmp/subtick-stress.$$
alive=$(opn 'echo alive')
# RRUL may report an error from the gap while the pipes were gone; the
# router must have survived, with nothing wrong in the fork afterwards
[ "$alive" = alive ] && [ "$(errs)" = 0 ] && [ "$(bad)" = "$base" ] &&
    [ -n "$s1" ] && [ -n "$s2" ] && ok=1 || ok=0
result swap $ok "$s1; $s2; $r (a gap in the pipes may fail it), check_errors $(errs)"

fi

if want cycles; then
echo "== cycles"
# eight swaps out and back while RRUL runs: dummynet_io() still in the old
# module, with a release armed, as it goes away
rrul 80 >/tmp/subtick-stress.$$ &
rpid=$!
sleep 5
n=0
for i in 1 2 3 4 5 6 7 8; do
	opn "sh /root/work/subtick-swap.sh stock" 120 | grep -q subtick-swap && setup >/dev/null &&
	    opn "sh /root/work/subtick-swap.sh fork $KO && sysctl -q net.inet.ip.dummynet.release_us=100" 120 |
	    grep -q subtick-swap && setup >/dev/null && n=$((n + 1))
done
wait $rpid
rm -f /tmp/subtick-stress.$$
[ "$(opn 'echo alive')" = alive ] && [ $n = 8 ] && [ "$(errs)" = 0 ] && [ "$(bad)" = "$base" ] &&
    [ "$(downrate)" -gt 30 ] && ok=1 || ok=0
result cycles $ok "$n of 8 swaps out and back under RRUL, then $(downrate) Mbit/s down, check_errors $(errs)"

fi

if want bounds; then
echo "== bounds"
# values that overflowed the fork's units before patch 0005: the pipe must
# keep its rate with them
opn 'ipfw -q pipe 1 config bw 50Mbit/s burst 281474976710655' >/dev/null
b=$(opn 'ipfw pipe 1 show | head -1')
t1=$(downrate)
opn 'ipfw -q pipe 1 config bw 50Mbit/s delay 9999' >/dev/null
d=$(opn 'ipfw pipe 1 show | head -1')
setup >/dev/null
t2=$(downrate)
[ "$t1" -gt 30 ] && [ "$t2" -gt 30 ] && echo "$d" | grep -q ' 9999 ms' && [ "$(bad)" = "$base" ] &&
    ok=1 || ok=0
result bounds $ok "burst 2^48-1: '$b', $t1 Mbit/s; delay 9999 ms: '$d'; after: $t2 Mbit/s"

fi

if want pause && [ -z "${PROX:-}" ]; then
echo "== pause"
echo "SKIP  pause  no PROX/PROX_VMID to suspend the router VM with"
elif want pause; then
echo "== pause"
# the router stopped for 5 s under load (a suspended VM): its pipes gain at
# most a second of credit, and pass traffic at their rate afterwards
opn 'sysctl -q net.inet.ip.dummynet.release_us=100' >/dev/null
rrul 25 >/tmp/subtick-stress.$$ &
rpid=$!
sleep 8
vm_pause 5
wait $rpid
r=$(cat /tmp/subtick-stress.$$)
rm -f /tmp/subtick-stress.$$
t=$(downrate)
[ "$(opn 'echo alive')" = alive ] && [ "$t" -gt 30 ] && [ "$(errs)" = 0 ] && [ "$(bad)" = "$base" ] &&
    ok=1 || ok=0
result pause $ok "$r (the pause may fail it), then $t Mbit/s down, check_errors $(errs)"
fi

if want coalesce; then
echo "== coalesce"
opn 'sysctl -q net.inet.ip.dummynet.release_us=100 net.inet.ip.dummynet.release_late_max=0 &&
    sysctl -q net.inet.ip.dummynet.release_task_delay_us=2000' >/dev/null
m0=$(opn 'sysctl -n net.inet.ip.dummynet.release_merged')
r=$(rrul 20)
t=$(downrate)
m=$(($(opn 'sysctl -n net.inet.ip.dummynet.release_merged') - m0))
lm=$(opn 'sysctl -n net.inet.ip.dummynet.release_late_max')
opn 'sysctl -q net.inet.ip.dummynet.release_task_delay_us=0' >/dev/null
[ "$r" = "flent-exit 0" ] && [ "$m" -gt 0 ] && [ "$lm" -ge 2000 ] && [ "$t" -gt 30 ] &&
    [ "$(errs)" = 0 ] && [ "$(bad)" = "$base" ] && ok=1 || ok=0
result coalesce $ok "$r, $m wakeups merged, release_late_max $lm us, then $t Mbit/s down, check_errors $(errs)"
fi

echo
[ $fails = 0 ] && echo "all tests passed" || echo "$fails test(s) failed"
exit $fails
