#!/bin/sh
# Run as root on the client VM at boot (installed as /usr/local/sbin/lul-netns,
# started by a oneshot systemd unit): put the two test NICs in their own
# namespaces so that client <-> server traffic is routed through OPNsense
# (bench.sh):
#   cli: cli0 10.10.1.2/24 via 10.10.1.1 (OPNsense vtnet2)
#   srv: srv0 10.10.2.2/24 via 10.10.2.1 (OPNsense vtnet3)
# The NICs are found by MAC address (CLI_MAC, SRV_MAC) and renamed, so the
# tests need not know how the hypervisor names them. Run again, it starts
# over.
set -e
CLI_MAC=${CLI_MAC:-52:54:00:c4:4e:11}
SRV_MAC=${SRV_MAC:-52:54:00:c4:4e:12}

ifbymac() { ip -o link | awk -v m="$1" 'index($0, m) { sub(":", "", $2); sub("@.*", "", $2); print $2 }'; }

setup() { # ns mac name addr gw
	if ip netns list | grep -qw "$1"; then
		ip netns pids "$1" | xargs -r kill 2>/dev/null || true
		# deleting the namespace returns its NIC to this one
		ip netns del "$1"
		sleep 1
	fi
	dev=$(ifbymac "$2")
	[ -n "$dev" ] || { echo "no NIC with MAC $2" >&2; exit 1; }
	ip link set "$dev" down
	ip link set "$dev" name "$3"
	ip netns add "$1"
	ip link set "$3" netns "$1"
	ip -n "$1" link set lo up
	ip -n "$1" addr add "$4" dev "$3"
	ip -n "$1" link set "$3" up
	ip -n "$1" route add default via "$5"
	# keep packets MTU sized, as on a real WAN link
	ip netns exec "$1" ethtool -K "$3" gro off gso off tso off 2>/dev/null || true
}

setup cli "$CLI_MAC" cli0 10.10.1.2/24 10.10.1.1
setup srv "$SRV_MAC" srv0 10.10.2.2/24 10.10.2.1

ip netns exec srv netserver -L 10.10.2.2 -p 12865
ip netns exec srv setsid irtt server -b 10.10.2.2 >/dev/null 2>&1 < /dev/null &
