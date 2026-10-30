#!/bin/sh
# Linux and sch_cake on the hw-subtick.sh hairpin, for comparison: the
# firewall box booted from a Debian live system instead, the same NIC,
# hosts and load. Both directions leave the one port, so its egress has a
# prio qdisc with a CAKE per direction (by address), each at RATE; ICMP
# redirects off, as A and B would follow them past the router.
#
#   test/hw-linux.sh setup RATE [fw]   forwarding and the qdiscs; with fw, a
#                                      stateful nftables ruleset (conntrack),
#                                      nearer OPNsense's pf than none
#   test/hw-linux.sh rps on|off        Receive Packet Steering over all CPUs
#   test/hw-linux.sh gro on|off
#   test/hw-linux.sh run LABEL         20 s of greedy TCP both ways: the box's
#                                      CPU (all, softirq, per CPU), CAKE's
#                                      drops and marks, throughput,
#                                      retransmits and ping RTT
#
#   LX=z8350lin IF=enp1s0 B=mintbox A_IP=192.168.11.59 B_IP=192.168.11.110 \
#       test/hw-linux.sh setup 250 fw
set -u

LX=${LX:-z8350lin}
IF=${IF:-enp1s0}
B=${B:-mintbox}
A_IP=${A_IP:-192.168.11.59}
B_IP=${B_IP:-192.168.11.110}

lx() {
	ssh -o BatchMode=yes "$LX" sh -s
}

rtt() {
	sed -n 's/.*time=\([0-9.]*\) ms/\1/p' | sort -n | awk '{ v[NR] = $1 }
		END { if (NR) printf "ping RTT median %.2f ms, p90 %.2f ms, max %.2f ms (%d)\n",
		    v[int((NR + 1) / 2)], v[int(NR * 0.9 + 0.5)], v[NR], NR }'
}

case "${1:-}" in
setup)
	R=${2:?rate in Mbit/s}
	lx <<-EOF
	set -e
	sudo modprobe sch_cake
	sudo sysctl -q -w net.ipv4.ip_forward=1 net.ipv4.conf.all.send_redirects=0 \
	    net.ipv4.conf.default.send_redirects=0 net.ipv4.conf.$IF.send_redirects=0
	sudo tc qdisc del dev $IF root 2>/dev/null || true
	# band 3 for everything else (the box's own traffic)
	sudo tc qdisc add dev $IF root handle 1: prio bands 3 \
	    priomap 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
	sudo tc qdisc add dev $IF parent 1:1 handle 10: cake bandwidth ${R}mbit
	sudo tc qdisc add dev $IF parent 1:2 handle 20: cake bandwidth ${R}mbit
	sudo tc filter add dev $IF parent 1: protocol ip prio 1 u32 \
	    match ip src $B_IP/32 match ip dst $A_IP/32 flowid 1:1
	sudo tc filter add dev $IF parent 1: protocol ip prio 1 u32 \
	    match ip src $A_IP/32 match ip dst $B_IP/32 flowid 1:2
	sudo nft flush ruleset
	if [ "${3:-}" = fw ]; then
		sudo nft -f - <<-'NFT'
		table inet filter {
			chain input { type filter hook input priority 0; policy accept; }
			chain forward {
				type filter hook forward priority 0; policy drop;
				ct state established,related accept
				ct state invalid drop
				ip saddr 192.168.11.0/24 ip daddr 192.168.11.0/24 accept
			}
		}
		NFT
	fi
	echo "setup: \$(sudo tc qdisc show dev $IF | grep -c cake) CAKE qdiscs at ${R}mbit, \$(sudo nft list ruleset | grep -c 'ct state') ct rules"
	EOF
	;;
rps)
	m=0; [ "${2:-}" = on ] && m=f
	echo "echo $m | sudo tee /sys/class/net/$IF/queues/rx-0/rps_cpus >/dev/null; echo rps_cpus \$(cat /sys/class/net/$IF/queues/rx-0/rps_cpus)" | lx
	;;
gro)
	echo "sudo ethtool -K $IF gro ${2:?on or off}; sudo ethtool -k $IF | grep generic-receive" | lx
	;;
run)
	echo "== ${2:-run}"
	ssh -n -o BatchMode=yes "$B" 'pkill -x iperf3; sleep 1; iperf3 -s -D'
	sleep 1
	iperf3 -c "$B_IP" -P 4 --bidir -t 20 >/tmp/hwl-iperf.$$ 2>&1 &
	ip=$!
	sleep 3
	ping -n -i 0.25 -c 60 "$B_IP" >/tmp/hwl-ping.$$ 2>&1 &
	lx <<-EOF
	cake() { sudo tc -s qdisc show dev $IF | awk '/^qdisc cake/ { n++ }
		n && /^ *drops/ { for (i = 2; i <= NF; i++) d += \$i }
		n && /^ *marks/ { for (i = 2; i <= NF; i++) m += \$i } END { print d + 0, m + 0 }'; }
	set -- \$(cake)
	mpstat -P ALL 10 1 | awk '/^Average/ && \$2 != "CPU" {
		printf "cpu %s: busy %.0f%% (soft %.0f%%, sys %.0f%%)\n", \$2, 100 - \$NF, \$8, \$5 }'
	set -- \$1 \$2 \$(cake)
	echo "cake: drops \$((\$3 - \$1)), marks \$((\$4 - \$2)) over 10 s"
	EOF
	wait $ip
	wait
	awk '/SUM/ && /receiver/ { for (i = 2; i <= NF; i++) if ($i ~ /bits\/sec/)
		printf "%s %s %s, ", ($0 ~ /TX-C/) ? "up" : "down", $(i - 1), $i }
		/SUM/ && /sender/ { r += $(NF - 1) } END { printf "%d retransmits\n", r }' /tmp/hwl-iperf.$$
	rtt </tmp/hwl-ping.$$
	rm -f /tmp/hwl-iperf.$$ /tmp/hwl-ping.$$
	;;
*)
	sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
	exit 1
	;;
esac
