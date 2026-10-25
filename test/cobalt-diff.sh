#!/bin/sh
# Compare dn_sched_cake's COBALT with Linux sch_cake's, event by event:
# extracts both implementations, builds them in userland side by side
# (test/cobalt-diff/) and plays the same random event sequences through
# them. Runs on any machine with a C compiler; fetches sch_cake.c at the
# pinned commit unless SCH_CAKE points to a copy.
#
#   test/cobalt-diff.sh [runs [events [seed]]]
set -eu

LINUX_COMMIT=${LINUX_COMMIT:-700b4c6c70d6a36e6878c5ea092c4877da3f10d8}
TOP=$(cd "$(dirname "$0")/.." && pwd)
WRK=$(mktemp -d)
trap 'rm -rf "$WRK"' EXIT

if [ -z "${SCH_CAKE:-}" ]; then
	SCH_CAKE=$WRK/sch_cake.c
	curl -fsSL -o "$SCH_CAKE" \
	    "https://raw.githubusercontent.com/torvalds/linux/$LINUX_COMMIT/net/sched/sch_cake.c"
fi

# ours: the structs, the 1/sqrt cache and the functions from the Newton
# step to cobalt_should_drop()
{
	sed -n '/^struct cobalt_params {/,/^};/p;/^struct cobalt_vars {/,/^};/p' \
	    "$TOP/sys/netpfil/ipfw/dn_sched_cake.h"
	grep '^#define COBALT_CACHE' "$TOP/sys/netpfil/ipfw/dn_sched_cake.c"
	sed -n '/^static const uint32_t cobalt_rec_inv_sqrt_cache/,/^};/p' \
	    "$TOP/sys/netpfil/ipfw/dn_sched_cake.c"
	sed -n '/^\/\* one Newton-Raphson step/,/^\/\* Helper function to update flow/p' \
	    "$TOP/sys/netpfil/ipfw/dn_sched_cake.c" | sed '$d'
} > "$WRK/ours-cobalt.inc"

# sch_cake: its structs and everything from the 1/sqrt cache to
# cobalt_should_drop(), without the forward declaration in between
{
	sed -n '/^struct cobalt_params {/,/^};/p;/^struct cobalt_vars {/,/^};/p' "$SCH_CAKE"
	sed -n '/^#define REC_INV_SQRT_CACHE/,/^static bool cake_update_flowkeys/p' "$SCH_CAKE" |
	    sed '$d' | grep -v '^static void cake_configure_rates'
} > "$WRK/linux-cobalt.inc"

for f in "$WRK/ours-cobalt.inc" "$WRK/linux-cobalt.inc"; do
	grep -q 'cobalt_should_drop' "$f" || { echo "extraction failed: $f" >&2; exit 1; }
done

cp "$TOP"/test/cobalt-diff/*.c "$TOP"/test/cobalt-diff/*.h "$WRK/"
${CC:-cc} -O2 -Wall -Wno-unused-function -o "$WRK/cobalt-diff" \
    "$WRK/main.c" "$WRK/ours.c" "$WRK/linux.c"
echo "dn_sched_cake $(git -C "$TOP" rev-parse --short HEAD 2>/dev/null || echo '?')" \
    "vs sch_cake ${LINUX_COMMIT%"${LINUX_COMMIT#????????????}"}"
"$WRK/cobalt-diff" "$@"
