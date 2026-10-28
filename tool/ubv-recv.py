#!/usr/bin/env python3
# ubv-recv.py --- forced-command receiver for source -> target recording-file pushes into the import staging; runs ON
# THE TARGET console, bound to ONE restricted key in root's authorized_keys:
#   command="python3 <dir>/ubv-recv.py --base <TARGET_STAGING>",restrict ssh-ed25519 AAAA... <comment>
# --base is required and must be an existing directory (files land in <base>/files, its log in <base>/state/recv.log;
# both are created on first use); without it, or when it does not exist (a mistyped path must not quietly grow a tree
# somewhere else), every command is refused. RECV_BASE (environment) replaces --base for local tests only: sshd does
# not pass it through.
# Accepted commands (SSH_ORIGINAL_COMMAND), everything else is rejected and logged:
#   put <srv|ssd1> <YYYY/MM/DD>/<MAC>_<ch>_<type>_<ms>.ubv <size>   (stdin = file bytes)
#   tput <srv|ssd1> <YYYY/MM/DD>/<name> <size>   (data over plain TCP, ssh = control channel only: prints
#        'LISTEN <ip> <port> <token>', accepts ONE connection from the ssh client's own IP that starts with the
#        16-byte token, then the file bytes; answers like put. No transport encryption: trusted LAN only;
#        integrity = sha256 on both ends.)
#   verify <srv|ssd1> <YYYY/MM/DD>/<name>                            (re-read from disk, sha256)
#   ping
import ctypes
import fcntl
import hashlib
import hmac
import json
import os
import queue
import re
import socket
import sys
import threading
import time

def _base():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == '--base' and a[1].startswith('/'):
        return a[1].rstrip('/')
    if not a and os.environ.get('RECV_BASE', '').startswith('/'):
        return os.environ['RECV_BASE'].rstrip('/')
    return None


BASE = _base()
FILES = (BASE or '') + '/files'
LOG = (BASE or '') + '/state/recv.log'
NAME = r'[0-9A-F]{12}_[0-9]_(?:rotating|thumbnails|timelapse)_[0-9]{13}\.ubv'
DAY = r'[0-9]{4}/[0-9]{2}/[0-9]{2}'
PUT = re.compile(r'put (srv|ssd1) (' + DAY + r')/(' + NAME + r') ([0-9]{1,12})')
TPUT = re.compile(r'tput (srv|ssd1) (' + DAY + r')/(' + NAME + r') ([0-9]{1,12})')
VERIFY = re.compile(r'verify (srv|ssd1) (' + DAY + r')/(' + NAME + r')')
CHUNK = 4 << 20
ACCEPT_TIMEOUT = int(os.environ.get('RECV_ACCEPT_TIMEOUT', '30'))   # tput: wait for the data connection (env = tests)
IO_TIMEOUT = 60         # tput: a stalled data connection fails the put


def log(**kw):
    kw['ts'] = time.strftime('%Y-%m-%dT%H:%M:%S%z')
    os.makedirs(os.path.dirname(LOG), mode=0o700, exist_ok=True)   # a fresh staging dir has no state/ yet
    with open(LOG, 'a') as f:
        f.write(json.dumps(kw) + '\n')
        f.flush()
        os.fsync(f.fileno())


def grow_pipe(fd, size=1 << 20):
    # F_SETPIPE_SZ (1031): a 1 MiB pipe instead of 64 KiB (capped by /proc/sys/fs/pipe-max-size); no-op on non-pipes
    try:
        fcntl.fcntl(fd, 1031, size)
    except OSError:
        pass


try:                                   # sync_file_range(2): start / wait for writeback of one file range
    _libc = ctypes.CDLL(None, use_errno=True)
    _sfr = _libc.sync_file_range
    _sfr.argtypes = [ctypes.c_int, ctypes.c_longlong, ctypes.c_longlong, ctypes.c_uint]
except (OSError, AttributeError):
    _sfr = None
SFR_WAIT_BEFORE, SFR_WRITE, SFR_WAIT_AFTER = 1, 2, 4
WINDOW = 32 << 20


def flush_behind(fd, cur, prev):
    # Keep the page cache out of a multi-GB staging copy (it drives kswapd hard and evicts Protect's cache):
    # start writeback of the window just written, wait for the previous window and drop it. Best effort.
    try:
        if _sfr is not None:
            _sfr(fd, cur[0], cur[1], SFR_WRITE)
            if prev is not None:
                _sfr(fd, prev[0], prev[1], SFR_WAIT_BEFORE | SFR_WRITE | SFR_WAIT_AFTER)
        if prev is not None:
            os.posix_fadvise(fd, prev[0], prev[1], os.POSIX_FADV_DONTNEED)
    except OSError:
        pass


def fsync_dir(d):
    fd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def target(root, day, name):
    d = os.path.join(FILES, root, day)
    return f'{root}/{day}/{name}', d, os.path.join(d, name)


def put(root, day, name, size):
    rel, d, dst = target(root, day, name)
    if os.path.lexists(dst):
        log(op='put', rel=rel, result='exists')
        print('EXISTS')
        return 3
    grow_pipe(0)
    return receive(sys.stdin.buffer, rel, d, dst, size, 'put')


