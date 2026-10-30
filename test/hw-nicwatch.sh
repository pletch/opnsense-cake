#!/bin/sh
# Run on the firewall by hw-subtick.sh soak: on the first NIC watchdog
# timeout from now (a re(4) transmit hang, after which the chip keeps
# hanging until a reboot), note the time and the dummynet in use in
# /root/hw/nicwatch.log and reboot. shutdown(8), not reboot(8): os-cake's
# crash marker takes an orderly shutdown as a clean end, so the fork is
# not kept out after it.
base=$(dmesg | grep -c 'watchdog timeout')
while sleep 1; do
	n=$(dmesg | grep -c 'watchdog timeout')
	[ "$n" -gt "$base" ] || continue
	echo "$(date '+%F %T') $(dmesg | grep 'watchdog timeout' | tail -1)," \
	    "$(kldstat | awk '/dummynet/ { print $NF }')," \
	    "release_us $(sysctl -n net.inet.ip.dummynet.release_us 2>/dev/null || echo -)" \
	    >>/root/hw/nicwatch.log
	sync
	shutdown -r now "NIC watchdog timeout"
	exit 0
done
