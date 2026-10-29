#!/bin/sh
# On the test VM, as root (test/kfuzz.sh sends it there): build
# cake_kfuzz.ko against the running kernel's object directory, then send
# malformed packets in exact-size mbuf chains (cake_kfuzz.c) through a
# CAKE pipe, in rounds with random CAKE settings, pipe rates and masks.
# During a round the scheduler is reconfigured while packets are queued,
# and some rounds end by deleting the pipe with packets still in it. At
# the end every piece must have been freed, and the CAKE_DEBUG checker
# (if built in) must have found no error. A KASAN report panics the VM.
#
#   run.sh [packets [seed [kernel object directory]]]
set -u

N=${1:-1000000}
SEED=${2:-1}
KOBJ=${3:-/root/kasanobj}
HERE=$(cd "$(dirname "$0")" && pwd)
D=/usr/local/libexec/cake/dnctl		# a dnctl that knows CAKE
P=9999
ROUNDS=20

fail() { echo "FAIL $*"; exit 1; }

make -C "$HERE" KERNBUILDDIR="$KOBJ" clean all >/tmp/kfuzz-build.log 2>&1 ||
    { tail -20 /tmp/kfuzz-build.log; fail build; }
if sysctl -n kern.conftxt | grep -Eq "^options[[:space:]]+KASAN$"; then
	echo "kernel $(sysctl -n kern.bootfile), KASAN"
else
	echo "kernel $(sysctl -n kern.bootfile), no KASAN: reads past a piece go unseen"
fi
kldstat -q -m dummynet || fail "dummynet is not loaded"
kldstat | awk '/dummynet|dn_cake/ { print "module", $5 }'
kldload "$HERE/cake_kfuzz.ko" || fail kldload
sysctl -q debug.cake_kfuzz.seed="$SEED" debug.cake_kfuzz.queue=$P >/dev/null

checks() { sysctl -n net.inet.ip.dummynet.cake.check_errors 2>/dev/null || echo none; }
# the pipe's CAKE counters, over its instances and tins
counters() {
	sysctl -n net.inet.ip.dummynet.cake.stats 2>/dev/null | awk -v p=$P '
	    { for (i = 1; i < NF; i += 2) v[$i] = $(i + 1) }
	    v["sched"] == p { n += v["pkts"]; d += v["drops"]; a += v["ack_drops"]; m += v["marks"] }
	    END { printf "sent %d dropped %d acks filtered %d marked %d", n, d, a, m }'
}
e0=$(checks)

# each round's settings, from the seed
awk -v seed="$SEED" -v rounds=$ROUNDS 'BEGIN {
	srand(seed)
	split("besteffort diffserv3 diffserv4 diffserv8 precedence", ds)
	split("flowblind srchost dsthost hosts flows dual-srchost dual-dsthost triple-isolate", iso)
	split("no-ack-filter ack-filter ack-filter-aggressive", ack)
	split("noatm atm ptm", atm)
	split("0 1Mbit/s 10Mbit/s 100Mbit/s 1Gbit/s", bw)
	for (r = 0; r < rounds; r++) {
		line = bw[int(rand() * 5) + 1] (rand() < 0.3 ? " mask src-ip 0xffffffff" : "")
		for (k = 0; k < 3; k++) {	# the settings, then two reconfigurations
			o = ds[int(rand() * 5) + 1] " " iso[int(rand() * 8) + 1] " " \
			    ack[int(rand() * 3) + 1] " " atm[int(rand() * 3) + 1] " " \
			    (rand() < 0.5 ? "ecn" : "noecn") " " (rand() < 0.5 ? "wash" : "nowash") " " \
			    (rand() < 0.3 ? "ingress" : "egress")
			if (rand() < 0.5)
				o = o " overhead " (int(rand() * 321) - 64)
			if (rand() < 0.3)
				o = o " mpu " int(rand() * 257)
			if (rand() < 0.3)
				o = o " memlimit " (1 + int(rand() * 256)) "k"
			line = line "|" o
		}
		print line "|" (rand() < 0.3 ? "delete" : "keep")
	}
}' > /tmp/kfuzz-rounds

per=$((N / ROUNDS))
r=0
total=0
while IFS='|' read -r link o1 o2 o3 end; do
	r=$((r + 1))
	# as OPNsense's shaper rules with the os-cake wrapper's CAKE; a
	# reconfiguration rebuilds CAKE's tables
	$D pipe $P config bw $link type cake $o1 >/dev/null || fail "round $r: $link $o1"
	$D queue $P config pipe $P >/dev/null || fail "round $r: queue"
	sysctl -q debug.cake_kfuzz.run=$per >/dev/null &
	run=$!
	for o in "$o2" "$o3"; do
		sleep 1
		$D pipe $P config bw $link type cake $o >/dev/null || fail "round $r: $link $o"
	done
	wait $run || fail "round $r: run"
	c=$(counters)
	total=$((total + $(echo "$c" | awk '{ print $2 + $4 }')))
	[ "$end" = delete ] && $D pipe $P delete && $D queue $P delete
	echo "round $r: bw $link; $o1; then $o2; then $o3; $end; $c;" \
	    "pieces held $(sysctl -n debug.cake_kfuzz.bufs)"
done < /tmp/kfuzz-rounds

$D pipe $P delete 2>/dev/null
$D queue $P delete 2>/dev/null
# dummynet frees what it holds at its next tick
sleep 2
left=$(sysctl -n debug.cake_kfuzz.bufs)
echo "packets $(sysctl -n debug.cake_kfuzz.packets) pieces $(sysctl -n debug.cake_kfuzz.pieces)" \
    "read-only $(sysctl -n debug.cake_kfuzz.rdonly) mutated $(sysctl -n debug.cake_kfuzz.mutated)" \
    "seed $SEED; check_errors $e0 -> $(checks)"
[ "$left" = 0 ] || fail "$left pieces not freed"
# counters since each pipe was made, so this only shows that packets went through
[ "$total" -gt 0 ] || fail "no packet reached CAKE"
kldunload cake_kfuzz || fail kldunload
[ "$(checks)" = "$e0" ] || fail "CAKE_DEBUG consistency errors"
echo PASS
