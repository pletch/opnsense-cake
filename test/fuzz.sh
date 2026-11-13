#!/bin/sh
# Fuzz dn_sched_cake's packet parsers and scheduling core in userland:
# extracts the core from the production source as sched-diff does, but
# keeps its own flow hashing, builds it with AddressSanitizer and
# UndefinedBehaviorSanitizer (any finding aborts) and the CAKE_DEBUG
# consistency checker, and sends it malformed packets under random
# configurations (test/fuzz/fuzz.c). Fails on a sanitizer finding, a
# packet not freed, or a consistency error.
#
#   test/fuzz.sh [packets [seed]]	(default 1000000 packets, seed 1)
#
# CC picks the compiler (cc by default); it needs -fsanitize=address,undefined.
set -eu

TOP=$(cd "$(dirname "$0")/.." && pwd)
WRK=$(mktemp -d)
trap 'rm -rf "$WRK"' EXIT

# the scheduler with its build conditionals resolved: the plugin's module,
# or with CAKE_VARIANT=upstream the build proposed to FreeBSD
CAKE_VARIANT=${CAKE_VARIANT:-plugin}
SRCDIR=$WRK/src
"$TOP/upstream/resolve.sh" "$CAKE_VARIANT" "$SRCDIR"
VDEF=
[ "$CAKE_VARIANT" = upstream ] && VDEF=-DCAKE_UPSTREAM
python3 -I "$TOP/test/sched-diff/extract-ours.py" --hash \
    "$SRCDIR/dn_sched_cake.c" >"$WRK/ours-cake.inc"
${CC:-cc} -O1 -g -DCAKE_DEBUG $VDEF -fsanitize=address,undefined \
    -fno-sanitize-recover=all -fno-omit-frame-pointer \
    -I"$TOP/test/fuzz" -I"$WRK" -I"$SRCDIR" -Wall \
    -Wno-unused-function -Wno-unused-variable -Wno-unused-value \
    -Wno-unused-but-set-variable \
    -o "$WRK/fuzz" "$TOP/test/fuzz/fuzz.c"
echo "dn_sched_cake $(git -C "$TOP" rev-parse --short HEAD 2>/dev/null || echo '?') ($CAKE_VARIANT)"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 "$WRK/fuzz" "$@"
