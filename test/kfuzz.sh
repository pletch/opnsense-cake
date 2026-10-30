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

. "$(dirname "$0")/bench.sh"
KOBJ=${KOBJ:-/root/kasanobj}
SRC=$(cd "$(dirname "$0")/.." && pwd)

pack=$(mktemp -d)
trap 'rm -rf "$pack"' EXIT INT TERM
tar -C "$SRC/test" -czf "$pack/kfuzz.tgz" kfuzz fuzz/gen.h

opn "rm -rf /root/kfuzz && mkdir /root/kfuzz" && put "$pack/kfuzz.tgz" /root/kfuzz/ &&
opn "cd /root/kfuzz && tar xzf kfuzz.tgz && sh kfuzz/run.sh ${1:-1000000} ${2:-1} $KOBJ" 1800
rc=$?
# 255 (ssh) or 124 (timeout): no answer. A panic reboots the VM, after
# OPNsense's ddb script saves a textdump: show the panic from it
if [ $rc = 255 ] || [ $rc = 124 ]; then
	echo "FAIL no answer from the VM; waiting for it to come back"
	i=0
	until opn true 10 >/dev/null 2>&1; do
		i=$((i + 1))
		[ $i -ge 60 ] && { echo "the VM is not back after 10 minutes"; exit $rc; }
		sleep 10
	done
	opn 'f=$(ls -t /var/crash/textdump.tar.* 2>/dev/null | head -1)
	    [ -n "$f" ] && echo "$f:" && tar -xOf "$f" msgbuf.txt |
	    sed -n "/^panic:/,/^KDB: enter/p" | head -40'
fi
exit $rc
