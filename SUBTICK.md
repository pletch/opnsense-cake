# Sub-tick release timing (experimental)

A plan for a forked `dummynet.ko` that releases packets between ticks, and
what has been measured along the way. Work happens on the
`experimental/subtick-release` branch; nothing here is in a release.

## Why the pipe is tick-bound

- `dn_reschedule()` re-arms a single callout every `tick_sbt`.
  `dummynet_task()` advances `curr_time` by one tick (plus what
  `tick_delta_sum` says it fell behind) and serves every heap event due
  by then.
- `serve_sched()` adds `(now - sched_time) * bw` to the instance's credit,
  in bits × hz, and dequeues until it runs out, so a tick's packets all
  leave at one time. That is the 142-packet bursts and the Bulk / Voice
  gap in [DESIGN.md](DESIGN.md).
- Ticks are also the unit of `link.delay`, `burst`, RED's `q_time`, the
  delay profiles and the AQMs that read `V_dn_cfg.curr_time` (fq_codel,
  fq_pie, codel, pie).

## Design

1. **Keep `curr_time` in ticks.** The AQMs, delay, burst and RED keep
   their units; changing them all would mean owning code we don't need
   to touch.
2. **A fine clock for the shaper only.** The scheduler instance's
   `credit`, `sched_time` and `idle_time` move to a fine unit taken from
   `sbinuptime()`. Credit must not overflow: at 4 Gbit/s in bits ×
   10^9, about 2 s of accumulated time does, so it is clamped or scaled.
3. **A callout at the earliest due instance.** A heap of instances keyed
   in the fine unit, armed with `callout_reset_sbt(..., C_ABSOLUTE |
   C_DIRECT_EXEC)` and a precision. The tick callout stays for delay
   lines, expiry and the AQMs' clock.
4. **A release slot,** `net.inet.ip.dummynet.release_us` (around 100 µs
   to start). One wakeup per packet is 166,000/s at 2 Gbit/s, so a wakeup
   releases what is due within a slot. `release_us` equal to the tick
   should behave as stock dummynet, which is the A/B switch.
5. **Catch up from the real clock.** A late wakeup reads `sbinuptime()`
   rather than relying on the `tick_delta_sum` correction. After a stall
   it releases all it is owed, as stock dummynet does, unless a cap is
   set (phase 1: a cap trades throughput for a smaller burst).
6. **Output from the taskqueue first.** The callout enqueues `dn_task` on
   `dn_tq`, which adds jitter; measure it before sending directly from
   the callout.
7. **CAKE on the fine clock.** `dn_sched_cake.c` takes the pipe's credit
   unit, its release interval and the grain that widens its targets from
   `DN_CREDIT_HZ`, `DN_RELEASE_NS` and `DN_RELEASE_GRAIN_NS`, by default
   `hz` and a tick; the fork defines them, so the link clock's window and
   the targets' floor become the slot. A late release's batch keeps the
   link's time without the fork's help (phase 4). `link_clock=0` stays
   for comparison.

## Packaging

- **A patch series against `SRC_COMMIT`** (`patches/dummynet-subtick/`),
  not a copied tree: reviewable against stock, and rebased when
  `opnsense-watch` reports a new `dummynet.ko`.
- **The same module name.** The fork must still declare the `dummynet`
  module so that ipfw's `ip_dn_io_ptr`, the AQMs and the schedulers bind
  to it, so it cannot be loaded beside the stock one. It is installed
  under its own file name (`/boot/modules/dummynet_st.ko`) and loaded
  instead (`dummynet_name=` in loader.conf, or a swap like the dn_cake
  reload). `kldload dummynet` looks in `/boot/kernel` first.
- **CAKE built in,** as `opnsense-src-cake.patch` does: the fork changes
  `struct dn_sch_inst`, so a `dn_cake.ko` built against stock headers
  would not match.
- **CI:** another variant in `test/build-variants.sh`; not in the release
  packages until it earns it.

## Phases

| phase | work | gate |
|---|---|---|
| 0. Baseline | Stock dummynet on the bench at `kern.hz` 1000, 4000 and 10000: burst sizes, Bulk against greedy Voice, rrul ICMP, router CPU idle, late ticks | If `kern.hz=10000` gets most of the benefit at an acceptable CPU cost, the fork may not be worth it |
| 1. Model | `test/sched-diff.sh pace` with a fine clock and a release slot; slot sweep 10 µs – 1 ms, with and without late wakeups | Predicted gain against slot size; a default slot |
| 2. Fork skeleton | Patch, rename, build with `release_us` = tick; existing tests and `robustness.sh` | Same results as stock |
| 3. Fine clock and callout | Design 2–5, with counters: wakeups/s, packets per wakeup, lateness, backlog releases | No regressions; bursts shrink as modelled |
| 4. CAKE | Design 7; sched-diff pace-random, Bulk / Voice, rrul | Bulk ≈ 3.93 Mbit/s in the harness at 1000 Hz; tin shares as 1.4.2 or better |
| 5. Stress | Contention (busy host, pinned and not), load / unload under traffic, many pipes, CPU at 2 Gbit/s, a real-hardware burst capture | Acceptable cost, no hangs |
| 6. Decide | Write up in DESIGN / VERIFICATION; an opt-in package, keep it experimental, or propose upstream | |

## Risks

