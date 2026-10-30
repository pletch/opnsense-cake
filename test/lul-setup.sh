#!/bin/sh
# Run on the OPNsense VM after boot: load the modules, address the test
# links and build the shaper. Not persistent; rerun after every reboot.
#
#   vtnet2 10.10.1.1/24  -> client netns (download pipe, out xmit vtnet2)
#   vtnet3 10.10.2.1/24  -> server netns (upload pipe,   out xmit vtnet3)
#
# DIR=in (or "in" in /root/work/lul-dir, for the scripts that run this
# themselves) puts the pipes on the receiving interfaces instead, in recv
# vtnet3 and vtnet2: the released packets then go on through the input
# path, which is what the fork's send threads take (spread).
set -e

# a patched ipfw/dnctl in /root/work/bin, if the base one is stock
[ -x /root/work/bin/ipfw ] && PATH=/root/work/bin:$PATH

DOWN=${DOWN:-50Mbit/s}
UP=${UP:-10Mbit/s}
DIR=${DIR:-$(cat /root/work/lul-dir 2>/dev/null || echo out)}
KO=${KO:-/root/work/dn_sched_cake/sys/modules/dn_sched_cake/dn_cake.ko}

kldstat -q -m ipfw || kldload ipfw
kldstat -q -m dummynet || kldload dummynet
# CAKE may be built into dummynet.ko (opnsense-src-cake.patch)
sysctl -q net.inet.ip.dummynet.cake.flows >/dev/null ||
    kldstat -q -n dn_cake.ko || kldload "$KO"

# manual ipfw + dummynet reinjection stalls with pf enabled; see README
pfctl -d >/dev/null 2>&1 || true

sysctl -q net.inet.ip.forwarding=1
# let the fifo baseline have a realistically bloated 1000 packet buffer
sysctl -q net.inet.ip.dummynet.pipe_slot_limit=1000

for i in vtnet2:10.10.1.1 vtnet3:10.10.2.1; do
	ifconfig "${i%%:*}" inet "${i#*:}/24" -lro -tso -txcsum -rxcsum up
done

ipfw -q flush
ipfw -q pipe flush
ipfw -q sched flush
ipfw -q queue flush
ipfw -q pipe 1 config bw "$DOWN"
ipfw -q pipe 2 config bw "$UP"
if [ "$DIR" = in ]; then
	ipfw -q add 100 queue 1 ip from any to 10.10.1.0/24 in recv vtnet3
	ipfw -q add 110 queue 2 ip from 10.10.1.0/24 to any in recv vtnet2
else
	ipfw -q add 100 queue 1 ip from any to 10.10.1.0/24 out xmit vtnet2
	ipfw -q add 110 queue 2 ip from 10.10.1.0/24 to any out xmit vtnet3
fi

/root/work/lul-sched.sh fifo
echo "lul-setup: down $DOWN up $UP, $DIR, hz $(sysctl -n kern.hz)"
