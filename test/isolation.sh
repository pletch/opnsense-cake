#!/bin/sh
# Host isolation test through the OPNsense Traffic Shaper (opnsense-core-cake
# patch): two CAKE pipes, 50 Mbit/s download (out on opt1) and 10 Mbit/s
# upload (out on opt2), each with a queue the shaper rules point at.
#
# For each flow isolation mode, set through the REST API, host A
# (10.10.1.2) runs 8 TCP flows and host B (10.10.1.3) runs 1, first
# upload, then download, and B's share of the total is printed. Each flow
# goes to its own server address (10.10.2.11-18 for A, 10.10.2.20 for B),
# since with one shared server the destination host balances per flow.
#
# Expected B share, upload / download: flows 11/11%, dual-srchost 50/11%,
# dual-dsthost 11/50%, triple-isolate 50/50%, srchost 50/11%.
#
#   KEYFILE=apikey.txt test/isolation.sh [mode ...]
#
# KEYFILE holds the API key and secret on two lines.
set -u

CLI=${CLI:-$HOME/VMs/lul-client}
API=${API:-https://127.0.0.1:8443/api}
KEYFILE=${KEYFILE:?KEYFILE must name the API key file}
LEN=${LEN:-20}
MODES=${*:-flows dual-srchost dual-dsthost triple-isolate srchost}

api() { # METHOD PATH [JSON]
	auth="$(sed -n 1p "$KEYFILE"):$(sed -n 2p "$KEYFILE")"
	# a JSON content type without a body is rejected, so only send it with one
	if [ -n "${3:-}" ]; then
		curl -sk -X "$1" -u "$auth" -H 'Content-Type: application/json' \
		    -d "$3" "$API/$2"
	else
		curl -sk -X "$1" -u "$auth" "$API/$2"
	fi
}

cli() {
	ssh -q -i "$CLI/id_lul" -p 2223 -o BatchMode=yes \
	    -o UserKnownHostsFile="$CLI/known_hosts" debian@127.0.0.1 "$@"
}

# uuids of the CAKE pipes
pipes=$(api GET trafficshaper/settings/search_pipes | python3 -c '
import json, sys
for r in json.load(sys.stdin)["rows"]:
    if r.get("scheduler") in ("cake", "CAKE"):
        print(r["uuid"])')
[ -n "$pipes" ] || { echo "no CAKE pipes configured" >&2; exit 1; }

# second client host, one server address per flow
cli 'N="sudo ip netns exec"
$N cli ip addr replace 10.10.1.3/24 dev enp0s3
# netperf -L does not bind the data connection, so pick B by route
$N cli ip route replace 10.10.2.20/32 via 10.10.1.1 src 10.10.1.3
dev=$($N srv ip -o link | awk "!/lo:/ { sub(\":\", \"\", \$2); print \$2; exit }")
for i in 11 12 13 14 15 16 17 18 20; do $N srv ip addr replace 10.10.2.$i/24 dev $dev; done
# the standing netserver only listens on 10.10.2.2
$N srv ss -ltn | grep -q "0.0.0.0:12869 " || $N srv netserver -L 0.0.0.0 -p 12869 >/dev/null'

# run 8 flows from A and 1 from B; print A and B throughput, Mbit/s
measure() { # TCP_STREAM (upload) or TCP_MAERTS (download)
	cli "N='sudo ip netns exec cli'
	for i in 1 2 3 4 5 6 7 8; do
		\$N netperf -H 10.10.2.1\$i -p 12869 -t $1 -l $LEN -P 0 -- -o THROUGHPUT >/tmp/a\$i &
	done
	\$N netperf -H 10.10.2.20 -p 12869 -t $1 -l $LEN -P 0 -- -o THROUGHPUT >/tmp/b &
	wait
	cat /tmp/a? | awk '{ a += \$1 } END { printf \"%.2f \", a }'; cat /tmp/b"
}

printf '%-15s %-28s %-28s\n' mode "upload A / B (B share)" "download A / B (B share)"
for mode in $MODES; do
	for p in $pipes; do
		api POST trafficshaper/settings/set_pipe/$p \
		    "{\"pipe\":{\"cake_isolation\":\"$mode\"}}" >/dev/null
	done
	api POST trafficshaper/service/reconfigure >/dev/null
	sleep 2
	line=$(printf '%-15s' "$mode")
	for t in TCP_STREAM TCP_MAERTS; do
		set -- $(measure $t)
		line="$line $(printf '%-28s' "$(awk -v a="$1" -v b="$2" \
		    'BEGIN { printf "%.1f / %.1f (%.0f%%)", a, b, 100 * b / (a + b) }')")"
	done
	echo "$line"
done
