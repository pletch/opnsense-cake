#!/usr/local/bin/python3

"""
    Copyright (c) 2026 Tim Pletcher
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
    INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
    AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
    OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
    INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
    --------------------------------------------------------------------------------------
    dnctl wrapper for rc.d/dnctl (dnctl_program): switch the pipes set up on
    Firewall: Shaper: CAKE to the CAKE scheduler and load the rules with the CAKE capable
    dnctl. When there are none, or the kernel module cannot be used, the rules are loaded
    unchanged with /sbin/dnctl, so the shaper keeps working with each pipe's own scheduler,
    and an unused module is unloaded, so a newer one is picked up when it is needed again.
    A loaded module that is not the one installed (cake-kmod was upgraded) is replaced the
    same way: the rules go in unchanged, which frees and unloads it, then the new one is
    loaded and the CAKE rules go in. The CAKE service shows as running when every enabled
    CAKE entry got CAKE.
    With dummynet-st installed and not switched off, the CAKE rules go in on the forked
    dummynet_st.ko instead (CAKE built in, packets released between ticks), loaded in place
    of dummynet.ko and dn_cake.ko; without CAKE entries, or when it does not match the
    kernel or load, the stock dummynet comes back.
"""
import fcntl
import os
import subprocess
import sys
import syslog
import tempfile
import time
from lib import cake_enabled, cake_pipes, kmod_status, kmod_current, set_active, DNCTL, \
    load_dummynet, rules_on_cake_pipes, set_release, shaper_pipes, st_active, st_loaded, st_status, \
    st_trying, subtick_settings, ST_KMOD

# held for the whole run: boot, configd reloads and Apply may start the wrapper at once,
# and two runs would interleave flushes, unloads and loads
LOCK = '/var/run/cake-dnctl.lock'
LOCK_WAIT = 120


def cake_rule(line, args):
    """ rewrite "pipe N config ... type X ..." to use CAKE
    :param line: pipe definition
    :param args: CAKE scheduler arguments
    :return: string
    """
    parts = line.split()
    idx = parts.index('type')
    # CoDel / PIE AQM keywords don't apply to CAKE, their target, interval and FQ-CoDel
    # quantum, limit and flows parameters do
    params = [x for x in parts[idx + 2:] if x not in ['codel', 'pie']]
    return ' '.join(parts[:idx] + ['type', 'cake'] + params + args) + '\n'


