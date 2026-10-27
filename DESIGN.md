# opnsense-cake design

How `dn_sched_cake` implements Linux's sch_cake on dummynet: what is
implemented and how it differs, the design notes, and the roadmap. The
tests and their results are in [VERIFICATION.md](VERIFICATION.md).

## What is implemented

| Feature | Status |
|---|---|
| Tins: `besteffort`, `diffserv3` (default), `diffserv4`, `diffserv8`, `precedence` | yes, DSCP maps and shares match `sch_cake.c`; `diffserv8` and `precedence` are experimental (see design notes) |
| Tin rate thresholds: priority within share (Bulk 1/16, Video 1/2, Voice 1/4), rate-proportional above | yes, as sch_cake shaped mode; needs pipe `bw` |
| WDRR between tins when the pipe has no `bw` (sch_cake unlimited mode) | yes |
| 8-way set-associative flow hash per tin (5-tuple, perturbed Jenkins) | yes |
| DRR between flows, sparse (new) flows served first | yes |
| COBALT: CoDel with ECN marking + BLUE on overflow | yes, ported from sch_cake |
| Per-tin target/interval stretched for slow tin rates (`cake_set_rate`) | yes, from pipe `bw` |
| Drop from the fattest flow at the packet or byte limit (`limit`, `memlimit`) | yes, from sch_cake's max-heap of flow backlogs; bytes counted, not mbuf memory, and a packet limit as well (sch_cake has only the byte limit, on memory) |
| Microsecond sojourn timestamps (`sbinuptime`, not dummynet ticks) | yes |
| Link-layer overhead compensation: `overhead`, `mpu`, ATM / PTM framing, tc-cake presets | yes: through the `wire_len` hook of the src patch, or with a stock dummynet by adjusting the pipe credit |
| ACK filter (`ack-filter`, `ack-filter-aggressive`) | yes, ported from `cake_ack_filter()`, with SACK, timestamp and ECN checks; IPv4, IPv6 and 6in4 |
| `wash` | yes, IPv4 (checksum adjusted) and IPv6 |
| Ingress mode | yes; unlike sch_cake, what drops may owe the link is capped at one interval |
| Integrated shaper with sub-tick release timing | no: the pipe still releases packets once per tick |
| Flow isolation modes `flowblind`, `srchost`, `dsthost`, `hosts`, `flows`, `dual-srchost`, `dual-dsthost`, `triple-isolate` (default) | yes, host bulk-flow counts and quantum split as sch_cake |
| NAT-aware hashing via pf states | not needed on OPNsense: ipfw sees pre-NAT addresses (see below) |
| GSO splitting | not needed: OPNsense turns off TSO/LRO, so dummynet sees no super-packets |
| `fwmark` tin override | no; ipfw's `setdscp` action can mark packets for a tin instead |
| `autorate-ingress` | no (experimental in Linux too) |

## Design notes

- **Rate comes from the pipe.** The per-tin rate shares and AQM parameters
  are sized from the pipe's `bw`.
- **Reconfiguring live instances.** If the type and mask are unchanged,
  dummynet reconfigures a scheduler in place and keeps its instances; only
  `config()` runs. OPNsense's Apply does exactly that. `cake_config()`
  bumps a generation counter, and the next enqueue or dequeue on each
  instance picks up the change:
  - A new rate, target, interval or quantum is applied in place, without
    dropping anything.
  - A new tin count, flow count or isolation mode builds new tables, then
    drops what was queued in the old ones. A type change drops queued
    packets as well.
  - Each instance runs on its own copy of the configuration, which changes
    only when the change has been applied. If the new tables cannot be
    allocated, the instance keeps its old tables and the old configuration
    and tries again on the next packet, logging at most once a second.
    Before 1.1 the packet paths read flags, quantum, limit and overhead
    from the scheduler's configuration, so such a failure mixed old tables
    with new parameters, and a backlog drained at the old rate until a new
    packet arrived.

  Before this was added, a GUI change to the diffserv mode or the flow count
  did nothing until the instance was recreated, e.g. by a reboot.
