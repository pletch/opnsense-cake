#!/bin/sh
# Robustness tests for dn_cake on the OPNsense + lul-client test VMs
# (see lul-setup.sh; run that on OPNsense after boot first).
#
# Builds and loads the CAKE_DEBUG module, then:
#   normal    RRUL through cake, consistency checks on
#   overflow  limit 64, 8 flows/tin, quantum 300: fattest-flow drops,
#             BLUE, set-associative collisions
#   flood     unpaced UDP floods with 8000-byte datagrams (IP fragments)
#             both ways, plus fragmented ICMP
#   ipv6      TCP and ping over IPv6
#   churn     scheduler type, diffserv mode and pipe rate changed every
#             second under RRUL load
#   allocfail tin count changed under RRUL while table allocations fail:
#             the old tables stay in use, then the rebuild succeeds
#   unload    kldunload refused while in use, and while a CAKE scheduler
#             is only configured (no instance yet), works once released
#             (skipped when CAKE is built into dummynet.ko)
#   leaks     mbufs, dummynet memory and queued packets back to baseline
set -u

OPN=${OPN:-$HOME/VMs/opnsense-cake}
CLI=${CLI:-$HOME/VMs/lul-client}
SRC=$(cd "$(dirname "$0")/.." && pwd)
PORT=8765
fails=0

serve=$(mktemp -d)
cleanup() { [ -n "${httpd:-}" ] && kill "$httpd" 2>/dev/null; rm -rf "$serve"; }
trap cleanup EXIT INT TERM

tar -C "$SRC/.." -czf "$serve/cake.tgz" "$(basename "$SRC")"
cp "$SRC/test/opn-robust.sh" "$SRC/test/lul-sched.sh" "$serve/"
python3 -I -m http.server --bind 127.0.0.1 $PORT --directory "$serve" \
    >/dev/null 2>&1 &
httpd=$!

# run a command on OPNsense, print its output, return its exit status
opn() {
	tag=R$(date +%N)
	out=$("$OPN/sercmd.py" -t "${2:-120}" -e "END-$tag [0-9]+" \
	    "printf 'BEG-%s\\\\n' $tag; ( $1 ) 2>&1; printf 'END-%s %d\\\\n' $tag \$?")
	printf '%s\n' "$out" | sed -n "/^BEG-$tag\$/,/^END-$tag /p" | sed '1d;$d'
	rc=$(printf '%s\n' "$out" | sed -n "s/^END-$tag \([0-9]*\).*/\1/p")
	return "${rc:-99}"
}

cli() {
	ssh -q -i "$CLI/id_lul" -p 2223 -o BatchMode=yes \
	    -o UserKnownHostsFile="$CLI/known_hosts" debian@127.0.0.1 "$@"
}

stat() { opn '/root/work/opn-robust.sh status' | sed -n "s/^$1 //p"; }

result() { # name ok detail
	if [ "$2" = 1 ]; then
		echo "PASS  $1  $3"
	else
		echo "FAIL  $1  $3"
		fails=$((fails + 1))
	fi
}

# errors must stay 0 and no new cake_check / panic lines may appear in
# dmesg (the message buffer survives a warm reboot, so count from a baseline)
consistent() { [ "$(stat check_errors)" = 0 ] && [ "$(stat dmesg_bad)" = "$base_dmesg" ]; }

rrul() { # seconds -> background RRUL in the cli netns
	cli "sudo ip netns exec cli flent rrul -l $1 -H 10.10.2.2 -D /tmp \
	    >/tmp/rrul.log 2>&1; echo flent-exit \$?"
}

# clear whatever the console shell is in the middle of (e.g. an open quote)
"$OPN/sercmd.py" -t 3 '\x03' >/dev/null 2>&1

# CAKE built into a CAKE_DEBUG dummynet.ko: only fetch the scripts
builtin=0
opn '! kldstat -q -n dn_cake.ko && sysctl -n net.inet.ip.dummynet.cake.check_errors' \
    >/dev/null && builtin=1

