#!/bin/sh
# fw-run.sh LABEL: run on the firewall, then start the speed test.
# Waits (up to 2 minutes) until more than 500 Mbit/s leaves on vlan02, the
# download phase, then 1 s more, then measures CPU, late ticks and the
# fork's releases over 5 s, then captures the burst pattern on vlan02.
cd /root/subtick || exit 1
obytes() { netstat -I vlan02 -bn | awk 'NR == 2 { print $11 }'; }
echo "waiting for the download on vlan02 ..."
i=0
while :; do
	b0=$(obytes); sleep 1; b1=$(obytes)
	[ $(( (b1 - b0) * 8 )) -gt 500000000 ] && break
	i=$((i + 1))
	[ $i -ge 120 ] && { echo "no download seen in 2 minutes"; exit 1; }
done
echo "download seen at $(( (b1 - b0) * 8 / 1000000 )) Mbit/s, measuring"
sleep 1
sc() { sysctl -n "$@" 2>/dev/null | tr '\n' ' '; }
hz=$(sysctl -n kern.hz)
t0=$(sc net.inet.ip.dummynet.tick_diff)
r0=$(sc net.inet.ip.dummynet.release_wakeups net.inet.ip.dummynet.release_pkts net.inet.ip.dummynet.release_late_us net.inet.ip.dummynet.release_catchups)
cpu=$(sh subtick-burst.sh cpu 5)
t1=$(sc net.inet.ip.dummynet.tick_diff)
r1=$(sc net.inet.ip.dummynet.release_wakeups net.inet.ip.dummynet.release_pkts net.inet.ip.dummynet.release_late_us net.inet.ip.dummynet.release_catchups)
burst=$(sh subtick-burst.sh burst 100000 vlan02)
echo "== $1: $(kldstat | awk '/dummynet/ { print $NF }'), release_us $(sysctl -n net.inet.ip.dummynet.release_us 2>/dev/null || echo -)"
echo "$cpu"
echo "$t0 $t1" | awk -v hz="$hz" '{ printf "ticks late %.1f%%\n", 100 * ($2 - $1) / (5 * hz) }'
[ -n "$r0" ] && echo "$r0 $r1" | awk '{ w = $5 - $1; if (w > 0)
	printf "releases between ticks %.0f/s, %.1f packets each, late mean %.0f us, later than a slot %.1f%%\n",
	    w / 5, ($6 - $2) / w, ($7 - $3) / w, 100 * ($8 - $4) / w }'
echo "$burst"
dnctl sched show 2>/dev/null | grep -c CAKE | awk '{ print "CAKE schedulers: " $1 }'
