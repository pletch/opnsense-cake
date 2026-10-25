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
    CAKE kernel module status and the active CAKE schedulers, for the GUI.
"""
import json
import subprocess
from lib import kmod_status, DNCTL

if __name__ == '__main__':
    result = kmod_status()
    result['status'] = 'ok'
    result['schedulers'] = []
    if result['loaded']:
        sched = None
        for line in subprocess.run([DNCTL, 'sched', 'show'], capture_output=True, text=True).stdout.split('\n'):
            parts = line.split()
            if len(parts) > 3 and parts[0] == 'sched' and parts[2] == 'type':
                sched = parts[1] if parts[3] == 'CAKE' else None
            elif sched is not None and parts and parts[0] == 'CAKE':
                result['schedulers'].append({'sched': sched, 'config': line.strip()})
                sched = None
    print(json.dumps(result))
