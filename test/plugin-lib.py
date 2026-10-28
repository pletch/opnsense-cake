#!/usr/bin/env python3
"""
Unit tests for the os-cake wrapper's handling of config.xml
(plugin/net/cake/src/opnsense/scripts/cake/lib): which pipes get CAKE,
with which arguments, and which are skipped or changed, with the message
the wrapper logs and the CAKE page shows; and whether the loaded dn_cake.ko
is the installed one. Runs anywhere with Python 3.

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

    def test_enabled_count(self):
        # the services list shows CAKE stopped unless every enabled entry got CAKE,
        # so an entry whose pipe is gone counts
        lib.CONFIG = config([('p1', '1', 'none'), ('p2', '2', 'dst-ip')], [
            ('c1', 'p1', {'enabled': '1'}), ('c2', 'p2', {'enabled': '1'}),
            ('c3', 'gone', {'enabled': '1'}), ('c4', 'p1', {'enabled': '0'})])
        try:
            self.assertEqual((len(lib.cake_pipes()), lib.cake_enabled()), (1, 3))
        finally:
            os.unlink(lib.CONFIG)

    def test_active(self):
        # the placeholder process starts when CAKE becomes active and stops when not,
        # once each: commands faked, with pgrep reporting whether it runs
        saved = lib.subprocess.run
        calls, state = [], {'running': False}

        def run(args, **kwargs):
            calls.append(args[0])
            if args[0] == '/usr/sbin/daemon':
                state['running'] = True
            elif args[0] == '/bin/pkill':
                state['running'] = False
            rc = 0 if args[0] != '/bin/pgrep' or state['running'] else 1
            return lib.subprocess.CompletedProcess(args, rc, '', '')
        lib.subprocess.run = run
        try:
            for active in (True, True, False, False, True):
                lib.set_active(active)
        finally:
            lib.subprocess.run = saved
        self.assertEqual(calls, ['/bin/pgrep', '/usr/sbin/daemon', '/bin/pgrep', '/bin/pgrep', '/bin/pkill',
                                 '/bin/pgrep', '/bin/pgrep', '/usr/sbin/daemon'])

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


class LoadedModule(unittest.TestCase):
    """ kmod_current: whether the loaded dn_cake.ko is the installed one, with kldstat,
    sysctl and the module file faked """
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.saved = lib.KMOD, lib.KMOD_LOADED, lib.subprocess.run
        lib.KMOD = os.path.join(self.dir.name, 'dn_cake.ko')
        lib.KMOD_LOADED = os.path.join(self.dir.name, 'cake-kmod.loaded')
        self.install(b'module 1')
        self.kld_id, self.boot, self.path = 7, 1793050555, '/boot/modules/dn_cake.ko'
        lib.subprocess.run = self.run_cmd

    def tearDown(self):
        lib.KMOD, lib.KMOD_LOADED, lib.subprocess.run = self.saved
        self.dir.cleanup()

    def install(self, data):
        with open(lib.KMOD, 'wb') as f:
            f.write(data)

    def run_cmd(self, args, **kwargs):
        if args[0] == '/sbin/kldstat':
            out = 'Id Refs Address                Size Name\n'
            if self.kld_id is not None:
                out += '%2d    1 0xffffffff8305f000     7954 dn_cake.ko (%s)\n' % (self.kld_id, self.path)
                out += '        Contains modules:\n                 Id Name\n                 77 dn_cake\n'
            return lib.subprocess.CompletedProcess(args, 0 if self.kld_id is not None else 1, out, '')
        if args[:3] == ['/sbin/sysctl', '-n', 'kern.boottime']:
            out = '{ sec = %d, usec = 314159 } Mon Oct 26 15:02:35 2026\n' % self.boot
            return lib.subprocess.CompletedProcess(args, 0, out, '')
        raise AssertionError(args)

    def test_not_loaded(self):
        self.kld_id = None
        self.assertIsNone(lib.kmod_current())

    def test_no_record(self):
        # loaded by kldload, or by an os-cake before 1.3.4
        self.assertIs(lib.kmod_current(), False)

    def test_recorded(self):
        lib.kmod_record()
        self.assertIs(lib.kmod_current(), True)

    def test_upgraded(self):
        lib.kmod_record()
        self.install(b'module 2')
        self.assertIs(lib.kmod_current(), False)

    def test_loaded_again(self):
        # unloaded and loaded by other means since, with a new kld id
        lib.kmod_record()
        self.kld_id = 8
        self.assertIs(lib.kmod_current(), False)

    def test_other_file(self):
        # loaded by hand from another file, which took the same kld id
        lib.kmod_record()
        self.path = '/root/work/dn_cake.ko'
        self.assertIs(lib.kmod_current(), False)

    def test_rebooted(self):
        # a record from before a reboot, with the kld id taken again
        lib.kmod_record()
        self.boot += 3600
        self.assertIs(lib.kmod_current(), False)

    def test_module_missing(self):
        lib.kmod_record()
        os.unlink(lib.KMOD)
        self.assertIs(lib.kmod_current(), False)



class Subtick(unittest.TestCase):
    """ dummynet-st: the setting, and whether the package can be used """
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.saved = (lib.CONFIG, lib.ST_KMOD, lib.ST_KERNEL, lib.ST_DUMMYNET, lib.ST_LOADED,
                      lib.ST_TRYING, lib.ST_ACTIVE, lib.ST_ACTIVE_BOOT, lib.DUMMYNET, lib.subprocess.run)
        d = self.dir.name
        lib.CONFIG = os.path.join(d, 'config.xml')
        lib.ST_KMOD = os.path.join(d, 'dummynet_st.ko')
        lib.ST_KERNEL = os.path.join(d, 'kernel')
        lib.ST_DUMMYNET = os.path.join(d, 'dummynet.sha256')
        lib.ST_LOADED = os.path.join(d, 'dummynet-st.loaded')
        lib.ST_TRYING = os.path.join(d, 'dummynet-st.loading')
        lib.ST_ACTIVE = os.path.join(d, 'dummynet-st.active')
        lib.ST_ACTIVE_BOOT = os.path.join(d, 'run-dummynet-st.active')
        lib.DUMMYNET = os.path.join(d, 'dummynet.ko')
        self.loaded = False
        # the kernel's message buffer: a power cut's, which keeps no earlier boot
        self.msgbuf = '[1] FreeBSD 15.1-RELEASE\n'
        lib.subprocess.run = self.run_cmd

    def tearDown(self):
        (lib.CONFIG, lib.ST_KMOD, lib.ST_KERNEL, lib.ST_DUMMYNET, lib.ST_LOADED, lib.ST_TRYING,
         lib.ST_ACTIVE, lib.ST_ACTIVE_BOOT, lib.DUMMYNET, lib.subprocess.run) = self.saved
        self.dir.cleanup()

    def run_cmd(self, args, **kwargs):
        if args[:3] == ['/sbin/sysctl', '-n', 'kern.msgbuf']:
            return lib.subprocess.CompletedProcess(args, 0, self.msgbuf, '')
        # kldstat -q -n dummynet_st.ko
        return lib.subprocess.CompletedProcess(args, 0 if self.loaded else 1, '', '')

    def general(self, fields):
        with open(lib.CONFIG, 'w') as f:
            f.write('<opnsense><OPNsense><Cake>%s<pipes/></Cake></OPNsense></opnsense>' % (
                '' if fields is None else '<general>%s</general>' % ''.join(
                    '<%s>%s</%s>' % (k, v, k) for k, v in fields.items())))

    def install(self, release=None, stock=b'stock dummynet', known=None):
        for path, data in [(lib.ST_KMOD, b'fork'), (lib.DUMMYNET, stock)]:
            with open(path, 'wb') as f:
                f.write(data)
        with open(lib.ST_KERNEL, 'w') as f:
            f.write((release or os.uname().release.split('-')[0]) + '\n')
        with open(lib.ST_DUMMYNET, 'w') as f:
            f.write((known or lib.file_digest(lib.DUMMYNET)) + '\n')

    def test_settings_default_on(self):
        # a config.xml from before the setting: on, the default interval
        self.general(None)
        self.assertEqual(lib.subtick_settings(), (True, lib.RELEASE_DEFAULT, 'cake'))

    def test_settings(self):
        self.general({'subtick': '0', 'release_us': '100'})
        self.assertEqual(lib.subtick_settings(), (False, 100, 'cake'))
        self.general({'subtick': '1', 'release_us': '250', 'subtick_scope': 'all'})
        self.assertEqual(lib.subtick_settings(), (True, 250, 'all'))
        # anything else is the default, CAKE pipes
        self.general({'subtick': '1', 'release_us': '250', 'subtick_scope': 'every'})
        self.assertEqual(lib.subtick_settings()[2], 'cake')

    def test_settings_invalid_interval(self):
        for value in ['5', '20000', 'x', '']:
            self.general({'subtick': '1', 'release_us': value})
            self.assertEqual(lib.subtick_settings()[:2], (True, lib.RELEASE_DEFAULT), value)

    def test_shaper_pipes(self):
        rules = os.path.join(self.dir.name, 'dnctl.conf')
        for text, expected in [('pipe 10000 config bw 50Mbit/s type fq_codel\n', True),
                               ('# define dummynet pipes\nqueue 1 config pipe 1\n', False),
                               ('', False)]:
            with open(rules, 'w') as f:
                f.write(text)
            self.assertEqual(lib.shaper_pipes(rules), expected, text)
        self.assertFalse(lib.shaper_pipes(os.path.join(self.dir.name, 'missing')))

    def test_not_installed(self):
        st = lib.st_status()
        self.assertFalse(st['usable'])
        self.assertEqual(st['reason'], 'dummynet-st is not installed')

    def test_other_release(self):
        self.install(release='14.3')
        st = lib.st_status()
        self.assertFalse(st['usable'])
        self.assertIn('built for FreeBSD 14.3', st['reason'])

    def test_other_dummynet(self):
        self.install(known='0' * 64)
        st = lib.st_status()
        self.assertFalse(st['usable'])
        self.assertIn('is not the one dummynet-st replaces', st['reason'])

    def test_usable(self):
        self.install()
        st = lib.st_status()
        self.assertTrue(st['usable'])
        self.assertEqual((st['loaded'], st['current']), (False, None))

    def test_crash_marker(self):
        # left behind by a crash while loading: not used until Apply removes it
        self.install()
        lib.st_trying(True)
        st = lib.st_status()
        self.assertFalse(st['usable'])
        self.assertIn('went down while dummynet-st was loading', st['reason'])
        lib.st_trying(False)
        self.assertTrue(lib.st_status()['usable'])

    def test_active_this_boot(self):
        # in use this boot: still usable, and gone once the stock dummynet is back
        self.install()
        lib.st_active(True)
        self.assertTrue(os.path.exists(lib.ST_ACTIVE))
        self.assertFalse(lib.st_crashed())
        self.assertTrue(lib.st_status()['usable'])
        lib.st_active(False)
        self.assertFalse(os.path.exists(lib.ST_ACTIVE) or os.path.exists(lib.ST_ACTIVE_BOOT))

    def test_active_after_crash(self):
        # in use when the last boot ended without a clean shutdown (this boot's twin is
        # gone): the stock dummynet until Apply, even after the wrapper ran on it
        self.install()
        lib.st_active(True)
        os.unlink(lib.ST_ACTIVE_BOOT)
        self.assertTrue(lib.st_crashed())
        st = lib.st_status()
        self.assertFalse(st['usable'])
        self.assertIn('without a clean shutdown', st['reason'])
        lib.st_active(False)
        self.assertFalse(lib.st_status()['usable'])
        # Apply (the retry action) removes the marker
        os.unlink(lib.ST_ACTIVE)
        self.assertTrue(lib.st_status()['usable'])

    def test_active_after_reboot(self):
        # reboot(8) skips the shutdown scripts, but the kernel logged an orderly reboot
        self.install()
        lib.st_active(True)
        os.unlink(lib.ST_ACTIVE_BOOT)
        self.msgbuf = '[5] dummynet_st loaded\n[130] Uptime: 2m10s\n---<<BOOT>>---\n[1] FreeBSD\n'
        self.assertTrue(lib.st_status()['usable'])
        self.assertFalse(os.path.exists(lib.ST_ACTIVE))

    def test_active_after_panic(self):
        # a panic logs its uptime too, after the panic
        self.install()
        lib.st_active(True)
        os.unlink(lib.ST_ACTIVE_BOOT)
        self.msgbuf = '[90] panic: page fault\n[90] Uptime: 1m30s\n---<<BOOT>>---\n[1] FreeBSD\n'
        self.assertEqual(lib.previous_boot_end(), 'panic')
        self.assertFalse(lib.st_status()['usable'])
        # only the boot before this one counts
        self.msgbuf = '[90] panic: x\n---<<BOOT>>---\n[60] Uptime: 1m\n---<<BOOT>>---\n[1] FreeBSD\n'
        self.assertEqual(lib.previous_boot_end(), 'reboot')

    def test_active_after_clean_shutdown(self):
        # the stop hook removed the marker; the boot cleared its twin
        self.install()
        lib.st_active(True)
        os.unlink(lib.ST_ACTIVE)
        os.unlink(lib.ST_ACTIVE_BOOT)
        self.assertTrue(lib.st_status()['usable'])

    def test_active_loaded(self):
        # a stale marker does not make a loaded fork unusable
        self.install()
        lib.st_active(True)
        os.unlink(lib.ST_ACTIVE_BOOT)
        self.loaded = True
        self.assertTrue(lib.st_status()['usable'])

    def test_loaded_current_and_upgraded(self):
        self.install()
        self.loaded = True
        with open(lib.ST_LOADED, 'w') as f:
            f.write(lib.file_digest(lib.ST_KMOD) + '\n')
        self.assertTrue(lib.st_status()['current'])
        with open(lib.ST_KMOD, 'wb') as f:
            f.write(b'fork, upgraded')
        self.assertFalse(lib.st_status()['current'])
        os.unlink(lib.ST_LOADED)
        self.assertFalse(lib.st_status()['current'])


class WrapperLock(unittest.TestCase):
    """ one run of dnctl.py at a time, without waiting for good on a hung one """
    def setUp(self):
        import dnctl
        self.dnctl = dnctl
        self.dir = tempfile.TemporaryDirectory()
        self.saved = (dnctl.LOCK, dnctl.LOCK_WAIT)
        dnctl.LOCK = os.path.join(self.dir.name, 'cake-dnctl.lock')
        dnctl.LOCK_WAIT = 0.5

    def tearDown(self):
        self.dnctl.LOCK, self.dnctl.LOCK_WAIT = self.saved
        self.dir.cleanup()

    def held(self, f_lock):
        import fcntl
        with open(self.dnctl.LOCK, 'a') as f_other:
            try:
                fcntl.flock(f_other, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return False
            except BlockingIOError:
                return True

    def test_free(self):
        f_lock = self.dnctl.lock_run()
        self.assertTrue(self.held(f_lock))
        f_lock.close()
        self.assertFalse(self.held(None))

    def test_waits_then_goes_ahead(self):
        import time
        first = self.dnctl.lock_run()
        start = time.monotonic()
        second = self.dnctl.lock_run()
        self.assertGreaterEqual(time.monotonic() - start, 0.5)
        self.assertIsNotNone(second)
        first.close()
        second.close()

    def test_waits_for_release(self):
        import threading
        import time
        self.dnctl.LOCK_WAIT = 10
        first = self.dnctl.lock_run()
        threading.Timer(0.3, first.close).start()
        start = time.monotonic()
        second = self.dnctl.lock_run()
        self.assertLess(time.monotonic() - start, 5)
        self.assertTrue(self.held(second))
        second.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
