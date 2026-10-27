#!/bin/sh
# Stress the forked dummynet of SUBTICK.md on the bench, beyond
# robustness.sh, with a CAKE_DEBUG dummynet_st.ko (KO, on the router):
#
#   toggle  release_us changed every 0.2 s (0, 50, 100, 250, 1000) for
#           30 s under RRUL through CAKE
#   swap    under RRUL, the fork swapped for the stock dummynet and back
#           (subtick-swap.sh), with packets queued and a release armed
#
# Each must keep RRUL running to its end (or, for swap, let it finish
# once the pipes are back), CAKE's check_errors at 0 and dmesg free of
# panics and cake_check lines; the router must answer afterwards.
#
#   KO=/root/work/subtick/debug/dummynet_st.ko test/subtick-stress.sh
set -u

OPN=${OPN:-$HOME/VMs/opnsense-cake}
CLI=${CLI:-$HOME/VMs/lul-client}
KO=${KO:?KO: the CAKE_DEBUG dummynet_st.ko on the router}
fails=0

opn() {
	tag=R$(date +%N)
	"$OPN/sercmd.py" -t "${2:-120}" -e "END-$tag [0-9]+" \
	    "printf 'BEG-%s\\\\n' $tag; ( $1 ) 2>&1; printf 'END-%s %d\\\\n' $tag \$?" \
	    2>/dev/null | tr -d '\r' | sed -n "/^BEG-$tag\$/,/^END-$tag/p" | sed '1d;$d'
}

cli() {
	ssh -n -q -i "$CLI/id_lul" -p 2223 -o BatchMode=yes \
	    -o UserKnownHostsFile="$CLI/known_hosts" debian@127.0.0.1 "$@"
}

rrul() { # seconds -> RRUL in the cli netns, prints flent's exit status
	cli "sudo ip netns exec cli flent rrul -l $1 -H 10.10.2.2 -D /tmp \
	    >/tmp/rrul.log 2>&1; echo flent-exit \$?"
}

setup() {
	opn "cd /root/work && DOWN=50Mbit/s UP=10Mbit/s ./lul-setup.sh &&
	    /root/work/lul-sched.sh cake >/dev/null" 60 | grep lul-setup
}

# (no double quotes or backslashes: sercmd mangles them)
bad() { opn 'dmesg | grep -ci -e panic -e cake_check -e witness -e lock.order'; }
errs() { opn 'sysctl -n net.inet.ip.dummynet.cake.check_errors'; }

result() { # name ok detail
	if [ "$2" = 1 ]; then
		echo "PASS  $1  $3"
	else
		echo "FAIL  $1  $3"
		fails=$((fails + 1))
	fi
}

"$OPN/sercmd.py" -t 3 '\x03' >/dev/null 2>&1
opn "sh /root/work/subtick-swap.sh fork $KO" 120
setup
base=$(bad)

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

echo
[ $fails = 0 ] && echo "all tests passed" || echo "$fails test(s) failed"
exit $fails
