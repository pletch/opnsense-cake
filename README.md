# opnsense-cake: the CAKE scheduler for FreeBSD dummynet and OPNsense

CAKE (Common Applications Kept Enhanced) is the traffic scheduler behind
Linux's `sch_cake` and OpenWrt's SQM. It keeps latency low on a busy
connection, so calls, games and browsing stay responsive while something
else saturates the link, and it shares bandwidth fairly between devices,
not just between connections. FreeBSD's dummynet, and with it the OPNsense
traffic shaper, offers FQ-CoDel but not CAKE. This repository is a port of
CAKE to dummynet, and an OPNsense plugin to use it.

CAKE is the work of Jonathan Morton, Toke Høiland-Jørgensen, Dave Taht,
Sebastian Moeller, Kevin Darbyshire-Bryant and Ryan Mounce, who wrote
Linux's `sch_cake`; this port follows their code, under its BSD-3-Clause
license option, and is checked against it packet by packet. The dummynet
side follows FreeBSD's FQ-CoDel scheduler by Rasool Al-Saadi (Centre for
Advanced Internet Architectures, Swinburne University of Technology).

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
suites in [VERIFICATION.md](VERIFICATION.md), and in use on one OPNsense
26.7 router (a Proxmox VM) on a 2 Gbit/s symmetric fiber link. **Running
OPNsense in a VM? Set `kern.hz=1000`**
([why](#opnsense-in-a-vm-set-kernhz1000)); it helps FQ-CoDel too. `dn_cake.ko` is an unofficial kernel module: it runs
in your firewall's kernel and is not supported by OPNsense or FreeBSD. If
it can't be used, the plugin leaves the shaper on each pipe's own
scheduler.

To install on OPNsense, see [Install on OPNsense](#install-on-opnsense) and
[`plugin/README.md`](plugin/README.md). Read [Security notes](#security-notes)
first; vulnerabilities can be reported as described in
[`SECURITY.md`](SECURITY.md).

More documentation:

- [`plugin/README.md`](plugin/README.md): building the packages, upgrading
  and removing them
- [`FREEBSD.md`](FREEBSD.md): CAKE on FreeBSD without the plugin: building
  the module, its `dnctl` options, and the patches that build it into
  dummynet
- [`DESIGN.md`](DESIGN.md): what is implemented compared with Linux's
  sch_cake, how, and why it differs where it does; the roadmap
- [`VERIFICATION.md`](VERIFICATION.md): the test suites, the comparisons
  with sch_cake and their results

## Install on OPNsense

The plugin route changes none of OPNsense's own files and survives its
updates, but by default it replaces part of the kernel at runtime: the
wrapper swaps a forked dummynet (`dummynet_st.ko`, in beta) in for the
stock `dummynet.ko`. To stay on the stock dummynet, untick *Sub-tick
release* on the CAKE page and Apply. There are three packages:

- **`cake-kmod`**: `/boot/modules/dn_cake.ko`, and a dnctl that can set CAKE
  parameters, in `/usr/local/libexec/cake/`. It is built for one OPNsense
  series (26.7 is FreeBSD 15.1) and records that release.
- **`dummynet-st`** (beta, used by default): `/boot/modules/dummynet_st.ko`,
  dummynet with CAKE built in that releases packets between clock ticks
  ([SUBTICK.md](SUBTICK.md)), built and checked like `cake-kmod`. Nothing
  loads it at boot: the wrapper swaps it in for the stock `dummynet.ko`
  while CAKE entries are enabled (or, with *Sub-tick release for* set to
  *All pipes*, whenever the shaper has pipes, so FQ-CoDel and the other
  schedulers release between ticks too), unless *Sub-tick release* is
  switched off on the CAKE page, and uses the stock dummynet and
  `dn_cake.ko` when it does not match the kernel or does not load.
- **`os-cake`**: a **Firewall → Shaper → CAKE** page and a dnctl wrapper.
  It depends on `cake-kmod` and `dummynet-st`.

`rc.d/dnctl` loads the shaper rules through the wrapper (`dnctl_program`, set
in `/usr/local/etc/rc.conf.d/dnctl`). The wrapper switches the pipes listed on
the CAKE page to `type cake` with their options, loads `dn_cake.ko` and runs
the CAKE capable dnctl. If no pipe uses CAKE, or the module is missing or was
built for another FreeBSD release or another `dummynet.ko`, it passes the rules on unchanged to
`/sbin/dnctl`, logs why, and the shaper keeps running with each pipe's own
scheduler.

### Install the packages

The packages are ready built for **OPNsense 26.7 (amd64)**, so there is
nothing to build. They are in a signed package repository, and attached to
the [releases](https://github.com/pletch/opnsense-cake/releases).

**From the repository** (recommended): as root on the firewall (console or
ssh, shell option 8), trust the repository's key by its fingerprint, add the
repository, and install:

```sh
mkdir -p /usr/local/etc/pkg/fingerprints/cake/trusted /usr/local/etc/pkg/fingerprints/cake/revoked
cat > /usr/local/etc/pkg/fingerprints/cake/trusted/cake-repo <<'EOF'
function: "sha256"
fingerprint: "5f20160ba5f94441e79af9f1f1c2fe8ad8dd52cdea612efa838cdc798d2eb502"
EOF
cat > /usr/local/etc/pkg/repos/cake.conf <<'EOF'
cake: {
  url: "https://pletch.github.io/opnsense-cake/26.7",
  signature_type: "fingerprints",
  fingerprints: "/usr/local/etc/pkg/fingerprints/cake",
  enabled: yes
}
EOF
pkg update -r cake
pkg install -r cake os-cake
/usr/local/opnsense/scripts/firmware/register.php install os-cake
```

`pkg update -r cake` must say `3 packages processed`. If it prints `No
trusted public keys found` or `No trusted certificate`, the catalogue does
not match the fingerprint, and pkg installs nothing from the repository
(check the fingerprint against [Security notes](#security-notes) and the
release notes). pkg checks every package it installs against the signed
catalogue; `os-cake` brings `cake-kmod` and `dummynet-st` along. The last command registers
the plugin, as the Plugins page does when it installs one; from the shell,
`pkg` skips that, and System → Firmware → Plugins would list `os-cake` as
*misconfigured*. A firewall that installed the packages from files moves
over to the repository with `pkg install -fy -r cake cake-kmod dummynet-st os-cake`.

**From the files:** with the versions of the latest release,

```sh
cd /tmp
R=https://github.com/pletch/opnsense-cake/releases/download/v1.5.5
fetch $R/cake-kmod-1.5.5.pkg $R/dummynet-st-1.0.5.pkg $R/os-cake-1.4.5.pkg $R/SHA256SUMS
sha256sum -c SHA256SUMS
pkg add cake-kmod-1.5.5.pkg
pkg add dummynet-st-1.0.5.pkg
pkg add os-cake-1.4.5.pkg
/usr/local/opnsense/scripts/firmware/register.php install os-cake
```

`sha256sum -c` must say `OK` for the three packages; `SHA256SUMS.sig` on the
release signs `SHA256SUMS` (see [`SECURITY.md`](SECURITY.md#verifying-packages)).
Install `cake-kmod` and `dummynet-st` first: `os-cake` depends on them. Registered, the plugin
is listed as *orphaned*, as any plugin installed from a file. That is
expected. Building the packages yourself (for another series, or from
source) is in [`plugin/README.md`](plugin/README.md).

### Set up the shaper

Then:

1. On **Firewall → Shaper**, set up pipes and queues as for FQ-CoDel, and point
   the shaper rules at the **queues**. Rules that target a pipe itself go
   through its internal FIFO. FQ-CoDel's target, interval, quantum, limit and
   flows on the pipe also apply to CAKE; the quantum is the most a flow gets
   per round, and tins with a low rate share get less, as in sch_cake.
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
Proxmox VM; see *Release bursts on real hardware* in
[DESIGN.md](DESIGN.md)). Bare-metal installs already run at 1000 Hz.

**Give the firewall VM CPU time it does not have to wait for.** dummynet
releases packets only when its tick runs. When the hypervisor runs
something else on the firewall's virtual CPU, ticks come late, then
release several ticks' traffic at once. Packets wait longer, and CAKE's
AQM, like FQ-CoDel's, sees that as a standing queue and drops more. On
the test bench, one busy process on the router VM's host CPU made
dummynet miss about half of its ticks (about 800 in 14 s ran over 5 ms
late, against 2 to 4 otherwise). The sender's loss recoveries rose from
about 25 to about 40, and a TCP download with the ACK filter fell from
47 to 43 Mbit/s (33 with the VMs not pinned to separate host CPUs). On
a busy host, pin the VM's vCPUs or give them a reservation. To check,
compare the change in `net.inet.ip.dummynet.tick_diff` over a minute with
60 × `kern.hz`: that's the share of ticks dummynet had to catch up, a
few percent or less on an idle host. The bench scripts in `test/` print it
with their results (`test/ticks.sh`).

## Upgrade, roll back and remove

- **Upgrade:** from the repository, `pkg upgrade -r cake`; from files,
  `pkg add` the new packages over the old ones. The plugin registration is
  kept. The install reloads the shaper, which swaps the loaded module for
  the new one (from os-cake 1.3.4: upgrading to it already does). Before
  1.3.4, the module already loaded stays in use until the pipes let go of
  it: disable the CAKE entries and Apply, then enable them and Apply again,
  or reboot.
- **Roll back** to an earlier release with `pkg add -f` and that release's
  packages (the repository has only the latest).
- **Turn CAKE off** without uninstalling: disable the CAKE entries and
  Apply. The pipes go back to their own scheduler and the module is
  unloaded.
- **Remove:** `pkg delete os-cake dummynet-st cake-kmod`, then
  `/usr/local/opnsense/scripts/firmware/register.php remove os-cake`. The
  CAKE entries stay in the configuration, unused. To drop the repository
  too: `rm -r /usr/local/etc/pkg/repos/cake.conf /usr/local/etc/pkg/fingerprints/cake`.
- **If the firewall doesn't come up** after enabling CAKE, run
  `pkg delete -y os-cake dummynet-st cake-kmod` from the console, or
  restore a VM snapshot. A crash while the forked dummynet is loaded or
  its rules go in leaves `/conf/dummynet-st.loading` behind, and a boot
  that ends without a clean shutdown while it is in use (a panic, a power
  cut) leaves `/conf/dummynet-st.active` (os-cake 1.4.5 on); either way the
  wrapper then uses the stock dummynet, and the CAKE page says why, until
  Apply there (or `rm /conf/dummynet-st.loading /conf/dummynet-st.active`
  and a shaper reload) tries it again.

Details, and building the packages yourself, are in
[`plugin/README.md`](plugin/README.md).

## FAQ

**How do I know CAKE is in use?** The status line on Firewall → Shaper →
CAKE says whether the module is loaded and how many pipes use it, or why
it can't be used. Below it, each pipe's statistics per tin, as
`tc -s qdisc` shows them on Linux.

**What happens when OPNsense updates?** If the update changes
`dummynet.ko`, or moves to a new FreeBSD release, the plugin no longer
loads the module: the pipes keep running with their own scheduler (FQ-CoDel
or whatever they are set to), and the CAKE page says why. A `cake-kmod`
built for the new kernel brings CAKE back. Updates that leave
`dummynet.ko` unchanged, which are most of them, keep CAKE.

**Which diffserv mode?** `besteffort` if you don't mark traffic, otherwise
`diffserv3` or `diffserv4`. `diffserv8` and `precedence` are experimental:
under load, busy higher tins can starve a lower one.

**Why does my pipe show a mask warning?** A pipe with a mask gets a
scheduler instance per host, so the plugin doesn't use CAKE on it. Set the
mask to none: CAKE's host isolation shares bandwidth between hosts itself.

**Why is `os-cake` listed as orphaned on the Plugins page?** It was
installed from a file, not from one of the firewall's package
repositories. That is expected; see *Install the packages*.

**Does it work on real hardware?** It is built for any amd64 OPNsense
26.7. So far it has been tested in VMs (see *Status*); reports from
bare-metal installs, especially on cable and DSL links, are welcome.

**Where do I report a problem?** Bugs in the GitHub issues, with the
OPNsense version, the CAKE settings and the status line. Vulnerabilities
privately, as described in [`SECURITY.md`](SECURITY.md).

## Security notes

- **It runs in the kernel.** A bug in `dn_cake.ko` can crash the firewall.
  `dummynet_st.ko`, which replaces all of dummynet, more so. Keep a way
  back: a VM snapshot, or console access to run
  `pkg delete -y os-cake dummynet-st cake-kmod`.
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
- **CAKE is not used on pipes with a mask.** A mask creates a scheduler
  instance per host, and each CAKE instance allocates its flow tables (up to
  about 60 MB with 8 tins and 65536 flows). Allocation fails cleanly, but a
  mask on traffic from the Internet lets outsiders create instances. CAKE's
  host isolation does what masks were used for. From `os-cake` 1.3.3 the
  wrapper leaves a pipe with a mask on its own scheduler, logs why and
  shows it on the CAKE page; with `dnctl` directly, it is still up to you.
- **The plugin's memory limit is at most 256 MB** per pipe (`os-cake`
  1.3.3; 4096 MB before, and a larger configured value is lowered to 256
  with a warning on the CAKE page). Without one, the byte limit is four
  times what the pipe sends in an interval, at least 4 MB, and at most the
  packet limit (10240 by default) in full-size packets, about 15 MB.
- **Floods past the packet or byte limit** pick the fattest flow from a
  max-heap, as sch_cake does (from 1.4; before, a scan of the active
  flows): each drop costs O(log n), and the heap is rebuilt, O(n), only on
  the first overflow after 65535 packets without one.
- **The ACK filter** looks at no more than 128 queued packets of a flow per
  new ACK, so its cost per packet is bounded.
- **Packets are parsed defensively:** headers outside the first mbuf are
  copied out with bounds checks, and short or non-IP packets, and IPv4
  headers shorter than 20 bytes, go to a fixed flow. The ACK filter only
  takes a packet for TCP if its IP length covers the TCP header and fits
  in the packet. `test/fuzz.sh` runs the parsers and the scheduling core in
  userland under AddressSanitizer and UndefinedBehaviorSanitizer with
  millions of malformed packets (see [VERIFICATION.md](VERIFICATION.md)).
- **The plugin's dnctl wrapper** runs as root at every shaper start. It
  checks every value it takes from `config.xml` against what the GUI allows,
  so a hand-edited or restored configuration can't inject dnctl commands, and
  on any error it loads the shaper rules unchanged.
- **The package repository is signed** with the key in
  [`plugin/keys/cake-repo.pub`](plugin/keys/cake-repo.pub), kept offline,
  whose fingerprint (the SHA256 of that file) is
  `5f20160ba5f94441e79af9f1f1c2fe8ad8dd52cdea612efa838cdc798d2eb502`.
  The same key signs each release's `SHA256SUMS` (`SHA256SUMS.sig`).
  Releases after 1.4.4 are also built by CI with provenance attestations,
  and the builds are reproducible; see
  [`SECURITY.md`](SECURITY.md#verifying-packages).

## Layout

```
sys/netpfil/ipfw/dn_sched_cake.[ch]   kernel scheduler (type "cake", id 8)
sys/modules/dn_sched_cake/Makefile    out-of-tree kld build -> dn_cake.ko
plugin/net/cake/                      os-cake, an opnsense/plugins plugin (GUI page, dnctl wrapper)
plugin/kmod/                          cake-kmod package build (dn_cake.ko + a CAKE capable dnctl)
plugin/dummynet-st/                   dummynet-st package build (dummynet_st.ko)
plugin/build.sh                       builds the three packages on an OPNsense machine
patches/dummynet-subtick/             the forked dummynet: patches on opnsense-src-cake.patch, build.sh
patches/ipfw-cake.patch               ipfw(8)/dnctl(8): "type cake" parameters, display, manual
patches/opnsense-src-cake.patch       opnsense/src: scheduler in dummynet.ko, wire_len hook, ipfw patch
patches/opnsense-core-cake.patch      opnsense/core: Traffic Shaper support (older option set)
test/                                 latency, robustness, isolation, overhead, feature, perf and fuzz tests
LICENSE                               BSD-3-Clause (scheduler) and BSD-2-Clause (everything else)
SECURITY.md                           how to report vulnerabilities, verifying packages
FREEBSD.md                            CAKE on FreeBSD without the plugin, patches
DESIGN.md                             what is implemented, design notes, roadmap
VERIFICATION.md                       tests and results
RELEASING.md                          how releases are built, signed and published
.github/workflows/                    CI: userland tests, package builds, OPNsense kernel watch
```
