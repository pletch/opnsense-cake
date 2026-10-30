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
import glob
import hashlib
import os
import re
import subprocess
import xml.etree.ElementTree as ET

CONFIG = '/conf/config.xml'
KMOD = '/boot/modules/dn_cake.ko'
KMOD_KERNEL = '/usr/local/libexec/cake/kernel'
KMOD_DUMMYNET = '/usr/local/libexec/cake/dummynet.sha256'
# the kernel cake-kmod is built for, as its version string (cake-kmod 1.6 on)
KMOD_KERNEL_VERSION = '/usr/local/libexec/cake/kernel.version'
DUMMYNET = '/boot/kernel/dummynet.ko'
DNCTL = '/usr/local/libexec/cake/dnctl'
# which dn_cake.ko the wrapper loaded: kld id, boot time, file and its SHA256
KMOD_LOADED = '/var/run/cake-kmod.loaded'
# the pidfile of the CAKE entry in the services list, see plugins.inc.d/cake.inc
ACTIVE = '/var/run/cake.pid'
# dummynet-st: dummynet with CAKE built in and packets released between
# ticks (SUBTICK.md), loaded instead of dummynet.ko and dn_cake.ko
ST_KMOD = '/boot/modules/dummynet_st.ko'
IPFW_RULES = '/usr/local/etc/ipfw.rules'
ST_KERNEL = '/usr/local/libexec/dummynet-st/kernel'
ST_DUMMYNET = '/usr/local/libexec/dummynet-st/dummynet.sha256'
ST_KERNEL_VERSION = '/usr/local/libexec/dummynet-st/kernel.version'
# the SHA256 of the dummynet_st.ko the wrapper loaded
ST_LOADED = '/var/run/dummynet-st.loaded'
# there from loading dummynet_st.ko until its rules are in, kept across a reboot: left
# behind, a crash on the way stops the wrapper trying it again at every boot
ST_TRYING = '/conf/dummynet-st.loading'
# there while dummynet_st.ko is in use, kept across a reboot, and removed by a clean
# shutdown (rc.syshook.d/stop/90-cake) or when the stock dummynet comes back. Its twin in
# /var/run, which a boot clears, tells this boot's marker from one an earlier boot left
# behind. Then the kernel's message buffer says how that boot ended: an orderly reboot
# (reboot(8) skips the shutdown scripts) is clean, a panic keeps the stock dummynet until
# the retry action ("Try dummynet-st again" on the CAKE page), and an end it does not
# explain (a power cut, a reset, a hang) does so only the ST_UNCLEAN_MAX'th time in a row
# (ST_UNCLEAN counts them; a clean shutdown or the retry action clears it). A machine that
# clears its memory at boot keeps no message buffer: there a crash dump saved at this
# boot (CRASH_DIR, with a swap device to dump to) still tells a panic, and a UFS root an
# orderly reboot (see previous_boot_end); with neither, the end is unexplained. ST_HELD
# keeps a verdict to stay out until the retry action, across boots, and ST_CHECKED holds
# this boot's.
ST_ACTIVE = '/conf/dummynet-st.active'
ST_ACTIVE_BOOT = '/var/run/dummynet-st.active'
ST_UNCLEAN = '/conf/dummynet-st.unclean'
ST_UNCLEAN_MAX = 2
ST_HELD = '/conf/dummynet-st.held'
# where savecore(8) puts a crash dump at boot (/usr/local/etc/rc.subr.d/crashdump)
CRASH_DIR = '/var/crash'
# the end of the reason a crash keeps dummynet-st out for
ST_RETRY = 'Try dummynet-st again on the CAKE page loads it again'
ST_CHECKED = '/var/run/dummynet-st.checked'
# net.inet.ip.dummynet.release_us when the setting is missing or invalid
RELEASE_DEFAULT = 250


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


