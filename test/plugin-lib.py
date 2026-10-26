#!/usr/bin/env python3
"""
Unit tests for the os-cake wrapper's handling of config.xml
(plugin/net/cake/src/opnsense/scripts/cake/lib): which pipes get CAKE,
with which arguments, and which are skipped or changed, with the message
the wrapper logs and the CAKE page shows. Runs anywhere with Python 3.

    python3 test/plugin-lib.py
"""
import os
import sys
import tempfile
import unittest

# no __pycache__ in the plugin's source tree, which is packaged as it is
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'plugin', 'net', 'cake',
                                'src', 'opnsense', 'scripts', 'cake'))
import lib  # noqa: E402


def config(shaper_pipes, cake_pipes):
    """ a config.xml with traffic shaper pipes (uuid, number, mask) and CAKE entries (uuid, pipe, fields) """
    xml = '<opnsense><OPNsense><TrafficShaper><pipes>'
    for uuid, number, mask in shaper_pipes:
        xml += '<pipe uuid="%s"><number>%s</number>%s</pipe>' % (
            uuid, number, '' if mask is None else '<mask>%s</mask>' % mask)
    xml += '</pipes></TrafficShaper><Cake><pipes>'
    for uuid, pipe, fields in cake_pipes:
        xml += '<pipe uuid="%s"><pipe>%s</pipe>%s</pipe>' % (
            uuid, pipe, ''.join('<%s>%s</%s>' % (k, v, k) for k, v in fields.items()))
    xml += '</pipes></Cake></OPNsense></opnsense>'
    f = tempfile.NamedTemporaryFile('w', suffix='.xml', delete=False)
    f.write(xml)
    f.close()
    return f.name


class CakePipes(unittest.TestCase):
    def run_lib(self, shaper_pipes, cake_pipes):
        lib.CONFIG = config(shaper_pipes, cake_pipes)
        try:
            errors = []
            return lib.cake_pipes(errors), errors
        finally:
            os.unlink(lib.CONFIG)

    def test_defaults(self):
        pipes, errors = self.run_lib([('p1', '1', 'none')], [('c1', 'p1', {'enabled': '1'})])
        self.assertEqual(pipes, {'1': ['diffserv3', 'triple-isolate', 'noecn', 'nowash', 'egress',
                                       'no-ack-filter']})
        self.assertEqual(errors, [])

    def test_options(self):
        pipes, errors = self.run_lib([('p1', '10000', 'none')], [('c1', 'p1', {
            'enabled': '1', 'diffserv': 'diffserv4', 'isolation': 'dual-dsthost', 'ecn': '1',
            'wash': '1', 'ingress': '1', 'ack_filter': 'ack-filter-aggressive', 'link': 'docsis',
            'overhead': '18', 'mpu': '64', 'framing': 'ptm', 'memlimit': '32'})])
        self.assertEqual(pipes, {'10000': ['diffserv4', 'dual-dsthost', 'ecn', 'wash', 'ingress',
                                           'ack-filter-aggressive', 'docsis', 'overhead', '18',
                                           'mpu', '64', 'ptm', 'memlimit', '32m']})
        self.assertEqual(errors, [])

    def test_disabled_and_unknown_pipe(self):
        pipes, errors = self.run_lib([('p1', '1', 'none')], [
            ('c1', 'p1', {'enabled': '0'}), ('c2', 'gone', {'enabled': '1'})])
        self.assertEqual((pipes, errors), ({}, []))

    def test_mask_refused(self):
        for mask in ('src-ip', 'dst-ip', 'src-ip6', 'dst-ip6'):
            pipes, errors = self.run_lib([('p1', '1', mask), ('p2', '2', 'none')], [
                ('c1', 'p1', {'enabled': '1'}), ('c2', 'p2', {'enabled': '1'})])
            self.assertEqual(list(pipes), ['2'], mask)
            self.assertEqual(len(errors), 1)
            self.assertIn('pipe 1 has a mask (%s)' % mask, errors[0])

    def test_no_mask_element(self):
        pipes, errors = self.run_lib([('p1', '1', None)], [('c1', 'p1', {'enabled': '1'})])
        self.assertEqual((list(pipes), errors), (['1'], []))

    def test_memlimit(self):
        for value, want, warned in (('1', '1m', False), ('256', '256m', False),
                                    ('257', '256m', True), ('4096', '256m', True)):
            pipes, errors = self.run_lib([('p1', '1', 'none')], [('c1', 'p1', {'enabled': '1', 'memlimit': value})])
            self.assertEqual(pipes['1'][-2:], ['memlimit', want], value)
            self.assertEqual(len(errors), 1 if warned else 0, value)
            if warned:
                self.assertIn('pipe 1: memory limit %s MB lowered to 256 MB' % value, errors[0])

    def test_invalid_values_skipped(self):
        for field, value in (('diffserv', 'diffserv9'), ('isolation', 'x; rm -rf /'), ('overhead', '300'),
                             ('overhead', '-65'), ('mpu', 'abc'), ('memlimit', '0'), ('memlimit', '4097'),
                             ('link', 'cable'), ('framing', 'adsl'), ('ack_filter', 'yes')):
            pipes, errors = self.run_lib([('p1', '1', 'none')], [('c1', 'p1', {'enabled': '1', field: value})])
            self.assertEqual(pipes, {}, (field, value))
            self.assertEqual(errors, ['invalid CAKE settings for pipe 1, skipped'], (field, value))


if __name__ == '__main__':
    unittest.main(verbosity=2)
