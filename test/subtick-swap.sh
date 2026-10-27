#!/bin/sh
# Run on the OPNsense VM: put the forked dummynet of SUBTICK.md in place of
# the stock one, and back.
#
#   subtick-swap.sh fork KO     turn off the os-cake entries that are on
#                               (they keep dn_cake.ko in use), noting
#                               which, unload dn_cake.ko and dummynet.ko
#                               and load KO (a dummynet_st.ko)
#   subtick-swap.sh stock       load the stock dummynet.ko again and turn
#                               the noted entries back on
#
# Uses the VM's API key, /root/work/apikey.txt (key and secret on two
# lines). Rerun lul-setup.sh afterwards for the bench pipes.
set -e

NOTE=/root/work/subtick/disabled.txt
KEY=$(sed -n 1p /root/work/apikey.txt)
SECRET=$(sed -n 2p /root/work/apikey.txt)

api() {
	curl -fsk -u "${KEY}:${SECRET}" -H 'Content-Type: application/json' \
	    -X POST -d '{}' "https://127.0.0.1/api/$1"
}

# the os-cake entries that are on, one uuid a line
enabled() {
	curl -fsk -u "${KEY}:${SECRET}" "https://127.0.0.1/api/cake/settings/search_pipes" |
	    python3 -c 'import json, sys
for r in json.load(sys.stdin)["rows"]:
    if r.get("enabled") == "1":
        print(r["uuid"])'
}

flush() {
	ipfw -q pipe flush 2>/dev/null || true
	ipfw -q sched flush 2>/dev/null || true
	ipfw -q queue flush 2>/dev/null || true
}

# dummynet, whichever file it was loaded from
unload() {
	for F in dummynet_st.ko dummynet.ko; do
		if kldstat -q -n "$F"; then kldunload -n "$F"; fi
	done
}

case "$1" in
fork)
	[ -f "$2" ] || { echo "usage: $0 fork KO" >&2; exit 1; }
	mkdir -p "$(dirname "${NOTE}")"
	if [ ! -s "${NOTE}" ]; then
		enabled > "${NOTE}"
		for U in $(cat "${NOTE}"); do
			api "cake/settings/toggle_pipe/${U}/0" >/dev/null
		done
		api cake/service/reconfigure >/dev/null
	fi
	flush
	if kldstat -q -n dn_cake.ko; then kldunload -n dn_cake.ko; fi
	unload
	kldload "$2"
	echo "subtick-swap: $(kldstat | awk '/dummynet/ { print $NF }') loaded," \
	    "subtick $(sysctl -n net.inet.ip.dummynet.subtick)," \
	    "release_us $(sysctl -n net.inet.ip.dummynet.release_us)," \
	    "os-cake entries off: $(wc -l < "${NOTE}" | tr -d ' ')"
	;;
stock)
	flush
	unload
	kldload dummynet
	if [ -f "${NOTE}" ]; then
		for U in $(cat "${NOTE}"); do
			api "cake/settings/toggle_pipe/${U}/1" >/dev/null
		done
		api cake/service/reconfigure >/dev/null
		rm -f "${NOTE}"
	fi
	echo "subtick-swap: stock dummynet loaded," \
	    "dn_cake $(kldstat -q -n dn_cake.ko && echo loaded || echo 'not loaded')"
	;;
*)
	echo "usage: $0 fork KO | stock" >&2
	exit 1
	;;
esac