- **Host isolation** follows sch_cake. Each tin has a host table, the same
  size as its flow table and 8-way set-associative, with separate source
  and destination tags and bulk-flow counts. A flow becomes bulk once it
  uses up its deficit while still backlogged, and stops being bulk when it
  goes idle. Its refill is its tin's quantum divided by the larger bulk
  count of its source and destination hosts, as the dual and triple modes
  require, as `cake_get_flow_quantum()` computes it: 65535 / load in 16
  bits plus a random 16-bit dither, so that the average is exact. Under a
  heavy host load that can round down to 0, and the flow waits for its
  next turn. A tin's quantum is its rate in bytes per second over 4096,
  between 300 and the configured quantum (sch_cake's is fixed at 1514), as
  `cake_set_rate()` sets it. (From 1.4; before, every tin used the
  configured quantum, dithered only with several bulk flows per host and
  never below 1 byte.)
- **Flow lifecycle** follows sch_cake, not fq_codel (from 1.3; before, an
  emptied new flow moved to the old list as in fq_codel):
  - A flow found empty, from either list, goes to the tin's *decaying* list
    if its COBALT state is not at rest (BLUE active, a drop count, or
    signalled within an interval), else it is deactivated. Either way its
    next packet puts it among the new flows with a full quantum.
  - Each dequeue first visits one decaying flow, so that state decays while
    other traffic flows, and a decaying flow's hash slot is not given to
    another flow. Before, an idle flow's state was frozen (a stale BLUE
    probability survived) or lost when its slot was reused.
  - A sparse flow that runs out of quantum while empty is moved to the old
    rotation but still counted as sparse (`SPARSE_WAIT`), and becomes bulk
    when its next packet arrives, as in sch_cake.
  - Measured with RRUL on the bench (50/10 Mbit/s, besteffort, 4 runs
    each): throughput unchanged; ICMP median 2.26–2.48 ms against
    1.75–2.26 ms before, UDP 2.65–2.67 against 2.51–2.61 ms. Flows that
    send often but never queue, like the download's ACKs in the upload
    pipe, now keep returning to the new flows instead of being treated as
    bulk, and pings share that list with them. This is sch_cake's
    behavior. Sparse flows spaced wider than a DRR round, like pings or
    VoIP, were already deactivated between packets and got the same
    priority under both.
- **Overhead compensation.** `serve_sched()` charges `m_pkthdr.len` against
  the pipe rate. The src patch gives `struct dn_alg` an optional
  `wire_len(si, m)` method for this, appended to the struct and only read
  when the new `DN_WIRE_LEN` flag is set, so other and older schedulers keep
  working. With a stock dummynet, as for the plugin, the scheduler instead
  charges the difference between the wire size and the packet length to the
  pipe's credit (`si->credit`, in bits × hz) when it dequeues the packet,
  which comes to the same. CAKE computes the wire size as
  `cake_calc_overhead()` does, from the network-layer length
  (`m_pkthdr.len - iphdr_off`), and charges the same bytes to the flow
  deficits and the tin clocks, so the tin shares match what the pipe
  charges.
- **Unloading.** dummynet refuses to unload a scheduler module while its
  `ref_count` is non-zero, but only instances take a reference. A
  configured CAKE scheduler without an instance (e.g. right after Apply)
  still points at the module, and unloading it then crashed the kernel on
  the next `dnctl sched show`. Every CAKE scheduler now holds a reference
  from its first `config()` until `destroy()`.
- **ACK filter** as `cake_ack_filter()`: when a pure ACK is queued, look
  through its flow for older pure ACKs of the same connection (the flow may
  hold colliding ones) that it makes redundant. They must carry no data, no
  flags other than ACK, no options except SACK, timestamps and MD5, the
  same ECN flags, an ack number not beyond the new one, and SACK blocks the
  new one covers. Normally one is dropped once two are found; in aggressive
  mode also a single one right in front of the new ACK. Headers that are
  not in the first mbuf are copied out with `m_copydata()`.
