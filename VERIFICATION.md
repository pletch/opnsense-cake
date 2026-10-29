# opnsense-cake verification

How `dn_sched_cake` and the plugin were tested, and the results. The
scripts are in [`test/`](test/); the design they test is in
[DESIGN.md](DESIGN.md).

## Verification status

- Built with FreeBSD clang and `-Werror` against `opnsense/src` `stable/26.7`
  (OPNsense 26.7 runs on **FreeBSD 15.1**), then loaded on an OPNsense 26.7
  VM (`load_dn_sched dn_sched CAKE loaded`). The build gets `VIMAGE` from the
  generated `opt_global.h`, which matches the kernel.
- Smoke test: one 200 MB TCP download through a 50 Mbit/s pipe
  (`kern.hz=100`, nested KVM):

  | scheduler | throughput |
  |---|---|
  | fifo | 5939 kB/s |
  | fq_codel | 5939 kB/s |
  | cake, first version | 1240 kB/s (COBALT dropping on dummynet tick batching) |
  | cake, tick-aware target | 5939 kB/s, no AQM drops |

- Latency under load: `test/run-lul.sh` runs flent RRUL (4 TCP flows each
  way, marked BE/BK/CS5/EF, plus ping) through a 50/10 Mbit/s shaper at
  `kern.hz=1000`. The VM's idle RTT is about 3.8 ms. Results from 2026-10-24:

  | scheduler | ICMP median / p99 | UDP EF median | down / up sum | down per flow (BE/BK/CS5/EF) |
  |---|---|---|---|---|
  | fifo, 1000 pkt | 22.6 / 30.8 ms | 23.95 ms | 40.4 / 9.07 | 9.6 / 10.0 / 10.2 / 10.3 |
  | fq_codel | 1.80 / 5.34 ms | 2.50 ms | 48.0 / 8.71 | 16.0 / 8.1 / 7.8 / 16.0 |
  | cake besteffort | 1.81 / 5.03 ms | 2.42 ms | 48.0 / 8.59 | 12.0 / 12.0 / 12.0 / 12.0 |
  | cake diffserv3, WDRR only (superseded) | 2.74 / 10.6 ms | 6.94 ms | 48.0 / 8.81 | 19.8 / 2.6 / 19.9 / 5.9 |
  | **cake diffserv3, rate thresholds** | 2.64 / 7.63 ms | 4.58 ms | 48.0 / 8.71 | 16.6 / 3.0 / 16.6 / 11.9 |
  | **cake diffserv4, rate thresholds** | 2.57 / 5.97 ms | 4.13 ms | 48.0 / 8.88 | 33.1 / 2.9 / 6.0 / 6.0 |

  With a single tin, CAKE is level with fq_codel on latency and splits
  bandwidth more evenly between flows. With rate thresholds, each tin gets
  its share: Bulk 6.1% down and 6.2% up (1/16 is 6.25%); Voice 24.8% in
  diffserv3, and EF+CS5 together 24.9% in diffserv4 (share 25%). Best Effort
  takes the rest. Under RRUL, EF stays above BE because RRUL puts a bulk TCP
  flow in EF, which fills the voice tin.

  Per-DSCP ping under `rrul_be` load (8 BE TCP flows; voice and bulk tins
  carry only the probe), average RTT:

  | scheduler | BE | EF | CS1 |
  |---|---|---|---|
  | fq_codel | 2.31 ms | 3.17 ms | 2.06 ms |
  | cake diffserv3, WDRR only (superseded) | 2.11 ms | 2.03 ms | 5.21 ms (max 156) |
  | cake diffserv3, rate thresholds | 2.22 ms | 2.04 ms | 2.09 ms |

  A first attempt at thresholds ranked Bulk below Best Effort and starved
  it, with 0.05 Mbit/s and a 124 ms ping. sch_cake numbers its tins in
  priority order BE < Bulk < Video < Voice, so Bulk outranks Best Effort
  within its 1/16 share. The tin clock rules are now copied from
  `cake_advance_shaper()` and the idle-tin reset in `cake_enqueue()`.
