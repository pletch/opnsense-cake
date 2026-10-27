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
   rather than relying on the `tick_delta_sum` correction. Open: how much
   backlog to release at once after a hypervisor stall (one or two slots?).
6. **Output from the taskqueue first.** The callout enqueues `dn_task` on
   `dn_tq`, which adds jitter; measure it before sending directly from
   the callout.
7. **CAKE's link clock from the fine clock,** through a flag like
   `DN_WIRE_LEN`. With fine release it should stay close to the real
   time; `link_clock=0` stays for comparison.

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
  160% under load; at 4000 Hz an eighth of the ticks ran late. Voice RTT
  doubled at 10 kHz, likely the vCPUs' contention. (That the idle cost
  is dummynet's callout rather than the kernel's own hardclock is not yet
  checked.)
- **Gate.** `kern.hz=10000` is no substitute in a VM: it costs a host CPU
  at idle for little gain here. But this bench gains little from finer
  release at all; the case for the fork is a fast NIC feeding a slower
  shaped link on real hardware (DESIGN.md, release bursts), and a fork
  that arms its timer only when packets are due would also drop the idle
  cost. Next: a burst capture on real hardware at 1000 and 4000 Hz, and
  phase 1 in the harness.