- **Ingress mode** charges dropped packets (COBALT, overflow, ACK filter) to
  the tin clock and the pipe credit, and lets COBALT's target grow with the
  tin's bulk flows, as sch_cake does. Also as sch_cake (from 1.4.2), a
  failsafe that only sends advance, by 1.5 times their duration, bounds
  that debt: it never delays the pipe's next send past the failsafe time,
  so at least 2/3 of the rate goes out however much is dropped. Up to
  1.4.1 there was no failsafe, only a cap of one interval of link time on
  the debt (kept as well); with drops charged as fast as the cap renewed,
  mostly overflow drops under a flood, the pipe sent next to nothing:
  `test/sched-diff.sh pace-random` found runs at 19 Mbit/s where sch_cake
  sent 112.
- **Tins borrow idle capacity.** A tin's rate threshold only decides
  whether it has priority; a tin over its threshold is still served when
  the higher tins have nothing due, as in sch_cake. Checked in diffserv4
  at 50 Mbit/s with a single TCP download at a time: marked CS1 (Bulk,
  threshold 3.1 Mbit/s), CS4 or EF (Voice, 12.5 Mbit/s), or unmarked, each
  got 48.26 Mbit/s.
- **Sharing under contention matches sch_cake.** `test/contention.sh`
  runs the same scenarios on the bench and on Linux's own sch_cake
  (veth between namespaces, kernel 6.12), diffserv4 at 50 Mbit/s each
  way: a 5 Mbit/s isochronous flow (irtt, 1250-byte packets every 2 ms)
  against greedy TCP downloads in other tins. Rates in Mbit/s
  (2026-10-25):

  | scenario | | Linux sch_cake | this port |
  |---|---|---|---|
  | Voice flow + greedy Bulk | Voice flow / Bulk | 5.0 (0% loss) / 43.2 | 5.0 (0% loss) / 43.4 |
  | Bulk flow + greedy Voice | Bulk flow / Voice | 4.2 (16% loss), 3 runs alike / 44.1 | 1.3.4: 3.5, 4.6, 3.6 (7–29% loss); 1.4: 3.6, 3.6, 3.5 (29% loss) / 45.0; 1.4.2: 4.0–4.1 (19–21% loss) in 6 of 8 runs, 4.4–5.0 in the others / 44.5 |
  | Voice flow + greedy Video, Best Effort, Bulk | Voice / Video / BE / Bulk | 5.0 (0% loss) / 23.9 / 16.3 / 3.0 | 5.0 (0% loss) / 24.1 / 16.2 / 3.0 |

  A Voice flow within its threshold gets all it offers while the other
  tins share the rest, and the shares between Video, Best Effort and Bulk
  agree to a few percent. A Bulk flow over its 3.1 Mbit/s threshold, up
  against greedy Voice, gets somewhat more than the threshold in both;
  with 1.4, whose scheduling decisions match sch_cake's packet for packet
  (`test/sched-diff.sh`), it is as steady as on Linux but gets 3.5–3.6
  rather than 4.2 Mbit/s. Measured, this is dummynet's tick:
  - It is not the path. Linux's sch_cake on the bench's own path (`test/
    contention.sh path`: shaping the client VM's interfaces, the router's
    pipes opened to 1 Gbit/s) gives the same 4.2 Mbit/s (16% loss) as
    between namespaces, at this port's 15.8 ms RTT.
  - It is the release times. dummynet asks the scheduler for a tick's
    worth of packets at once, all at the same time, where sch_cake's
    shaper asks for each when the link is free. With both tins over their
    thresholds, the tin with the earlier clock sends, and sending sets its
    clock to now plus the packet's time at the tin's rate. So Bulk sends
    again once Voice's clock passes Bulk's, which in batches is only at
    the next tick. `test/sched-diff.sh pace` drives the same two
    schedulers with the same trace of this scenario, sch_cake on its own
    shaper and dn_sched_cake on dummynet's `serve_sched()` credit per
    tick, and reproduces the gap without any network. Bulk gets, in
    Mbit/s:

    | kern.hz | sch_cake | dn_sched_cake (harness) | bench |
    |---|---|---|---|
    | 1000 | 3.93 | 3.41 | 3.5 (29% loss), 5 of 6 runs |
    | 4000 | 3.93 | 3.77 | 3.6–3.8 (23–28% loss) |
    | 10000 | 3.93 | 3.90 | |
    | 100000 | 3.93 | 3.93 | |

    (The harness counts IP lengths and has no TCP, hence 3.93 rather than
    4.2.) With release times as fine as sch_cake's, the shares are
    identical; the scheduler's decisions are not the cause.
  - 1.4.2 takes the tick out of those decisions with the link clock (see
    the design notes): the harness gives 3.92–3.93 Mbit/s at `kern.hz`
    100, 1000 and 4000, and the bench 4.0–4.1 Mbit/s in 6 of 8 runs
    (Linux 4.2), the others higher, 4.4–5.0. `test/sched-diff.sh
    pace-random` checks it against 300 random scenarios released the
    same way: each tin's throughput is as before (mean deviation from
    sch_cake 0.26% of the rate), so it costs nothing elsewhere. Those
    runs also found the missing ingress failsafe (from 87 ingress runs,
    the mean deviation went from 7.1% to 0.25% of the rate, the worst
    from 65% to 5.7%). What is left is the tick's own: with the
    harness's small memory limits (32–512 KB), a tick's arrivals held
    back overflow sooner, and at `kern.hz=100000` the same scenarios
    match.
