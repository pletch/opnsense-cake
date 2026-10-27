#!/usr/bin/env python3
"""
Unit tests for the checks plugin/sign-server.py makes before it signs a
package repository catalogue: that the release directory's packages match
its SHA256SUMS, and that a catalogue file has the SHA256 it is signed as
and lists exactly the release's packages. Runs anywhere with Python 3.

    python3 test/sign-check.py
"""
import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    'sign_server', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'plugin', 'sign-server.py'))
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class Release(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.pkgs = {'cake-kmod-9.9.9.pkg': b'kmod' * 100, 'os-cake-9.9.9.pkg': b'plugin' * 50}
        for name, data in self.pkgs.items():
            with open(os.path.join(self.dir.name, name), 'wb') as f:
                f.write(data)
        self.write_sums(self.pkgs)

    def tearDown(self):
        self.dir.cleanup()

    def write_sums(self, pkgs):
        with open(os.path.join(self.dir.name, 'SHA256SUMS'), 'w') as f:
            for name, data in sorted(pkgs.items()):
                f.write('%s  %s\n' % (hashlib.sha256(data).hexdigest(), name))

    def expected(self):
        return {('All/' + n, server.pkg_sum(d), len(d)) for n, d in self.pkgs.items()}

    def catalogue(self, pkgs):
        """ packagesite.yaml and data as pkg repo writes them, reduced to the fields checked """
        entries = [{'name': n.rsplit('-', 1)[0], 'repopath': p, 'sum': s, 'pkgsize': z} for p, s, z in pkgs
                   for n in [p[4:]]]
        return ('\n'.join(json.dumps(e) for e in entries) + '\n').encode(), \
            json.dumps({'groups': [], 'expired_packages': [], 'packages': entries}).encode()

    def request(self, name, data, digest=None):
        return '%s %s %d' % (digest or hashlib.sha256(data).hexdigest(), name, len(data))

    def test_release(self):
        self.assertEqual(server.release(self.dir.name), self.expected())

    def test_release_mismatch(self):
        sums = dict(self.pkgs)
        sums['os-cake-9.9.9.pkg'] = b'other'
        self.write_sums(sums)
        with self.assertRaises(SystemExit):
            server.release(self.dir.name)

    def test_pkg_sum(self):
        # pkg's "2$" checksum: BLAKE2b-512 in pkg's base32. Checked against the
        # catalogue pkg 2.8.4 wrote for the 1.4.5 release packages; this value
        # guards the implementation against changes
        self.assertEqual(server.pkg_sum(b''),
                         '2$au4ro5mebesgyd5a7xbmnjj41mr91dbeb8sqwojtgwaxt59dwkgrpxbnt3m7qcpkuenjgnp1qnczrek8e5sebr7siki9gajd69gfq8d')

    def test_catalogue_accepted(self):
        yaml, data = self.catalogue(self.expected())
        for name, content in (('packagesite.yaml', yaml), ('data', data)):
            self.assertIsNone(server.check(self.request(name, content), content, self.expected(), set()))

    def test_catalogue_refused(self):
        exp = self.expected()
        good = sorted(exp)
        extra = exp | {('All/evil-1.0.pkg', server.pkg_sum(b'evil'), 4)}
        changed = {(p, server.pkg_sum(b'changed') if 'os-cake' in p else s, z) for p, s, z in exp}
        resized = {(p, s, z + 1) for p, s, z in exp}
        moved = {(p.replace('All/', ''), s, z) for p, s, z in exp}
        for label, pkgs in (('extra', extra), ('missing', {good[0]}), ('changed', changed),
                            ('resized', resized), ('moved', moved)):
            yaml, data = self.catalogue(pkgs)
            for name, content in (('packagesite.yaml', yaml), ('data', data)):
                self.assertIsNotNone(server.check(self.request(name, content), content, exp, set()),
                                     (label, name))
        yaml, data = self.catalogue(exp)
        cases = [
            ('wrong digest', self.request('packagesite.yaml', yaml, '0' * 64), yaml, set()),
            ('other file', self.request('meta.conf', yaml), yaml, set()),
            ('signed already', self.request('data', data), data, {'data'}),
            ('truncated', self.request('data', data), data[:-1], set()),
            ('not json', self.request('data', b'not json'), b'not json', set()),
            ('malformed', 'just one field', yaml, set()),
        ]
        for label, header, content, signed in cases:
            self.assertIsNotNone(server.check(header, content, exp, signed), label)


if __name__ == '__main__':
    unittest.main(verbosity=2)
