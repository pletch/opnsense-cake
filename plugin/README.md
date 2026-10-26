# CAKE for OPNsense: build and install

Two packages. For OPNsense 26.7 (amd64), each
[release](https://github.com/pletch/opnsense-cake/releases) has them ready
built: skip to [Install](#install). Build them yourself only for another
series, or to run your own build of the sources. They are built on an
OPNsense machine of the series they are for:

| package | contents |
|---|---|
| `cake-kmod` | `/boot/modules/dn_cake.ko`, a CAKE capable dnctl in `/usr/local/libexec/cake/`, and the FreeBSD release and `dummynet.ko` (SHA256) they are built for |
| `os-cake` | the Firewall → Shaper → CAKE page and the dnctl wrapper; depends on `cake-kmod` |

Neither changes a file of OPNsense itself, so they survive its updates. If the
module doesn't match the running kernel, e.g. after an upgrade to a new
series or an update that changed `dummynet.ko`, the pipes keep their own
scheduler until `cake-kmod` is rebuilt. Build on a machine that runs the
kernel of the source tree: `kmod/build.sh` records that machine's
`/boot/kernel/dummynet.ko` (or `DUMMYNET=path`).

## Build

On an OPNsense machine of the target series (a VM will do), as root:

1. Get the `opnsense/src` tree of that series into `/usr/src`, with `sys`,
   `sbin/ipfw` and `share/mk`. Its dummynet must be the stock one. For 26.7:

   ```sh
   git clone --depth 1 --filter=blob:none --sparse -b stable/26.7 \
       https://github.com/opnsense/src.git /usr/src
   cd /usr/src && git sparse-checkout set sys sbin/ipfw share/mk
   ```

2. Copy this repository over, then:

   ```sh
   sh dn_sched_cake/plugin/build.sh /root/pkgs
   ```

   This builds `cake-kmod` (`kmod/build.sh`), installs it, and builds
   `os-cake` with the `opnsense/plugins` framework from the series' stable
   branch, which needs network access. Both packages end up in `/root/pkgs`.

### Rebuild a release exactly

`ci-build.sh` builds the packages the way the CI does, from scratch on
OPNsense or on FreeBSD of the series' release (15.1 for 26.7): it fetches
`opnsense/src` and `opnsense/plugins` at the commits in `build.conf`, takes
`dummynet.ko` from OPNsense's newest kernel set for the series, and needs
`git`. The builds are reproducible, so the result can be checked against a
release:

```sh
sh opnsense-cake/plugin/ci-build.sh /root/out vX.Y.Z
```

It writes the packages, `SHA256SUMS` and `CONTENTS` (the SHA256 of every
file in each package) to `/root/out`, then fetches that release's packages
and fails if any file in them differs. Every file of a package gets the
time of the sources' commit (`SOURCE_DATE_EPOCH`), so the package files
themselves come out byte for byte the same as well. Releases built by CI
start with the first one after 1.4.4; earlier ones were built on the test
VM, and only their `dn_cake.ko` is known to reproduce.

## Install

Get the two packages onto the firewall: your own build, or a release's,
which can be fetched and checked on the firewall itself (as root, with the
versions of that release):

```sh
cd /tmp
R=https://github.com/pletch/opnsense-cake/releases/download/v1.4.4
fetch $R/cake-kmod-1.4.4.pkg $R/os-cake-1.3.3.pkg $R/SHA256SUMS
sha256sum -c SHA256SUMS
```

Both must say `OK`. Then install `cake-kmod` first, and register `os-cake`
as an installed plugin:

```sh
pkg add cake-kmod-<version>.pkg
pkg add os-cake-<version>.pkg
/usr/local/opnsense/scripts/firmware/register.php install os-cake
```

The last step is what the Plugins page does after installing from a
repository; `pkg add` from the shell skips it, and System → Firmware →
Plugins then lists `os-cake` as *misconfigured* (installed, but not in the
configuration's list of plugins). It changes nothing else, and is only
needed once: upgrading either package with `pkg add` keeps the
registration. Instead of the command, the Plugins page's conflicts menu
has **Reset all local conflicts**, which registers every installed plugin
(and drops listed ones that are gone); not **Run the automatic resolver**,
which looks for configured plugins in the repositories, and `os-cake` is in
none. Registered, it is listed as *orphaned*, from *unknown-repository*:
installed and configured, but not provided by any of the firewall's package
repositories, as for any plugin installed from a file. That is the expected
state; *installed* would need `os-cake` served from a configured repository.

Then set up the shaper as described in the main README (*Install on
OPNsense*): pipes and queues on Firewall → Shaper, rules pointing at the
queues, and a CAKE entry for each pipe on Firewall → Shaper → CAKE, then
Apply.

**In a VM, set `kern.hz` to 1000.** FreeBSD defaults to 100 Hz under a
hypervisor, which makes dummynet release traffic in 10 ms bursts and
coarsens every shaper's delay control, FQ-CoDel's included. Add the tunable
`kern.hz` = `1000` on System → Settings → Tunables and reboot. Check with
`sysctl kern.hz`; if it still says 100, reboot once more (the tunable is
written to `/boot/loader.conf` during boot). See the main README, *OPNsense
in a VM*.

## Check

- While a CAKE entry is enabled, System → Diagnostics → Services and the
  dashboard's Services widget list **CAKE shaper** (from 1.3.4): running
  when every enabled entry's pipe uses CAKE, stopped when any is left on its
  own scheduler. Its button reloads the shaper. CAKE has no daemon, so a
  placeholder process (`daemon: cake`, a `sleep`) runs while it is active,
  with its PID in `/var/run/cake.pid`.
- The status line on the CAKE page says whether the module is in use and by
  how many pipes, or why it can't be used.
- Below the pipes, the page shows each CAKE pipe's statistics per tin, as
  `tc -s qdisc` does on Linux, refreshed every 5 seconds. The same numbers
  come from `sysctl net.inet.ip.dummynet.cake.stats` (cake-kmod 1.3 on).
- `sysctl kern.hz` should say 1000; in a VM it defaults to 100 (see
  *Install*). From 1.2 the CAKE page shows a warning below the status line
  when it is lower.
- `/usr/local/libexec/cake/dnctl sched show` lists the CAKE schedulers with
  their options; the stock `dnctl` lists them as `type CAKE` without options.
- If the module can't be used, the reason is logged in the system log with
  the tag `cake`.

## Upgrade and remove

- `pkg delete os-cake cake-kmod` puts the pipes back on their own scheduler
  and unloads the module. The CAKE entries stay in the configuration and are
  used again if the plugin is reinstalled. Then run
  `/usr/local/opnsense/scripts/firmware/register.php remove os-cake`, or
  the Plugins page lists it as *missing*.
- A newer `cake-kmod` replaces the module file, and its install reloads the
  shaper (as `os-cake`'s does). On each reload with CAKE pipes, the wrapper
  checks that the loaded module is the installed file: it records the file's
  SHA256, the kld id, the file and the boot time in
  `/var/run/cake-kmod.loaded` when it loads the module. If not (upgraded,
  loaded by hand or by an `os-cake` before 1.3.4), it loads the rules
  unchanged, which frees and unloads the module, then loads the new one and
  the CAKE rules, so shaping pauses for a moment. If a CAKE scheduler the
  plugin does not manage holds the module, it stays loaded, the system log
  says so, and the CAKE page warns until it is replaced. Before 1.3.4:
  disable the CAKE entries and Apply, then enable them again and Apply.
- dummynet does not let the module be unloaded while a CAKE scheduler
  exists, so removing `cake-kmod` on its own leaves the running module
  loaded.