- **The 8-tin modes can starve a tin.** Each tin may use its share of the
  rate at priority, and in `diffserv8` and `precedence` each share is 7/8 of
  the one below (87.5%, 77%, 67%, ...), so together they claim far more
  than the link. Under RRUL, greedy flows in two higher tins kept the tin
  below them from ever being due: `precedence` starved Best Effort (0.01
  Mbit/s, pings taking seconds), `diffserv8` starved Bulk. The pipe rate
  itself held (the router counted exactly 50 Mbit/s). This follows
  `sch_cake.c`'s shares, and tc-cake(8) calls `diffserv8` experimental and
  discourages `precedence`, so they are kept as they are but marked
  experimental. In `diffserv3` and `diffserv4` the priority shares add up to
  31% and 81%, so Best Effort always gets the rest.

  Linux behaves the same. Checked 2026-10-25 with Linux's own `sch_cake`
  (kernel 6.12, iproute2 6.15) on a veth pair between two network
  namespaces, shaped 50/10 Mbit/s like the bench, with the same RRUL test:

  | mode | Linux `sch_cake`, ICMP median | this port, ICMP median |
  |---|---|---|
  | `diffserv4` | 0.70, 0.84 ms | 2.6–2.7 ms |
  | `diffserv8` | 0.72, 0.82 ms | 2.6–2.8 ms |
  | `precedence` | 22.4, 23.8, 778 ms | 72–618 ms in most runs, 2.7 ms in some |

  The absolute numbers differ (the Linux test has no router hop), but the
  pattern is the same: in `precedence`, RRUL's CS1 flows (tin 1, 43.75
  Mbit/s) and CS5/EF flows (tin 5, 25.6 Mbit/s) sit above Best Effort
  (tin 0) and their thresholds add up to more than the link, so Best Effort
  starves, by a varying amount from run to run. In `diffserv8` CS1 is the
  lowest tin, below Best Effort, so with this traffic only one busy tin is
  above it; another mix could starve it there too. Linux also reported
  more throughput than the shaped rate while starving (12.4 Mbit/s up
  through 10, 56.8 down through 50), so those readings are a flent
  artifact, not a dummynet one.
- **Flags** share `par[2]`: the flags given in the low 16 bits and which ones
  they are in the next 16, so `wash` alone leaves ECN at its default. A mask
  of 0 is the older ECN-only form. `memlimit` (KB) is in the upper 32 bits of
  `par[5]`, next to `limit`; all ten parameter slots are in use.
- **NAT.** On OPNsense, ipfw runs after pf on input and before pf on output
  (`sync_fw_hooks.py`). On a WAN interface, dummynet therefore sees the
  internal LAN addresses in both directions, and host isolation needs no pf
  state lookups. This was checked with outbound NAT on the test VM. Counter
  rules on the NAT interface matched 4293 packets from `10.10.1.0/24` and 0
  from the translated address, while the server saw only the translated
  address.
