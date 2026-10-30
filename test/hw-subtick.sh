#!/bin/sh
# Sub-tick release on real hardware (SUBTICK.md, phase 5 on a slow box):
# an OPNsense firewall with only its LAN, and two hosts on that LAN, A
# (this machine) and B, that route to each other through it with a /32
# route each, so that their traffic goes in and back out of the same
# port. hw-shaper.php's two pipes, with CAKE, shape it both ways at RATE.
# On A and on B, once per boot:
#
#   sudo ip route add B_IP/32 via FW_IP      (on A)
#   sudo ip route add A_IP/32 via FW_IP      (on B)
#
# and net.inet.ip.redirect=0 and reply-to disabled on the firewall.
#
#   test/hw-subtick.sh setup          copy the firewall's side over, create the
#                                     shaper if it is not there yet
#   test/hw-subtick.sh idle           the firewall's CPU and timer interrupts
#                                     with no traffic: dummynet unloaded, stock
#                                     dummynet with dn_cake.ko, and the fork
#   test/hw-subtick.sh load MODE...   greedy TCP both ways for each MODE: the
#                                     firewall's CPU, late ticks, releases, a
#                                     ping's RTT, the bursts out of the
#                                     download pipe, the CPU per release and
#                                     the throughput
#   test/hw-subtick.sh profile MODE   the kernel functions the firewall spends
#                                     its CPU in under the load
#   test/hw-subtick.sh threads MODE...  for each MODE, 20 s of greedy TCP both
#                                     ways (no capture, no probes but the
#                                     profile): the receiving thread's CPU and
#                                     its spinning on a lock, dummynet's and
#                                     netisr's threads, the packets staged
#                                     (patch 0008), throughput, retransmits
#                                     and ping RTT
#   test/hw-subtick.sh soak N MODE... the load N times over for each MODE in
#                                     turn, with hw-nicwatch.sh rebooting the
#                                     firewall on a NIC watchdog timeout; then
#                                     which runs ended in one
#
# MODE is off (stock dummynet and dn_cake.ko) or the fork's release
# interval in us (1000: at the tick, at kern.hz 1000). With BUSY=N, N busy
# loops run on the firewall during the load, pinned to its CPUs 0 to N-1.
# DIR=out puts the two rules on the "out" direction (default in).
#
#   FW=z8350 B=mintbox A_IP=192.168.11.59 B_IP=192.168.11.110 RATE=100 \
#       LEN=35 MEAS=10 test/hw-subtick.sh load off 1000 250 100
set -u

FW=${FW:-z8350}
B=${B:-mintbox}
A_IP=${A_IP:-192.168.11.59}
B_IP=${B_IP:-192.168.11.110}
RATE=${RATE:-100}
LEN=${LEN:-35}
MEAS=${MEAS:-10}
COUNT=${COUNT:-20000}
BUSY=${BUSY:-0}
TOP=$(cd "$(dirname "$0")/.." && pwd)
SHAPER="php /root/hw/hw-shaper.php"

# run the script on stdin on the firewall (its login shell is not sh)
fw() {
	ssh -o BatchMode=yes "$FW" sh -s
}

# the CAKE page's Apply, then the dummynet module in use
apply() {
	fw <<-EOF
	for a in "template reload OPNsense/Shaper" "template reload OPNsense/IPFW" \
	    "shaper reload" "ipfw reload"; do
		r=\$(configctl \$a); [ "\$r" = OK ] || echo "\$a: \$r"
	done
	sleep 2
	kldstat | awk '/dummynet/ { print \$NF }'
	EOF
}

# switch to MODE: off, or the fork at a release interval
mode() {
	if [ "$1" = off ]; then
		echo "$SHAPER subtick $A_IP $B_IP 0" | fw >/dev/null || exit 1
	else
		echo "$SHAPER subtick $A_IP $B_IP 1 $1" | fw >/dev/null || exit 1
	fi
	echo "$SHAPER rate $A_IP $B_IP $RATE" | fw >/dev/null || exit 1
	echo "$SHAPER direction $A_IP $B_IP ${DIR:-in}" | fw >/dev/null || exit 1
	mod=$(apply)
	MAC=$(echo "ifconfig re0 ether | awk '/ether/ { print \$2 }'" | fw)
	case "$1:$mod" in
	off:dummynet.ko|[0-9]*:dummynet_st.ko) ;;
	*) echo "mode $1: $mod is loaded"; exit 1 ;;
	esac
}

