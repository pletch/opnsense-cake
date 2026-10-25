# CAKE for OPNsense: build and install

Two packages, built on an OPNsense machine of the series they are for:

| package | contents |
|---|---|
| `cake-kmod` | `/boot/modules/dn_cake.ko`, a CAKE capable dnctl in `/usr/local/libexec/cake/`, and the FreeBSD release they are built for |
| `os-cake` | the Firewall → Shaper → CAKE page and the dnctl wrapper; depends on `cake-kmod` |

Neither changes a file of OPNsense itself, so they survive its updates. If the
module doesn't match the running kernel, e.g. after an upgrade to a new
series, the pipes keep their own scheduler until `cake-kmod` is rebuilt.

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

## Install

Copy the two packages to the firewall and install `cake-kmod` first:

```sh
pkg add cake-kmod-1.0.pkg
pkg add os-cake-1.0.pkg
```

Then set up the shaper as described in the main README (*Install on
OPNsense*): pipes and queues on Firewall → Shaper, rules pointing at the
queues, and a CAKE entry for each pipe on Firewall → Shaper → CAKE, then
Apply.

## Check

- The status line on the CAKE page says whether the module is in use and by
  how many pipes, or why it can't be used.
- `/usr/local/libexec/cake/dnctl sched show` lists the CAKE schedulers with
  their options; the stock `dnctl` lists them as `type CAKE` without options.
- If the module can't be used, the reason is logged in the system log with
  the tag `cake`.

## Upgrade and remove

- `pkg delete os-cake cake-kmod` puts the pipes back on their own scheduler
  and unloads the module. The CAKE entries stay in the configuration and are
  used again if the plugin is reinstalled.
- A newer `cake-kmod` replaces the module file, but the module already
  loaded stays in use as long as a pipe uses CAKE. To switch without a
  reboot, disable the CAKE entries and Apply (the wrapper then unloads the
  unused module), then enable them again and Apply.
- dummynet does not let the module be unloaded while a CAKE scheduler
  exists, so removing `cake-kmod` on its own leaves the running module
  loaded.