- **Timestamps.** Packets are tagged with a 64-bit microsecond timestamp
  (`DN_CAKE_MTAG_TS`). This is separate from fq_codel's 32-bit tick-based tag,
  so packets that pass through both schedulers don't get confused.
- **Tick granularity.** dummynet releases packets once per tick. As
  `cake_set_rate()` does for slow links, each tin's target is raised to at
  least 1.5 × max(MTU time, tick), and the interval is raised to match. With
  `kern.hz=100`, FreeBSD's default in a VM, that gives a 15 ms target. For
  tighter control, set `kern.hz=1000` (see
  [OPNsense in a VM](README.md#opnsense-in-a-vm-set-kernhz1000)).
- **Release bursts on real hardware.** The pipe sends a tick's worth of
  packets at once, so a saturated pipe releases in bursts. Measured
  2026-10-25 on an OPNsense 26.7 VM on Proxmox: Intel `igc` 2.5 Gbit/s NICs
  in PCIe passthrough, `kern.hz=1000`, and the download pipe at 1950 Mbit/s
  saturated by a wired client. Outgoing full-size packets on the LAN VLAN
  were captured with `tcpdump -Q out` for 1.2 s (200,000 packets):

  | measure | result |
  |---|---|
  | bursts | 1164/s; the tick is 1000/s |
  | mean burst | 142 packets, about 210 KB (one tick at 1950 Mbit/s is about 160) |
  | largest burst | 331 packets, after the single late tick |
  | gaps of 500–1000 µs | 1128 |
  | gaps of 200–500 µs | 34 |
  | gaps of 50–200 µs | 240 (bursts split, likely by NIC interrupt moderation) |
  | gaps over 1 ms | 1 |

  The capture timestamps packets as they are handed to the transmit ring.
  The 2.5 Gbit/s NIC takes about 0.7 ms to send each burst, so on the wire
  a tick's burst fills most of the millisecond. Sub-tick release, or a
  higher `kern.hz`, would save a fraction of a millisecond of upstream
  queueing at this ratio of NIC speed to shaped rate. It matters when a
  much faster NIC feeds a slower link, e.g. 10 Gbit/s shaping 1–2 Gbit/s.
  The one late tick in 1.2 s also shows that the VM's timer is steady.
- **COBALT is sch_cake's, bit for bit** (from 1.3): the same Q0.32
  1/√count with its cache table, control law, BLUE and signalling
  decisions, in nanoseconds as in sch_cake (microseconds before 1.4), and
  the tin clocks and MTU time use sch_cake's `rate_ns`/`rate_shft`
  representation of the tin rate. `test/cobalt-diff.sh`
  builds both in userland and compares them; see [VERIFICATION.md](VERIFICATION.md).
  One deliberate difference: a fresh flow starts at 1/√1, so the first
  signal comes one interval after it first exceeds the target, as
  sch_cake's comments describe. sch_cake's `cobalt_vars_init()` zeroes it,
  so there a flow that was never signalled is signalled on its second
  packet over the target. The control law is also split so that it cannot
  overflow for very long intervals (slow pipes), where `reciprocal_scale()`
  truncates the interval to 32 bits.
- **Ingress drops** charge the link as if the packet had been sent (the
  tin clock, the link clock and the pipe credit), within sch_cake's
  failsafe (from 1.4.2), and, as in sch_cake, a COBALT drop in ingress
  mode charges the flow's deficit and sends DRR back to choose a flow
  again (from 1.4).
- **The link clock** (from 1.4.2). dummynet asks the scheduler for a
  tick's worth of packets at once, at one time; sch_cake's shaper asks for
  each when the link is free. Tin selection and the tin clocks go by that
  time, so tin shares changed with the tick: Bulk against greedy Voice got
  13% less at `kern.hz=1000`. They now use the time each packet would
  leave a link paced at the pipe's rate (the previous packet's plus its
  own duration, at most a tick behind the real time and never ahead);
  COBALT keeps the real time. `net.inet.ip.dummynet.cake.link_clock=0`
  turns it off, for comparison. The window is one tick, or, while the
  queue has been backlogged since the pipe's previous release, back to
  that release (each `serve_sched()` call stamps the instance's
  `sched_time`, which tells a release from the next packet of the same
  one): a batch carrying more than a tick's credit (a late tick) keeps
  the link's time. Before, the clock was pulled forward to a tick back
  and held at the real time for the rest of such a batch, i.e. fell back
  to dummynet's time: in `test/sched-diff.sh release bulkvoice` with a
  quarter of the time stalled (60/s up to 8 ms), Bulk against greedy
  Voice got 3.76 Mbit/s instead of sch_cake's 3.93, and now 3.92.
  CAKE_DEBUG builds count the corrections (`link_reads`, `link_behind`,
  `link_ahead` and their largest, see *The link clock's clamp* in
  [VERIFICATION.md](VERIFICATION.md)); this experimental branch's
  [SUBTICK.md](SUBTICK.md) has the measurements.
- **Overflow drops** go to another flow's head. In that case `enqueue` returns
  0, so dummynet still activates the instance for the packet it just accepted.
- **Instance expiry.** dummynet destroys a scheduler instance as soon as
  nothing is queued in it (`drain_scheduler_cb`, swept every tick with the
  default `net.inet.ip.dummynet.expire=1`), and creates a new one for the
  next packet. On a quiet link that is nearly every packet: with a 10 Hz
  ping, DTrace counted 198 instances in 10 s. Up to 1.3, each new
  instance allocated and zeroed CAKE's flow and host tables (over 500 KB
  with diffserv4 and 1024 flows) in the packet path, and lost the flow
  tags, COBALT and host state and the statistics. From 1.3.1, for a
  scheduler without a mask, `cake_free_sched` keeps the tables, tins
  (with their flow lists) and state with the scheduler, and the next
  instance adopts them: 0 table allocations in the same test, and the
  statistics keep counting. With a mask, each instance belongs to one
  host, so they are freed as before. dummynet's FQ-CoDel has the same
  churn. The kept state is created in `free_sched`, adopted in
  `new_sched` and freed in `destroy`, all called under dummynet's lock,
  and dummynet destroys a scheduler's instances before calling `destroy`,
  so it is adopted or freed exactly once. The robustness suite's `expiry`
  test runs about 200 expire/adopt cycles while reading the statistics in
  a loop, then deletes the scheduler while its state is kept, and checks
  that dummynet's memory returns to what it was without CAKE.
  - Since instances now outlive their creation, CAKE also notices a pipe
    rate changed on its own (`dnctl pipe N config bw`), which dummynet
    does not report to the scheduler, and recomputes its tin rates and
    COBALT parameters. Before, only a new instance or a scheduler
    reconfiguration picked it up; OPNsense's Apply always does the
    latter.
