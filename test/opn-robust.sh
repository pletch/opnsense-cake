#!/bin/sh
# Run on the OPNsense VM; helpers for robustness.sh.
#
#   status            counters used for leak and consistency checks
#   params KEY=VAL..  set cake sysctl defaults (limit, flows, quantum, diffserv)
#   churn SECONDS     keep switching scheduler type, diffserv, isolation
#                     mode and pipe rate
#   v6up              IPv6 on the test links, shaped like IPv4
#   cpu SECONDS       all-CPU busy share over SECONDS, from kern.cp_time
#   prof SCHED SECONDS  time SCHED_enqueue/SCHED_dequeue (cake, fq_codel)
#                     with DTrace: calls, average and maximum ns
SYSCTL=net.inet.ip.dummynet.cake

case "$1" in
status)
	echo "mbufs $(netstat -m | sed -n 's|^\([0-9]*\)/.*mbufs in use.*|\1|p')"
	echo "dnmem $(vmstat -m | awk '$1 == "dummynet" { n += $2; b += $3 } END { print n, b }')"
	echo "check_errors $(sysctl -n $SYSCTL.check_errors 2>/dev/null || echo n/a)"
	echo "drops $(sysctl -n net.inet.ip.dummynet.io_pkt_drop)"
	echo "cake_loaded $(kldstat -q -n dn_cake.ko && echo yes || echo no)"
	echo "sched_backlog $(ipfw sched show 2>/dev/null |
	    awk '$1 ~ /^[0-9]+$/ && NF >= 9 { p += $(NF-2) } END { print p + 0 }')"
	echo "dmesg_bad $(dmesg | grep -cE 'cake_check|has backlog|panic')"
	;;
params)
	shift
	for kv in "$@"; do
		sysctl -q "$SYSCTL.$kv" >/dev/null || exit 1
	done
	;;
churn)
	end=$(( $(date +%s) + ${2:-30} ))
	i=0
	while [ "$(date +%s)" -lt "$end" ]; do
		# cake -> cake steps reconfigure live instances in place
		case $(( i % 6 )) in
		0) t=cake; d=0 ;; 1) t=cake; d=1 ;; 2) t=fq_codel; d=1 ;;
		3) t=cake; d=2 ;; 4) t=cake; d=2 ;; 5) t=fifo; d=0 ;;
		esac
		sysctl -q $SYSCTL.diffserv=$d >/dev/null
		sysctl -q $SYSCTL.flowmode=$(( i % 8 )) >/dev/null
		[ $(( i % 2 )) -eq 0 ] && bw=50Mbit/s || bw=30Mbit/s
		ipfw -q pipe 1 config bw $bw
		/root/work/lul-sched.sh $t >/dev/null || exit 1
		i=$(( i + 1 ))
		sleep 1
	done
	echo "churn: $i reconfigurations"
	;;
v6up)
	sysctl -q net.inet6.ip6.forwarding=1
	ifconfig vtnet2 inet6 fd00:1::1/64 alias
	ifconfig vtnet3 inet6 fd00:2::1/64 alias
	ipfw -q delete 101 111 2>/dev/null
	ipfw -q add 101 queue 1 ip6 from any to fd00:1::/64 out xmit vtnet2
	ipfw -q add 111 queue 2 ip6 from fd00:1::/64 to any out xmit vtnet3
	;;
cpu)
	a=$(sysctl -n kern.cp_time)
	sleep "${2:-10}"
	b=$(sysctl -n kern.cp_time)
	# cp_time: user nice sys intr idle
	echo $a $b | awk '{
		for (i = 1; i <= 5; i++) { d[i] = $(i + 5) - $i; t += d[i] }
		printf "cpu busy %.1f sys %.1f intr %.1f user %.1f\n",
		    100 * (t - d[5]) / t, 100 * d[3] / t, 100 * d[4] / t,
		    100 * (d[1] + d[2]) / t
	}'
	;;
prof)
	kldstat -q -m dtraceall || kldload dtraceall
	d=$(mktemp -t prof)
	cat >"$d" <<EOD
fbt:dummynet:${2}_enqueue:entry { self->e = vtimestamp; }
fbt:dummynet:${2}_enqueue:return /self->e/ {
	@ec = count(); @ea = avg(vtimestamp - self->e);
	@em = max(vtimestamp - self->e); self->e = 0;
}
fbt:dummynet:${2}_dequeue:entry { self->d = vtimestamp; }
fbt:dummynet:${2}_dequeue:return /self->d/ {
	@dc = count(); @da = avg(vtimestamp - self->d);
	@dm = max(vtimestamp - self->d); self->d = 0;
}
tick-${3:-10}s { exit(0); }
END {
	printa("prof enqueue calls %@d", @ec); printa(" avg %@d", @ea);
	printa(" max %@d\n", @em);
	printa("prof dequeue calls %@d", @dc); printa(" avg %@d", @da);
	printa(" max %@d\n", @dm);
}
EOD
	# the OPNsense kernel has no CTF, which the D libraries need
	dtrace -x nolibs -q -s "$d" | grep '^prof' | tr -s ' '
	rm -f "$d"
	;;
*)
	echo "usage: $0 status|params|churn|v6up|cpu|prof" >&2
	exit 1
	;;
esac