if [ $builtin = 1 ]; then
echo "== CAKE_DEBUG built into dummynet.ko"
opn "cd /root/work &&
fetch -qo opn-robust.sh http://10.0.2.2:$PORT/opn-robust.sh &&
fetch -qo lul-sched.sh http://10.0.2.2:$PORT/lul-sched.sh &&
chmod +x opn-robust.sh lul-sched.sh && /root/work/lul-sched.sh fifo >/dev/null &&
sysctl -n net.inet.ip.dummynet.cake.check_errors" 60 >/dev/null
else
echo "== build and load CAKE_DEBUG module"
opn "cd /root/work && fetch -qo cake.tgz http://10.0.2.2:$PORT/cake.tgz &&
fetch -qo opn-robust.sh http://10.0.2.2:$PORT/opn-robust.sh &&
fetch -qo lul-sched.sh http://10.0.2.2:$PORT/lul-sched.sh &&
chmod +x opn-robust.sh lul-sched.sh && rm -rf dn_sched_cake &&
tar xzf cake.tgz && cd dn_sched_cake/sys/modules/dn_sched_cake &&
make SYSDIR=/usr/src/sys CAKE_DEBUG=1 >/tmp/build.log 2>&1 &&
/root/work/lul-sched.sh fifo >/dev/null &&
(kldunload dn_cake 2>/dev/null; true) && kldload ./dn_cake.ko &&
sysctl -n net.inet.ip.dummynet.cake.check_errors" 300 >/dev/null
fi
if [ $? != 0 ]; then
	result build 0 "debug module not loaded, stopping"
	exit 1
fi
result build 1 "debug module loaded"

base_mbufs=$(stat mbufs)
base_dmesg=$(stat dmesg_bad)
base_dnmem=$(stat dnmem)
echo "   baseline: mbufs $base_mbufs, dummynet mem $base_dnmem"

echo "== normal"
opn '/root/work/lul-sched.sh cake' >/dev/null
r=$(rrul 30)
consistent && ok=1 || ok=0
[ "$r" = "flent-exit 0" ] || ok=0
result normal $ok "$r, check_errors $(stat check_errors)"

echo "== overflow"
d0=$(stat drops)
opn '/root/work/opn-robust.sh params limit=64 flows=8 quantum=300 &&
/root/work/lul-sched.sh cake' >/dev/null
r=$(rrul 30)
d1=$(stat drops)
opn '/root/work/opn-robust.sh params limit=10240 flows=1024 quantum=1514 &&
/root/work/lul-sched.sh cake' >/dev/null
consistent && [ "$d1" -gt "$d0" ] && [ "$r" = "flent-exit 0" ] && ok=1 || ok=0
result overflow $ok "$r, drops +$((d1 - d0)), check_errors $(stat check_errors)"

