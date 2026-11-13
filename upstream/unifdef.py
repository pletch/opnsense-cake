#!/usr/bin/env python3
# Resolve the preprocessor conditionals on the given symbols, as unifdef(1)
# does, leaving every other line and conditional as it is:
#
#   unifdef.py -DSYM ... -USYM ... file
#
# Only "#ifdef SYM", "#ifndef SYM", "#else" and "#endif" are understood for
# the symbols named; a conditional on any other symbol is copied through
# with its own #else and #endif.
import re
import sys

defined, undefined, path = set(), set(), None
for a in sys.argv[1:]:
    if a.startswith('-D'):
        defined.add(a[2:])
    elif a.startswith('-U'):
        undefined.add(a[2:])
    else:
        path = a
if path is None:
    sys.exit(__doc__ or 'usage: unifdef.py -DSYM -USYM file')

out = []
stack = []      # None: a conditional copied through; else whether it is kept
for n, line in enumerate(open(path).read().split('\n'), 1):
    keep = all(s is not False for s in stack)
    m = re.match(r'\s*#\s*(ifdef|ifndef)\s+(\w+)\s*(/\*.*\*/)?\s*$', line)
    if m:
        sym = m.group(2)
        if sym in defined or sym in undefined:
            stack.append((sym in defined) == (m.group(1) == 'ifdef'))
        else:
            stack.append(None)
            if keep:
                out.append(line)
        continue
    if re.match(r'\s*#\s*if\b', line):
        stack.append(None)
        if keep:
            out.append(line)
        continue
    if re.match(r'\s*#\s*else\b', line):
        if not stack:
            sys.exit('%s:%d: #else without #if' % (path, n))
        if stack[-1] is None:
            if keep:
                out.append(line)
        else:
            stack[-1] = not stack[-1]
        continue
    if re.match(r'\s*#\s*elif\b', line):
        if not stack or stack[-1] is not None:
            sys.exit('%s:%d: #elif on a resolved symbol' % (path, n))
        if keep:
            out.append(line)
        continue
    if re.match(r'\s*#\s*endif\b', line):
        if not stack:
            sys.exit('%s:%d: #endif without #if' % (path, n))
        if stack.pop() is None and all(s is not False for s in stack):
            out.append(line)
        continue
    if keep:
        out.append(line)
if stack:
    sys.exit('%s: unterminated conditional' % path)
sys.stdout.write('\n'.join(out))
