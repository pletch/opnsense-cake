# Releasing

How a release of `cake-kmod` and `os-cake` is built, checked, signed and
published. CI builds the packages and attests where they came from; the
maintainer signs the package repository with a key that never leaves their
machine, so taking over the GitHub repository is not enough to ship a signed
package. The repository is built on FreeBSD or OPNsense, which pkg(8) needs;
the key can stay on another machine, which signs the catalogue's two
digests over a connection (`plugin/sign-server.py`).

## One-time setup

1. **Repository signing key**, on a machine you control, kept offline
   (not in GitHub):

   ```sh
   openssl genrsa -out cake-repo.key 4096
   openssl rsa -in cake-repo.key -pubout -out plugin/keys/cake-repo.pub
   sha256sum plugin/keys/cake-repo.pub
   ```

   Commit `plugin/keys/cake-repo.pub`, and put the fingerprint (the last
   command's output) in the README and in each release's notes, so users
   can check the key they trust against more than one source. pkg checks
   the catalogue against this fingerprint, the SHA256 of the PEM file.
   Keep a second offline copy of the key: firewalls trust only it.

2. **GitHub Pages** serves the repository: create an empty `gh-pages`
   branch, and under Settings → Pages, deploy from it.

   ```sh
   git switch --orphan gh-pages && git commit --allow-empty -m "Package repository" &&
       git push origin gh-pages && git switch main
   ```

3. **Signed tags**: a GPG or SSH signing key for git
   (`git config user.signingkey`, `gpg.format`), with its public key added
   to the GitHub account, so tags show as verified.

## Each release

1. Bump `VERSION` in `plugin/kmod/build.sh` and `PLUGIN_VERSION` in
   `plugin/net/cake/Makefile`, add the changelog to
   `plugin/net/cake/pkg-descr`, update the version numbers in the install
   commands of `README.md` and `plugin/README.md`, and commit.
2. Run the VM suites on the bench (`test/robustness.sh`, `test/features.sh`)
   and the userland ones (`test/fuzz.sh`, `test/sched-diff.sh`,
   `test/cobalt-diff.sh`; CI runs these on every push too).
3. Tag and push:

   ```sh
   git tag -s vX.Y.Z -m "opnsense-cake X.Y.Z for OPNsense 26.7"
   git push origin main vX.Y.Z
   ```

   The `packages` workflow runs the tests, then builds both packages in a
   FreeBSD VM from the commits and the kernel set pinned in
   `plugin/build.conf` (it fails if the kernel set's `dummynet.ko` is not
   the pinned one), attests their provenance, and creates a draft release
   with the packages and `SHA256SUMS`.
4. Check the draft's packages: install them on the bench, and if you like,
   rebuild them yourself with `plugin/ci-build.sh` and compare
   `SHA256SUMS` (the builds are reproducible).
5. Sign the repository, from the draft's files: `repo.sh` uses exactly the
   packages its `SHA256SUMS` lists, refuses any that differ, and checks the
   catalogue it made is signed with the key (`pkg repo` reports success
   even when signing fails). With the key on the FreeBSD or OPNsense
   machine:

   ```sh
   gh release download vX.Y.Z --dir release
   git worktree add site gh-pages
   sh plugin/repo.sh cake-repo.key release site
   ```

   With the key on another machine, download the draft's files there too,
   and run the signing server with them. It listens on 127.0.0.1 only, and
   signs a catalogue file only if it lists exactly those packages, with
   their checksums and sizes (`sign.sh` sends it the file being signed),
   each of the two files once. Forward it to the FreeBSD machine, and build
   the repository there:

   ```sh
   key$ gh release download vX.Y.Z --dir release
   key$ python3 plugin/sign-server.py cake-repo.key release &
   key$ ssh -R 8471:127.0.0.1:8471 freebsd-machine
   freebsd$ sh plugin/repo.sh 127.0.0.1:8471 release site
   ```

   (A QEMU guest with user networking reaches the host's 127.0.0.1 at
   `10.0.2.2:8471` without ssh.) Bring `site/` to the key machine and sign
   `SHA256SUMS` there:

   ```sh
   openssl dgst -sha256 -sign cake-repo.key -out site/26.7/SHA256SUMS.sig site/26.7/SHA256SUMS
   ```

   `site/26.7/SHA256SUMS` is the release's. Commit `site/` to `gh-pages`
   and push it, and attach `SHA256SUMS.sig` to the release.
6. Write the notes, with the package SHA256s and the key fingerprint, and
   publish the release.

## Installing from the repository

The README's install section has the client setup: a fingerprint file with
the key's SHA256 and a `cake` repository with `signature_type:
"fingerprints"`. If the key ever changes, that section, `SECURITY.md` and
the release notes need the new fingerprint, and every firewall its new
fingerprint file.

Installed from the repository, `os-cake` shows on the Plugins page as
provided by the `cake` repository (not orphaned), and updates arrive with
the firmware updates. Tested on the bench with a throwaway key: pkg refuses
a package changed after signing (by its size, or by its checksum at the
same size), and an edited `SHA256SUMS` fails its signature check. With the
real key (v1.4.4): the README's setup installs both packages from
https://pletch.github.io/opnsense-cake/26.7; the catalogue is refused against
another fingerprint and when edited. pkg's refusal is easy to miss: it
prints `No trusted public keys found` or `No trusted certificate has been
used to sign the repository`, then `cake repository is up to date` with
exit status 0, and offers no packages from the repository.