def receive(src, rel, d, dst, size, op):
    # src: binary stream with read(n) (stdin, or a socket file); answers OK / SIZE / WERR / RERR on stdout
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = dst + '.part'
    h = hashlib.sha256()
    n = 0
    # Pipelined (v2, 10G): this thread reads stdin while one thread writes and one hashes (hashlib and file writes
    # release the GIL on large buffers). A single-threaded read -> write -> hash loop left sshd blocked on a full
    # 64 KiB pipe most of the time (~100 MB/s with neither sshd nor python using a full core).
    wq, hq = queue.Queue(maxsize=8), queue.Queue(maxsize=8)
    werr, rerr = [], []

    def writer(f):
        fd, off, mark, prev = f.fileno(), 0, 0, None
        while True:
            b = wq.get()
            if b is None:
                return
            if not werr:
                try:
                    mv = memoryview(b)
                    while mv:                  # unbuffered FileIO: write until the whole chunk is on the fd
                        k = f.write(mv)
                        mv = mv[k:]
                    off += len(b)
                    if off - mark >= WINDOW:
                        flush_behind(fd, (mark, off - mark), prev)
                        prev, mark = (mark, off - mark), off
                except OSError as e:          # keep draining so the reader never blocks on a full queue
                    werr.append(str(e))

    def hasher():
        while True:
            b = hq.get()
            if b is None:
                return
            h.update(b)

    with open(tmp, 'wb', buffering=0) as f:
        tw = threading.Thread(target=writer, args=(f,))
        th = threading.Thread(target=hasher)
        tw.start()
        th.start()
        try:
            while True:
                b = src.read(CHUNK)
                if not b:
                    break
                wq.put(b)
                hq.put(b)
                n += len(b)
                if n > size:
                    break
        except OSError as e:                  # e.g. a stalled / reset data connection (tput)
            rerr.append(str(e) or type(e).__name__)
        finally:                              # the writer / hasher threads must always get their end marker
            wq.put(None)
            hq.put(None)
        tw.join()
        th.join()
        if not werr:
            try:
                f.flush()
                os.fsync(f.fileno())
            except OSError as e:
                werr.append(str(e))
            else:
                try:
                    os.posix_fadvise(f.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)   # on disk: drop the rest from cache
                except OSError:
                    pass
    if werr:
        os.unlink(tmp)
        log(op=op, rel=rel, result='write-error', err=werr[0][:200])
        print('WERR')
        return 5
    if rerr:
        os.unlink(tmp)
        log(op=op, rel=rel, result='read-error', got=n, err=rerr[0][:200])
        print(f'RERR {n}')
        return 7
    if n != size:
        os.unlink(tmp)
        log(op=op, rel=rel, result='size-mismatch', got=n, want=size)
        print(f'SIZE {n}')
        return 4
    os.rename(tmp, dst)
    fsync_dir(d)
    digest = h.hexdigest()
    log(op=op, rel=rel, result='ok', size=n, sha256=digest)
    print(f'OK {n} {digest}')
    return 0


def recv_exact(c, k):
    b = b''
    while len(b) < k:
        x = c.recv(k - len(b))
        if not x:
            break
        b += x
    return b


def tput(root, day, name, size):
    # Plain-TCP data path (no ssh crypto on the hot path). Bound to the address the ssh client connected to; only a
    # connection from the ssh client's own IP that presents the one-time token is used; one file, then the port closes.
    rel, d, dst = target(root, day, name)
    ce = os.environ.get('SSH_CONNECTION', '').split()
    if len(ce) != 4:
        log(op='tput', rel=rel, result='reject', err='no SSH_CONNECTION')
        print('REJECT')
        return 2
    peer_ip, local_ip = ce[0], ce[2]
    if os.path.lexists(dst):
        log(op='tput', rel=rel, result='exists')
        print('EXISTS')
        return 3
    token = os.urandom(16)
    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    conn = None
    try:
        ls.bind((local_ip, 0))
        ls.listen(1)
        print(f'LISTEN {local_ip} {ls.getsockname()[1]} {token.hex()}', flush=True)
        deadline = time.monotonic() + ACCEPT_TIMEOUT
        while conn is None and time.monotonic() < deadline:
            ls.settimeout(max(0.1, deadline - time.monotonic()))
            try:
                c, addr = ls.accept()
            except socket.timeout:
                break
            c.settimeout(IO_TIMEOUT)
            try:
                ok = addr[0] == peer_ip and hmac.compare_digest(recv_exact(c, 16), token)
            except OSError:
                ok = False
            if ok:
                conn = c
            else:
                log(op='tput', rel=rel, result='conn-reject', peer=addr[0])
                c.close()
    finally:
        ls.close()
    if conn is None:
        log(op='tput', rel=rel, result='no-connection')
        print('NOCONN')
        return 6
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    with conn, conn.makefile('rb', buffering=CHUNK) as src:
        return receive(src, rel, d, dst, size, 'tput')


def verify(root, day, name):
    p = os.path.join(FILES, root, day, name)
    h = hashlib.sha256()
    n = 0
    with open(p, 'rb') as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
            n += len(b)
    print(f'OK {n} {h.hexdigest()}')
    return 0


def main():
    if BASE is None:
        print('receiver misconfigured: the forced command must pass --base <staging dir>', file=sys.stderr)
        print('REJECT')
        return 2
    if not os.path.isdir(BASE):
        print(f'receiver misconfigured: --base {BASE} does not exist (create the staging dir first)', file=sys.stderr)
        print('REJECT')
        return 2
    cmd = os.environ.get('SSH_ORIGINAL_COMMAND', '')
    m = PUT.fullmatch(cmd)
    if m:
        return put(m.group(1), m.group(2), m.group(3), int(m.group(4)))
    m = TPUT.fullmatch(cmd)
    if m:
        return tput(m.group(1), m.group(2), m.group(3), int(m.group(4)))
    m = VERIFY.fullmatch(cmd)
    if m:
        return verify(m.group(1), m.group(2), m.group(3))
    if cmd == 'ping':
        print('PONG')
        return 0
    log(op='reject', cmd=cmd[:200])
    print('REJECT')
    return 2


if __name__ == '__main__':
    sys.exit(main())
