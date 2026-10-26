#!/usr/bin/env python3

# Copyright (c) 2026 Tim Pletcher
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
# AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
# OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

"""Sign the package repository's catalogue for sign.sh on another machine,
so the key stays where it is: pkg repo runs on FreeBSD or OPNsense, the
key is on the maintainer's machine.

    sign-server.py key.pem [port] [count]

Listens on 127.0.0.1 only (reach it with ssh -R port:127.0.0.1:port, or
from a QEMU guest with user networking at 10.0.2.2), reads one SHA256 per
connection, replies with its base64 signature, and exits after count
signatures (2: a catalogue has packagesite and data) or ten minutes.
"""
import base64
import re
import socket
import subprocess
import sys
import time

key = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8471
count = int(sys.argv[3]) if len(sys.argv) > 3 else 2

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(4)
s.settimeout(1)
print("listening on 127.0.0.1:%d for %d signatures" % (port, count), flush=True)
end = time.time() + 600
while count > 0 and time.time() < end:
    try:
        c, _ = s.accept()
    except socket.timeout:
        continue
    with c:
        c.settimeout(10)
        line = b""
        try:
            while b"\n" not in line and len(line) < 128:
                b = c.recv(128)
                if not b:
                    break
                line += b
        except socket.timeout:
            pass
        line = line.strip()
        if not re.fullmatch(rb"[0-9a-f]{64}", line):
            print("refused", line[:80], flush=True)
            continue
        sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key],
                             input=line, capture_output=True, check=True).stdout
        c.sendall(base64.b64encode(sig) + b"\n")
        count -= 1
        print("signed", line.decode(), flush=True)
