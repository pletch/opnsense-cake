# Security

`dn_cake.ko` runs in the kernel of the firewall it is installed on, so a bug
in it can crash the firewall or, at worst, be exploitable by crafted packets.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/pletch/opnsense-cake/security/advisories/new)
rather than in a public issue. Include the OPNsense version, the CAKE
settings of the affected pipes, and, if you have one, a packet capture or
the steps that trigger the problem.

## Supported versions

Only the latest release is supported. Packages are built for one OPNsense
series (see the release notes); on another series the plugin does not load
the module.

## Verifying packages

Release packages are not signed. Compare their SHA256 sums with the ones
in the release notes before installing:

```sh
sha256 cake-kmod-*.pkg os-cake-*.pkg
```

For the strongest assurance, build the packages yourself from the tagged
sources with `plugin/build.sh` (see `plugin/README.md`).