echo "== flood"
r=$(cli 'N="sudo ip netns exec"
$N cli netserver -L 10.10.1.2 -p 12866 >/dev/null 2>&1
$N cli netperf -H 10.10.2.2 -t UDP_STREAM -l 20 -P 0 -- -m 8000 -R 1 >/dev/null 2>&1 &
$N srv netperf -H 10.10.1.2 -p 12866 -t UDP_STREAM -l 20 -P 0 -- -m 8000 -R 1 >/dev/null 2>&1 &
$N cli ping -q -c 40 -i 0.25 -s 4000 10.10.2.2 | sed -n "s/.* \([0-9.]*%\) packet loss.*/frag-ping-loss \1/p"
wait
$N cli ping -q -c 5 10.10.2.2 | sed -n "s/.* \([0-9]*\)% packet loss.*/after-loss \1%/p"')
consistent && printf '%s' "$r" | grep -q 'after-loss 0%' && ok=1 || ok=0
result flood $ok "$(printf '%s' "$r" | tr '\n' ' ')check_errors $(stat check_errors)"

echo "== ipv6"
opn '/root/work/opn-robust.sh v6up' >/dev/null
r=$(cli 'N="sudo ip netns exec"
for x in cli:1 srv:2; do ns=${x%%:*}; n=${x#*:}
	dev=$($N $ns ip -o link | awk "!/lo:/ { sub(\":\", \"\", \$2); print \$2; exit }")
	$N $ns ip -6 addr replace fd00:$n::2/64 dev $dev nodad
	$N $ns ip -6 route replace default via fd00:$n::1
done
$N srv netserver -6 -L fd00:2::2 -p 12867 >/dev/null 2>&1
$N cli ping -6 -q -c 20 -i 0.2 fd00:2::2 | sed -n "s/.* \([0-9]*\)% packet loss.*/ping6-loss \1%/p"
$N cli netperf -6 -H fd00:2::2 -p 12867 -t TCP_MAERTS -l 15 -P 0 -- -o THROUGHPUT')
tput=$(printf '%s\n' "$r" | tail -1 | cut -d. -f1)
consistent && printf '%s' "$r" | grep -q 'ping6-loss 0%' &&
    [ "${tput:-0}" -gt 30 ] 2>/dev/null && ok=1 || ok=0
result ipv6 $ok "$(printf '%s' "$r" | head -1), TCP down ${tput:-?} Mbit/s"

echo "== churn"
rrul 60 >"$serve/churn.out" &
rpid=$!
sleep 5
c=$(opn '/root/work/opn-robust.sh churn 45' 120)
wait $rpid
r=$(cat "$serve/churn.out")
opn '/root/work/opn-robust.sh params diffserv=1 flowmode=7 && ipfw -q pipe 1 config bw 50Mbit/s &&
/root/work/lul-sched.sh cake' >/dev/null
consistent && [ "$r" = "flent-exit 0" ] && ok=1 || ok=0
result churn $ok "$c, $r, check_errors $(stat check_errors)"

echo "== allocfail"
rrul 45 >"$serve/allocfail.out" &
rpid=$!
sleep 5
a=$(opn '/root/work/opn-robust.sh allocfail 8' 60)
wait $rpid
r=$(cat "$serve/allocfail.out")
opn '/root/work/opn-robust.sh params diffserv=1 && /root/work/lul-sched.sh cake' >/dev/null
# two instances (one per direction) rebuilt; the failures include the
# held ones that raced the switch, so check the mask was used up instead
printf '%s\n' "$a" | awk '$1 == "held_rebuilds" && $2 == 0 && $4 > 0 &&
    $6 > 0 && $10 == 2 && $12 >= 2 && $14 == 0 { ok = 1 } END { exit !ok }' &&
    consistent && [ "$r" = "flent-exit 0" ] && ok=1 || ok=0
result allocfail $ok "$(printf '%s\n' "$a" | grep held_), $r, check_errors $(stat check_errors)"

echo "== unload"
if [ $builtin = 1 ]; then
	echo "SKIP  unload  CAKE is built into dummynet.ko"
else
errs=$(stat check_errors)
# a freshly configured scheduler has no instance, but still needs the module
opn '/root/work/lul-sched.sh cake' >/dev/null
opn 'kldunload dn_cake' >/dev/null && idle=0 || idle=1
rrul 30 >"$serve/unload.out" &
rpid=$!
sleep 8
opn 'kldunload dn_cake' >/dev/null && busy=0 || busy=1
loaded=$(stat cake_loaded)
wait $rpid
opn '/root/work/lul-sched.sh fifo' >/dev/null
opn 'kldunload dn_cake' >/dev/null && freed=1 || freed=0
opn 'kldload /root/work/dn_sched_cake/sys/modules/dn_sched_cake/dn_cake.ko' >/dev/null
[ $idle = 1 ] && [ $busy = 1 ] && [ "$loaded" = yes ] && [ $freed = 1 ] &&
    [ "$(cat "$serve/unload.out")" = "flent-exit 0" ] && ok=1 || ok=0
result unload $ok "refused with a configured scheduler: $idle, refused while in use: $busy, unloaded when released: $freed, check_errors before unload $errs"
fi

echo "== leaks"
# The NIC rings and UMA caches settle at a higher mbuf count after the
# floods, so compare against a warm count: one more cake run, back to fifo,
# and nothing may be left behind.
sleep 5
warm_mbufs=$(stat mbufs)
opn '/root/work/lul-sched.sh cake' >/dev/null
r=$(rrul 20)
opn '/root/work/lul-sched.sh fifo' >/dev/null
sleep 5
mbufs=$(stat mbufs)
dnmem=$(stat dnmem)
backlog=$(stat sched_backlog)
[ "$backlog" = 0 ] && [ "$dnmem" = "$base_dnmem" ] && [ "$r" = "flent-exit 0" ] &&
    [ "$mbufs" -le $((warm_mbufs + 64)) ] && ok=1 || ok=0
result leaks $ok "mbufs $base_mbufs (cold) $warm_mbufs (warm) -> $mbufs, dummynet mem $base_dnmem -> $dnmem, queued $backlog"

echo
[ $fails = 0 ] && echo "all tests passed" || echo "$fails test(s) failed"
exit $fails
