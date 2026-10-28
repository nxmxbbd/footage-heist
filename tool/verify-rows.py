#!/usr/bin/env python3
"""verify-rows.py <rows.pre> <rows.post> <ledger.jsonl> <slug>.list <slug>.gone <successors.out>

Step (1) of verify-staged.sh: one camera's source recordingFiles rows (rows.sql) before the copy vs after it.

Explained, and not a failure:
- a row that disappeared (Protect deletes the oldest recordings) whose file was copied before that, or that is in
  <slug>.gone (deleted before it could be copied), or that is outside <slug>.list (e.g. a filtered list);
- the successor update that comes with such a deletion (MECHANISM.md 5): the row of the same type and channel whose
  `start` is now exactly the deleted row's `end` (the same value or later than before), every other column but
  `updatedAt` unchanged. Its file is not rewritten; to prove that, each successor that is in the list and was copied is
  written to <successors.out> (id|folder/file|ledger sha256) and verify-staged.sh re-reads it on the source.

Anything else --- a row added, any other change, a disappearance the copy cannot explain --- is a FAIL (exit 1).
"""
import json
import os
import sys

# rows.sql column order
ID, FOLDER, FILE, SIZE, TYPE, CHANNEL, START, END = range(8)
UPDATED = 12
NCOLS = 13


def rows(path):
    out = {}
    for l in open(path):
        l = l.rstrip('\n')
        if not l.strip():
            continue
        c = l.split('|')
        if len(c) != NCOLS:
            sys.exit(f'FAIL: {path}: a row with {len(c)} columns, expected {NCOLS}: {l[:200]}')
        if c[ID] in out:
            sys.exit(f'FAIL: {path}: row id {c[ID]} twice')
        out[c[ID]] = c
    return out


def as_int(v):
    try:
        return int(v)
    except ValueError:
        return None


def successor_of(old, new, removed_rows, used):
    """The deleted row this change is the successor update of, or None. A deleted row explains one successor only."""
    for k in range(NCOLS):
        if k not in (START, UPDATED) and old[k] != new[k]:
            return None
    s0, s1, end = as_int(old[START]), as_int(new[START]), as_int(new[END])
    if None in (s0, s1, end) or s1 < s0 or s1 > end:
        return None
    for r in removed_rows:
        if r[ID] not in used and r[TYPE] == new[TYPE] and r[CHANNEL] == new[CHANNEL] and as_int(r[END]) == s1:
            used.add(r[ID])
            return r
    return None


def main():
    pre_f, post_f, led_f, list_f, gone_f, succ_f = sys.argv[1:]
    pre, post = rows(pre_f), rows(post_f)
    open(succ_f, 'w').close()
    added = [i for i in post if i not in pre]
    removed = [i for i in pre if i not in post]
    changed = [i for i in post if i in pre and post[i] != pre[i]]
    if not added and not removed and not changed:
        print(f'rows: unchanged ({len(post)})')
        return 0
    ok = {}
    for l in open(led_f):
        r = json.loads(l)
        if r['result'] == 'ok' and r['remote'] == 'OK %d %s' % (r['size'], r['sha256']):
            ok[r['id']] = r['sha256']
    listed = {l.split('|')[0] for l in open(list_f) if l.strip()}
    gone = {l.split('|')[0] for l in open(gone_f) if l.strip()} if os.path.exists(gone_f) else set()
    copied = [i for i in removed if i in ok]
    lost = [i for i in removed if i not in ok and i in gone]
    outside = [i for i in removed if i not in ok and i not in gone and i not in listed]
    bad = [i for i in removed if i not in ok and i not in gone and i in listed]
    removed_rows = [pre[i] for i in removed]
    succ, other, used = [], [], set()
    for i in sorted(changed, key=lambda i: (post[i][TYPE], post[i][CHANNEL], as_int(post[i][START]) or 0, i)):
        p = successor_of(pre[i], post[i], removed_rows, used)
        (succ if p else other).append((i, p))
    to_reread = [i for i, _ in succ if i in listed and i in ok]
    print(f'rows: CHANGED --- pre {len(pre)}, post {len(post)}; added {len(added)}; '
          f'changed {len(changed)} (successor of a deleted file {len(succ)}, other {len(other)}); '
          f'disappeared {len(removed)} (copied before deletion {len(copied)}, in .gone {len(lost)}, '
          f'outside this list {len(outside)}, unexplained {len(bad)})')
    for i, p in succ:
        n = post[i]
        where = ('copied, source re-read follows' if i in to_reread
                 else 'not copied (outside this list)' if i not in listed else 'not in the ledger')
        print(f'  INFO successor of a deleted file: {n[FILE]} start {pre[i][START]} -> {n[START]} = end of deleted '
              f'{p[FILE]}; {where}')
    for i in added[:5]:
        print('  added:', '|'.join(post[i])[:200])
    for i, _ in other[:5]:
        print('  changed, before:', '|'.join(pre[i])[:200])
        print('  changed, after: ', '|'.join(post[i])[:200])
    for i in bad[:5]:
        print('  unexplained disappearance:', i)
    with open(succ_f, 'w') as f:
        for i in to_reread:
            f.write(f'{i}|{post[i][FOLDER]}/{post[i][FILE]}|{ok[i]}\n')
    if added or other or bad:
        print('FAIL: source rows changed in a way the copy cannot account for')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
