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
    CAKE kernel module status and the active CAKE schedulers, with their
    per-tin statistics, for the GUI.
"""
import json
import subprocess
import xml.etree.ElementTree as ET
from lib import cake_pipes, kmod_status, CONFIG, DNCTL

# tin names by diffserv mode, in the kernel's tin order, and the order
# tc(8) shows them in (by priority)
TINS = {
    0: (['Best Effort'], [0]),
    1: (['Best Effort', 'Bulk', 'Voice'], [1, 0, 2]),
    2: (['Best Effort', 'Bulk', 'Video', 'Voice'], [1, 0, 2, 3]),
    3: (['Tin %d' % i for i in range(8)], list(range(8))),
    4: (['Tin %d' % i for i in range(8)], list(range(8)))
}


def sysctl(name):
    """ read one sysctl, None if it can't be read
    :param name: sysctl name
    :return: str or None
    """
    out = subprocess.run(['/sbin/sysctl', '-n', name], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def tin_stats():
    """ per-tin statistics of every CAKE instance (cake-kmod 1.3 on)
    :return: {scheduler number: [instance: [tin: dict]]}, None without them
    """
    out = sysctl('net.inet.ip.dummynet.cake.stats')
    if out is None:
        return None
    result = dict()
    for line in out.split('\n'):
        parts = line.split()
        if len(parts) < 8 or len(parts) % 2 != 0:
            continue
        try:
            tin = {key: int(value) for key, value in zip(parts[0::2], parts[1::2])}
        except ValueError:
            continue
        names = TINS.get(tin['diffserv'], ([], []))[0]
        tin['name'] = names[tin['tin']] if tin['tin'] < len(names) else 'Tin %d' % tin['tin']
        result.setdefault(str(tin['sched']), dict()).setdefault(tin['inst'], dict())[tin['tin']] = tin
    # each instance's tins in display order
    for sched, instances in result.items():
        for inst, tins in instances.items():
            order = TINS.get(next(iter(tins.values()))['diffserv'], ([], sorted(tins)))[1]
            instances[inst] = [tins[i] for i in order if i in tins]
        result[sched] = [instances[inst] for inst in sorted(instances)]
    return result


def pipe_descriptions():
    """ traffic shaper pipe descriptions by pipe number
    :return: dict
    """
    result = dict()
    try:
        for pipe in ET.parse(CONFIG).getroot().findall('./OPNsense/TrafficShaper/pipes/pipe'):
            if (pipe.findtext('number') or '').isdigit():
                result[str(int(pipe.findtext('number')))] = pipe.findtext('description') or ''
    except (OSError, ET.ParseError):
        pass
    return result


if __name__ == '__main__':
    result = kmod_status()
    result['status'] = 'ok'
    result['schedulers'] = []
    # dummynet times everything in clock ticks, and FreeBSD drops to 100 Hz
    # in a virtual machine
    hz = sysctl('kern.hz')
    result['hz'] = int(hz) if hz is not None and hz.isdigit() else None
    result['vm_guest'] = sysctl('kern.vm_guest')
    # CAKE entries the wrapper skips or changes, as it logs them
    result['warnings'] = []
    try:
        cake_pipes(result['warnings'])
    except (OSError, ET.ParseError):
        pass
    if result['loaded']:
        sched = None
        for line in subprocess.run([DNCTL, 'sched', 'show'], capture_output=True, text=True).stdout.split('\n'):
            parts = line.split()
            if len(parts) > 3 and parts[0] == 'sched' and parts[2] == 'type':
                sched = parts[1] if parts[3] == 'CAKE' else None
            elif sched is not None and parts and parts[0] == 'CAKE':
                result['schedulers'].append({'sched': sched, 'config': line.strip()})
                sched = None
    # None: the module has no statistics (cake-kmod before 1.3)
    stats = tin_stats() if result['loaded'] else None
    result['stats_available'] = stats is not None
    descriptions = pipe_descriptions()
    for scheduler in result['schedulers']:
        scheduler['description'] = descriptions.get(scheduler['sched'], '')
        scheduler['instances'] = stats.get(scheduler['sched'], []) if stats else []
    print(json.dumps(result))
