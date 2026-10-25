#!/bin/sh
# Compare dn_sched_cake's scheduling core with Linux sch_cake's, packet by
# packet: extracts both from their sources, builds them in userland side
# by side (test/sched-diff/) and drives them with the same random traces
# of already-classified packets, checking that they send the same packet
# from the same tin and drop the same packets at every step. Fetches
# sch_cake.c and pkt_sched.h at the pinned commit unless SCH_CAKE and
# PKT_SCHED point to copies.
#
#   test/sched-diff.sh [runs [seconds [seed]]]
#
# SD_TRACE=N prints both sides' tin states from packet N on.
set -eu

LINUX_COMMIT=${LINUX_COMMIT:-700b4c6c70d6a36e6878c5ea092c4877da3f10d8}
TOP=$(cd "$(dirname "$0")/.." && pwd)
WRK=$(mktemp -d)
trap 'rm -rf "$WRK"' EXIT
RAW=https://raw.githubusercontent.com/torvalds/linux/$LINUX_COMMIT

if [ -z "${SCH_CAKE:-}" ]; then
	SCH_CAKE=$WRK/sch_cake.c
	curl -fsSL -o "$SCH_CAKE" "$RAW/net/sched/sch_cake.c"
fi
if [ -z "${PKT_SCHED:-}" ]; then
	PKT_SCHED=$WRK/pkt_sched.h
	curl -fsSL -o "$PKT_SCHED" "$RAW/include/uapi/linux/pkt_sched.h"
fi

"$TOP/test/sched-diff/extract-linux.sh" "$SCH_CAKE" "$PKT_SCHED" >"$WRK/linux-cake.inc"
python3 -I "$TOP/test/sched-diff/extract-ours.py" \
    "$TOP/sys/netpfil/ipfw/dn_sched_cake.c" >"$WRK/ours-cake.inc"

${CC:-cc} -O2 -DCAKE_DEBUG -I"$TOP/test/sched-diff" -I"$WRK" \
    -I"$TOP/sys/netpfil/ipfw" -Wall -Wno-unused-function \
    -Wno-unused-variable -Wno-unused-value -Wno-unused-but-set-variable \
    -o "$WRK/sched-diff" "$TOP/test/sched-diff/main.c" \
    "$TOP/test/sched-diff/linux.c" "$TOP/test/sched-diff/ours.c"
echo "dn_sched_cake $(git -C "$TOP" rev-parse --short HEAD 2>/dev/null || echo '?')" \
    "(working tree) vs sch_cake ${LINUX_COMMIT%"${LINUX_COMMIT#????????????}"}"
"$WRK/sched-diff" "$@"