# the firewall over MEAS seconds: CPU, late ticks, timer interrupts and
# the fork's releases
measure() {
	fw <<-EOF
	cd /root/hw
	sc() { sysctl -n "\$@" 2>/dev/null | tr '\n' ' '; }
	timer() { vmstat -i | awk '/timer/ { s += \$(NF - 1) } END { print s + 0 }'; }
	rel="net.inet.ip.dummynet.release_wakeups net.inet.ip.dummynet.release_pkts
	    net.inet.ip.dummynet.release_late_us net.inet.ip.dummynet.release_catchups"
	t0=\$(sc net.inet.ip.dummynet.tick_diff); i0=\$(timer); r0=\$(sc \$rel)
	cpu=\$(sh subtick-burst.sh cpu $MEAS)
	t1=\$(sc net.inet.ip.dummynet.tick_diff); i1=\$(timer); r1=\$(sc \$rel)
	echo "\$cpu"
	echo "\$t0 \$t1 \$i0 \$i1" | awk -v hz=\$(sysctl -n kern.hz) '{
		printf "ticks late %.1f%%, timer interrupts %.0f/s\n",
		    100 * (\$2 - \$1) / ($MEAS * hz), (\$4 - \$3) / $MEAS }'
	[ -n "\$r0" ] && echo "\$r0 \$r1" | awk '{ w = \$5 - \$1; if (w > 0)
		printf "releases between ticks %.0f/s, %.1f packets each, late mean %.0f us, later than a slot %.1f%%\n",
		    w / $MEAS, (\$6 - \$2) / w, (\$7 - \$3) / w, 100 * (\$8 - \$4) / w }'
	EOF
}

# the CPU time of releases between ticks and of ticks over 5 s: each
# one's own (taking the events off the heap and dequeuing) and that of
# sending their packets on (dummynet_send(): pf, ip_output, the NIC),
# which the packets cost however they are released
per_release() {
	fw <<-'EOF'
	dtrace -x nolibs -Z -q -n '
	fbt::dummynet_fine_task:entry, fbt::dummynet_task:entry {
		self->k = probefunc == "dummynet_task" ? "tick" : "release";
		self->t = vtimestamp; self->s = 0; }
	fbt::dummynet_send:entry /self->t/ { self->st = vtimestamp; }
	fbt::dummynet_send:return /self->st/ {
		self->s += vtimestamp - self->st; self->st = 0; }
	fbt::dummynet_fine_task:return, fbt::dummynet_task:return /self->t/ {
		@n[self->k] = count();
		@own[self->k] = avg(vtimestamp - self->t - self->s);
		@send[self->k] = avg(self->s);
		self->t = 0; }
	tick-5s { exit(0); }
	END { printa("%-7s %@6d in 5 s, own %@6d ns, sending %@7d ns each\n", @n, @own, @send); }' 2>&1 |
	    grep -v -E 'lowered|^$'
	EOF
}

# median and 90th percentile of the RTTs in ping's output on stdin
rtt() {
	sed -n 's/.*time=\([0-9.]*\) ms/\1/p' | sort -n | awk '{ v[NR] = $1 }
		END { if (NR) printf "ping RTT median %.2f ms, p90 %.2f ms (%d)\n",
		    v[int((NR + 1) / 2)], v[int(NR * 0.9 + 0.5)], NR }'
}

busy_start() {
	[ "$BUSY" -gt 0 ] || return 0
	fw <<-EOF
	i=0
	while [ \$i -lt $BUSY ]; do
		daemon -f cpuset -l \$i sh -c 'while :; do :; done # hw-busy'
		i=\$((i + 1))
	done
	EOF
}

busy_stop() {
	[ "$BUSY" -gt 0 ] && echo "pkill -f 'hw-busy'" | fw
	return 0
}

