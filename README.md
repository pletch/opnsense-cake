# opnsense-cake: the CAKE scheduler for FreeBSD dummynet and OPNsense

CAKE (Common Applications Kept Enhanced) is the traffic scheduler behind
Linux's `sch_cake` and OpenWrt's SQM. It keeps latency low on a busy
connection, so calls, games and browsing stay responsive while something
else saturates the link, and it shares bandwidth fairly between devices,
not just between connections. FreeBSD's dummynet, and with it the OPNsense
traffic shaper, offers FQ-CoDel but not CAKE. This repository is a port of
CAKE to dummynet, and an OPNsense plugin to use it.

What it adds over FQ-CoDel:

- **Host isolation**: bandwidth is shared per device first, then per
  connection, so a machine with dozens of connections (game updates,
  backups, torrents) can't crowd out the others.
- **Link-layer overhead compensation** (Ethernet, DOCSIS, VDSL2, ADSL
  presets): packets are charged what they take on the line, so the shaper
  can be set closer to the real line rate.
- **Diffserv tins**: DSCP-marked traffic such as voice gets priority within
  a capped share.
- **ACK filter**, for asymmetric links where download ACKs fill the uplink.
- COBALT AQM, DSCP wash, ingress mode and a byte memory limit.

**Status:** tested on OPNsense 26.7 (FreeBSD 15.1) in a VM with the test
suites below, and in use on one OPNsense 26.7 router (a Proxmox VM) on a
2 Gbit/s symmetric fiber link. **Running OPNsense in a VM? Set
`kern.hz=1000`** ([why](#opnsense-in-a-vm-set-kernhz1000)); it helps
FQ-CoDel too. `dn_cake.ko` is an unofficial kernel module: it runs
in your firewall's kernel and is not supported by OPNsense or FreeBSD. If
it can't be used, the plugin leaves the shaper on each pipe's own
scheduler.

To install on OPNsense, see [Install on OPNsense](#install-on-opnsense) and
[`plugin/README.md`](plugin/README.md). Read [Security notes](#security-notes)
first; vulnerabilities can be reported as described in
[`SECURITY.md`](SECURITY.md). The rest of this file describes the
implementation, its design and how it was verified.

## Layout

```
sys/netpfil/ipfw/dn_sched_cake.[ch]   kernel scheduler (type "cake", id 8)
sys/modules/dn_sched_cake/Makefile    out-of-tree kld build -> dn_cake.ko
plugin/net/cake/                      os-cake, an opnsense/plugins plugin (GUI page, dnctl wrapper)
plugin/kmod/                          cake-kmod package build (dn_cake.ko + a CAKE capable dnctl)
plugin/build.sh                       builds both packages on an OPNsense machine
patches/ipfw-cake.patch               ipfw(8)/dnctl(8): "type cake" parameters, display, manual
patches/opnsense-src-cake.patch       opnsense/src: scheduler in dummynet.ko, wire_len hook, ipfw patch
patches/opnsense-core-cake.patch      opnsense/core: Traffic Shaper support (older option set)
test/                                 latency, robustness, isolation, overhead, feature and perf tests
LICENSE                               BSD-3-Clause (scheduler) and BSD-2-Clause (everything else)
SECURITY.md                           how to report vulnerabilities, verifying packages
```

## Install on OPNsense

The plugin route needs no changes to OPNsense's own files and survives its
updates. There are two packages:

- **`cake-kmod`**: `/boot/modules/dn_cake.ko`, and a dnctl that can set CAKE
  parameters, in `/usr/local/libexec/cake/`. It is built for one OPNsense
  series (26.7 is FreeBSD 15.1) and records that release.
- **`os-cake`**: a **Firewall → Shaper → CAKE** page and a dnctl wrapper.
  It depends on `cake-kmod`.

`rc.d/dnctl` loads the shaper rules through the wrapper (`dnctl_program`, set
in `/usr/local/etc/rc.conf.d/dnctl`). The wrapper switches the pipes listed on
the CAKE page to `type cake` with their options, loads `dn_cake.ko` and runs
the CAKE capable dnctl. If no pipe uses CAKE, or the module is missing or was
built for another FreeBSD release or another `dummynet.ko`, it passes the rules on unchanged to
`/sbin/dnctl`, logs why, and the shaper keeps running with each pipe's own
scheduler.

Build and install: see [`plugin/README.md`](plugin/README.md). Then:

1. On **Firewall → Shaper**, set up pipes and queues as for FQ-CoDel, and point
   the shaper rules at the **queues**. Rules that target a pipe itself go
   through its internal FIFO. FQ-CoDel's target, interval, quantum, limit and
   flows on the pipe also apply to CAKE.
2. On **Firewall → Shaper → CAKE**, add an entry for each pipe that should use
   CAKE: diffserv mode, isolation, link type (overhead), ACK filter and so on.
   Then **Apply**. The status line at the top says whether the module is in
   use, or why not.
3. With a link type set, the pipe bandwidth can be close to the line or sync
   rate; without one, set it 5–15% below.
4. **If OPNsense runs in a VM, set `kern.hz` to 1000.** See below.

### OPNsense in a VM: set `kern.hz=1000`

FreeBSD runs its clock at 100 Hz instead of 1000 when it detects a
hypervisor (`HZ_VM` in `kern/subr_param.c`): Proxmox, KVM, ESXi, Hyper-V,
bhyve and others. dummynet does all its timing in clock ticks, so at 100 Hz
every shaper suffers, not only CAKE:

- A saturated pipe sends 10 ms of traffic at once, e.g. 2.5 MB at
  2 Gbit/s, instead of 1 ms worth.
- dummynet's own FQ-CoDel and CoDel measure queue delay in ticks, so they
  see it in 10 ms steps against a 5 ms target.
- CAKE measures delay with a precise clock, but has to raise its target to
  15 ms (1.5 ticks), or the release bursts alone would look like a
  standing queue.

Check with `sysctl kern.hz`. To set it to 1000:

1. On **System → Settings → Tunables**, add `kern.hz` with value `1000`,
   and save.
2. Reboot, then check `sysctl kern.hz`. OPNsense writes the tunable to
   `/boot/loader.conf` during boot, so the first reboot may still come up
   at 100; if so, reboot once more.

On a 2 Gbit/s link at 1000 Hz, the timer cost is negligible (measured on a
Proxmox VM; see *Release bursts on real hardware*). Bare-metal installs
already run at 1000 Hz.

`dn_cake.ko` is an unofficial kernel module running in your firewall's
kernel. See *Status* at the top for where it has been tested.

## Security notes

- **It runs in the kernel.** A bug in `dn_cake.ko` can crash the firewall.
  Keep a way back: a VM snapshot, or console access to run
  `pkg delete -y os-cake cake-kmod`.
- **Compatibility is checked against the exact `dummynet.ko`.** The module
  depends on dummynet's internal structures, which no interface version
  covers. From `cake-kmod` 1.3, the package records the SHA256 of the
  `dummynet.ko` it was built against, and the plugin only loads CAKE if the
  `dummynet.ko` in use matches (as well as the FreeBSD release). OPNsense
  builds its kernels reproducibly: 26.7 and 26.7.7, 485 commits apart, ship
  a byte-identical `dummynet.ko`. So the file changes only when dummynet or
  a header it uses does, and an OPNsense update that changes it switches
  the pipes back to their own scheduler, with the reason on the CAKE page,
  until `cake-kmod` is rebuilt. With `cake-kmod` 1.0 or 1.1 only the
  release is checked.
- **Don't combine CAKE with pipe masks.** A mask creates a scheduler
  instance per host, and each CAKE instance allocates its flow tables (up to
  about 60 MB with 8 tins and 65536 flows). Allocation fails cleanly, but a
  mask on traffic from the Internet lets outsiders create instances. CAKE's
  host isolation does what masks were used for.
- **Floods past the packet or byte limit** make every arriving packet search
  the active flows for the fattest one. fq_codel scans all of its queues in
  the same case, so this is no worse than today, but a heap would make it
  cheaper.
- **The ACK filter** looks at no more than 128 queued packets of a flow per
  new ACK, so its cost per packet is bounded.
- **Packets are parsed defensively:** headers outside the first mbuf are
  copied out with bounds checks, and short or non-IP packets go to a fixed
  flow. The parsers were fuzzed with over 100,000 malformed packets
  (TCP options, data offsets, truncated headers, IPv6, 6in4, fragments)
  without a fault or leak.
- **The plugin's dnctl wrapper** runs as root at every shaper start. It
  checks every value it takes from `config.xml` against what the GUI allows,
  so a hand-edited or restored configuration can't inject dnctl commands, and
  on any error it loads the shaper rules unchanged.
- **Packages are not signed.** Check their SHA256 sums against the release
  notes, or build them yourself from the tagged sources.

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
| Drop from the fattest flow at the packet or byte limit (`limit`, `memlimit`) | yes, linear scan over active flows; bytes counted, not mbuf memory |
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

## Build

You need a kernel source tree that matches the running kernel. On OPNsense that
means the `opnsense/src` tree for the installed release, not stock FreeBSD,
because dummynet's private headers are not installed.

```sh
cd sys/modules/dn_sched_cake
make SYSDIR=/usr/src/sys
kldload dummynet
kldload ./dn_cake.ko
```

To build it into `dummynet.ko` instead, apply `patches/opnsense-src-cake.patch`.
It adds the two source files, `sys/conf/files` and
`sys/modules/dummynet/Makefile` entries, and the ipfw change. That's the
route for OPNsense; see below.

Userland (optional, enables per-scheduler parameters). The patch is made
against `opnsense/src` `stable/26.7`. In a sparse checkout, `share/mk` is
needed too:

```sh
cd /usr/src && git sparse-checkout add sbin/ipfw share/mk
patch -p1 < .../patches/ipfw-cake.patch
cd sbin/ipfw
make -m /usr/src/share/mk SRCTOP=/usr/src MK_TESTS=no
```

This replaces `/sbin/ipfw` once you run `make install`. To try it out first,
run the binary from `/usr/obj/usr/src/amd64.amd64/sbin/ipfw/ipfw` instead.
The stock ipfw still configures and lists a cake scheduler, but it can't set
or show its parameters.

## Use

```sh
ipfw pipe 1 config bw 95Mbit/s
ipfw sched 1 config pipe 1 type cake diffserv4 target 5ms interval 100ms ecn
ipfw queue 1 config sched 1
ipfw add 100 queue 1 ip from any to any out xmit igb0
ipfw sched show
```

The scheduler parameters are:

- `target`, `interval`
- `ecn` / `noecn` (ECN on by default)
- `besteffort` / `diffserv3` / `diffserv4` / `diffserv8` / `precedence`
- `quantum`: 300–9000 bytes
- `limit`: packets, up to 65535
- `memlimit size`: byte limit of all queues, with a k/m/g suffix. The default
  is four times what the pipe sends in an interval, at least 4 MB.
- `ack-filter` / `ack-filter-aggressive` / `no-ack-filter`
- `wash` / `nowash`
- `ingress` / `egress`
- `flows N`: flow queues per tin, rounded up to a multiple of 8
- `flowblind` / `srchost` / `dsthost` / `hosts` / `flows` /
  `dual-srchost` / `dual-dsthost` / `triple-isolate`: the flow isolation
  mode, as in tc-cake(8). A bare `flows` is the mode; `flows N` sets the
  count.
- Link-layer overhead compensation: `overhead N` (-64 to 256), `mpu N`
  (up to 256), and `atm` / `ptm` / `noatm`. There are also the tc-cake(8)
  presets `ethernet`, `docsis`, `pppoe-ptm`, `bridged-ptm`, `conservative`
  and `raw`, and the ADSL encapsulations `pppoa-vcmux`, `pppoa-llc`,
  `pppoe-vcmux`, `pppoe-llcsnap`, `bridged-vcmux`, `bridged-llcsnap`,
  `ipoa-vcmux` and `ipoa-llcsnap`. `ether-vlan` adds 4 bytes; give it after
  a preset. A later keyword overrides what a preset set.

`ipfw sched show` prints them:

```
 sched 1 type CAKE flags 0x0 0 buckets 0 active
 CAKE diffserv4 triple-isolate target 3ms interval 50ms quantum 1000 limit 2000 flows 504 ECN
```

With compensation, the line ends in, for example, `overhead 30 mpu 0 ptm`.
The flags follow `ECN`, e.g. `wash ack-filter ingress memlimit 32768K`.

Without the ipfw patch, `type cake` still works and uses the defaults
under `sysctl net.inet.ip.dummynet.cake`:

```
net.inet.ip.dummynet.cake.target    5000    (us)
net.inet.ip.dummynet.cake.interval  100000  (us)
net.inet.ip.dummynet.cake.diffserv  1       (0 besteffort, 1 diffserv3, 2 diffserv4, 3 diffserv8, 4 precedence)
net.inet.ip.dummynet.cake.flags     1       (1 ecn, 2 wash, 4 ack-filter, 8 aggressive, 16 ingress)
net.inet.ip.dummynet.cake.memlimit  0       (KB, 0 for the default)
net.inet.ip.dummynet.cake.quantum   1514
net.inet.ip.dummynet.cake.limit     10240
net.inet.ip.dummynet.cake.flows     1024
net.inet.ip.dummynet.cake.flowmode  7       (0 flowblind ... 4 flows, 5 dual-srchost, 6 dual-dsthost, 7 triple-isolate)
net.inet.ip.dummynet.cake.overhead  0       (bytes, -64 to 256)
net.inet.ip.dummynet.cake.mpu       0       (bytes)
net.inet.ip.dummynet.cake.atm       0       (0 none, 1 ATM, 2 PTM)
```

## OPNsense integration through patches

Instead of the plugin, CAKE can go into OPNsense itself, which would be the
route for an upstream submission. There are two patches, one for each
OPNsense repository:

- **`opnsense-src-cake.patch`** compiles the scheduler into `dummynet.ko`, as
  fq_codel and fq_pie are, and patches `/sbin/ipfw` (which is also
  `/sbin/dnctl`). `rc.d/dnctl` only loads `dummynet`, so nothing else needs
  to be loaded. A separate kld would have to match each kernel build
  exactly, and a plugin cannot replace the base `dnctl`, so this goes into
  the src tree rather than a plugin.
- **`opnsense-core-cake.patch`** changes the Traffic Shaper:
  - Model: `cake` scheduler type, a `cake_diffserv` option (default,
    besteffort, diffserv3, diffserv4) and a `cake_isolation` option (the
    eight flow isolation modes).
  - Validation: a CAKE quantum below 300 is rejected.
  - Form: the (FQ-)CoDel target, interval, ECN, quantum, limit and flows
    fields are relabelled to cover CAKE. There are new "CAKE diffserv",
    "CAKE isolation", "CAKE link type" (the presets), "CAKE overhead",
    "CAKE MPU" and "CAKE framing" fields; the last three override the link
    type.
    The scheduler help now says that rules have to target a queue.
  - `dnctl.conf` template: CAKE takes the fq_codel parameter path plus the
    diffserv, isolation and link keywords. The `codel` and `pie` keywords are
    never emitted with it.
  - It predates the ACK filter, wash, ingress, diffserv8 / precedence and
    memlimit options, which so far only the plugin offers.

Set it up the same way as FQ-CoDel:

1. Create a pipe with scheduler *CAKE* and, under advanced, the diffserv
   mode. Tick *ECN*: the GUI's ECN checkbox defaults to off, unlike CAKE's
   own default.
2. Create a queue on that pipe.
3. Leave *CAKE isolation* at its default, triple isolate, which is fair
   between LAN hosts on both the upload and the download pipe. Use
   *dual-srchost* on an upload pipe or *dual-dsthost* on a download pipe
   if one side of the traffic is a single server.
4. Pick the *CAKE link type* of the bottleneck link, such as VDSL2 PPPoE or
   DOCSIS cable. With it, set the bandwidth near the line or sync rate.
   Without it, set the bandwidth 5–15% below the rate.
5. Point the shaper rules at the **queue**. A rule that targets the pipe
   itself goes through the pipe's internal FIFO, and CAKE never sees the
   traffic. That's standard dummynet behavior, and the same applies to
   fq_codel.

Generated rules for a 50/10 Mbit/s pair look like this:

```
pipe 10000 config bw 50Mbit/s type  cake  ecn       diffserv4
pipe 10001 config bw 10Mbit/s type  cake  ecn    quantum 300    flows 500
queue 10000 config pipe 10000 weight 100
queue 10001 config pipe 10001 weight 100
```

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
  goes idle. Its refill is the quantum divided by the larger bulk count of
  its source and destination hosts, as the dual and triple modes require,
  dithered so that the average is exact, and never less than 1 byte.
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
  tin's bulk flows, as sch_cake does. Unlike sch_cake, what drops can owe is
  capped at one interval of link time: traffic that has crossed the
  bottleneck can't arrive faster than it, but a flood into a misused pipe
  owed ~6 minutes of link time at 10 Mbit/s and stalled the pipe.
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
  [OPNsense in a VM](#opnsense-in-a-vm-set-kernhz1000)).
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
  decisions, in microseconds instead of nanoseconds. `test/cobalt-diff.sh`
  builds both in userland and compares them; see *Verification status*.
  One deliberate difference: a fresh flow starts at 1/√1, so the first
  signal comes one interval after it first exceeds the target, as
  sch_cake's comments describe. sch_cake's `cobalt_vars_init()` zeroes it,
  so there a flow that was never signalled is signalled on its second
  packet over the target. The control law is also split so that it cannot
  overflow for very long intervals (slow pipes), where `reciprocal_scale()`
  truncates the interval to 32 bits.
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
  churn.
  - Since instances now outlive their creation, CAKE also notices a pipe
    rate changed on its own (`dnctl pipe N config bw`), which dummynet
    does not report to the scheduler, and recomputes its tin rates and
    COBALT parameters. Before, only a new instance or a scheduler
    reconfiguration picked it up; OPNsense's Apply always does the
    latter.
- **Packet ownership.** All callbacks run under dummynet's lock
  (`DN_BH_WLOCK`, held by `dummynet_io`, `dummynet_task`, `config_sched` and
  the delete paths), so each packet is in exactly one place at a time. Every
  way a packet enters or leaves the scheduler (checked 2026-10-25 for 1.3):

  | path | where | the packet | counted |
  |---|---|---|---|
  | accepted | `cake_flow_enqueue` | appended to its flow, timestamp tag added | queued: flow, tin, queue and instance length and bytes |
  | no timestamp tag (allocation failure) | `cake_flow_enqueue` | freed; `enqueue` returns 1, so dummynet clears its pointer without freeing | drop, once (dummynet undoes its own count) |
  | ACK filter | `cake_enqueue` | an older ACK of the same connection unlinked and freed; the scan stops at the new packet, which is never chosen | drop, ACK drop |
  | over the packet or byte limit | `cake_drop_fattest` | head of the fattest flow freed, which can be the new packet; `enqueue` returns 0 and dummynet does not touch it again (it only compares the pointer with packets still queued) | drop |
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
  | unload | `kldunload` during RRUL, then after switching to fifo | refused while busy, unloads when idle, reloads |
  | leaks | after all of the above | dummynet malloc back to baseline, 0 queued, mbufs flat across further runs |

  The fragmented ping loses 90–100% under the flood with fifo and fq_codel
  too, while a plain ping in the same flood loses 0%. Losing any one of a
  ping's fragments loses the whole ping. The mbuf count steps up once
  after the floods, because NIC rings and UMA caches settle higher, and
  then stays flat. So the leak check compares against a warm count.
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
  the whole table, so a heap isn't needed at these flow counts. The
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
  | `ack-filter` | TCP download, 50 Mbit/s down, 0.2 Mbit/s up | 17.95 → 47.65 Mbit/s, aggressive 48.20 |
  | `memlimit 32k` | UDP flood | largest backlog 31500 bytes |
  | `ingress` | UDP flood, then ping | flood is charged its drops (0 delivered), ping right after: 0% loss |
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
  - The force-removal case first crashed the kernel (see *Unloading* under
    design notes); `robustness.sh` now also tries to unload with a configured
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

## Roadmap

1. ~~Build and load on an OPNsense VM. Test with `flent rrul` against
   fq_codel.~~ Done; see above.
2. ~~Tin priority thresholds.~~ Done; see above.
3. ~~Robustness tests and the ipfw(8) patch.~~ Done; see above.
4. ~~OPNsense Traffic Shaper integration.~~ Done as src and core patches;
   see above. Upstreaming means a PR to `opnsense/src` (or FreeBSD first)
   and one to `opnsense/core`.
5. ~~Host isolation.~~ Done; see above.
6. ~~Overhead compensation.~~ Done; see above.
7. ~~ACK filter, wash, ingress mode, diffserv8 / precedence, byte memory
   limit.~~ Done; see above.
8. ~~OPNsense plugin.~~ Done: `os-cake` and `cake-kmod`; see above.
9. **Next.** Run on real hardware, at the user's line rate and at 1 Gbit/s
   and above. In nested KVM the virtio interrupt cost hides the scheduler's.
10. Run `make style` (phpcs) on a machine with current packages.
11. Sub-tick release timing, i.e. an integrated shaper. dummynet sends a
    tick's worth of packets at once (1 ms at `kern.hz=1000`). It needs
    dummynet's timer reworked, so it can't be part of the plugin. Measured
    on 2.5 Gbit/s NICs shaping 1950 Mbit/s, it would gain little (see
    *Release bursts on real hardware*); it matters for 10 Gbit/s NICs
    feeding much slower links.
12. A heap for fattest-flow selection, only if much larger flow counts show
    up in profiles; at 256 flows the linear scan is cheaper than fq_codel's.