- Robustness: `test/robustness.sh` builds the module with `CAKE_DEBUG=1`.
  In that build, `cake_check()` walks every tin and flow list after each
  enqueue and dequeue and counts mismatches in
  `net.inet.ip.dummynet.cake.check_errors`. All tests passed on 2026-10-24
  with 0 check errors, and again on 2026-10-25 for 1.3, where the checker
  also verifies each flow's state against its list (decaying flows empty)
  and the per-tin sparse, bulk, decaying and unresponsive flow counts and
  byte backlog. For 1.3, 20,681 reads of the statistics sysctl during 30
  reconfigurations under RRUL also left 0 check errors:

  | test | load | result |
  |---|---|---|
  | normal | 30 s RRUL | clean |
  | overflow | `limit 64`, 8 flows/tin, quantum 300, 30 s RRUL | 3303 drops (fattest flow, BLUE, hash collisions), RRUL completes |
  | flood | unpaced 8000-byte UDP (IP fragments) both ways + 4000-byte ping | recovers, 0% loss after |
  | ipv6 | ping6 + TCP download | 0% loss, 47 Mbit/s of 50 |
  | churn | 45 reconfigs in 45 s (cake/fq_codel/fifo, all diffserv modes, 50↔30 Mbit/s) under RRUL | clean, RRUL completes |
  | allocfail (1.1) | tin count changed under RRUL while every table allocation fails for 8 s, then one host and one flow allocation fail | old tables kept (0 rebuilds in about 125,000 failed attempts, traffic flowing), then both instances rebuild; 0 check errors |
  | expiry (1.3.3) | 10 Hz ping so that nearly every packet expires and re-creates the instances, statistics read in a loop, then the schedulers deleted while their state is kept | 198 adoptions, 0% loss, dummynet memory back to its value without CAKE (13 allocations, 5888 bytes), 0 check errors |
  | vnet (1.3.4) | CAKE in the host (RRUL) and in two vnet jails joined by an epair (pipes 7 and 8), with jail traffic, 58 reconfigurations and scheduler deletions, and statistics read in a loop in all three vnets; then the jails removed with their CAKE state kept | each vnet saw only its own pipes (host 1 and 2, jails 7 and 8), no jail ping loss, dummynet memory back to its value without CAKE, 0 check errors |
  | unload | `kldunload` during RRUL, then after switching to fifo | refused while busy, unloads when idle, reloads |
  | leaks | after all of the above | dummynet malloc back to baseline, 0 queued, mbufs flat across further runs |

  The fragmented ping loses 90–100% under the flood with fifo and fq_codel
  too, while a plain ping in the same flood loses 0%. Losing any one of a
  ping's fragments loses the whole ping. The mbuf count steps up once
  after the floods, because NIC rings and UMA caches settle higher, and
  then stays flat. So the leak check compares against a warm count.
