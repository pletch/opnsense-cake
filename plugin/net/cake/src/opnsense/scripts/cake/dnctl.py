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
"""
import os
import subprocess
import sys
import syslog
import tempfile
from lib import cake_pipes, kmod_status, DNCTL


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


if __name__ == '__main__':
    rules_file = sys.argv[1] if len(sys.argv) > 1 else '/usr/local/etc/dnctl.conf'
    syslog.openlog('cake', facility=syslog.LOG_LOCAL4)
    try:
        pipes = cake_pipes()
    except Exception as e:
        syslog.syslog(syslog.LOG_ERR, 'unable to read the CAKE settings (%s)' % e)
        pipes = dict()

    if pipes:
        status = kmod_status(load=True)
        if not status['usable']:
            syslog.syslog(syslog.LOG_WARNING, '%s, pipes keep their own scheduler' % status['reason'])
            pipes = dict()

    if not pipes:
        result = subprocess.run(['/sbin/dnctl', rules_file]).returncode
        # no CAKE scheduler is left, dummynet refuses the unload otherwise
        subprocess.run(['/sbin/kldunload', '-n', 'dn_cake.ko'], capture_output=True)
        sys.exit(result)

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
        sys.exit(os.spawnv(os.P_WAIT, DNCTL, ['dnctl', f_out.name]))
    finally:
        os.unlink(f_out.name)