- The fork has to follow every OPNsense dummynet change; the
  `DUMMYNET_SHA256` pin narrows this but does not remove it.
- Fine timers are expensive in a VM; the nested 4-vCPU bench may
  overstate the cost.
- Pipes with the stock schedulers (fq_codel and others) get fine release
  too, which changes their behaviour: test them as well.

## Results

### Phase 0: stock dummynet at kern.hz 1000, 4000, 10000

Measured 2026-10-27 on the bench (cake-kmod 1.4.5, stock `dummynet.ko`,
VMs pinned: router qemu on host CPUs 0–1, client on 2–3, host otherwise
idle). `test/subtick-baseline.sh` at 300 Mbit/s each way with CAKE, 4
TCP downloads; `test/contention.sh bench` and `test/run-lul.sh cake` (30
s) at 50 Mbit/s.

| | 1000 | 4000 | 10000 |
|---|---|---|---|
| host CPU of the router's qemu, no traffic | 32%, 26% | 51% | 105%, 105% |
| under the TCP load: router idle / host qemu | 87% / 84%, 83% / 89% | 76% / 152% | 85% / 164% |
| ticks late under the TCP load | 3.9%, 4.8% | 12.8% | 6.5% |
| bursts out of the download pipe: per s, mean packets, largest | 976, 25.4, 146; 960, 26.0, 124 | 1898, 12.9, 156 | 1796, 13.7, 100 |
| Bulk flow against greedy Voice (Mbit/s, loss) | 4.1 (17%), 4.2 (16%), 4.2 (16%) | 3.8 (24%) | 3.9 (21%), 4.3 (14%), 3.8 (24%) |
| Voice RTT median against greedy Bulk | 0.88–0.93 ms | 0.92 ms | 1.97–1.98 ms |
| rrul ICMP median / 99th percentile | 1.85 / 5.49 ms | 1.48 / 5.98 ms | 1.68 / 2.90 ms |
| rrul UDP BK median | 4.93 ms | 4.68 ms | 3.73 ms |

- **dummynet does tick at 10 kHz.** DTrace on `dummynet_task` under the
  TCP load at `kern.hz=10000`: 9,300 runs/s, most 64–127 µs apart.
  Still, the capture shows only half the bursts of 1000 Hz (about 940
  gaps/s of 0.5–1 ms remain): the packets arrive from the client VM in
  bursts about a millisecond apart, and between them the pipe runs empty
  (287 of 300 Mbit/s). The bench cannot show release finer than that.
  An unpaced UDP flood (`LOAD=udp`) keeps the pipe backlogged but loads
  the router itself (41% interrupt, 70% of ticks late at 10 kHz), so it
  measures overload instead.
- **Tin shares do not depend on kern.hz any more.** Bulk against greedy
  Voice is 3.8–4.3 Mbit/s at every rate, within the run-to-run spread
  (Linux 4.2): the 1.4.2 link clock already took the tick out of the
  scheduler's decisions. Finer release would not improve them on this
  bench.
- **A faster kern.hz costs CPU all the time.** dummynet re-arms its
  callout every tick even with no traffic, and the router's qemu goes
  from about 30% of a host CPU to 105% idle at 10 kHz, and from 85% to
  160% under load; at 4000 Hz an eighth of the ticks ran late. (That the
  idle cost is dummynet's callout rather than the kernel's own hardclock
  is not yet checked.)
- **Voice RTT is the bench's, not kern.hz's.** It was 1.97 ms at 10 kHz
  against 0.9 at 1000 and 4000 Hz, but in phase 2 stock dummynet at 1000
  Hz gave 1.8–1.9 ms too, after another reboot of the router: the median
  is about 0.9 or 1.9 ms depending on the boot, whatever the module or
  kern.hz. Compare it only within one boot. (Phase 3 found why: the
  tick's phase, see there.)
- **Gate.** `kern.hz=10000` is no substitute in a VM: it costs a host CPU
  at idle for little gain here. But this bench gains little from finer
  release at all; the case for the fork is a fast NIC feeding a slower
  shaped link on real hardware (DESIGN.md, release bursts), and a fork
  that arms its timer only when packets are due would also drop the idle
  cost. Next: a burst capture on real hardware at 1000 and 4000 Hz, and
  phase 1 in the harness.

### Phase 1: the release clock in the harness

`test/sched-diff.sh release [bulkvoice|fast [seconds [slot_us ...]]]`
drives sch_cake (its own shaper: the reference) and dn_sched_cake behind
a model of the pipe (`test/sched-diff/ours.c`) with the same trace, event
to event. Slot 0 is dummynet as it is at `SD_HZ`: credit in bits × hz,
io_fast's initial credit, a wakeup every tick. Otherwise the fine clock:
credit in bits × 10^6, and while packets are due a wakeup at the first
point of a grid of the slot at or after the next one is due. Measured:
wakeups, how long a packet waited after it was due (hold), the delay of
a probe (100-byte datagrams every ms, a sparse flow) and the queue the
releases build at a next hop 1/0.95 times the pipe's rate (a modem behind
a shaper at 95%). `fast` is 16 greedy flows of full-size packets at 1.2
times the rate, `bulkvoice` contention.sh's Bulk against greedy Voice.

`fast` at 1 Gbit/s (3 s; µs):