load() {
	mode "$1"
	echo "== $1: $mod, release_us $(echo 'sysctl -n net.inet.ip.dummynet.release_us 2>/dev/null || echo -' | fw), $RATE Mbit/s each way$([ "$BUSY" -gt 0 ] && echo ", $BUSY busy")"
	ssh -n -o BatchMode=yes "$B" 'pgrep -x iperf3 >/dev/null || iperf3 -s -D'
	busy_start
	iperf3 -c "$B_IP" -P 4 --bidir -t "$LEN" >/tmp/hw-iperf.$$ 2>&1 &
	ip=$!
	sleep 3
	ping -n -i 0.2 -c $((MEAS * 5)) "$B_IP" >/tmp/hw-ping.$$ 2>&1 &
	measure
	wait $!
	rtt </tmp/hw-ping.$$
	# bpf on re(4) sees no outgoing packets with -Q out: the download
	# pipe's are those to A sent with the firewall's own address
	echo "bursts: $(echo "BURST_Q= sh /root/hw/subtick-burst.sh burst $COUNT re0 \
	    'ether src $MAC and dst host $A_IP'" | fw |
	    tr '\n' ';' | sed 's/;$//; s/;/; /g')"
	per_release
	wait $ip
	busy_stop
	awk '/SUM/ && /receiver/ { for (i = 2; i <= NF; i++) if ($i ~ /bits\/sec/)
		printf "%s %s %s, ", ($0 ~ /TX-C/) ? "up" : "down", $(i - 1), $i }
		END { print "received" }' /tmp/hw-iperf.$$
	rm -f /tmp/hw-iperf.$$ /tmp/hw-ping.$$
}

case "${1:-}" in
setup)
	echo "mkdir -p /root/hw" | fw
	scp -q "$TOP/test/hw-shaper.php" "$TOP/test/subtick-burst.sh" \
	    "$TOP/test/hw-nicwatch.sh" "$FW:/root/hw/" || exit 1
	if echo "$SHAPER pipes $A_IP $B_IP $RATE" | fw; then
		for s in queues rules cake; do
			echo "$SHAPER $s $A_IP $B_IP" | fw || exit 1
		done
	fi
	echo "loaded: $(apply)"
	;;
idle)
	idle() {
		echo "== $1"
		ssh -o BatchMode=yes "$FW" sh -s <<-EOF
		timer() { vmstat -i | awk '/timer/ { s += \$(NF - 1) } END { print s + 0 }'; }
		i0=\$(timer); cpu=\$(sh /root/hw/subtick-burst.sh cpu 30); i1=\$(timer)
		echo "\$cpu, timer interrupts \$(( (i1 - i0) / 30 ))/s"
		EOF
	}
	# an Apply sets off some background work: let it settle first
	mode 250
	sleep 30
	idle "fork, $mod"
	mode off
	sleep 30
	idle "stock, $mod"
	fw <<-EOF
	# a list (delete 1,2) deletes only the first
	for n in 1 2; do dnctl queue delete \$n; dnctl pipe delete \$n; done
	kldstat -q -n dn_cake && kldunload dn_cake
	kldunload \$(kldstat | awk '/dummynet/ { print \$NF }')
	kldstat | grep -E 'dummynet|cake'
	EOF
	sleep 30
	idle "dummynet unloaded"
	mode 250
	echo "restored: $mod"
	;;
