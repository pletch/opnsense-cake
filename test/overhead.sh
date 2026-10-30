#!/bin/sh
# Overhead compensation check on the lul-setup.sh bench: flood the upload
# pipe (UP, default 2 Mbit/s) with fixed-size UDP datagrams and compare
# the packet rate reaching the server with rate / (8 * wire bytes), where
# the wire bytes follow sch_cake's cake_calc_overhead().
#
#   test/overhead.sh
set -u

. "$(dirname "$0")/bench.sh"
. "$(dirname "$0")/ticks.sh"
UP=${UP:-2}		# Mbit/s; keeps 48-byte packets near 5k pps, well
			# below what the VM path forwards (8k with dn_cake.ko)
LEN=${LEN:-12}

# label|cake parameters|overhead|mpu|framing (none, atm, ptm)|UDP payload sizes
CASES=${CASES:-"none|besteffort|0|0|none|1472 100 20
ethernet|besteffort ethernet|38|84|none|1472 100 18
docsis|besteffort docsis|18|64|none|1472 100
pppoe-ptm|besteffort pppoe-ptm|30|0|ptm|1472 100
atm|besteffort atm|0|0|atm|1472 20 21
pppoe-llcsnap|besteffort pppoe-llcsnap|40|0|atm|1472 100
negative|besteffort overhead -20|-20|0|none|1472"}

# wire bytes for an IP packet of length $1
wire() { # ip overhead mpu framing
	awk -v l="$1" -v o="$2" -v mpu="$3" -v f="$4" 'BEGIN {
		if (o == 0 && mpu == 0 && f == "none") { print l; exit }
		l += o; if (l < mpu) l = mpu; if (l < 1) l = 1
		if (f == "atm") l = int((l + 47) / 48) * 53
		else if (f == "ptm") l += int((l + 63) / 64)
		print l
	}'
}

opn "cd /root/work && UP=${UP}Mbit/s ./lul-setup.sh" 60 | tail -1

printf '%-14s %8s %7s %7s %10s %10s %7s\n' case payload ip wire expect-pps got-pps ratio
fails=0
printf '%s\n' "$CASES" | while IFS='|' read -r label params ovh mpu fr sizes; do
	[ -n "$label" ] || continue
	opn "/root/work/lul-sched.sh cake $params >/dev/null; dnctl sched 2 show | grep ' CAKE'" 30 |
	    sed "s/^/  $label:/"
	for m in $sizes; do
		ip=$((m + 28))
		w=$(wire $ip "$ovh" "$mpu" "$fr")
		ticks_mark
		pps=$(cli "N='sudo ip netns exec'
		\$N cli netperf -H 10.10.2.2 -t UDP_STREAM -l $LEN -P 0 -- -m $m -R 1 >/dev/null 2>&1 &
		sleep 3
		f=/sys/class/net/srv0/statistics/rx_packets
		a=\$(\$N srv cat \$f); sleep 6; b=\$(\$N srv cat \$f)
		wait
		echo \$(( (b - a) / 6 ))")
		awk -v l="$label" -v m="$m" -v ip="$ip" -v w="$w" -v up="$UP" -v got="$pps" 'BEGIN {
			want = up * 1e6 / (8 * w)
			printf "%-14s %8d %7d %7d %10.0f %10d %7.3f ", l, m, ip, w, want, got, got / want
		}'
		ticks_late
	done
done