| release | wakeups/s | packets each | hold mean / max | next hop queue mean / max | probe delay mean / p99 |
|---|---|---|---|---|---|
| stock 1000 Hz | 1000 | 83.5 | 500 / 1000 | 464 / 945 | 506 / 993 |
| slot 10 µs | 82,560 | 1.0 | 5 / 10 | 3 / 7 | 7 / 19 |
| slot 25 µs | 40,000 | 2.1 | 12 / 25 | 8 / 23 | 13 / 24 |
| slot 50 µs | 20,000 | 4.2 | 25 / 50 | 19 / 47 | 25 / 49 |
| slot 100 µs | 10,000 | 8.3 | 50 / 100 | 42 / 93 | 51 / 99 |
| slot 250 µs | 4000 | 20.9 | 125 / 250 | 112 / 231 | 126 / 247 |
| slot 500 µs | 2000 | 41.7 | 250 / 500 | 229 / 473 | 251 / 496 |
| sch_cake | | | | 0 / 0 | 6 / 11 |

- **The slot sets the delay, not the rate.** At 100 Mbit/s and 2 Gbit/s
  the hold and the next hop queue are the same in time (a mean of half
  the slot, at most the slot); only the packets per wakeup scale with the
  rate, and the wakeups are at most the packet rate (at 100 Mbit/s, 8300
  packets/s, so slots of 100 µs and less wake for nearly every packet).
  So stock dummynet at 1000 Hz adds a mean 0.5 ms, at most 1 ms, to each
  packet of a backlogged pipe at any rate, and a sparse flow sees it: at
  100 Mbit/s the probe waits 493 µs on average against sch_cake's 60.
  DESIGN.md's "it matters when a much faster NIC feeds a slower link"
  holds for the bytes a burst puts on the next hop, not for this. The
  bench agrees: the rrul ICMP median fell 0.37 ms from 1000 to 4000 Hz
  (phase 0), where the model's mean hold falls 0.375 ms.
- **A slot is kern.hz = 1/slot,** to the microsecond: slot 1000 µs gives
  exactly stock 1000 Hz, slot 250 µs stock 4000 Hz. The fine clock's gain
  over a faster tick is its cost: it wakes only while packets are due
  (never on an idle pipe), and at low rates per packet.
- **Tin shares:** with the link clock (as released), Bulk gets sch_cake's
  3.93 Mbit/s at every slot and at stock 1000 Hz. Without it, slots of
  10–50 µs get 3.93 too, 100 µs 3.90, 250 µs 3.77, stock 1000 Hz 3.41.
  The link clock is still needed above about 50 µs, with the slot as its
  window.

With the CPU away (`SD_STALLS`, `SD_STALL_US`), `fast` at 1 Gbit/s; a
cap of n slots on the credit after a stall:

| stalls | release | Mbit/s | next hop queue mean / max (µs) | probe delay mean / p99 (µs) |
|---|---|---|---|---|
| 40/s up to 1 ms | stock 1000 Hz | 1000 | 499 / 1809 | 511 / 998 |
| | slot 100 µs | 1000 | 144 / 990 | 57 / 332 |
| | slot 100 µs, cap 1 | 982 | 42 / 94 | 57 / 360 |
| | slot 100 µs, cap 2 | 985 | 46 / 190 | 57 / 360 |
| | slot 250 µs | 1000 | 201 / 1159 | 133 / 443 |
| | slot 250 µs, cap 2 | 992 | 129 / 473 | 134 / 443 |
| 60/s up to 8 ms | stock 1000 Hz | 1000 | 3874 / 8423 | 992 / 6551 |
| | slot 100 µs | 998 | 4065 / 7658 | 606 / 6094 |
| | slot 100 µs, cap 2 | 812 | 49 / 189 | 544 / 6152 |

- **Light stalls:** the fine clock without a cap already cuts the next
  hop queue to less than a third and the probe's delay ninefold; a cap of
  one or two slots also removes the catch-up bursts, for 1.5–2% of the
  throughput.
- **Heavy stalls** (a quarter of the time away) dominate whatever the
  slot. Catching up sends the backlog to the next hop at once; a cap keeps
  it in CAKE, under COBALT, but the time away is lost (19% of the rate).
  That is a choice for the user, so the default should catch up fully, as
  stock dummynet does, with an optional cap in time
  (`release_catchup_us`), not slots.
- **Tin shares under stalls** are no better with the fine clock (Bulk
  3.92 Mbit/s light, 3.75 heavy, as stock): the link clock's window is a
  slot, so a catch-up batch falls back to the real time. A window as wide
  as the catch-up is a phase 4 option.

**Gate.** The gain is predictable and linear in the slot, so the default
comes from the cost: 100 µs to start (a tenth of stock 1000 Hz's delay,
at most 10,000 wakeups/s and only while packets are due), 250 µs if
phase 3 finds a wakeup expensive. Phase 0 measured an always-on 10 kHz
tick at about a host CPU in the VM; the cost per wakeup is not in the
model.

The model has one pipe, jittered arrivals rather than TCP, the kernel's
timer coalescing as rounding up to the slot's grid, and stalls of
uniform length.

