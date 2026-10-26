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
import hashlib
import os
import subprocess
import xml.etree.ElementTree as ET

CONFIG = '/conf/config.xml'
KMOD = '/boot/modules/dn_cake.ko'
KMOD_KERNEL = '/usr/local/libexec/cake/kernel'
KMOD_DUMMYNET = '/usr/local/libexec/cake/dummynet.sha256'
DUMMYNET = '/boot/kernel/dummynet.ko'
DNCTL = '/usr/local/libexec/cake/dnctl'
# which dn_cake.ko the wrapper loaded: kld id, boot time, file and its SHA256
KMOD_LOADED = '/var/run/cake-kmod.loaded'
# the pidfile of the CAKE entry in the services list, see plugins.inc.d/cake.inc
ACTIVE = '/var/run/cake.pid'


# the values the model allows, checked again as config.xml may be edited or
# restored outside the GUI and the wrapper writes them into dnctl commands
DIFFSERV = ['besteffort', 'diffserv3', 'diffserv4', 'diffserv8', 'precedence']
ISOLATION = [
    'triple-isolate', 'dual-srchost', 'dual-dsthost', 'flows', 'hosts', 'srchost', 'dsthost',
    'flowblind'
]
ACK_FILTER = ['', 'ack-filter', 'ack-filter-aggressive']
LINK = [
    '', 'ethernet', 'docsis', 'pppoe-ptm', 'bridged-ptm', 'pppoe-vcmux', 'pppoe-llcsnap',
    'pppoa-vcmux', 'pppoa-llc', 'bridged-vcmux', 'bridged-llcsnap', 'ipoa-vcmux',
    'ipoa-llcsnap', 'conservative'
]
FRAMING = ['', 'noatm', 'atm', 'ptm']
# MB; the model allowed 4096 before os-cake 1.3.3, larger values are lowered to this
MEMLIMIT_MAX = 256


def int_value(value, low, high):
    """ value as an integer within [low, high]
    :return: int or None
    """
    try:
        value = int(value)
    except (TypeError, ValueError):
        return None
    return value if low <= value <= high else None


def cake_args(item, warnings=None):
    """ CAKE scheduler arguments of one CAKE pipe entry
    :param item: config.xml element of the entry
    :param warnings: list to add a message to for a value that is lowered
    :return: list, or None when a value is not one the model allows
    """
    diffserv = item.findtext('diffserv') or 'diffserv3'
    isolation = item.findtext('isolation') or 'triple-isolate'
    ack_filter = item.findtext('ack_filter') or ''
    link = item.findtext('link') or ''
    framing = item.findtext('framing') or ''
    if diffserv not in DIFFSERV or isolation not in ISOLATION or ack_filter not in ACK_FILTER \
            or link not in LINK or framing not in FRAMING:
        return None

    args = [
        diffserv,
        isolation,
        'ecn' if item.findtext('ecn') == '1' else 'noecn',
        'wash' if item.findtext('wash') == '1' else 'nowash',
        'ingress' if item.findtext('ingress') == '1' else 'egress',
        ack_filter or 'no-ack-filter'
    ]
    # a link type preset first, so the explicit values override it
    if link:
        args.append(link)
    for field, low, high in [('overhead', -64, 256), ('mpu', 0, 256)]:
        if item.findtext(field):
            value = int_value(item.findtext(field), low, high)
            if value is None:
                return None
            args += [field, str(value)]
    if framing:
        args.append(framing)
    if item.findtext('memlimit'):
        value = int_value(item.findtext('memlimit'), 1, 4096)
        if value is None:
            return None
        if value > MEMLIMIT_MAX:
            if warnings is not None:
                warnings.append('memory limit %d MB lowered to %d MB' % (value, MEMLIMIT_MAX))
            value = MEMLIMIT_MAX
        args += ['memlimit', '%dm' % value]
    return args


def cake_pipes(errors=None):
    """ CAKE scheduler arguments of the enabled CAKE pipes, by traffic shaper pipe number
    :param errors: list to add a message to for each entry that is skipped
    :return: dict
    """
    result = dict()
    root = ET.parse(CONFIG).getroot()
    numbers = dict()
    masks = dict()
    for pipe in root.findall('./OPNsense/TrafficShaper/pipes/pipe'):
        if int_value(pipe.findtext('number'), 1, 65535) is not None:
            numbers[pipe.get('uuid')] = str(int(pipe.findtext('number')))
            masks[pipe.get('uuid')] = pipe.findtext('mask') or 'none'

    for item in root.findall('./OPNsense/Cake/pipes/pipe'):
        if item.findtext('enabled') != '1' or item.findtext('pipe') not in numbers:
            continue
        number = numbers[item.findtext('pipe')]
        # a mask makes a scheduler instance, with its own flow tables, per
        # host, and on traffic from the Internet lets outsiders create them
        if masks[item.findtext('pipe')] != 'none':
            if errors is not None:
                errors.append('pipe %s has a mask (%s), CAKE is not used on it: remove the mask, '
                              'CAKE isolates hosts by itself' % (number, masks[item.findtext('pipe')]))
            continue
        warnings = []
        args = cake_args(item, warnings)
        if args is None:
            if errors is not None:
                errors.append('invalid CAKE settings for pipe %s, skipped' % number)
            continue
        if errors is not None:
            errors += ['pipe %s: %s' % (number, x) for x in warnings]
        result[number] = args

    return result


