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
7. **CAKE's link clock from the fine clock.** `dn_sched_cake.c` takes the
   pipe's credit unit and its release interval from `DN_CREDIT_HZ` and
   `DN_RELEASE_NS`, by default `hz` and a tick; the fork defines them, so
   the link clock's window becomes the slot. `link_clock=0` stays for
   comparison.

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