- **Statistics** (`net.inet.ip.dummynet.cake.stats`) come from a list of
  instances and kept states with its own mutex, as the list spans every
  vnet. Lock order: dummynet's lock, then the list's; the callbacks that
  add and remove entries already hold dummynet's. From 1.3.3 the sysctl
  takes both while it copies the counters, as dnctl's own statistics do,
  so a snapshot is consistent, and it reports only the reader's vnet. It
  formats and copies out after releasing them, as that may sleep. Up to
  1.3.1 it took only the list's mutex: memory safe (an entry cannot be
  freed while listed, and only fields embedded in it are read), but a
  snapshot could mix counters from different moments. Its buffer has to
  be allocated with the locks released; from 1.3.4 the entries are
  counted again once the locks are held and the allocation is retried if
  they no longer fit, so instances created meanwhile are never left out
  (1.3.3 allowed a fixed margin).
- **Packet ownership.** All callbacks run under dummynet's lock
  (`DN_BH_WLOCK`, held by `dummynet_io`, `dummynet_task`, `config_sched` and
  the delete paths), so each packet is in exactly one place at a time. Every
  way a packet enters or leaves the scheduler (checked 2026-10-25 for 1.3):

  | path | where | the packet | counted |
  |---|---|---|---|
  | accepted | `cake_flow_enqueue` | appended to its flow, timestamp tag added | queued: flow, tin, queue and instance length and bytes |
  | no timestamp tag (allocation failure) | `cake_flow_enqueue` | freed; `enqueue` returns 1, so dummynet clears its pointer without freeing | drop, once (dummynet undoes its own count) |
  | ACK filter | `cake_enqueue` | an older ACK of the same connection unlinked and freed; the scan stops at the new packet, which is never chosen | drop, ACK drop |
  | over the packet or byte limit | `cake_drop_fattest` | head of the fattest flow (top of the overflow heap) freed, which can be the new packet; `enqueue` returns 0 and dummynet does not touch it again (it only compares the pointer with packets still queued) | drop |
  | dequeued | `cake_extract_head` | unlinked and its tag removed, then handed to dummynet, which owns it | dequeued |
  | COBALT drop | `cake_flow_dequeue` | freed, never the flow's last packet (which may be marked instead) | drop |
  | receiving interface gone | `cake_extract_head` | freed | drop (from 1.3; before, only dequeued) |
  | reconfiguration with new tables | `cake_free_tables` | every packet in the old tables freed | drops; queue and instance totals reduced |
  | instance destroyed (delete, type change, flush, unload) | `cake_free_sched` | every flow's packets freed | none (the instance goes) |
  | idle instance expired | dummynet, `cake_free_sched` | nothing is queued (dummynet only expires such instances, which needs the instance length exact; the `CAKE_DEBUG` checker verifies it); without a mask, the tables and state are kept with the scheduler, see *Instance expiry* | |

  The packet pointer never changes (no `m_pullup`). Wash and ECN marking
  change the IP header in place only if it lies in the first mbuf and that
  mbuf is writable (not shared with other copies, e.g. by a bridge). Up to
  1.2, ECN marking used dummynet's `ecn_mark()`, which does not check
  either (FQ-CoDel, CoDel and PIE still do); a packet that can't be marked
  now is dropped instead. Also from 1.3, a timestamp tag a packet still
  carries is reused instead of being prepended a second time, which would
  corrupt its tag list (a pattern from dummynet's FQ-CoDel; not reachable
  as dequeue removes the tag). The robustness suite's leak test checks that
  mbufs and dummynet memory return to their baseline after floods,
  overflows, reconfigurations and failed rebuilds.

