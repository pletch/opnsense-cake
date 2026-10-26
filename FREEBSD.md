# CAKE on FreeBSD without the plugin

Building `dn_cake.ko` from source, the `dnctl` options of the CAKE
scheduler, and the patches that build it into dummynet. On OPNsense, the
plugin packages are simpler; see the [README](README.md#install-on-opnsense).

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
  is four times what the pipe sends in an interval, at least 4 MB, and at
  most `limit` full-size packets.
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
