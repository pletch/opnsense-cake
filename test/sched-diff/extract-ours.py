#!/usr/bin/env python3
# dn_sched_cake.c -> ours-cake.inc: the scheduling core, without the
# sysctls, instance list, statistics and module glue; cake_hash_flow() is
# replaced by ours_shim.h's, unless --hash (test/fuzz.sh) keeps it. Its
# input has the build conditionals resolved (upstream/resolve.sh).
import re
import sys

keep_hash = sys.argv[1] == '--hash'
lines = open(sys.argv[-1]).read().split('\n')


def find(*pats, start=0):
    """the first line from start matching the first pattern that matches"""
    for pat in pats:
        for i in range(start, len(lines)):
            if re.search(pat, lines[i]):
                return i
    sys.exit('extract-ours: no match for %r' % (pats,))


out = []
# tables and declarations, up to the sysctl handlers
a = find(r'^#define CAKE_MTU')
# (the upstream build has no handlers: up to its sysctl node)
b = find(r'^cake_sysctl_interval_handler',
         r'^SYSBEGIN') - 1
out += lines[a:b]
# COBALT up to the CAKE_DEBUG checker
a = find(r'^ \* COBALT: CoDel and BLUE') - 1
b = find(r'^#ifdef CAKE_DEBUG', start=a)
part = '\n'.join(lines[a:b])
if not keep_hash:
    part = part.replace('\ncake_hash_flow(struct mbuf *m',
                        '\n__attribute__((unused)) cake_hash_flow_kernel(struct mbuf *m')
out += part.split('\n')
# the checker (or its no-op macros), enqueue, dequeue, tables, reconfig
a = b
b = find(r'^ \* Every CAKE instance and kept state',
         r'^ \* Initialize cake scheduler instance') - 1
out += lines[a:b]
print('\n'.join(out))
