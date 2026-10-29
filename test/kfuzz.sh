#!/bin/sh
# Malformed packets through the kernel's dummynet and CAKE on the OPNsense
# test VM, in mbuf chains of exactly sized external buffers (see
# test/kfuzz/cake_kfuzz.c): the packets of test/fuzz.sh, through the real
# mbufs, m_copydata() and jenkins_hash(). Meant for the KASAN kernel with
# the KASAN build of dummynet-st loaded (SUBTICK.md); on another kernel it
# runs, but sees only crashes and leaks. Builds the module on the VM
# against KOBJ, the running kernel's object directory.
#
#   test/kfuzz.sh [packets [seed]]	(default 1000000 packets, seed 1)
set -u

OPN=${OPN:-$HOME/VMs/opnsense-cake}
KOBJ=${KOBJ:-/root/kasanobj}
SRC=$(cd "$(dirname "$0")/.." && pwd)
PORT=8765

serve=$(mktemp -d)
cleanup() { [ -n "${httpd:-}" ] && kill "$httpd" 2>/dev/null; rm -rf "$serve"; }
trap cleanup EXIT INT TERM

tar -C "$SRC/test" -czf "$serve/kfuzz.tgz" kfuzz fuzz/gen.h
python3 -I -m http.server --bind 127.0.0.1 $PORT --directory "$serve" \
    >/dev/null 2>&1 &
httpd=$!

# run a command on OPNsense, print its output, return its exit status
opn() {
	tag=R$(date +%N)
	out=$("$OPN/sercmd.py" -t "${2:-120}" -e "END-$tag [0-9]+" \
	    "printf 'BEG-%s\\\\n' $tag; ( $1 ) 2>&1; printf 'END-%s %d\\\\n' $tag \$?")
	printf '%s\n' "$out" | sed -n "/^BEG-$tag\$/,/^END-$tag /p" | sed '1d;$d'
	rc=$(printf '%s\n' "$out" | sed -n "s/^END-$tag \([0-9]*\).*/\1/p")
	return "${rc:-99}"
}

log=$(wc -c < "$OPN/serial.log")
sleep 1
opn "rm -rf /root/kfuzz && mkdir /root/kfuzz && cd /root/kfuzz && fetch -q http://10.0.2.2:$PORT/kfuzz.tgz && tar xzf kfuzz.tgz && sh kfuzz/run.sh ${1:-1000000} ${2:-1} $KOBJ" 1800
rc=$?
if [ $rc = 99 ]; then
	# no answer: the panic, if that is what it was
	tail -c +"$log" "$OPN/serial.log" | tr -d '\r' |
	    sed -n '/^panic:/,/^KDB: enter/p' | head -40
	echo "FAIL no answer from the VM"
fi
exit $rc
