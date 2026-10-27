#!/bin/sh
# Run on the OPNsense VM by subtick-baseline.sh:
#
#   subtick-burst.sh cpu SECONDS    the router's CPU use over SECONDS
#   subtick-burst.sh burst COUNT [IF]
#                                   capture COUNT full-size packets going
#                                   out on IF (vtnet2, the download pipe;
#                                   vtnet3 is the upload pipe) and report
#                                   their payload rate, the gaps between
#                                   them and the bursts they form (a gap
#                                   of 50 us or more starts a new burst)
set -e

case "$1" in
cpu)
	a=$(sysctl -n kern.cp_time)
	sleep "$2"
	b=$(sysctl -n kern.cp_time)
	echo "$a $b" | awk '{
		for (i = 1; i <= 5; i++) { d[i] = $(i + 5) - $i; n += d[i] }
		printf "router idle %.1f%%, intr %.1f%%, sys %.1f%%\n",
		    100 * d[5] / n, 100 * d[4] / n, 100 * d[3] / n
	}'
	;;
burst)
	rm -f /tmp/burst.pcap
	tcpdump -i "${3:-vtnet2}" -Q out -n -s 96 -c "$2" -w /tmp/burst.pcap \
	    greater 1000 2>/tmp/burst.err
	grep -E 'dropped' /tmp/burst.err || true
	tcpdump -r /tmp/burst.pcap -n -tt 2>/dev/null | awk '{
		t = $1
		if (n > 0) {
			g = (t - p) * 1e6
			if (g < 10) h[0]++
			else if (g < 50) h[1]++
			else if (g < 200) h[2]++
			else if (g < 500) h[3]++
			else if (g < 1000) h[4]++
			else h[5]++
			if (g >= 50) {
				nb++; sb += b; if (b > mb) mb = b
				b = 0
			}
		} else
			f = t
		b++; n++; p = t
		if ($(NF - 1) == "length") bytes += $NF
	}
	END {
		nb++; sb += b; if (b > mb) mb = b
		d = p - f
		printf "%d packets in %.2f s (payload %.0f Mbit/s), %.0f bursts/s, mean %.1f packets, largest %d\n",
		    n, d, bytes * 8 / d / 1e6, nb / d, sb / nb, mb
		printf "gaps (us): <10 %d, 10-50 %d, 50-200 %d, 200-500 %d, 500-1000 %d, >=1000 %d\n",
		    h[0], h[1], h[2], h[3], h[4], h[5]
	}'
	rm -f /tmp/burst.pcap
	;;
*)
	echo "usage: $0 cpu SECONDS | burst COUNT [IF]" >&2
	exit 1
	;;
esac
