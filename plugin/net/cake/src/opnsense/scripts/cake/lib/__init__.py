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
    Shared code for the CAKE plugin: the CAKE settings of traffic shaper pipes and the
    state of the cake-kmod kernel module.
"""
import os
import subprocess
import xml.etree.ElementTree as ET

CONFIG = '/conf/config.xml'
KMOD = '/boot/modules/dn_cake.ko'
KMOD_KERNEL = '/usr/local/libexec/cake/kernel'
DNCTL = '/usr/local/libexec/cake/dnctl'


def cake_pipes():
    """ CAKE scheduler arguments of the enabled CAKE pipes, by traffic shaper pipe number
    :return: dict
    """
    result = dict()
    root = ET.parse(CONFIG).getroot()
    numbers = dict()
    for pipe in root.findall('./OPNsense/TrafficShaper/pipes/pipe'):
        numbers[pipe.get('uuid')] = pipe.findtext('number')

    for item in root.findall('./OPNsense/Cake/pipes/pipe'):
        if item.findtext('enabled') != '1' or item.findtext('pipe') not in numbers:
            continue
        args = [
            item.findtext('diffserv') or 'diffserv3',
            item.findtext('isolation') or 'triple-isolate',
            'ecn' if item.findtext('ecn') == '1' else 'noecn',
            'wash' if item.findtext('wash') == '1' else 'nowash',
            'ingress' if item.findtext('ingress') == '1' else 'egress',
            item.findtext('ack_filter') or 'no-ack-filter'
        ]
        # a link type preset first, so the explicit values override it
        if item.findtext('link'):
            args.append(item.findtext('link'))
        for field in ['overhead', 'mpu']:
            if item.findtext(field):
                args += [field, item.findtext(field)]
        if item.findtext('framing'):
            args.append(item.findtext('framing'))
        if item.findtext('memlimit'):
            args += ['memlimit', '%sm' % item.findtext('memlimit')]
        result[numbers[item.findtext('pipe')]] = args

    return result


def kmod_status(load=False):
    """ whether dn_cake.ko is installed, built for the running kernel and loaded
    :param load: load the module if it is usable but not loaded yet
    :return: dict
    """
    result = {
        'installed': os.path.isfile(KMOD) and os.access(DNCTL, os.X_OK),
        'kernel_built': None,
        'kernel_running': os.uname().release,
        'loaded': subprocess.run(['/sbin/kldstat', '-q', '-m', 'dn_cake']).returncode == 0,
        'reason': ''
    }
    if os.path.isfile(KMOD_KERNEL):
        with open(KMOD_KERNEL) as f_in:
            result['kernel_built'] = f_in.read().strip()

    if not result['installed']:
        result['reason'] = 'cake-kmod is not installed'
    elif result['kernel_built'] != result['kernel_running'].split('-')[0]:
        # dummynet internals are only known to match within one FreeBSD release
        result['reason'] = 'cake-kmod is built for FreeBSD %s, this is %s' % (
            result['kernel_built'], result['kernel_running']
        )
    elif not result['loaded'] and load:
        if subprocess.run(['/sbin/kldload', '-n', KMOD], capture_output=True).returncode == 0:
            result['loaded'] = True
        else:
            result['reason'] = 'loading %s failed' % KMOD

    result['usable'] = result['reason'] == '' and (result['loaded'] or not load)
    return result