The hook (`DN_CREDIT_HZ`, `DN_RELEASE_NS`, and the src patch's copy of
`dn_sched_cake.c`) leaves the stock build unchanged: `sched-diff.sh` 50
runs and `link` 30 runs, 0 mismatches; `pace` as before (Bulk 3.41 /
3.77 Mbit/s at 1000 / 4000 Hz, 3.92 / 3.93 with the link clock);
`fuzz.sh` 1,000,000 packets, 0 check errors; `cobalt-diff.sh` 0
mismatching runs; `dn_cake.ko` built on the OPNsense 26.7 VM, as released
and with CAKE_DEBUG. The in-tree DN_WIRE_LEN build is left to the variants
workflow.

### Phase 2: the fork, releasing once per tick

The fork is `patches/dummynet-subtick/`: patches made with `git
format-patch` against opnsense/src at `SRC_COMMIT` with
`opnsense-src-cake.patch` applied, in the order of `series`, and
`build.sh`, which copies the dummynet sources of a stock tree (`SRCDIR`,
by default `/usr/src`), applies `opnsense-src-cake.patch` and the series,
builds `dummynet_st.ko` against that tree's headers and checks that the
patched code is in it. `test/build-variants.sh` builds it too, as
released and with CAKE_DEBUG.

`0001-dummynet_st-module.patch`:
- `sys/modules/dummynet_st`: dummynet with CAKE, as `dummynet_st.ko`. It
  declares the `dummynet` module like the stock one, so ipfw, the AQMs
  and the schedulers bind to it, and only one of the two can be loaded.
  Its own headers come before `SYSDIR`'s.
- `net.inet.ip.dummynet.subtick` (1) tells it from the stock dummynet.
- `net.inet.ip.dummynet.release_us` is the tick, the only value it takes
  so far (100 is refused).

`test/subtick-swap.sh fork KO` turns off the os-cake entries that are on
(they keep `dn_cake.ko` in use), noting which, unloads `dn_cake.ko` and
the dummynet module and loads the fork; `stock` loads `dummynet.ko` again
and turns those entries back on. Run `lul-setup.sh` after either: a new
dummynet starts without the bench's pipes and with the default
`pipe_slot_limit`.

Measured 2026-10-27 on the bench at 1000 Hz, the fork built on the VM
against its `/usr/src` (the 81 files the build copies are `SRC_COMMIT`'s):

| | stock (phase 0) | fork |
|---|---|---|
| host CPU of the router's qemu, idle / under the TCP load | 32%, 26% / 84%, 89% | 29% / 85% |
| bursts out of the download pipe: per s, mean packets | 976, 25.4; 960, 26.0 | 946, 26.3 |
| ticks late under the TCP load | 3.9%, 4.8% | 6.3% |
| rrul ICMP median / 99th percentile | 1.85 / 5.49 ms | 1.91 / 7.34 ms |

Stock and fork alternated in the same boot (two contention runs each, the
fork loaded twice), Bulk against greedy Voice: stock 4.2, 4.3, 4.3, 4.4
Mbit/s, the fork 4.3, 4.2, 4.2, 4.2; Voice RTT against greedy Bulk 1.92–
1.94 ms stock, 1.77–1.96 the fork. The fork's first runs (4.2, 5.0, 4.6
Mbit/s, one at 0.5% loss) were within that spread.

`test/robustness.sh` with the fork's CAKE_DEBUG build (CAKE built in):
all tests passed (normal, overflow, flood, ipv6, churn, allocfail,
expiry, vnet, leaks; unload is skipped for a built-in CAKE), check_errors
0, dummynet's memory and the mbufs back to their baselines.

**Gate:** passed; the fork releases as stock dummynet does. Phase 3 lets
`release_us` go below the tick.

### Phase 3: releases between ticks

`0002-release-between-ticks.patch` (`net.inet.ip.dummynet.subtick` 2):
- **Time in microseconds.** A pipe's times go from ticks to µs of uptime
  (`sbinuptime()`, `V_dn_cfg.now_us`, never going back): the scheduler
  instances' credit (bits × `DN_CREDIT_HZ`, 10^6), `sched_time` and
  `idle_time`, the packets' output times, the event heap's keys and the
  link's delay. `curr_time` stays in ticks for the AQMs and RED. CAKE
  takes `DN_CREDIT_HZ` and `DN_RELEASE_NS` from `ip_dn_private.h`.
- **A callout between ticks.** With `release_us` below the tick, heap
  keys are rounded up to a grid of `release_us`, and `dn_fine_arm()` arms
  an absolute callout (`C_DIRECT_EXEC`, guarded by a spin lock) at the
  first key whenever it moves earlier; it queues `dummynet_fine_task` on
  dummynet's taskqueue, which serves the heap and arms again. The tick
  task still runs and serves the heap too, so a missed wakeup waits a tick
  at most. At the tick (`release_us` 0, the default) nothing is armed.
- **The packet that overdraws the credit leaves at once,** as from
  sch_cake's shaper, and an idle pipe starts at no credit instead of
  io_fast's tick of it. Stock dummynet holds that packet until it is paid
  for; with credit in µs that would delay every packet of a sparse flow
  by its own time and the grid. A pipe's `burst` after idle is clamped so
  that a long idle cannot overflow.
- `release_catchup_us` caps the credit gained in one release (0: all it
  is owed, as stock). `release_wakeups`, `release_pkts`,
  `release_late_us`, `release_late_max` and `release_catchups` count the
  releases between ticks and how late they ran.

Measured 2026-10-27 on the bench at 1000 Hz, `subtick-baseline.sh` (300
Mbit/s, 4 TCP downloads):