- The whole scheduler against sch_cake (`test/sched-diff.sh`, from 1.4):
  both scheduling cores are extracted from their sources (sch_cake's
  enqueue and dequeue with its hashing, host isolation, DRR, tin
  selection, shaper and COBALT; dn_sched_cake's the same) and built in
  userland, each against a small shim. They get the same trace of
  already-classified packets: flows from several hosts in mixed DSCP
  classes, bulk and sparse, ECN and not. Both get the same flow and host
  hashes; ours rotated so that its multiply-shift slot is sch_cake's
  modulo slot. The clock advances in 10 µs steps, and each time sch_cake's
  link shaper releases a packet dn_sched_cake is asked for one. Every
  sent packet, its tin and every drop must match. Stage 1 leaves out
  overhead compensation, the ACK filter, ingress mode and overflow (the
  load stays under the buffer limits), and sets dummynet's tick to 1 µs
  and sch_cake's fresh flows to 1/√1, the two deliberate differences.
  Result: 300 random scenarios (besteffort, diffserv3, diffserv4; flows,
  dual-srchost, dual-dsthost, triple-isolate; 50–200 Mbit/s; 1–48 flows),
  8.23 million packets and 12,771 drops, all identical, and 0 consistency
  errors. Getting there found four differences, all fixed in 1.4:
  - a tin's flow quantum came from the configuration instead of from the
    tin's rate;
  - the quantum dithering used a different formula and only with several
    bulk flows per host;
  - a tin only counted for tin selection while it had packets, not while
    it had flows, so flows that emptied in a quiet tin stayed bulk and
    inflated their hosts' load; and between equally early tins the first
    won instead of the last;
  - COBALT and the tin clocks ran in microseconds, and the tin clocks used
    a different fixed-point rate, so rounding drifted after many drops.

  Stage 2 adds overhead compensation (raw, ethernet, docsis, pppoe-ptm,
  atm and random overhead/mpu), the ACK filter (on and aggressive; the
  trace carries real IPv4/TCP headers with timestamps, SACK blocks, ECN
  flags, duplicate ACKs and data), ingress mode and overflow (random small
  memory limits, up to 1.6 times the rate offered). Both use upstream's
  own ACK filter and overhead code; our ACK filter's 128-packet scan cap
  is lifted for the comparison, as differences past it are intended. To
  compare the same accounting, both see IP-length packets (sch_cake sees
  layer-2 lengths and limits memory by truesize; dummynet sees IP lengths,
  and has a packet limit as well, set out of the way). Result
  (`test/sched-diff.sh 300 2`): 300 random scenarios, 12.76 million
  packets and 1,054,452 drops (overflow, ACK filter and COBALT),
  identical outside ingress mode, 0 consistency errors.
  Stage 2 found three more differences, fixed in 1.4:
  - overflow picked the fattest flow by an exact scan; sch_cake keeps a
    max-heap that is only kept up to date while overflow is recent, so
    with ties or a stale heap it can pick another flow. dn_sched_cake now
    uses the same heap, laid out the same way;
  - in ingress mode, after a COBALT drop sch_cake chooses the flow again
    (the drop used up deficit); dn_sched_cake carried on with the same
    flow;
  - the ACK filter matched except past the scan cap (intended).

  Ingress mode is compared but not required to match: a drop also charges
  sch_cake's own link shaper, which it checks again when DRR comes to an
  empty flow, so a dequeue can end after a drop without sending, while
  dn_sched_cake, paced from outside by the pipe's credit, finishes the
  call. In the 300 runs, 87 were in ingress mode; 58 matched throughout,
  29 drifted apart after 7,673 identical packets on average.

  How much of each side is production code: `sched-diff.sh` prints every
  extracted line not matched, in order, to its source, and fails before
  comparing if any is not one of the documented substitutions. Of
  sch_cake's 2164
  lines, 3 are not (the DSCP stub); of dn_sched_cake's 1881, 1 (the
  renamed hash function's signature). The rest of the shims sit outside
  the extracted code: kernel and dummynet types, the clock, the flow
  dissector's hashes, and drop logging.
- The link clock's clamp (after 1.4.2): how often the window bounds it,
  from `CAKE_DEBUG` counters of the reads that choose a tin, in
  `sched-diff.sh pace-random` (300 scenarios each; `SD_LATE=n` makes n%
  of ticks late, as dummynet's are under load, the next one catching up
  their credit). Pulled forward means the clock was over a tick behind,
  pulled back that it was ahead of the real time:

  | ticks | mode | pulled forward (largest) | pulled back (largest) | tin deviation from sch_cake, mean / worst |
  |---|---|---|---|---|
  | 1000 Hz | egress | 0.02% (3 µs) | 0.56% (236 µs) | 0.26% / 6.8% |
  | 1000 Hz | ingress | 0.12% (0.8 ms) | 3.1% (1.6 ms) | 0.24% / 5.8% |
  | 1000 Hz, 10% late | both | 0.26–0.31% (5 ms) | 10.5–11.6% (1.4 ms) | 0.28–0.52% / 6.9% |
  | 1000 Hz, 50% late | both | 0.67–0.71% (20 ms) | 48% (1.8 ms) | 0.73–1.42% / 28% |
  | 4000 Hz | both | 0.06–0.59% (0.7 ms) | 2.5–5.2% (1.6 ms) | 0.00–0.08% / 4.2% |
  | 100 Hz | both | 0.00–0.02% (0.6 ms) | 0.05–1.6% (2.8 ms) | 3.9% / 74% |

  In egress mode a pull back is at most a packet's time, the pipe letting
  one out past zero credit; in ingress mode drops and the failsafe add up
  to 1.5 of them. With late ticks, the clock falls back to dummynet's
  time for the part of a batch beyond a tick, and the shares drift as
  they did without it: with the link clock off, 50% late gives 0.73% and
  1.73%, 100 Hz 3.85% and 4.36% (egress, ingress), the same or worse. The
  large worst cases at 100 Hz and with late ticks are the batches'
  own: the random scenarios' small memory limits overflow under 10 ms of
  held-back arrivals.
  On the bench (`kern.hz=1000`, CAKE_DEBUG module, three rounds of
  `test/contention.sh`): of 3.3 million reads, 0.62% pulled forward (at
  most 6.4 ms, the VM's late ticks), 2.2% pulled back (at most 239 µs,
  a 1514-byte packet's time at 50 Mbit/s being 242 µs).
- The link clock (1.4.2) against sch_cake: the lockstep comparison above
  asks dn_sched_cake for a packet whenever sch_cake's shaper sends one,
  so the real time is already the link's and runs with the link clock
  off. `test/sched-diff.sh link` runs it on: the clock goes from event to
  event (each arrival, and the moment sch_cake's shaper or failsafe next
  lets a packet out) instead of in 10 µs steps, so sch_cake decides at the
  times the link clock computes, from the same rate (the full-rate tin's
  `rate_ns`, as sch_cake's global shaper). 300 random scenarios, 12.1
  million packets and 1,006,675 drops, identical outside ingress mode.
  It fails within a few packets with the link clock's step 10% short or
  without its restart after an idle link.
- COBALT against sch_cake (`test/cobalt-diff.sh`, sch_cake at
  `torvalds/linux` 700b4c6c70d6): both implementations are extracted from
  their sources, built side by side and driven with the same random
  events (queue delays below, around and far above the target, ECN and
  non-ECN packets, overflows, drains, idle gaps; random target, interval,
  MTU time, BLUE steps and bulk counts). Over 10 million events in 2000
  runs, with counts up to 558 and BLUE active, every drop, mark, BLUE
  transition and state field matched. With the earlier Q0.16 arithmetic
  the drop and mark decisions differed in 135 of the 2000 runs. With
  sch_cake's zeroed start, it signals a fresh flow earlier in 71% of runs,
  by 66 events on average (the deliberate difference above).
- Fuzzing in the kernel (`test/kfuzz.sh`, on the bench's KASAN kernel): the
  same packets through the real dummynet, mbufs and `jenkins_hash()`, in
  chains of exactly sized external buffers (SUBTICK.md, KASAN with exactly
  sized mbufs).
- Fuzzing (`test/fuzz.sh [packets [seed]]`, from 1.4.4): the scheduling
  core is extracted from the source as for `sched-diff.sh`, with its own
  flow hashing, and built in userland with AddressSanitizer,
  UndefinedBehaviorSanitizer and the CAKE_DEBUG consistency checker. Each
  round configures an instance at random (every diffserv and isolation
  mode, ACK filter, wash, ingress, overhead and ATM/PTM, rates, packet and
  byte limits, small flow tables) and sends it TCP over IPv4, IPv6 and
  6in4 with valid and invalid options, SACKs and timestamps, UDP, ICMP,
  fragments and random bytes; a third of them are corrupted (header
  lengths, data offsets, IP lengths and versions, next headers,
  truncation, random bytes). The first mbuf ends at a random point in an
  exactly sized buffer, the IP header is at layer 3, layer 2 or a random
  offset, and some headers are not writable. Dequeues follow dummynet's
  tick, and some rounds are reconfigured with failed allocations while
  packets are queued. It fails on a sanitizer finding, a range outside
  the packet passed to `m_copydata()`, a packet not freed at the end of a
  round, or a consistency error. Results:
  - 10 million packets over seeds 1–10 (about 3 s per million): no
    finding. Every line of the parsers runs (overhead, ECN marking,
    wash, TCP header and option parsing, SACK comparison, ACK filter,
    flow hashing).
  - It found that a packet of length 0 was queued but not counted, as
    the counters go by the length's sign; dummynet never passes one, but
    from 1.4.4 CAKE drops it.
  - It catches each of these when introduced: `cake_hdr()` without its
    packet bound (`m_copydata` outside the packet), the port read in
    flow hashing without its `m_len` check, the TCP option walk without
    its size bound (both AddressSanitizer), and the zero-length packet
    (consistency errors).
- ipfw patch: builds with `-Werror` and FreeBSD's full userland warning
  set against `stable/26.7`. Tested on the VM:
  - every parameter is set and shown back
  - unset parameters fall back to the sysctls, and per-scheduler values
    override them
  - out-of-range values are clamped by the kernel (`quantum 1` → 300,
    `flows 3` → 8, `limit 999999` → 65535)
  - a missing value exits with `EX_DATAERR`
  - an unknown keyword only warns, as it does for fq_codel

  `ipfw.8` gets a `cake` entry and an example; `mandoc -T lint` adds no
  warnings. RRUL with the mode set on the command line gives the same split
  as the sysctl runs (`besteffort` 12/12/12/12, `diffserv4` 33/3/6/6 Mbit/s).
- OPNsense integration (2026-10-24), tested on the 26.7 VM through the stock
  boot path, with pf enabled and no hand-loaded modules:
  - Install and boot: patched `dummynet.ko` and `dnctl`, patched core files,
    then a reboot. CAKE comes up inside `dummynet.ko`.
  - Configuration: firewall rules, pipes, queues and shaper rules were all
    created through the REST API, which the GUI also uses.
  - Validation: a CAKE quantum of 100 is rejected on the quantum field, and
    fq_codel with quantum 100 is still accepted. An unknown diffserv value
    is rejected.
  - The template renders `type cake ... diffserv4` and the per-pipe
    quantum/flows, and `dnctl sched show` shows them in the kernel.
  - RRUL through the GUI-built shaper:

    | path | ICMP median | download split BE/BK/CS5/EF (Mbit/s) |
    |---|---|---|
    | rules → pipe (internal FIFO, misconfiguration) | 21.5 ms | 10.2 / 9.9 / 9.9 / 10.4 |
    | rules → queue → CAKE diffserv4 | 2.43 ms | 33.1 / 2.9 / 6.0 / 5.9 |

  - The Diagnostics page parser (`dummynet_stats.py`) and
    `/api/trafficshaper/service/statistics` both handle CAKE schedulers.
  - The Traffic Shaper page renders with the new field and help text.
  - Not tested: a kernel with `device dummynet` compiled in (the
    `sys/conf/files` path), and a full `opnsense/tools` package build.
- Host isolation (2026-10-24), through the OPNsense shaper with pf and
  outbound NAT enabled. `test/isolation.sh` switches the mode through the
  REST API, which also tests reconfiguring live instances. Host A runs 8 TCP
  flows and host B runs 1, each flow to its own server address. The table
  shows B's share, with the expected value in brackets:

  | mode | upload, 10 Mbit/s, via NAT | download, 50 Mbit/s |
  |---|---|---|
  | flows | 11% (11%) | 11% (11%) |
  | dual-srchost | 47% (50%) | 11% (11%) |
  | dual-dsthost | 11% (11%) | 50% (50%) |
  | triple-isolate | 48% (50%) | 50% (50%) |
  | srchost | 50% (50%) | 11% (11%) |

  Other checks:
  - The release build gives the same results: triple-isolate 47% / 50%.
  - With a single shared server, triple-isolate behaves like `flows`,
    because every flow then has the same destination host. This matches
    sch_cake, and is why each test flow gets its own server.
  - netperf's `-L` does not bind the data connection, so the test selects
    host B by a source route instead.
  - RRUL (one client, one server) with triple-isolate: ICMP median 2.70 ms,
    download split 16.6 / 3.0 / 16.6 / 12.0 Mbit/s, the same as before.
  - `robustness.sh` on a `CAKE_DEBUG` `dummynet.ko` passes everything
    except the unload test, which doesn't apply to a built-in scheduler.
    That includes 44 reconfigurations under load, with cake→cake changes of
    diffserv and isolation mode that rebuild the tables while packets are
    queued. 0 consistency errors; the checks now include the host bulk
    counts.
  - The full suite with the separate `dn_cake.ko` on a stock `dummynet.ko`
    passes all 8 tests, unload included, so the host table is freed
    correctly.
- Performance (2026-10-24), using `test/perf.sh` on the `lul-setup.sh` bench
  (pf off, `kern.hz=1000`, 2 vCPUs in nested KVM). Unshaped, the VMs forward
  about 760 Mbit/s one way, or about 400 Mbit/s each way with both directions
  loaded. The runs therefore use 300 Mbit/s each way. At 500 Mbit/s the
  pipes never filled.
  - RRUL, 3 runs. All CAKE modes and fq_codel give the same goodput (283–285
    Mbit/s each way, 95% of the rate), ICMP medians of 1.8–2.3 ms, and the
    same router CPU (27–31% busy, mostly virtio interrupts). The p99 varied
    between runs as much as between schedulers: 5.2–6.6 ms for fq_codel,
    4.9–9.8 ms for CAKE.
  - Scheduler cost per call, timed with DTrace (`PROF=1`, nanoseconds, probe
    overhead included):

    | load | fq_codel enq / deq | cake `flows` enq / deq | cake `triple-isolate` enq / deq |
    |---|---|---|---|
    | RRUL (8 flows) | 317 / 333 | 362 / 373 | 375 / 391 |
    | 64 download flows, one host | 339 / 349 | 399 / 406 | 408 / 534 |
    | 256 download flows, one host | 359 / 383 | 425 / 443 | 420 / 886 |
    | 256 flows, `limit 300` (overflow path) | 518 / 345 | 444 / 466 | 457 / 852 |

  CAKE costs about 15% more per packet than fq_codel, roughly 50–60 ns. The
  exception is host isolation with many bulk flows on a single host: each
  flow's refill is quantum/N, so dequeue spends more time on refill rounds.
  That doubles the dequeue cost at 256 flows, as it does in sch_cake, which
  is about 6% of one CPU at 65k packets/s. The overflow path is cheaper than
  fq_codel's, because the fattest-flow scan only visits active flows, not
  the whole table (1.4 replaced the scan with sch_cake's heap). The
  multi-millisecond maxima show up for every scheduler; they're the VM being
  descheduled, not scheduler work.
- Overhead compensation (2026-10-24), checked with `test/overhead.sh`. It
  floods a 4 Mbit/s CAKE pipe with fixed-size UDP datagrams and compares
  the packet rate reaching the server with rate / (8 × predicted wire
  bytes):

  | setting | IP length → wire bytes | expected / measured packets/s |
  |---|---|---|
  | none | 1500 → 1500, 48 → 48 | 333 / 333, 10417 / 10280 |
  | ethernet | 1500 → 1538, 46 → 84 (mpu) | 325 / 324, 5952 / 5938 |
  | docsis | 1500 → 1518, 128 → 146 | 329 / 329, 3425 / 3432 |
  | pppoe-ptm | 1500 → 1554, 128 → 161 | 322 / 321, 3106 / 3102 |
  | atm | 1500 → 1696, 48 → 53, 49 → 106 | 295 / 295, 9434 / 9419, 4717 / 4701 |
  | pppoe-llcsnap | 1500 → 1749, 128 → 212 | 286 / 286, 2358 / 2349 |
  | overhead -20 | 1500 → 1480 | 338 / 337 |

  Every case is within 1.3% of the prediction, and all but one within
  0.5%. The 48 → 49 byte ATM step halves the packet rate, from one cell to
  two, as it should.
  - RRUL with diffserv3 and `pppoe-llcsnap` on both 50/10 Mbit/s pipes:
    download goodput 41.0 Mbit/s against 48.0 without compensation (1500 /
    1749 of 48 is 41.2), Bulk 6.0% and Voice 24.5% of it, ICMP median 2.7 ms,
    0 consistency errors.
  - The GUI fields work through the REST API. The generated `pipe ...
    pppoe-ptm overhead -20 mpu 64` shows up in `dnctl sched show`. An
    overhead of 300 or an unknown link type is rejected.
  - The module also compiles against the stock `dn_sched.h`, without the
    hook.
  - With the credit adjustment instead of the hook (stock `dummynet.ko`,
    separate `dn_cake.ko`), the same cases at 2 Mbit/s are all within 0.4%,
    e.g. ATM 48 → 49 bytes 4723 / 2361 packets/s for 4717 / 2358. A first run
    looked wrong only because the test harness was configuring CAKE with
    the stock dnctl, which drops CAKE's parameters.
- Further options (2026-10-24), `test/features.sh` with a `CAKE_DEBUG`
  module on the stock kernel, 0 consistency errors:

  | option | test | result |
  |---|---|---|
  | `wash` | EF + ECT(1) pings, IPv4 and IPv6 | DSCP cleared, ECN kept, no bad checksums |
  | ECN (1.3) | TCP download with ECN negotiated at both ends | 67 packets marked CE at the client, 48 Mbit/s |
  | ACK filter with collisions (1.3.4) | two TCP downloads over a 0.2 Mbit/s upload in `flowblind` mode, so both connections' ACKs share one queue | 8.5 + 8.4 → 23.1 + 22.2 Mbit/s with 9576 ACKs filtered: each connection's ACKs are only replaced by its own, so neither stalls |
  | `ack-filter` | TCP download, 50 Mbit/s down, 0.2 Mbit/s up | 17.95 → 47.65 Mbit/s, aggressive 48.20 |
  | `memlimit 32k` | UDP flood | largest backlog 31500 bytes |
  | `ingress` | UDP flood, then ping | flood is charged its drops (up to 1.4.1 0 delivered; 1.4.2, with sch_cake's failsafe, 548 of egress mode's 829 pps, i.e. 2/3), ping right after: 0% loss |
  | `ingress-recovery` (after 1.4.2) | three rounds of a 10 s UDP flood and 5 s without, under a 10 Hz ping | flood delivered 556, 546, 549 pps (egress mode 826): steady at 2/3; ping during the floods 0% loss, median 6.1 ms; right after each 0% loss, median 3.0 ms |
  | `diffserv8`, `precedence` | RRUL | runs, but a later rerun showed tin starvation (see the 8-tin note under design notes); both are now marked experimental |

  The ingress run found the uncapped debt: before the cap, the flood left
  the pipe owing minutes of link time and the next tests got nothing
  through.
- Plugin (2026-10-24), both packages built with `plugin/build.sh` on the
  26.7 VM (`os-cake` through `opnsense/plugins` `stable/26.7`), installed on
  the stock kernel, base and core:
  - Install runs the framework's hooks (configd restart, model migration,
    plugin reconfigure) and reloads the shaper.
  - Entries made through the plugin's API, which its page uses, switch the
    pipes on Apply; a second entry for a pipe and an overhead of 300 are
    rejected. The page renders and is in the Shaper menu.
  - RRUL through it with pf on: diffserv4 33.2 / 2.9 / 6.0 / 5.9 Mbit/s, ICMP
    median 2.66 ms.
  - Fail-safe: with the module's release marker changed to 15.2, Apply puts
    both pipes back on FQ-CoDel, logs `cake-kmod is built for FreeBSD 15.2,
    this is 15.1-RELEASE-p1, pipes keep their own scheduler`, the page shows
    the reason, and traffic keeps flowing.
  - Lifecycle: removing both packages puts the pipes back on FQ-CoDel and
    unloads the module, `pkg check -s opnsense` passes; reinstalling brings
    CAKE back; force-removing `cake-kmod` alone while CAKE is in use leaves
    the module loaded (`CAKE not unloaded`). After a reboot CAKE comes up from
    `rc.d/dnctl`.
  - The force-removal case first crashed the kernel (see *Unloading* in
    [DESIGN.md](DESIGN.md)); `robustness.sh` now also tries to unload with a configured
    but idle scheduler. All 8 robustness tests pass on the stock kernel with
    `dn_cake.ko`.
  - `make lint` of the plugins framework passes except its PHP step, which
    needs a `parallel-lint` that core's stable branch doesn't carry; `php -l`
    and `pycodestyle` are clean. `make style` (phpcs) did not run: the
    packaged phpcs pulled PHP extensions newer than the VM's PHP. It needs a
    machine with current packages.
- DTrace on OPNsense needs `-x nolibs`: the kernel ships without CTF, and
  without it the D libraries fail to parse.
- The `quantum` floor is 300 bytes, as in sch_cake. With fq_codel's floor
  of 1, a single dequeue could loop through thousands of DRR refill rounds
  while holding the dummynet lock.
- The DSCP→tin tables and the tin rate shares were checked entry by entry
  against Linux `sch_cake.c`.
- **Testing gotcha:** if you `kldload ipfw` by hand on a running OPNsense,
  inbound dummynet traffic stalls while pf is enabled. This happens with every
  scheduler, including fifo. Use `pfctl -d` for bench tests, or go through
  OPNsense's own shaper, which sets ipfw up alongside pf.
- Builds and CI (after 1.4.4):
  - `plugin/ci-build.sh` builds both packages from scratch, from the
    `opnsense/src` and `opnsense/plugins` commits in `plugin/build.conf`
    and the `dummynet.ko` of the kernel set pinned there with its SHA256
    (26.7.8, the same file as 26.7's); a kernel set whose `dummynet.ko`
    differs fails the build, before anything is compiled. On the test VM, in 80 s, its `dn_cake.ko` is byte for
    byte the 1.4.4 release's. Two builds give byte-identical packages: every
    file gets the commit's time, and `dnctl` is built without a separate
    debug file, whose CRC in the binary depended on the build directory
    (the only difference, 4 bytes, from the 1.4.4 `dnctl`).
  - `.github/workflows/tests.yml` runs `fuzz.sh` (3 million packets),
    `sched-diff.sh` (lockstep and link clock), `cobalt-diff.sh`, the
    plugin wrapper's unit tests (`test/plugin-lib.py`: options, masks,
    memory limit, invalid and injected values) and syntax checks on every
    push, and the signing server's checks (`test/sign-check.py`).
    `variants.yml` compiles, in a FreeBSD 15.1 VM against the pinned
    sources (`test/build-variants.sh`), `dn_cake.ko` as released and with
    `CAKE_DEBUG`, `dummynet.ko` with CAKE built in by the patch, with and
    without `CAKE_DEBUG`, and the patched `dnctl`; each build is checked for
    the symbols it should and should not have (`cake_check` only with
    `CAKE_DEBUG`, `cake_wire_len` only with `DN_WIRE_LEN`), and a Makefile
    that dropped `CAKE_DEBUG` failed it. `packages.yml` runs the tests and
    the variants first, then builds the packages in a FreeBSD 15.1 VM on a
    tag, with provenance attestations, and drafts the release. Run on the
    `v1.4.5` tag on a fresh runner, it rebuilt both `.pkg` files byte for
    byte (the same SHA256s as the release);
    `opnsense-watch.yml` checks weekly that OPNsense's newest kernel set
    still ships the `dummynet.ko` the latest `cake-kmod` is built against,
    and opens an issue if not; a listing, download or release it cannot
    read fails the check with that reason instead (each case tried).
  - Signed repository (`plugin/repo.sh`), on the bench with a throwaway
    key: installing from it, `os-cake` is provided by the `cake`
    repository, so the Plugins page lists it as installed, not orphaned.
    pkg drops the repository when checked against another key, and
    refuses a package changed after signing, by size or, at the same
    size, by checksum; an edited `SHA256SUMS` fails its signature check.
  - Signing with the key on another machine (`plugin/sign-server.py`),
    on the bench with the v1.4.5 release: the server signs a catalogue
    only if it lists exactly the release's packages with their pkg
    checksums and sizes, which it computes from the release's files
    (BLAKE2b in pkg's base32, the same as pkg 2.8.4 writes). It refused a
    bare digest, and the catalogue of a repository with another
    `os-cake`; `repo.sh` refused a release directory with a changed
    package before asking for a signature, and fails when signing is
    refused, which `pkg repo` itself reports as success. The signed
    catalogue is byte for byte the published 1.4.5 one.
  - Package lifecycle (os-cake 1.3.4, on the bench): a module swap, and a
    plain Apply, during a 45 s download through CAKE at 50 Mbit/s: the
    TCP connection kept going, the one-second throughput dipped once to
    47.3 Mbit/s (48.2-48.3 otherwise), and a 10 Hz ping lost none of 440
    packets (worst 4.6 ms). Removing both packages while another CAKE pipe
    holds the module leaves the pipes on FQ-CoDel and the module loaded
    without its file; reinstalling from the repository puts CAKE back
    without a swap (the same file).