def cake_enabled():
    """ the number of enabled CAKE entries, including any whose pipe is gone """
    return len([item for item in ET.parse(CONFIG).getroot().findall('./OPNsense/Cake/pipes/pipe')
                if item.findtext('enabled') == '1'])


def set_active(active):
    """ mark the CAKE service running (every enabled entry's pipe uses CAKE) or not.
    The services list shows a service running while the process in its pidfile is, and
    pgrep -F takes no PID below 5, so a placeholder process stands for CAKE: a sleep,
    under daemon(8), which holds the pidfile and removes it when the sleep is killed.
    """
    running = subprocess.run(['/bin/pgrep', '-qF', ACTIVE], capture_output=True).returncode == 0
    if active and not running:
        subprocess.run(['/usr/sbin/daemon', '-f', '-t', 'cake', '-p', ACTIVE, '/bin/sleep', '2147483647'],
                       capture_output=True)
    elif not active and running:
        subprocess.run(['/bin/pkill', '-F', ACTIVE], capture_output=True)


def dummynet_file():
    """ the dummynet.ko in use: the loaded one, else the one kldload picks
    :return: path, or None if dummynet is built into the kernel
    """
    out = subprocess.run(['/sbin/kldstat', '-v', '-n', 'dummynet.ko'], capture_output=True, text=True)
    if out.returncode == 0:
        for line in out.stdout.split('\n'):
            parts = line.split()
            if len(parts) == 6 and parts[4] == 'dummynet.ko':
                return parts[5].strip('()')
    elif subprocess.run(['/sbin/kldstat', '-q', '-m', 'dummynet']).returncode == 0:
        return None
    return DUMMYNET


def dummynet_check():
    """ whether the dummynet.ko in use is one cake-kmod is built against
    :return: (state, reason): state is 'match', 'unchecked' for a cake-kmod
             that records no dummynet.ko (before 1.3), or 'mismatch'
    """
    if not os.path.isfile(KMOD_DUMMYNET):
        return 'unchecked', ''
    with open(KMOD_DUMMYNET) as f_in:
        known = [line.strip() for line in f_in if line.strip()]
    path = dummynet_file()
    if path is None:
        return 'mismatch', 'dummynet is built into this kernel, cake-kmod is built against dummynet.ko'
    try:
        with open(path, 'rb') as f_in:
            digest = hashlib.sha256(f_in.read()).hexdigest()
    except OSError:
        return 'mismatch', 'cannot read %s' % path
    if digest not in known:
        return 'mismatch', '%s is not the one cake-kmod is built against (kernel updated?)' % path
    return 'match', ''


def kmod_digest():
    """ SHA256 of the installed dn_cake.ko, None if it cannot be read """
    try:
        with open(KMOD, 'rb') as f_in:
            return hashlib.sha256(f_in.read()).hexdigest()
    except OSError:
        return None


def kmod_instance():
    """ the loaded dn_cake.ko, as its kld id, the boot time and the file it was loaded
    from. A kld id (and address) is reused after an unload, so this does not tell two
    loads from the same file apart; kmod_current compares the file's SHA256 for that.
    :return: string, None if it is not loaded
    """
    out = subprocess.run(['/sbin/kldstat', '-v', '-n', 'dn_cake.ko'], capture_output=True, text=True)
    kld = None
    for line in out.stdout.split('\n') if out.returncode == 0 else []:
        parts = line.split()
        if len(parts) == 6 and parts[0].isdigit() and parts[4] == 'dn_cake.ko':
            kld = '%s %s' % (parts[0], parts[5].strip('()'))
    boot = subprocess.run(['/sbin/sysctl', '-n', 'kern.boottime'], capture_output=True, text=True).stdout.split()
    # "{ sec = 1793050555, usec = 0 } ..."
    if kld is None or len(boot) < 4 or not boot[3].rstrip(',').isdigit():
        return None
    return '%s %s' % (boot[3].rstrip(','), kld)


def kmod_record():
    """ note which dn_cake.ko is loaded, just after loading it """
    instance, digest = kmod_instance(), kmod_digest()
    if instance is None or digest is None:
        return
    try:
        with open(KMOD_LOADED + '.new', 'w') as f_out:
            f_out.write('%s %s\n' % (digest, instance))
        os.replace(KMOD_LOADED + '.new', KMOD_LOADED)
    except OSError:
        pass


def kmod_current():
    """ whether the loaded dn_cake.ko is the one installed: False when the installed file
    changed (the package was upgraded) since the wrapper loaded it, or when the wrapper
    did not load it (kldload, another file, or an os-cake before 1.3.4)
    :return: bool, None if it is not loaded
    """
    instance = kmod_instance()
    if instance is None:
        return None
    try:
        with open(KMOD_LOADED) as f_in:
            recorded = f_in.read().rstrip('\n').split(' ', 1)
    except OSError:
        return False
    return len(recorded) == 2 and recorded[1] == instance and recorded[0] == kmod_digest()


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
        'dummynet': None,
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
    else:
        # the release alone misses a dummynet changed by an update within it
        result['dummynet'], result['reason'] = dummynet_check()
        if result['reason'] == '' and not result['loaded'] and load:
            if subprocess.run(['/sbin/kldload', '-n', KMOD], capture_output=True).returncode == 0:
                result['loaded'] = True
                kmod_record()
            else:
                result['reason'] = 'loading %s failed' % KMOD

    result['usable'] = result['reason'] == '' and (result['loaded'] or not load)
    result['current'] = kmod_current() if result['loaded'] else None
    return result