| release_us | router idle / host qemu under load | bursts per s, mean packets, gaps 0.5–1 ms | wakeups between ticks: packets each, mean late, later than a slot |
|---|---|---|---|
| tick | 78% / 90% | 895, 27.8, 1611 | – |
| 500 | 65% / 139% | 1725, 14.2, 1374 | not counted, 95 µs, 2.1% |
| 250 | 45% / 182% | 3912, 6.3, 47 | not counted, 61 µs, 1.2% |
| 100 | 29% / 193% | 6877, 3.6, 16 | 4.1, 62 µs, 15% |

Idle, no wakeups: the router's qemu at 27–29% of a host CPU at every
setting, as stock. The latest release was 6–11 ms late (the VM's stalls).

In one boot, `contention.sh` and rrul (50 Mbit/s):

| | tick | release_us 100 |
|---|---|---|
| Voice RTT median against greedy Bulk | 1.90, 1.94 ms | 0.55, 0.53 ms |
| Voice RTT median against Video, Best Effort, Bulk | 1.94, 1.94 ms | 0.52, 0.53 ms |
| Bulk against greedy Voice | 4.7, 4.3 Mbit/s | 4.3, 4.3 Mbit/s |
| rrul ICMP median / 99th percentile | 1.78 / 7.00 ms | 0.91 / 5.95 ms |
| rrul UDP BE, EF median | 2.19, 2.35 ms | 1.08, 1.64 ms |
| rrul TCP download sum | 47.2 Mbit/s | 46.9 Mbit/s |

- **Latency falls as modelled, and more.** The Voice flow's RTT crosses
  two busy pipes; at the tick each Voice packet waits for the next one,
  and irtt sends every 2 ms, so the wait is the same phase for the whole
  run: which phase depends on when the router booted, hence phase 0's
  0.9 or 1.9 ms. At 100 µs the phase no longer matters (0.53 ms). rrul's
  ICMP median halves.
- **The cost is per release, and large in this VM.** The router's CPU
  under the load goes from 22% at the tick to 35, 55 and 68% at 500, 250
  and 100 µs, about 80 µs of guest CPU per extra release, where bare metal
  takes a few: the bench's router is a KVM guest inside a KVM guest, so
  each timer and each NIC doorbell (a smaller burst each time) is an
  expensive exit. Two changes did not reduce it: serving from the callout
  thread instead of the taskqueue (192% host, 75 µs late), and a callout
  precision of half a slot (188%, but 104 µs late, i.e. a longer slot).
  Phase 5 has to measure it on real hardware.
- `robustness.sh` with the CAKE_DEBUG build at `release_us` 100: all
  tests passed (1.15 million releases between ticks, 1.8 million packets,
  check_errors 0, memory and mbufs back to baseline).
  `test/subtick-stress.sh`: `release_us` changed every 0.2 s under RRUL
  (70,688 releases), and the fork swapped for the stock dummynet and back
  under RRUL: both passed.

**Gate:** passed for behaviour (no regression, bursts and latency as
modelled or better); the CPU cost on this bench is high and is the open
question for phase 5. `release_us` stays opt-in, the tick by default.

### Phase 4: CAKE, and the other schedulers, on the fine clock

**The link clock after a late release.** Phases 1 and 3 left tin shares
under CPU stalls no better with the fine clock: the link clock may lag a
window (a slot, or the tick) behind now, so a batch carrying more credit
than that (a late release) falls back to the real time. CAKE now notes the
real time of each release of the pipe (`serve_sched()` stamps the
instance's `sched_time` once per call, in ticks on a stock dummynet and in
µs in the fork, which tells a release from the next packet of the same
one) and, while its queue has been backlogged since the previous release,
lets the link clock lag back to that release. This is in CAKE itself, so
it helps the released module on a stock dummynet as well
([DESIGN.md](DESIGN.md), the link clock). In the harness
(`sched-diff.sh release bulkvoice`, Bulk against greedy Voice, sch_cake
3.93 Mbit/s):

| stalls | stock 1000 Hz before / after | 100 µs before / after | 250 µs before / after |
|---|---|---|---|
| none | 3.93 / 3.93 | 3.93 / 3.93 | 3.93 / 3.93 |
| 40/s up to 1 ms | 3.92 / 3.92 | 3.92 / 3.93 | 3.90 / 3.93 |
| 60/s up to 8 ms | 3.75 / 3.92 | 3.75 / 3.93 | 3.75 / 3.93 |

(A first version noted the time of the last packet sent instead; the
first packet of a late batch moved it, and the rest of the batch fell back
as before: 3.76.) The rest of the harness is unchanged: `sched-diff.sh`
and `link`, 0 mismatches; `pace` 3.92 / 3.93; `fuzz.sh` and
`cobalt-diff.sh` clean; `release fast` as in phase 1. In `pace-random`
(150 scenarios each, mean of each scenario's worst tin's deviation from
sch_cake) the shares are the same, and the clamps nearly go:

| ticks | tin deviation egress / ingress, before → after | pulled back, before → after |
|---|---|---|
| 1000 Hz | 0.69 / 0.53% → the same | 0.74 / 2.87% → the same |
| 1000 Hz, 10% late | 0.72 / 0.74% → the same | 10.2 / 11.7% → 0.67 / 2.29% |
| 1000 Hz, 50% late | 1.18 / 2.29% → 1.19 / 2.32% | 46.6 / 47.9% → 0.37 / 1.81% |
| 100 Hz | 4.30 / 6.95% → the same | 0.06 / 1.03% → the same |

The random scenarios' deviations come from elsewhere (their small memory
limits); without the link clock, Bulk against greedy Voice at slots of 25–
100 µs gets 3.89–3.93 Mbit/s with light stalls but 3.75 with heavy ones,
so the link clock stays needed in the fork too. On the bench, with a busy
loop on one of the router's host CPUs (66–75% of ticks late), the Bulk
flow against greedy Voice got all its 5.0 Mbit/s (0.1–0.9% loss, at the
tick and at 100 µs) with the new rule and 4.8 (3–4% loss, at the tick)
with the old; with Voice's TCP flow held back by the stalls (27–36 Mbit/s
with either rule, three alternating runs each) that is no measure of
sch_cake's shares (4.2 on a calm link), only that nothing got worse.

