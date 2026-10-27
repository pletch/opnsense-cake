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
#   test/sched-diff.sh pace [seconds [hz ...]]
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
	curl -fsSL --retry 5 --retry-delay 10 -o "$SCH_CAKE" "$RAW/net/sched/sch_cake.c"
fi
if [ -z "${PKT_SCHED:-}" ]; then
	PKT_SCHED=$WRK/pkt_sched.h
	curl -fsSL --retry 5 --retry-delay 10 -o "$PKT_SCHED" "$RAW/include/uapi/linux/pkt_sched.h"
fi

"$TOP/test/sched-diff/extract-linux.sh" "$SCH_CAKE" "$PKT_SCHED" >"$WRK/linux-cake.inc"
python3 -I "$TOP/test/sched-diff/extract-ours.py" \
    "$TOP/sys/netpfil/ipfw/dn_sched_cake.c" >"$WRK/ours-cake.inc"

# How much of each implementation is its production source: every line
# of the extracted code not matched, in order, to the source (a line
# found elsewhere in the source does not count). Only the
# documented substitutions are allowed (sch_cake: DSCP from the trace
# instead of parsing it; dn_sched_cake: cake_hash_flow() renamed, its
# replacement in ours_shim.h returning the trace's hashes); any other
# line fails the comparison before it runs.
python3 -I - "$SCH_CAKE" "$WRK/linux-cake.inc" "$TOP/sys/netpfil/ipfw/dn_sched_cake.c" \
    "$WRK/ours-cake.inc" "$PKT_SCHED" <<'EOF'
import difflib, sys
lsrc, linc, osrc, oinc, uapi = sys.argv[1:6]
allowed = {
    'sch_cake': [
        '/* sched-diff: the DSCP comes from the trace (washing is not compared) */',
        '\t(void)wash;',
        '\treturn skb->trace->dscp;'],
    'dn_sched_cake': [
        '__attribute__((unused)) cake_hash_flow_kernel(struct mbuf *m, uint32_t perturbation, uint32_t mode,'],
}
bad = 0
for name, srcs, inc in (('sch_cake', (uapi, lsrc), linc),
                        ('dn_sched_cake', (osrc,), oinc)):
    src = [x for f in srcs for x in open(f).read().split('\n') if x.strip()]
    lines = [x for x in open(inc).read().split('\n') if x.strip()]
    matched = set()
    sm = difflib.SequenceMatcher(None, src, lines, autojunk=False)
    for b in sm.get_matching_blocks():
        matched.update(range(b.b, b.b + b.size))
    extra = [x for i, x in enumerate(lines) if i not in matched]
    print('%s: %d of %d extracted lines are its source verbatim; not:'
          % (name, len(lines) - len(extra), len(lines)))
    for x in extra:
        ok = x in allowed[name]
        bad += not ok
        print('    | ' + x + ('' if ok else '    <- not a documented substitution'))
sys.exit(1 if bad else 0)
EOF

# the ACK filter's scan cap is a deliberate addition: lift it, so that
# the comparison holds at any queue depth
${CC:-cc} -O2 -DCAKE_DEBUG -DCAKE_ACK_SCAN=1000000 -I"$TOP/test/sched-diff" -I"$WRK" \
    -I"$TOP/sys/netpfil/ipfw" -Wall -Wno-unused-function \
    -Wno-unused-variable -Wno-unused-value -Wno-unused-but-set-variable \
    -o "$WRK/sched-diff" "$TOP/test/sched-diff/main.c" \
    "$TOP/test/sched-diff/linux.c" "$TOP/test/sched-diff/ours.c"
echo "dn_sched_cake $(git -C "$TOP" rev-parse --short HEAD 2>/dev/null || echo '?')" \
    "(working tree) vs sch_cake ${LINUX_COMMIT%"${LINUX_COMMIT#????????????}"}"
"$WRK/sched-diff" "$@"