load)
	shift
	[ $# -gt 0 ] || { echo "usage: $0 load MODE..." >&2; exit 1; }
	for m in "$@"; do
		load "$m"
	done
	;;
threads)
	shift
	[ $# -gt 0 ] || { echo "usage: $0 threads MODE..." >&2; exit 1; }
	for m in "$@"; do
		mode "$m"
		echo "== $m: $mod, $RATE Mbit/s each way, rules ${DIR:-in}"
		ssh -n -o BatchMode=yes "$B" 'pkill -x iperf3; sleep 1; iperf3 -s -D'
		sleep 1
		iperf3 -c "$B_IP" -P 4 --bidir -t 20 >/tmp/hw-iperf.$$ 2>&1 &
		ip=$!
		sleep 3
		ping -n -i 0.25 -c 60 "$B_IP" >/tmp/hw-ping.$$ 2>&1 &
		fw <<-'EOF'
		s0=$(sysctl -n net.inet.ip.dummynet.staged 2>/dev/null || echo 0)
		N=$(procstat -t 12 | awk '/netisr/ { printf "%stid == %s", sep, $2; sep = " || " }')
		# receiving: re0's taskqueue (Realtek's driver) or interrupt thread
		R=$(procstat -t 0 12 | awk '/re0 taskq|: re0/ { print $2; exit }')
		D=$(procstat -t 0 | awk '/ dummynet / { print $2 }')
		dtrace -x nolibs -q -n "
		profile-997 /tid == $R/ { @r[\"receiving thread on CPU\"] = count(); }
		profile-997 /tid == $R && arg0 >= (uint64_t)&\`lock_delay &&
		    arg0 < (uint64_t)&\`lock_delay + 128/ { @r[\"receiving thread spinning\"] = count(); }
		profile-997 /tid == $D/ { @r[\"dummynet thread on CPU\"] = count(); }
		profile-997 /$N/ { @r[\"netisr threads on CPU\"] = count(); }
		tick-10s { exit(0); }
		END { normalize(@r, 100); printa(\"%-26s %@3d%%\n\", @r); }" 2>&1 | grep -v lowered
		s1=$(sysctl -n net.inet.ip.dummynet.staged 2>/dev/null || echo 0)
		echo "staged $(( (s1 - s0) / 10 ))/s"
		EOF
		wait $ip
		wait
		awk '/SUM/ && /receiver/ { for (i = 2; i <= NF; i++) if ($i ~ /bits\/sec/)
			printf "%s %s %s, ", ($0 ~ /TX-C/) ? "up" : "down", $(i - 1), $i }
			/SUM/ && /sender/ { r += $(NF - 1) } END { printf "%d retransmits\n", r }' /tmp/hw-iperf.$$
		rtt </tmp/hw-ping.$$
		rm -f /tmp/hw-iperf.$$ /tmp/hw-ping.$$
	done
	;;
soak)
	shift
	n=${1:-3}
	shift
	[ $# -gt 0 ] || { echo "usage: $0 soak N MODE..." >&2; exit 1; }
	hangs() {
		echo "cat /root/hw/nicwatch.log 2>/dev/null | wc -l" | fw | tr -d ' '
	}
	# after a reboot: up, ssh, and os-cake's shaper loaded
	wait_up() {
		i=0
		until ssh -o BatchMode=yes -o ConnectTimeout=5 "$FW" true 2>/dev/null; do
			i=$((i + 1))
			[ $i -ge 60 ] && { echo "firewall not back in 10 minutes"; exit 1; }
			sleep 10
		done
		sleep 60
	}
	h0=$(hangs)
	r=1
	while [ $r -le "$n" ]; do
		for m in "$@"; do
			echo "pgrep -f hw-nicwatch >/dev/null || daemon -f sh /root/hw/hw-nicwatch.sh" | fw
			echo "## round $r, $m"
			timeout $((LEN + 120)) "$0" load "$m"
			pkill -x iperf3; pkill -x ping
			if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$FW" true 2>/dev/null; then
				echo "## firewall unreachable after $m: waiting for it"
				sleep 30
				wait_up
			fi
			h1=$(hangs)
			if [ "$h1" -gt "$h0" ]; then
				echo "## NIC hang during round $r, $m:"
				echo "tail -$((h1 - h0)) /root/hw/nicwatch.log" | fw
				h0=$h1
			fi
		done
		r=$((r + 1))
	done
	echo "## NIC hangs logged: $(hangs)"
	;;
profile)
	mode "${2:-250}"
	echo "== profile ${2:-250}: $mod"
	iperf3 -c "$B_IP" -P 4 --bidir -t 20 >/dev/null 2>&1 &
	sleep 3
	fw <<-'EOF'
	dtrace -x nolibs -q -n 'profile-997 /arg0/ { @[func(arg0)] = count(); }
	    tick-10s { exit(0); } END { trunc(@, 25); }' 2>&1 | grep -v -E 'lowered|^$'
	EOF
	wait
	;;
*)
	sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
	exit 1
	;;
esac