**CAKE's targets** (`0003-cake-target-release-interval.patch`). CAKE
raises a tin's target to 1.5 × `DN_RELEASE_GRAIN_NS`, the tick on a stock
dummynet; the fork sets it to the release interval. At `kern.hz=100`, the
default in a VM, with CAKE configured after `release_us`: tin targets 15
ms on the stock dummynet and on the fork at the tick, 5 ms (5.8 for the
slowest tin) at 100 µs.

**The AQMs' clock** (`0004-aqm-clock-uptime.patch`). CoDel, PIE,
FQ-CoDel and FQ-PIE measure sojourn with `AQM_UNOW`, `curr_time * tick`;
it is now the uptime in µs (`sbinuptime()`), as CAKE's clock is.

**FQ-CoDel and the rest gain as CAKE does.** The release is dummynet's,
so every scheduler's pipe releases on the grid. FQ-CoDel, 1000 Hz, one
boot (rrul at 50 Mbit/s twice each; bursts at 300 Mbit/s):

| | stock | fork, 100 µs | fork with 0004, 100 µs | fork with 0004, tick |
|---|---|---|---|---|
| bursts per s, mean packets | 941, 26.6 | 7083, 3.5 | 6933, 3.6 | 893, 27.8 |
| rrul ICMP median | 1.94, 2.12 ms | 0.71, 0.70 ms | 0.72, 0.69 ms | 1.79, 1.87 ms |
| rrul UDP BE median | 2.33, 2.64 ms | 0.81, 0.77 ms | 0.80, 0.81 ms | 1.93, 2.23 ms |
| TCP download sum | 47.3 Mbit/s | 47.0, 47.2 | 47.2, 47.1 | 47.3 |

At `kern.hz=100` (rrul once each; CAKE in diffserv3):

| | stock | fork with 0004, tick | fork with 0004, 100 µs |
|---|---|---|---|
| FQ-CoDel: ICMP median / 99th | 15.2 / 22.8 ms | 14.7 / 22.5 ms | 0.75 / 5.0 ms |
| CAKE: ICMP median / 99th | 15.0 / 22.4 ms | 14.8 / 22.9 ms | 0.88 / 6.0 ms |
| TCP download sum | 47.9 Mbit/s | 47.0–47.6 | 47.0–47.1 |

rrul's pings ride FQ-CoDel's sparse queues, so they show the release, not
the AQM: with and without 0004 at 100 µs and 100 Hz, ICMP medians are
0.68–0.71 ms both. The AQM shows in a bulk flow's own RTT: one greedy TCP
download through FQ-CoDel, the sender's smoothed RTT sampled every 0.5 s
for 18 s (`ss -ti`, the data connection):

| kern.hz | stock | fork, 100 µs | fork with 0004, 100 µs | fork with 0004, tick |
|---|---|---|---|---|
| 100 | median 17.1, p90 23.2 ms | 10.3, 10.7 / 11.9, 11.8 ms | 6.6, 7.0 / 8.5, 8.4 ms | |
| 1000 | 7.1 / 8.5 ms | 6.7, 6.4 / 8.2, 8.1 ms | 6.7, 6.8 / 8.3, 8.0 ms | 7.6 / 9.5 ms |

At 100 Hz, finer release takes 7 ms off the bulk flow's RTT and the AQM
clock another 4: with ticks of 10 ms, FQ-CoDel saw each sojourn as 0 or
10 ms against its 5 ms target. At 1000 Hz a tick is fine enough and it
makes no difference. Throughput 47.9–48.3 Mbit/s in all.

`robustness.sh` (CAKE_DEBUG, `release_us` 100, the link clock change
included) and `test/subtick-stress.sh` passed on the fork with 0001–0003.
0004 was run only in the FQ-CoDel tests above; CoDel and PIE on a plain
queue, and FQ-PIE, are not tested yet.

**Gate:** passed. Bulk 3.93 Mbit/s in the harness at 1000 Hz and with
stalls; tin shares as 1.4.2 or better; and the fine clock's gains reach
every scheduler, most at `kern.hz=100`, where they are 15 ms of latency.

### Phase 5: stress on the bench

Measured 2026-10-27 on the bench at 1000 Hz, with the fork's patches
0001–0004 (`net.inet.ip.dummynet.subtick` 2).