def lock_run():
    """ wait for any other run of the wrapper to finish, LOCK_WAIT seconds at most: a
    run that hangs must not keep the shaper down for good
    :return: the lock file, open while this run lasts (None if it could not be opened)
    """
    try:
        f_lock = open(LOCK, 'a')
    except OSError:
        return None
    deadline = time.monotonic() + LOCK_WAIT
    while True:
        try:
            fcntl.flock(f_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return f_lock
        except BlockingIOError:
            if time.monotonic() > deadline:
                syslog.syslog(syslog.LOG_WARNING, 'another run still holds %s after %d s, going ahead'
                              % (LOCK, LOCK_WAIT))
                return f_lock
            time.sleep(0.2)
        except OSError:
            return f_lock


def load_stock(rules_file):
    """ load the rules unchanged with /sbin/dnctl and unload dn_cake.ko if unused
    :return: dnctl exit status
    """
    result = subprocess.run(['/sbin/dnctl', rules_file]).returncode
    # no CAKE scheduler is left, dummynet refuses the unload otherwise
    subprocess.run(['/sbin/kldunload', '-n', 'dn_cake.ko'], capture_output=True)
    return result


def load_cake(rules_file, pipes):
    """ load the rules with the pipes in pipes switched to CAKE
    :return: dnctl exit status
    """
    rules = []
    with open(rules_file) as f_in:
        for line in f_in:
            parts = line.split()
            if len(parts) > 3 and parts[0] == 'pipe' and parts[2] == 'config' \
                    and parts[1] in pipes and 'type' in parts:
                line = cake_rule(line, pipes[parts[1]])
            rules.append(line)

    with tempfile.NamedTemporaryFile('w', prefix='dnctl-cake.', suffix='.conf', delete=False) as f_out:
        f_out.write(''.join(rules))
    try:
        return os.spawnv(os.P_WAIT, DNCTL, ['dnctl', f_out.name])
    finally:
        os.unlink(f_out.name)


if __name__ == '__main__':
    rules_file = sys.argv[1] if len(sys.argv) > 1 else '/usr/local/etc/dnctl.conf'
    syslog.openlog('cake', facility=syslog.LOG_LOCAL4)
    lock = lock_run()
    # any failure on the CAKE path falls back to the rules as they are, so the
    # shaper always comes up
    try:
        errors = []
        pipes = cake_pipes(errors)
        # entries skipped (a mask, invalid settings, the pipe gone) leave the service stopped
        enabled = cake_enabled()
        for error in errors:
            syslog.syslog(syslog.LOG_WARNING, error)
        # and so does a rule aimed at a CAKE pipe itself, whose traffic CAKE never sees
        bypassed = rules_on_cake_pipes()
        for error in bypassed:
            syslog.syslog(syslog.LOG_WARNING, error)
        # dummynet-st, unless switched off: dummynet with CAKE built in, releasing
        # packets between ticks. Otherwise, or when it does not match the kernel or
        # does not load, the stock dummynet with dn_cake.ko.
        st_wanted, release_us, scope = subtick_settings()
        st = st_status()
        # for CAKE pipes, or for all: also for a shaper without CAKE entries
        st_needed = bool(pipes) or (scope == 'all' and shaper_pipes(rules_file))
        if st_needed and st_wanted and not st['usable']:
            syslog.syslog(syslog.LOG_WARNING, '%s, using the stock dummynet' % st['reason'])
        fork = st_needed and st_wanted and st['usable']
        if not load_dummynet(fork) and fork:
            syslog.syslog(syslog.LOG_WARNING, 'loading %s failed, using the stock dummynet' % ST_KMOD)
        # a crash from here on with the fork in keeps it out at the next boot
        st_active(st_loaded())
        if not pipes and st_loaded():
            # all pipes, none with CAKE: the rules as they are, on the fork
            st_trying(True)
            set_release(release_us)
            result = load_stock(rules_file)
            st_trying(False)
            set_active(False)
            sys.exit(result)
        if pipes and st_loaded():
            # before the rules: CAKE sets its targets by it when a pipe is configured
            st_trying(True)
            set_release(release_us)
            result = load_cake(rules_file, pipes)
            st_trying(False)
            if result == 0:
                set_active(len(pipes) == enabled and not bypassed)
                sys.exit(0)
            syslog.syslog(syslog.LOG_ERR, 'dnctl failed on the CAKE rules (%d), pipes keep their own scheduler' % result)
            set_active(False)
            sys.exit(load_stock(rules_file))
        if pipes and kmod_current() is False:
            syslog.syslog(syslog.LOG_NOTICE, 'the loaded dn_cake.ko is not the one installed, reloading it')
            load_stock(rules_file)
            if kmod_current() is not None:
                syslog.syslog(syslog.LOG_WARNING, 'dn_cake.ko is still in use, the old one stays loaded')
        if pipes:
            status = kmod_status(load=True)
            if not status['usable']:
                syslog.syslog(syslog.LOG_WARNING, '%s, pipes keep their own scheduler' % status['reason'])
                pipes = dict()
        if pipes:
            result = load_cake(rules_file, pipes)
            if result == 0:
                set_active(len(pipes) == enabled and not bypassed)
                sys.exit(0)
            syslog.syslog(syslog.LOG_ERR, 'dnctl failed on the CAKE rules (%d), pipes keep their own scheduler' % result)
    except SystemExit:
        raise
    except Exception as e:
        syslog.syslog(syslog.LOG_ERR, 'CAKE setup failed (%s), pipes keep their own scheduler' % e)

    set_active(False)
    sys.exit(load_stock(rules_file))