def rules_on_cake_pipes():
    """ the enabled shaper rules that point at a pipe with CAKE itself, not at a queue on it:
    dummynet sends their traffic through the pipe's internal FIFO, so the pipe still limits
    the rate but CAKE never sees a packet, and its statistics stay empty
    :return: list of messages
    """
    root = ET.parse(CONFIG).getroot()
    numbers = dict()
    for pipe in root.findall('./OPNsense/TrafficShaper/pipes/pipe'):
        if int_value(pipe.findtext('number'), 1, 65535) is not None:
            numbers[pipe.get('uuid')] = str(int(pipe.findtext('number')))
    cake = set(item.findtext('pipe') for item in root.findall('./OPNsense/Cake/pipes/pipe')
               if item.findtext('enabled') == '1' and item.findtext('pipe') in numbers)
    result = []
    for rule in root.findall('./OPNsense/TrafficShaper/rules/rule'):
        if (rule.findtext('enabled') or '1') != '1' or rule.findtext('target') not in cake:
            continue
        name = rule.findtext('description') or 'with sequence %s' % (rule.findtext('sequence') or '?')
        result.append('shaper rule %s points at pipe %s itself, so its traffic goes through the '
                      "pipe's FIFO, not CAKE: point the rule at a queue on the pipe"
                      % (name, numbers[rule.findtext('target')]))
    return result


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


def short_version(text):
    """ a kernel version string without "FreeBSD" and the kernel's name: "15.1-RELEASE-p6
    stable/26.7-n284176-c962f76493b6", which names the release and the source it was built from
    :return: string, None for an empty one
    """
    parts = text.split()
    if parts and parts[0] == 'FreeBSD':
        parts = parts[1:]
    return ' '.join(parts[:2]) or None


def running_version():
    """ the running kernel, as short_version() """
    return short_version(os.uname().version)


def built_version(path):
    """ the kernel a package is built for, as short_version(), None when it does not say """
    try:
        with open(path) as f_in:
            return short_version(f_in.readline())
    except OSError:
        return None


def kernel_reason(package, version_file, fallback):
    """ why a package does not match this kernel, when the FreeBSD release does: it is
    built for another kernel's dummynet.ko, until a release built for this kernel """
    built = built_version(version_file)
    return 'this kernel (%s) is not the one %s is built for (%s): its dummynet.ko differs, so %s ' \
           'until %s is updated for it' % (running_version(), package, built or 'an earlier kernel',
                                           fallback, package)


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
        return 'mismatch', kernel_reason('cake-kmod', KMOD_KERNEL_VERSION, 'each pipe keeps its own scheduler')
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
        result['reason'] = 'cake-kmod is built for FreeBSD %s, this is %s: each pipe keeps its own ' \
                           'scheduler until a cake-kmod for this release is installed' % (
                               built_version(KMOD_KERNEL_VERSION) or result['kernel_built'],
                               result['kernel_running'])
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


def subtick_settings():
    """ whether to use dummynet-st, the longest a due packet waits for release, and for
    which pipes: 'cake' (while a CAKE entry is enabled) or 'all' (while the shaper has a
    pipe). On, for CAKE pipes, unless set otherwise, also with a config.xml from before
    the settings.
    :return: (bool, us, scope)
    """
    general = ET.parse(CONFIG).getroot().find('./OPNsense/Cake/general')
    if general is None:
        return True, RELEASE_DEFAULT, 'cake'
    release = int_value(general.findtext('release_us'), 10, 10000)
    scope = 'all' if general.findtext('subtick_scope') == 'all' else 'cake'
    return (general.findtext('subtick') or '1') == '1', release or RELEASE_DEFAULT, scope


def shaper_pipes(rules_file):
    """ whether the shaper rules define a pipe """
    try:
        with open(rules_file) as f_in:
            return any(len(parts) > 2 and parts[0] == 'pipe' and parts[2] == 'config'
                       for parts in (line.split() for line in f_in))
    except OSError:
        return False


def file_digest(path):
    """ SHA256 of a file, None if it cannot be read """
    try:
        with open(path, 'rb') as f_in:
            return hashlib.sha256(f_in.read()).hexdigest()
    except OSError:
        return None


def st_loaded():
    """ whether dummynet_st.ko is the loaded dummynet """
    return subprocess.run(['/sbin/kldstat', '-q', '-n', 'dummynet_st.ko']).returncode == 0