**Many instances at once** (`test/subtick-pipes.sh`): 32 greedy TCP
downloads through an FQ-CoDel scheduler masked by destination port, so
that each flow has an instance of its own at 10 Mbit/s and its own events
in the heap.

| | per flow min / median / max | sum | router idle | releases between ticks |
|---|---|---|---|---|
| stock | 9.52 / 9.61 / 9.63; 9.41, 9.17 min in two more | 306–307 Mbit/s | 73% | – |
| fork, tick | 4.81 / 9.61 / 9.63; 9.50, 9.53 min in two more | 298–308 | 71% | – |
| fork, 100 µs | 9.51 / 9.61 / 9.62 | 307 | 29% | 6150/s, 6.1 packets each |

The one slow flow at the tick did not come back in two more runs; stock
has the same spread of its slowest flow. One release serves the events of
several instances, as their keys fall on the same grid.

**Contention** (`subtick-baseline.sh`, CAKE at 300 Mbit/s, a busy loop on
host CPU 0):

| VMs | release | throughput | bursts per s, mean packets | router idle / host qemu | releases: mean late, later than a slot |
|---|---|---|---|---|---|
| pinned (router on CPUs 0–1) | stock | 118 Mbit/s | 492, 21.0 | 58% / 100% | – (ticks 76% late) |
| pinned | fork, 100 µs | 102 Mbit/s | 831, 11.1 | 50% / 104% | 970 µs, 54% |
| not pinned | stock | 277 Mbit/s | 979, 24.7 | 83% / 80% | – (ticks 3% late) |
| not pinned | fork, 100 µs | 282 Mbit/s | 5525, 4.5 | 33% / 165% | 98 µs, 37% |

When the host can move the router's vCPUs away from the busy one, the
fork works as on a quiet host. When it cannot, the router is short of CPU
for either module, the fork's releases come about a millisecond late
(nothing finer than the tick is left), and its extra work per release
costs 13% of the throughput. On a router short of CPU, stay at the tick.

**Swapping and changing `release_us` under load**: `test/subtick-stress.sh`
(phases 3 and 4) passed.

**The other AQMs with 0004** (rrul at 50 Mbit/s once each, CAKE_DEBUG
build at `release_us` 100, against stock):

| | stock: ICMP median / 99th, TCP down | fork, 100 µs |
|---|---|---|
| FQ-PIE | 1.98 / 26.6 ms, 47.3 Mbit/s | 0.74 / 28.5 ms, 47.2 |
| FIFO + CoDel | 25.0 / 63.1 ms, 45.2 | 24.6 / 40.2 ms, 45.1 |
| FIFO + PIE | 34.9 / 96.9 ms, 43.6 | 38.3 / 99.3 ms, 43.0 |

FQ-PIE gains as FQ-CoDel does; with a single queue the pings wait behind
the bulk flows, which the AQM's target sets (PIE's is 15 ms), so finer
release does not show. No panics, lock warnings or CAKE check errors.

**Was still to do on real hardware** (done below): the CPU cost per release (the bench's
nested VM puts it at about 80 µs, which bare metal should not), a burst
capture as in DESIGN.md (2.5 Gbit/s NICs shaping 1950 Mbit/s) at the tick
and at 100 and 250 µs, and the latency gains with a NIC much faster than
the shaped rate. The fork built on the bench VM loads on a firewall with
the same kernel: the VM's `dummynet.ko` is the pinned kernel set's
(26.7.8, `DUMMYNET_SHA256` in `plugin/build.conf`).

### Phase 5: a live firewall

Measured 2026-10-27 on a live OPNsense 26.7 firewall: a Proxmox VM on an
Intel i5-12600K, 4 vCPUs, `kern.hz=1000`, kernel 15.1-p4 with the pinned
`dummynet.ko`; Intel `igc` 2.5 Gbit/s NICs in passthrough; os-cake 1.3.4
and cake-kmod 1.4.5 with CAKE on both pipes (download 1950 Mbit/s,
besteffort, dual-dsthost, wash, ingress; upload 2070 Mbit/s, diffserv4,
dual-srchost; both ECN and the ethernet overhead). The fork's release
build from the bench loaded as it was. The load was Waveform's bufferbloat
test from a wired LAN client; `test/subtick-fw-run.sh` waits for the
download phase (over 500 Mbit/s out on the LAN VLAN), measures the CPU
(all 4 vCPUs), late ticks and the fork's releases over 5 s, then captures
100,000 full-size packets leaving on the LAN VLAN.

| run | captured rate | router idle | bursts per s, mean / largest packets | gaps 0.5–1 ms | releases between ticks: per s, packets each, mean late, later than a slot |
|---|---|---|---|---|---|
| stock | 1847 Mbit/s | 79.1% | 1007, 165 / 170 | 599 | – |
| fork, tick | 1574 | 88.2% | 1118, 121 / 164 | 722 | – |
| fork, 250 µs | 1828 | 85.2% | 4011, 40 / 64 | 0 | 3875, 48.3, 5 µs, 0.0% |
| fork, 100 µs | 1685 | 83.1% | 9551, 15 / 49 | 0 | 9045, 21.4, 5 µs, 0.1% |
| stock, again | 1462 | 85.9% | 1528, 82 / 159 | 324 | – |

