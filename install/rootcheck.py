#!/usr/bin/env python3
"""rootcheck.py (path P | tree D)... --- for install/render.sh --top-user: can anyone but root change what a root-run
wrapper executes or reads? Exit 0 = everything named is root-only, 1 = refused (the reason on stdout), 2 = usage.

  path P   P as written: every directory its resolution passes through (symlinks expanded one hop at a time, so the
           directory holding each link counts, at every hop) and the final target
  tree D   path D, then everything under it; a symlink inside: its path, and the tree of the directory it leads to,
           or for a link to a file, of the directory that file is in (Python takes a script's directory from its real
           path: its sibling modules and __pycache__ are loaded from there). Each real directory is walked once, so
           links that loop are walked once

root-only = owned by root, not writable by group / others, and no ACL that grants write: access ACL (named user /
group, or the owning group behind a mask), default ACL of a directory (any entry but the owner's and the mask: they
decide what files created there later get). ACLs are read from the system.posix_acl_* attributes; ENODATA = none,
ENOTSUP = the filesystem has none, any other error refuses. A symlink's own owner does not matter (nobody can change
a link in place; replacing it needs write access to its directory, which is checked)."""
import errno
import os
import stat
import struct
import sys

USER_OBJ, USER, GROUP_OBJ, GROUP, MASK, OTHER = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20
MAX_HOPS = 40


class Refused(Exception):
    pass


def acl(p, name):
    try:
        raw = os.getxattr(p, name, follow_symlinks=False)
    except OSError as e:
        if e.errno in (errno.ENODATA, errno.ENOTSUP):
            return []
        raise Refused(f'{p}: cannot read its ACL ({e.strerror})')
    if len(raw) < 4 or (len(raw) - 4) % 8 or struct.unpack('<I', raw[:4])[0] != 2:
        raise Refused(f'{p}: unreadable ACL attribute {name}')
    return [struct.unpack('<HHI', raw[i:i + 8])[:2] for i in range(4, len(raw), 8)]


class Check:
    def __init__(self):
        self.ok = set()          # real paths already found root-only
        self.walked = set()      # real directories whose tree was walked

    def one(self, p):
        if p in self.ok:
            return
        try:
            st = os.lstat(p)
        except OSError as e:
            raise Refused(f'{p}: cannot stat ({e.strerror})')
        if not stat.S_ISLNK(st.st_mode):
            if st.st_uid != 0:
                raise Refused(f'{p} is not owned by root')
            if st.st_mode & 0o022:
                raise Refused(f'{p} is writable by group or others')
            if any(t in (USER, GROUP, GROUP_OBJ) and perm & 2 for t, perm in acl(p, 'system.posix_acl_access')):
                raise Refused(f'{p}: an ACL entry grants write access')
            if stat.S_ISDIR(st.st_mode) and any(t not in (USER_OBJ, MASK) and perm & 2
                                                for t, perm in acl(p, 'system.posix_acl_default')):
                raise Refused(f'{p}: a default ACL entry grants write access (to what is created there later)')
        self.ok.add(p)

    def path(self, path):
        """root-only resolution of `path`; returns the real path"""
        if not path.startswith('/'):
            raise Refused(f'{path}: not an absolute path')
        parts, cur, hops = [c for c in path.split('/') if c not in ('', '.')], '/', 0
        self.one('/')
        while parts:
            c = parts.pop(0)
            if c == '..':
                cur = os.path.dirname(cur)
                continue
            nxt = os.path.join(cur, c)
            self.one(nxt)                # a link: only stat-able; the directory holding it (cur) is checked already
            if os.path.islink(nxt):
                hops += 1
                if hops > MAX_HOPS:
                    raise Refused(f'{path}: more than {MAX_HOPS} symlinks (a loop?)')
                t = os.readlink(nxt)
                parts = [x for x in t.split('/') if x not in ('', '.')] + parts
                if t.startswith('/'):
                    cur = '/'
                continue
            if parts and not os.path.isdir(nxt):
                raise Refused(f'{nxt}: not a directory')
            cur = nxt
        return cur

    def tree(self, d):
        real = self.path(d)
        if not os.path.isdir(real):
            raise Refused(f'{d}: not a directory')
        if real in self.walked:
            return
        self.walked.add(real)

        def err(e):
            raise Refused(f'{e.filename}: cannot read ({e.strerror})')
        for top, dirs, files in os.walk(real, onerror=err):
            for n in dirs + files:
                p = os.path.join(top, n)
                if os.path.islink(p):
                    r = self.path(p)
                    self.tree(r if os.path.isdir(r) else os.path.dirname(r))
                else:
                    self.one(p)


def main(a):
    if not a or len(a) % 2 or any(k not in ('path', 'tree') for k in a[::2]):
        print(__doc__.split('\n')[0])
        return 2
    c = Check()
    try:
        for k, p in zip(a[::2], a[1::2]):
            c.path(p) if k == 'path' else c.tree(p)
    except Refused as e:
        print(e)
        return 1
    print(f'root-only: {len(c.ok)} paths checked')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