def st_status():
    """ whether dummynet-st is installed, built for the running kernel, and loaded. Like
    cake-kmod, it is built for one FreeBSD release and replaces one stock dummynet.ko,
    whose SHA256 it records; the stock file is checked on disk, as the fork may be the
    one loaded.
    :return: dict
    """
    result = {'installed': os.path.isfile(ST_KMOD), 'loaded': st_loaded(), 'reason': ''}
    running = os.uname().release.split('-')[0]
    if not result['installed']:
        result['reason'] = 'dummynet-st is not installed'
    else:
        try:
            with open(ST_KERNEL) as f_in:
                built = f_in.read().strip()
            with open(ST_DUMMYNET) as f_in:
                known = [line.strip() for line in f_in if line.strip()]
        except OSError:
            built, known = None, []
        if built != running:
            result['reason'] = 'dummynet-st is built for FreeBSD %s, this is %s: the stock dummynet is ' \
                               'used until a dummynet-st for this release is installed' % (
                                   built_version(ST_KERNEL_VERSION) or built, os.uname().release)
        elif file_digest(DUMMYNET) not in known:
            result['reason'] = kernel_reason('dummynet-st', ST_KERNEL_VERSION, 'the stock dummynet is used')
    # kept out after a crash, until the retry action
    result['held'] = False
    if result['reason'] == '' and os.path.exists(ST_TRYING) and not result['loaded']:
        result['reason'] = 'the system went down while dummynet-st was loading or its rules went in; ' + ST_RETRY
        result['held'] = True
    crashed = st_crashed()
    if result['reason'] == '' and crashed == 'panic' and not result['loaded']:
        result['reason'] = 'a boot ended in a panic while dummynet-st was in use; ' + ST_RETRY
        result['held'] = True
    elif result['reason'] == '' and crashed == 'unclean' and not result['loaded']:
        result['reason'] = '%d boots in a row ended without a clean shutdown while dummynet-st was in use ' \
                           '(power cuts, resets or hangs); %s' % (ST_UNCLEAN_MAX, ST_RETRY)
        result['held'] = True
    result['usable'] = result['reason'] == ''
    # an upgrade replaced the file since the wrapper loaded it
    result['current'] = None
    if result['loaded']:
        try:
            with open(ST_LOADED) as f_in:
                result['current'] = f_in.read().strip() == file_digest(ST_KMOD)
        except OSError:
            result['current'] = False
    return result


def load_dummynet(fork):
    """ make the forked dummynet_st.ko (fork) or the stock dummynet.ko the loaded dummynet,
    reloading a dummynet_st.ko an upgrade replaced. This removes every pipe, scheduler and
    queue, and dn_cake.ko; the caller loads the rules again. If dummynet_st.ko does not
    load, the stock dummynet is loaded instead.
    :return: whether the one asked for is loaded
    """
    loaded = st_loaded()
    if loaded == fork and (not fork or st_status()['current']):
        return True
    for what in ['pipe', 'sched', 'queue']:
        subprocess.run(['/sbin/ipfw', '-q', what, 'flush'], capture_output=True)
    subprocess.run(['/sbin/kldunload', '-n', 'dn_cake.ko'], capture_output=True)
    for name in ['dummynet_st.ko', 'dummynet.ko']:
        subprocess.run(['/sbin/kldunload', '-n', name], capture_output=True)
    if fork:
        st_trying(True)
    if fork and subprocess.run(['/sbin/kldload', ST_KMOD], capture_output=True).returncode == 0:
        try:
            with open(ST_LOADED + '.new', 'w') as f_out:
                f_out.write('%s\n' % file_digest(ST_KMOD))
            os.replace(ST_LOADED + '.new', ST_LOADED)
        except OSError:
            pass
        return True
    st_trying(False)
    if subprocess.run(['/sbin/kldstat', '-q', '-m', 'dummynet']).returncode != 0:
        subprocess.run(['/sbin/kldload', 'dummynet'], capture_output=True)
    return not fork and not st_loaded()