- **On time.** Releases between ticks ran 5 µs late on average at both 250
  and 100 µs, against 61–75 µs on the bench's nested VM, and almost never
  later than a slot: the slot holds on real hardware.
- **Bursts as modelled.** At the tick a release carries a millisecond of
  the link (165 packets at 1847 Mbit/s); at 250 µs 40, at 100 µs 15, with
  the largest burst down from 170 to 64 and 49, and no gaps between ticks
  left. The second stock run's rate was lower (the internet path to the
  test server varied between runs, 1462–1847 Mbit/s), with the pipe not
  always full, hence its smaller mean burst and mixed gaps.
- **No measurable CPU cost.** Busy time per Gbit/s captured: stock 11.3
  and 9.6%, the fork at the tick 7.5%, at 250 µs 8.1%, at 100 µs 10.0%
  (of 4 vCPUs): 9000 releases a second fall within stock's own spread. The
  bench's 80 µs per release was its nested virtualization.
- **Latency from the client** was not recorded: Waveform's grades and
  loaded latency for these runs are missing, so the latency gain on this
  link is not measured here; on the bench it was 1.9 to 0.5 ms (Voice RTT)
  at 50 Mbit/s.

The swap: `ipfw -q pipe|sched|queue flush`, unload `dn_cake.ko` and
`dummynet.ko`, `kldload` the fork, then os-cake's own rule builder
(`dnctl.cake_pipes()` and `load_cake()`) put CAKE back on the pipes with
the same settings, with the fork's built-in CAKE; WAN traffic stopped for
a second or two. os-cake's check refuses `dn_cake.ko` while the fork is
loaded (it sees no `dummynet.ko` file), so a shaper reload during the
test would only fall back to the pipes' own scheduler. The restore was
the same flush, `kldload dummynet` and os-cake's `dnctl.py`.

**Gate:** passed. The per-release cost that was the open question is not
measurable on this firewall at 100 µs and 1.5–1.8 Gbit/s, releases are on
time, and bursts shrink as modelled. Phase 6 decides what to do with it.

### Phase 6: the package, on by default

The fork ships as a third package, `dummynet-st` (`plugin/dummynet-st/`,
built by `plugin/build.sh` with the others and so by CI): the release
build of `patches/dummynet-subtick` as `/boot/modules/dummynet_st.ko`,
with the FreeBSD release and the stock `dummynet.ko` it replaces recorded
as cake-kmod records them. os-cake depends on it and uses it unless
**Sub-tick release** is switched off on its page (general settings above
the pipes; the release interval there, 250 µs by default, 10–10000):

- **When.** `rc.d/dnctl` loads the stock dummynet, then runs the wrapper
  (`dnctl.py`), at boot and at every shaper reload. With CAKE entries
  enabled, the setting on and `dummynet-st` matching the kernel, the
  wrapper flushes the pipes, unloads `dn_cake.ko` and `dummynet.ko`, loads
  `dummynet_st.ko`, sets `release_us`, and loads the CAKE rules on its
  built-in CAKE. Without CAKE entries, switched off, or not matching, it
  goes back to the stock dummynet and `dn_cake.ko`. Nothing loads the fork
  at boot, so a fork that fails to load does not stop the firewall coming
  up.
- **Fallbacks.** A `dummynet-st` built for another release or another
  `dummynet.ko`, or one that does not load, leaves the stock dummynet in
  place, logged and shown as a warning on the page. A crash while the fork
  loads or its rules go in leaves `/conf/dummynet-st.loading` (kept across
  reboots); the wrapper then stays on the stock dummynet, and Apply on the
  CAKE page (configd `cake retry`) clears it and tries again. An upgraded
  `dummynet_st.ko` replaces the loaded one at the next reload, as for
  `dn_cake.ko`.
- **Removing** `dummynet-st` swaps the stock dummynet back before the file
  goes and reloads the shaper after, whether os-cake is still installed or
  not.
- **Status:** the page says whether the fork is in use and its interval;
  `status.py` reports its counters.
- **All pipes** (os-cake 1.4.2): *Sub-tick release for* *All pipes* loads
  the fork whenever the shaper rules define a pipe, CAKE entries or not;
  without CAKE entries the rules go in unchanged on it, so FQ-CoDel and the
  other schedulers get the release and the AQM clock (patch 0004). The
  default stays *Pipes with CAKE*.

Checked 2026-10-27 on the bench VM with the three packages built there by
`plugin/build.sh` and installed over the released ones: installing os-cake
switched the VM's two CAKE entries to the fork at 250 µs (a config.xml
without the setting counts as on); the API reads and saves the setting and
rejects 5 µs; switching it off gives the stock dummynet with `dn_cake.ko`,
on again the fork at 100 µs; a wrong recorded `dummynet.ko` gives the stock
dummynet with the warning; after a reboot the fork came up at boot with the
CAKE service running; a marker left as after a crash keeps a reload on the
stock dummynet, with the warning, until Apply; deleting `dummynet-st` (and
os-cake with it) brought the stock dummynet back; the CAKE page renders
with the new settings and its script parses. `test/plugin-lib.py` covers
the setting's defaults and `st_status()` (26 tests). The VM is back on the
released 1.4.5 / 1.3.4 from the `cake` repository.

Before a release: version bumps (cake-kmod has the link clock change, os-cake
the new dependency and setting) and the README's file-install commands, as
in RELEASING.md, and a soak on a live firewall.
