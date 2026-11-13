#!/bin/sh
# Run on the OPNsense VM with a CAKE_DEBUG dummynet_st.ko loaded
# (subtick-swap.sh fork): load through the fork from the router alone, for
# the staged packets a holder leaves to dummynet's thread (patch 0012).
#
#   subtick-handoff.sh [SECONDS [ROUNDS [STREAMS]]]
#
# Two vnet jails, hoa and hob, each on an epair to the host, which routes
# between them through CAKE on pipes 7 (hoa to hob) and 8 (back) at RATE
# (100Mbit/s). STREAMS (4) TCP streams of zeroes each way (dd into nc) and
# a 100 Hz ping (below the ICMP reply limit, net.inet.icmp.icmplim) run for
# SECONDS (20) at release_us 100, with
# net.inet.ip.dummynet.stage_rounds at ROUNDS (0: a holder enqueues
# nothing as it leaves, so all that was staged while it held the lock goes
# to dummynet's thread; 4 is the fork's own). Prints, as "name value":
# the packets staged and the holders that handed off meanwhile, the Mbit/s
# through each pipe, the ping's loss, CAKE's check_errors. Removes the
# jails, pipes and rules and puts stage_rounds back when done.
set -u

# a patched ipfw/dnctl in /root/work/bin, if the base one is stock
[ -x /root/work/bin/ipfw ] && PATH=/root/work/bin:$PATH

secs=${1:-20}
rounds=${2:-0}
streams=${3:-4}
RATE=${RATE:-100Mbit/s}
DN=net.inet.ip.dummynet

sysctl -q $DN.stage_rounds >/dev/null || {
	echo "handoff_error no $DN.stage_rounds: not a CAKE_DEBUG fork" >&2
	exit 1
}

ea= eb=
cleanup() {
	pkill -f 'nc -l 52[0-9][0-9]' 2>/dev/null
	jail -r hoa hob >/dev/null 2>&1
	[ -n "$ea" ] && ifconfig "$ea" destroy 2>/dev/null
	[ -n "$eb" ] && ifconfig "$eb" destroy 2>/dev/null
	ipfw -q delete 90 91 2>/dev/null
	for n in 7 8; do
		ipfw -q queue $n delete 2>/dev/null
		ipfw -q pipe $n delete 2>/dev/null
	done
	sysctl -q $DN.stage_rounds=4 >/dev/null
	rm -f /tmp/handoff-ping.txt
}
trap cleanup EXIT

kldstat -q -m if_epair || kldload if_epair
jail -c name=hoa vnet persist path=/ >/dev/null || exit 1
jail -c name=hob vnet persist path=/ >/dev/null || exit 1
ea=$(ifconfig epair create)
eb=$(ifconfig epair create)
ifconfig "${ea%a}b" vnet hoa
ifconfig "${eb%a}b" vnet hob
ifconfig "$ea" inet 10.97.1.1/24 up
ifconfig "$eb" inet 10.97.2.1/24 up
jexec hoa ifconfig "${ea%a}b" inet 10.97.1.2/24 up
jexec hob ifconfig "${eb%a}b" inet 10.97.2.2/24 up
jexec hoa route -q add default 10.97.1.1 >/dev/null
jexec hob route -q add default 10.97.2.1 >/dev/null
sysctl -q net.inet.ip.forwarding=1 >/dev/null

for n in 7 8; do
	ipfw -q pipe $n config bw "$RATE"
	ipfw -q sched $n config pipe $n type cake
	ipfw -q queue $n config sched $n queue 1000
done
ipfw -q add 90 queue 7 ip from 10.97.1.0/24 to 10.97.2.0/24 out xmit "$eb"
ipfw -q add 91 queue 8 ip from 10.97.2.0/24 to 10.97.1.0/24 out xmit "$ea"

bytes() { ipfw -b show "$1" | awk '{ print $3; exit }'; }
n() { sysctl -n $DN."$1"; }

sysctl -q $DN.release_us=100 $DN.stage_rounds="$rounds" >/dev/null
i=0
while [ $i -lt "$streams" ]; do
	jexec hob nc -l $((5200 + i)) >/dev/null 2>&1 &
	jexec hoa nc -l $((5250 + i)) >/dev/null 2>&1 &
	i=$((i + 1))
done
sleep 1
s0=$(n staged) h0=$(n stage_handoffs) a0=$(bytes 90) b0=$(bytes 91)
t0=$(date +%s)
i=0
while [ $i -lt "$streams" ]; do
	jexec hoa timeout "$secs" sh -c \
	    "dd if=/dev/zero bs=64k 2>/dev/null | nc 10.97.2.2 $((5200 + i))" \
	    >/dev/null 2>&1 &
	jexec hob timeout "$secs" sh -c \
	    "dd if=/dev/zero bs=64k 2>/dev/null | nc 10.97.1.2 $((5250 + i))" \
	    >/dev/null 2>&1 &
	i=$((i + 1))
done
jexec hoa ping -q -i 0.01 -s 1200 -t "$secs" 10.97.2.2 >/tmp/handoff-ping.txt 2>&1
sleep 1
t1=$(date +%s)
s1=$(n staged) h1=$(n stage_handoffs) a1=$(bytes 90) b1=$(bytes 91)

echo "handoff_rounds $rounds"
echo "handoff_staged $((s1 - s0))"
echo "handoff_handoffs $((h1 - h0))"
echo "handoff_mbit_ab $(( (a1 - a0) * 8 / (t1 - t0) / 1000000 ))"
echo "handoff_mbit_ba $(( (b1 - b0) * 8 / (t1 - t0) / 1000000 ))"
echo "handoff_ping $(grep -o '[0-9.]*% packet loss' /tmp/handoff-ping.txt)"
echo "handoff_check_errors $(n cake.check_errors)"
echo handoff_done
