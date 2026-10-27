#!/bin/sh
# What dummynet's tick costs and how it releases packets, at the router's
# current kern.hz (SUBTICK.md, phase 0), on the lul-setup.sh bench with
# SCHED (cake, or fq_codel or fifo) on both pipes at RATE:
#
#   idle    the router's CPU use and the host CPU of its qemu process with
#           no traffic (dummynet's callout runs every tick even then)
#   load    the same with 4 greedy TCP downloads, their throughput, and
#           how late the ticks ran
#   bursts  the gaps between full-size packets leaving the download pipe
#
# With LOAD=udp, the load is an unpaced UDP flood on the upload pipe
# instead, which keeps it backlogged (TCP may let it run empty, and then
# the gaps are those of the arrivals), at some CPU cost on the router.
#
#   RATE=300Mbit/s LEN=30 COUNT=60000 LOAD=tcp SCHED=cake test/subtick-baseline.sh
#
# The router fetches subtick-burst.sh from a web server on this machine
# (port 8765), as sercmd mangles quotes and backslashes. Contention and
# rrul at the same kern.hz: test/contention.sh bench, test/run-lul.sh cake.
set -u

OPN=${OPN:-$HOME/VMs/opnsense-cake}
CLI=${CLI:-$HOME/VMs/lul-client}
TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/ticks.sh"
RATE=${RATE:-300Mbit/s}
LEN=${LEN:-30}
COUNT=${COUNT:-60000}
SECS=8
LOAD=${LOAD:-tcp}
SCHED=${SCHED:-cake}

cli() {
	ssh -n -q -i "$CLI/id_lul" -p 2223 -o BatchMode=yes \
	    -o UserKnownHostsFile="$CLI/known_hosts" debian@127.0.0.1 "$@"
}

# run a command on the router and print its output
opn() {
	tag=R$(date +%N)
	"$OPN/sercmd.py" -t "${2:-120}" -e "END-$tag [0-9]+" \
	    "printf 'BEG-%s\\\\n' $tag; ( $1 ) 2>&1; printf 'END-%s %d\\\\n' $tag \$?" \
	    2>/dev/null | tr -d '\r' | sed -n "/^BEG-$tag\$/,/^END-$tag/p" | sed '1d;$d'
}

# CPU time of the router's qemu process, in clock ticks
host_cpu() {
	awk '{ print $14 + $15 }' "/proc/$(cat "$OPN/qemu.pid")/stat"
}

# router and host CPU over SECS seconds
cpu() {
	h0=$(host_cpu)
	r=$(opn "sh /root/work/subtick-burst.sh cpu $SECS" 60)
	h1=$(host_cpu)
	echo "$1: $r; host qemu $(awk -v d=$((h1 - h0)) -v s=$SECS -v t="$(getconf CLK_TCK)" \
	    'BEGIN { printf "%.0f%%", 100 * d / t / s }') of a CPU"
}

python3 -m http.server 8765 --bind 127.0.0.1 -d "$TOP/test" >/dev/null 2>&1 &
WWW=$!
trap 'kill $WWW 2>/dev/null' EXIT
sleep 1

"$OPN/sercmd.py" -t 3 '\x03' >/dev/null 2>&1
opn "fetch -qo /root/work/subtick-burst.sh http://10.0.2.2:8765/subtick-burst.sh" >/dev/null
opn "cd /root/work && DOWN=$RATE UP=$RATE ./lul-setup.sh" 60 | grep lul-setup
opn "/root/work/lul-sched.sh $SCHED" >/dev/null

cpu idle

if [ "$LOAD" = udp ]; then
	IF=vtnet3
	cli "cd /tmp; rm -f /tmp/sb-*.txt; sudo ip netns exec cli netperf \
	    -H 10.10.2.2 -t UDP_STREAM -l $LEN -P 0 -- -R 1 -m 1400 >/dev/null 2>&1" &
else
	IF=vtnet2
	cli "cd /tmp; rm -f /tmp/sb-*.txt; for i in 1 2 3 4; do
		sudo ip netns exec cli netperf -H 10.10.2.2 -t TCP_MAERTS -l $LEN -P 0 \
		    -- -o THROUGHPUT >/tmp/sb-\$i.txt &
	done; wait" &
fi
NP=$!
sleep 3
ticks_mark
cpu load
echo "load: $(ticks_late)"
echo "bursts: $(opn "sh /root/work/subtick-burst.sh burst $COUNT $IF" 120 | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
wait $NP
[ "$LOAD" = udp ] ||
    echo "load: $(cli 'cat /tmp/sb-*.txt' | awk '{ s += $1 } END { printf "%.0f", s }') Mbit/s in $LEN s"
