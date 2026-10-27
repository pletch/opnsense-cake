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

    sign-server.py key.pem release-directory [port]

The release directory holds the release's packages and its SHA256SUMS
(gh release download vX.Y.Z), checked against each other first. The
server then signs only a catalogue of exactly those packages: each request
carries the catalogue file pkg is signing (packagesite.yaml or data) with
its SHA256, and is refused unless the file has that SHA256 and lists the
release's packages, no more and no fewer, with the checksums and sizes of
the files here. Each of the two files is signed once; the server exits
when both are, or after ten minutes.

Listens on 127.0.0.1 only: reach it with ssh -R port:127.0.0.1:port, or
from a QEMU guest with user networking at 10.0.2.2.
"""
import base64
import hashlib
import json
import os
import socket
import subprocess
import sys
import time

# pkg's checksum of a package file, as its catalogue lists it ("2$": BLAKE2b
# over the file, in pkg's base32, libpkg/pkg_checksum.c)
B32 = 'ybndrfg8ejkmcpqxot1uwisza345h769'


def pkg_sum(data):
    out = []
    remain = -1
    for i, c in enumerate(hashlib.blake2b(data).digest()):
        if i % 5 == 0:
            out.append(B32[c & 0x1f])
            remain = c >> 5
        elif i % 5 == 1:
            x = remain | c << 3
            out += [B32[x & 0x1f], B32[x >> 5 & 0x1f]]
            remain = x >> 10
        elif i % 5 == 2:
            x = remain | c << 1
            out.append(B32[x & 0x1f])
            remain = x >> 5
        elif i % 5 == 3:
            x = remain | c << 4
            out += [B32[x & 0x1f], B32[x >> 5 & 0x1f]]
            remain = x >> 10 & 0x3
        else:
            x = remain | c << 2
            out += [B32[x & 0x1f], B32[x >> 5 & 0x1f]]
            remain = -1
    if remain >= 0:
        out.append(B32[remain])
    return '2$' + ''.join(out)


def release(directory):
    """ {(path in the repository, pkg checksum, size)} of the release's packages """
    result = set()
    with open(os.path.join(directory, 'SHA256SUMS')) as f_in:
        for line in f_in:
            digest, name = line.split()
            if '/' in name or not name.endswith('.pkg'):
                sys.exit('SHA256SUMS: unexpected entry %s' % name)
            with open(os.path.join(directory, name), 'rb') as f_pkg:
                data = f_pkg.read()
            if hashlib.sha256(data).hexdigest() != digest:
                sys.exit('%s does not have the SHA256 in SHA256SUMS' % name)
            result.add(('All/' + name, pkg_sum(data), len(data)))
    if not result:
        sys.exit('SHA256SUMS lists no packages')
    return result


def listed(name, data):
    """ {(path in the repository, pkg checksum, size)} of the packages a catalogue file lists """
    if name == 'packagesite.yaml':
        packages = [json.loads(line) for line in data.decode().split('\n') if line.strip()]
    else:
        packages = json.loads(data)['packages']
    return {(p['repopath'], p['sum'], int(p['pkgsize'])) for p in packages}


def check(header, data, expected, signed):
    """ the reason to refuse a request, or None """
    try:
        digest, name, size = header.split()
    except ValueError:
        return 'malformed request'
    if name not in ('packagesite.yaml', 'data'):
        return 'not a catalogue file: %s' % name[:40]
    if name in signed:
        return '%s is signed already' % name
    if not size.isdigit() or int(size) != len(data):
        return 'truncated %s' % name
    if hashlib.sha256(data).hexdigest() != digest:
        return '%s does not have the SHA256 %s' % (name, digest[:64])
    try:
        found = listed(name, data)
    except (ValueError, KeyError, TypeError, AttributeError):
        return '%s cannot be parsed' % name
    if found != expected:
        return '%s lists other packages than the release: %s' % (
            name, ', '.join(sorted({x[0] for x in found ^ expected})))
    return None


def main():
    key, directory = sys.argv[1], sys.argv[2]
    port = int(sys.argv[3]) if len(sys.argv) > 3 else 8471
    expected = release(directory)
    for path, _, size in sorted(expected):
        print('release package', path, size, 'bytes', flush=True)

    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('127.0.0.1', port))
    s.listen(4)
    s.settimeout(1)
    print('listening on 127.0.0.1:%d' % port, flush=True)
    signed = set()
    end = time.time() + 600
    while len(signed) < 2 and time.time() < end:
        try:
            c, _ = s.accept()
        except socket.timeout:
            continue
        with c:
            c.settimeout(10)
            buf, header, data = b'', '', b''
            try:
                while b'\n' not in buf and len(buf) < 256:
                    b = c.recv(256)
                    if not b:
                        break
                    buf += b
                header, _, data = buf.partition(b'\n')
                header = header.decode('ascii', 'replace')
                size = header.split()[2] if len(header.split()) == 3 else ''
                want = int(size) if size.isdigit() and int(size) <= 16 << 20 else 0
                while len(data) < want:
                    b = c.recv(65536)
                    if not b:
                        break
                    data += b
            except socket.timeout:
                pass
            reason = check(header, data, expected, signed)
            if reason:
                print('refused:', reason, flush=True)
                continue
            digest, name, _ = header.split()
            sig = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', key],
                                 input=digest.encode(), capture_output=True, check=True).stdout
            c.sendall(base64.b64encode(sig) + b'\n')
            signed.add(name)
            print('signed', name, digest, flush=True)


if __name__ == '__main__':
    main()
