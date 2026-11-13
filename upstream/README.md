# CAKE for FreeBSD's dummynet

What a submission to FreeBSD would contain, generated from this
repository's one scheduler source. Not submitted; see
[FREEBSD.md](../FREEBSD.md) for the plugin-free route on OPNsense.

## What differs from the plugin's module

`sys/netpfil/ipfw/dn_sched_cake.c` and `.h` carry `CAKE_UPSTREAM`
conditionals. `resolve.sh` resolves them:

| | plugin (`dn_cake.ko`) | upstream |
|---|---|---|
| COBALT, a fresh flow | starts at 1/√1 (first signal an interval after the target is first exceeded) | as `sch_cake`: zeroed, and a reused flow slot keeps its state |
| ingress mode | yes | no: its drops charge the pipe's credit from inside the scheduler, and it does not match `sch_cake` |
| packet limit, quantum | configurable | `sch_cake`'s constants, 10240 packets (as the cap of the byte limit) and 1514 |
| overhead compensation | `wire_len` method, or the pipe's credit on a stock dummynet | `wire_len` method only (patch 0001) |
| an idle instance | expired by dummynet, its state kept by the scheduler and adopted by the next | kept by dummynet (`DN_KEEP_IDLE`, patch 0002) |
| defaults | `net.inet.ip.dummynet.cake.*` sysctls | constants |
| statistics | `net.inet.ip.dummynet.cake.stats`, from the scheduler's own list of instances | `net.inet.ip.dummynet.sched_stats`, a `stats` method dummynet calls (patch 0003) |
| parameters (`par[]`) | ten slots, three of them packed | ten slots, one value each |
| sysctl node | always | only with `CAKE_DEBUG` (`check_errors`, `link_clock`, ...) |

## Files

- `resolve.sh plugin|upstream|freebsd DIR`: the two files with the
  conditionals resolved. `freebsd` is what goes into the tree (no
  conditional left); `upstream` keeps its `CAKE_DEBUG` code, for the tests.
- `patches/` against FreeBSD `main` (fddd0bc3f875, 2026-11-08); they also
  apply to `opnsense/src` `stable/26.7`:
  - `0001-dummynet-wire-len.diff`: an optional `wire_len` method of
    `struct dn_alg`, what `serve_sched()` charges for a dequeued packet.
  - `0002-dummynet-keep-idle.diff`: `DN_KEEP_IDLE`, a scheduler without a
    mask keeps its one instance while idle.
  - `0003-dummynet-sched-stats.diff`: an optional `stats` method
    (`DN_STATS`) and `net.inet.ip.dummynet.sched_stats`, per vnet, in
    which dummynet prints what the schedulers that have one report;
    CAKE's is a line per tin. `dnctl` does not show it yet.
  - `0004-dummynet-cake-build.diff`: `sys/conf/files` and the module's
    Makefile; the scheduler itself comes from `resolve.sh freebsd`.
  - `0005-ipfw-cake.diff`: `ipfw(8)`/`dnctl(8)` parameters and `ipfw.8`
    (`mandoc -T lint` adds no warning).
  - `0006-tests-cake.diff`: a `cake` case for
    `tests/sys/netpfil/common/dummynet.sh`. Under kyua on the bench,
    `ipfw_cake` and `pf_cake` pass, as `ipfw_codel` and `pf_codel` do.
- `build.sh [DIR]`: on FreeBSD, builds `dummynet.ko` and `ipfw` with
  patches 0001-0005 against `SRCDIR` (`CAKE_DEBUG=1` for the checker).

## Tested

- `CAKE_VARIANT=upstream` runs `test/sched-diff.sh`, `test/cobalt-diff.sh`
  and `test/fuzz.sh` on the upstream build, in CI too. Against
  unmodified `sch_cake` (700b4c6c70d6): COBALT, 2000 runs and 10 million
  events, every decision the same and the first signal at the same event
  in all 2000; lockstep and link clock, every packet and drop in step.
- `test/upstream-bench.sh` on the bench (OPNsense 26.7, FreeBSD 15.1,
  2026-11-11, `CAKE_DEBUG` build): every parameter set and shown back;
  RRUL through diffserv4 48.0 Mbit/s of 50 with Bulk at 6.1% (1/16 is
  6.25%); both instances and their 1.26 MB still there 5 s after the load;
  `pppoe-llcsnap` 41.0 against 48.0 Mbit/s (1500/1749 of it is 41.2); a
  line per tin in `sched_stats`; a TCP stream from the router with TSO
  on (27 KB a packet into CAKE) and `ethernet` at 5.90 MB/s, where the
  headers and 38 bytes charged for each segment give 5.88 and for each
  packet 6.24; 40
  reconfigurations under RRUL; dummynet's memory back to its start after
  deleting everything; 0 check errors.
- Style: `tools/build/checkstyle9.pl` leaves only the `_SI( .x = )`
  initializers, which every in-tree scheduler has.

## Open

- Packets to be segmented (TSO, a host shaping its own traffic) are
  charged as their segments but queued, marked and dropped whole;
  `sch_cake` splits them by default. With COBALT's 5 ms target, a stream
  of 30 KB packets through 50 Mbit/s stayed about 5% under the rate
  (5.63 against 5.88 MB/s). Turn TSO off on a shaped interface, as
  OPNsense does.
- NAT: host isolation sees the addresses dummynet sees.
- `dnctl` does not print `sched_stats`; the sysctl was not run on a
  WITNESS kernel.
- The pipe still releases once per tick; `sch_cake`'s shaper is the
  sub-tick work in [SUBTICK.md](../SUBTICK.md), a separate proposal.