def sync_dir(path):
    """ write a directory's entries to disk: a marker made or removed just before a power
    cut or a reset is otherwise lost, or left behind """
    try:
        fd = os.open(path, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def st_trying(trying):
    """ mark dummynet_st.ko being loaded and set up (ST_TRYING), or done with """
    try:
        if trying:
            with open(ST_TRYING, 'w') as f_out:
                f_out.write('%d\n' % os.getpid())
                f_out.flush()
                os.fsync(f_out.fileno())
            sync_dir(os.path.dirname(ST_TRYING))
        elif os.path.exists(ST_TRYING):
            os.unlink(ST_TRYING)
            sync_dir(os.path.dirname(ST_TRYING))
    except OSError:
        pass


def st_active(active):
    """ mark dummynet_st.ko in use (ST_ACTIVE and its twin for this boot), or no longer """
    try:
        if active:
            if not os.path.exists(ST_ACTIVE_BOOT):
                with open(ST_ACTIVE_BOOT, 'w') as f_out:
                    f_out.write('%d\n' % os.getpid())
            if not os.path.exists(ST_ACTIVE):
                with open(ST_ACTIVE, 'w') as f_out:
                    f_out.write('%d\n' % os.getpid())
                    f_out.flush()
                    os.fsync(f_out.fileno())
                sync_dir(os.path.dirname(ST_ACTIVE))
        elif os.path.exists(ST_ACTIVE_BOOT):
            # this boot's only: one a crash left stays until the retry action
            for path in [ST_ACTIVE, ST_ACTIVE_BOOT]:
                if os.path.exists(path):
                    os.unlink(path)
            sync_dir(os.path.dirname(ST_ACTIVE))
    except OSError:
        pass


def kernel_line(text, line):
    """ whether the kernel printed a line starting with line, after the uptime
    kern.msgbuf_show_timestamp puts first; a "<priority>" starts log(9)'s lines and what
    userland writes to the console """
    return re.search(r'^(\[[0-9.]+\] )?' + re.escape(line), text, re.M) is not None


def previous_boot_end():
    """ how the boot before this one ended, from the kernel's message buffer. A warm reboot
    keeps it: every reboot logs its uptime, a panic its message first. Where it is lost (a
    machine that clears its memory at boot), a UFS root still tells, in this boot's
    messages: an orderly reboot or shutdown unmounts it clean (OPNsense checks it at every
    boot, so it is clean again after one that did not)
    :return: 'panic', 'reboot', or None when neither tells (a power cut, a reset or a
             panic without the buffer, a ZFS root, or this boot's messages overwrote it)
    """
    out = subprocess.run(['/sbin/sysctl', '-n', 'kern.msgbuf'], capture_output=True, text=True,
                         errors='replace')
    boots = out.stdout.split('---<<BOOT>>---') if out.returncode == 0 else []
    if len(boots) < 2:
        return None
    if kernel_line(boots[-2], 'panic: '):
        return 'panic'
    if kernel_line(boots[-2], 'Uptime: '):
        return 'reboot'
    if kernel_line(boots[-1], 'Trying to mount root from ufs:') and \
            not kernel_line(boots[-1], 'WARNING: / was not properly dismounted'):
        return 'reboot'
    return None


def crash_saved_since(path):
    """ whether savecore(8) saved a crash dump after the file at path was last written:
    the boot that wrote it then ended in a panic, as dumps are saved at the next boot """
    try:
        since = os.stat(path).st_mtime
        return any(os.stat(info).st_mtime >= since
                   for info in glob.glob(os.path.join(CRASH_DIR, 'info.[0-9]*')))
    except OSError:
        return False


def read_count(path):
    """ a count kept in a file, 0 when there is none """
    try:
        with open(path) as f_in:
            return int(f_in.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def write_file(path, text):
    """ a small marker file, on disk at once (see sync_dir) """
    with open(path, 'w') as f_out:
        f_out.write(text)
        f_out.flush()
        os.fsync(f_out.fileno())
    sync_dir(os.path.dirname(path))


def remove_file(path):
    """ remove a marker file, on disk at once """
    if os.path.exists(path):
        os.unlink(path)
        sync_dir(os.path.dirname(path))


def st_crashed():
    """ whether dummynet_st.ko is to stay out after how the last boot ended while it was in
    use, decided once a boot (this boot's messages may overwrite the last one's)
    :return: 'panic' or 'unclean' when it is to stay out until the retry action, else None
    """
    try:
        with open(ST_CHECKED) as f_in:
            return f_in.read().strip() or None
    except OSError:
        pass
    verdict = ''
    try:
        if os.path.exists(ST_HELD):
            # decided at an earlier boot: until the retry action, whatever this one follows
            with open(ST_HELD) as f_in:
                verdict = f_in.read().strip() or 'unclean'
            with open(ST_CHECKED, 'w') as f_out:
                f_out.write(verdict + '\n')
            return verdict
        end = previous_boot_end()
        active = os.path.exists(ST_ACTIVE) and not os.path.exists(ST_ACTIVE_BOOT)
        if active and end != 'panic' and crash_saved_since(ST_ACTIVE):
            # a dump of a panic the message buffer did not keep
            end = 'panic'
        if end == 'reboot':
            remove_file(ST_UNCLEAN)
        if active:
            if end == 'panic':
                verdict = 'panic'
            elif end is None:
                count = read_count(ST_UNCLEAN) + 1
                write_file(ST_UNCLEAN, '%d\n' % count)
                if count >= ST_UNCLEAN_MAX:
                    verdict = 'unclean'
            if verdict == '':
                # this time it may load again, and mark itself in use for this boot
                remove_file(ST_ACTIVE)
            else:
                write_file(ST_HELD, verdict + '\n')
        with open(ST_CHECKED, 'w') as f_out:
            f_out.write(verdict + '\n')
    except OSError:
        pass
    return verdict or None

def set_release(release_us):
    """ net.inet.ip.dummynet.release_us of the loaded dummynet_st.ko """
    subprocess.run(['/sbin/sysctl', '-q', 'net.inet.ip.dummynet.release_us=%d' % release_us],
                   capture_output=True)


# OPNsense's own rules in the ipfw ruleset it generates (templates/OPNsense/IPFW/ipfw.conf),
# none of which changes what happens to a forwarded packet on output
IPFW_FIXED = {tuple(line.split()) for line in (
    'add 100 allow pfsync from any to any',
    'add 110 allow carp from any to any',
    'add 120 pass layer2 mac-type arp,rarp',
    'add 130 pass layer2 mac-type 0x888e,0x88c7',
    'add 140 pass layer2 mac-type 0x8863,0x8864',
    'add 150 deny layer2 not mac-type ip,ipv6',
    'add 200 skipto 60000 ipv6 from ::1 to any',
    'add 201 skipto 60000 ipv4 from 127.0.0.0/8 to any',
    'add 202 skipto 60000 ipv6 from any to ::1',
    'add 203 skipto 60000 ipv4 from any to 127.0.0.0/8',
    'add 60000 return via any',
    'add 65533 pass ip from any to any',
    'add 65534 deny all from any to any',
)}


def keep_tag_wanted():
    """ whether "Skip ipfw on output for traffic shaped inbound" is ticked (CAKE page) """
    general = ET.parse(CONFIG).getroot().find('./OPNsense/Cake/general')
    return general is not None and general.findtext('keep_tag') == '1'


def keep_tag_blockers(path=IPFW_RULES):
    """ why released "in" packets may not skip ipfw on output: a rule in the generated ruleset
    that acts on output (a shaper rule "out", for both directions or on two interfaces, or
    any rule but OPNsense's own and single-interface "in" shaper rules), or a captive portal
    zone, whose accounting counts traffic on output. With none, ipfw would pass such a packet
    on output anyway, and dummynet-st (patch 0010) can let it keep ipfw's one-pass tag so that
    ipfw passes it at once.
    :return: list of messages, empty when it may
    """
    result = []
    try:
        with open(path) as f_in:
            lines = f_in.readlines()
    except OSError:
        return ['the ipfw ruleset (%s) cannot be read' % path]
    for line in lines:
        rule, _, comment = line.partition('//')
        words = rule.split()
        if not words or words[0].startswith('#') or words == ['flush'] or tuple(words) in IPFW_FIXED:
            continue
        number = words[1] if len(words) > 1 else '?'
        if (words[0] == 'add' and number.isdigit() and 60000 < int(number) < 65533
                and len(words) > 3 and words[2] in ('pipe', 'queue')):
            if 'in' in words and 'via' in words and not {'out', 'xmit', 'recv'} & set(words):
                continue
            # the description follows the rule's uuid and interfaces: "uuid lan: name"
            name = comment.split(':', 1)[1].strip() if ':' in comment else 'number %s' % number
            result.append('shaper rule %s also acts on output (direction out or both, or two '
                          'interfaces)' % name)
        else:
            result.append('ipfw rule %s is neither OPNsense\'s own nor an "in" shaper rule' % number)
    if ET.parse(CONFIG).getroot().find('./OPNsense/captiveportal/zones/zone') is not None:
        result.append('captive portal has a zone, and its accounting counts traffic on output')
    return result


def set_keep_tag(on):
    """ net.inet.ip.dummynet.release_keep_tag of the loaded dummynet_st.ko (absent before
    dummynet-st 1.0.11: then nothing happens) """
    subprocess.run(['/sbin/sysctl', '-q', 'net.inet.ip.dummynet.release_keep_tag=%d' % bool(on)],
                   capture_output=True)
