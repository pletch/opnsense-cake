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

Release packages are not signed yet. Compare their SHA256 sums with the
ones in the release notes before installing:

```sh
sha256 cake-kmod-*.pkg os-cake-*.pkg
```

Releases after 1.4.4 are built by GitHub Actions
(`.github/workflows/packages.yml`) with build provenance attestations,
which tie each package to the commit and workflow run that built it:

```sh
gh attestation verify cake-kmod-X.Y.Z.pkg -R pletch/opnsense-cake
```

The builds are reproducible: `plugin/ci-build.sh` rebuilds a release's
packages from its tag on OPNsense or FreeBSD and compares them with the
published ones, file by file (see `plugin/README.md`).

The packages are also published in a pkg(8) repository,
https://pletch.github.io/opnsense-cake/26.7, whose catalogue lists every
package's SHA256 and is signed with a key kept offline rather than in
GitHub (`plugin/repo.sh`, see `RELEASING.md`). Its public key is
`plugin/keys/cake-repo.pub` (RSA 4096), with the fingerprint

```
5f20160ba5f94441e79af9f1f1c2fe8ad8dd52cdea612efa838cdc798d2eb502
```

the SHA256 of that file (`sha256 cake-repo.pub`). pkg checks the
catalogue against this fingerprint (`signature_type: "fingerprints"`), and
each package against the catalogue. `SHA256SUMS.sig` next to the catalogue
signs `SHA256SUMS`, for packages downloaded by hand:

```sh
openssl dgst -sha256 -verify cake-repo.pub -signature SHA256SUMS.sig SHA256SUMS
```