## Roadmap

1. ~~Build and load on an OPNsense VM. Test with `flent rrul` against
   fq_codel.~~ Done.
2. ~~Tin priority thresholds.~~ Done.
3. ~~Robustness tests and the ipfw(8) patch.~~ Done.
4. ~~OPNsense Traffic Shaper integration.~~ Done as src and core patches
   ([FREEBSD.md](FREEBSD.md)). Upstreaming means a PR to `opnsense/src` (or FreeBSD first)
   and one to `opnsense/core`.
5. ~~Host isolation.~~ Done.
6. ~~Overhead compensation.~~ Done.
7. ~~ACK filter, wash, ingress mode, diffserv8 / precedence, byte memory
   limit.~~ Done.
8. ~~OPNsense plugin.~~ Done: `os-cake` and `cake-kmod`.
9. **Next.** Run on real hardware, at the user's line rate and at 1 Gbit/s
   and above. In nested KVM the virtio interrupt cost hides the scheduler's.
10. Run `make style` (phpcs) on a machine with current packages.
11. Sub-tick release timing, i.e. an integrated shaper. dummynet sends a
    tick's worth of packets at once (1 ms at `kern.hz=1000`). The link
    clock (1.4.2) takes the tick out of CAKE's decisions, but the packets
    still leave in batches, and a small memory limit overflows sooner
    with a tick's arrivals held back. It needs
    dummynet's timer reworked, so it can't be part of the plugin. Measured
    on 2.5 Gbit/s NICs shaping 1950 Mbit/s, it would gain little (see
    *Release bursts on real hardware*); it matters for 10 Gbit/s NICs
    feeding much slower links.
12. ~~A heap for fattest-flow selection.~~ Done in 1.4, as sch_cake's.
