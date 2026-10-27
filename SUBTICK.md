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

None yet.
