#!/usr/bin/env python3
# ubv-push.py --- push listed recording files (.ubv) from the source console into the target's import staging; runs ON
# THE SOURCE console. Installed in SOURCE_WORKDIR next to source-run-push.sh (as run-push.sh), id_ed25519 (the
# restricted key the target's ubv-recv.py is bound to) and known_hosts (the target's host key).
# Usage: ubv-push.py <list>   list lines: id|folder|file|size  (from recordingFiles)
# Stops on the first failure; a re-run skips ids already ok in the ledger (<PUSH_HOME>/ledger.jsonl).
# Env: PUSH_DEST    user@target as the source reaches it (required)
#      RATE_MBPS    rate limit in MB/s (default 80)
#      PUSH_HOME    key, known_hosts and ledger directory (default: this script's directory)
#      PUSH_MODE=ssh (default: data inside the ssh channel) | tcp (ssh = control channel only; data over a one-shot
#        plain-TCP connection the receiver opens per file, gated by a one-time token and the ssh client's IP but NOT
#        encrypted: use it only on a trusted LAN; integrity = sha256 on both ends either way)
#      Test knobs (never for real copies): PUSH_LEDGER=<path> (other ledger), PUSH_TEST_DAY=1970/MM/DD
#        (remote day directory override, must start with 1970/ so it can never collide with a real recording).
import fcntl
import hashlib
import json
import os
import queue
import re
import socket
import subprocess
import sys
import threading
import time

HERE = os.environ.get('PUSH_HOME') or os.path.dirname(os.path.realpath(__file__))
KEY = HERE + '/id_ed25519'
KH = HERE + '/known_hosts'
LEDGER = os.environ.get('PUSH_LEDGER', HERE + '/ledger.jsonl')
DEST = os.environ.get('PUSH_DEST', '')
RATE = float(os.environ.get('RATE_MBPS', '80')) * 1e6
MODE = os.environ.get('PUSH_MODE', 'ssh')
TEST_DAY = os.environ.get('PUSH_TEST_DAY', '')
CHUNK = 4 << 20
SSH = ['ssh', '-i', KEY, '-o', 'UserKnownHostsFile=' + KH, '-o', 'StrictHostKeyChecking=yes',
       '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=10',
       '-c', 'aes128-gcm@openssh.com', DEST]


def grow_pipe(fd, size=1 << 20):
    # F_SETPIPE_SZ (1031): 1 MiB pipe to ssh instead of 64 KiB (capped by /proc/sys/fs/pipe-max-size)
    try:
        fcntl.fcntl(fd, 1031, size)
    except OSError:
        pass


def led(**kw):
    kw['ts'] = time.strftime('%Y-%m-%dT%H:%M:%S%z')
    with open(LEDGER, 'a') as f:
        f.write(json.dumps(kw) + '\n')
        f.flush()
        os.fsync(f.fileno())


def stream(src, write):
    # Pipelined (v2, 10G): a reader thread keeps the disk busy while this thread sends and hashes.
    # Returns (bytes sent, sha256 hex, error text or '').
    h = hashlib.sha256()
    n = 0
    t0 = time.monotonic()
    err = ''
    rq = queue.Queue(maxsize=8)
    stop = threading.Event()

    def reader(f):
        fd, off = f.fileno(), 0
        try:
            while not stop.is_set():
                b = f.read(CHUNK)
                if b:                       # old recordings are read once: keep them out of the page cache
                    try:
                        os.posix_fadvise(fd, off, len(b), os.POSIX_FADV_DONTNEED)
                    except OSError:
                        pass
                    off += len(b)
                rq.put(b)
                if not b:
                    return
        except OSError as e:                # a read error ends the stream (the consumer must never wait forever)
            rq.put(e)

    with open(src, 'rb') as f:
        try:
            os.posix_fadvise(f.fileno(), 0, 0, os.POSIX_FADV_SEQUENTIAL)
        except OSError:
            pass
        t = threading.Thread(target=reader, args=(f,), daemon=True)
        t.start()
        while True:
            b = rq.get()
            if isinstance(b, OSError):
                err = f'read error: {b}'
                break
            if not b:
                break
            try:
                write(b)
            except OSError as e:            # BrokenPipeError (ssh), ConnectionResetError / timeout (tcp)
                err = 'broken pipe' if isinstance(e, BrokenPipeError) else (str(e) or type(e).__name__)
                break
            h.update(b)
            n += len(b)
            ahead = n / RATE - (time.monotonic() - t0)
            if ahead > 0:
                time.sleep(ahead)
        stop.set()
        while t.is_alive():                 # unblock a reader waiting on a full queue, then let it exit
            try:
                rq.get_nowait()
            except queue.Empty:
                t.join(0.05)
    return n, h.hexdigest(), err


def send_ssh(cmd, src):
    p = subprocess.Popen(SSH + [cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    grow_pipe(p.stdin.fileno())
    n, digest, err = stream(src, p.stdin.write)
    try:
        p.stdin.close()
    except BrokenPipeError:
        err = err or 'broken pipe'
    out = p.stdout.read().decode(errors='replace').strip()
    serr = p.stderr.read().decode(errors='replace').strip()[-300:]
    return n, digest, err, out, serr, p.wait()


def send_tcp(cmd, src):
    p = subprocess.Popen(SSH + ['t' + cmd], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    first = p.stdout.readline().decode(errors='replace').split()
    n, digest, err = 0, hashlib.sha256().hexdigest(), ''
    if len(first) == 4 and first[0] == 'LISTEN':
        try:
            s = socket.create_connection((first[1], int(first[2])), timeout=30)
            s.settimeout(60)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 << 20)
            with s:
                s.sendall(bytes.fromhex(first[3]))
                n, digest, err = stream(src, s.sendall)
                if not err:
                    s.shutdown(socket.SHUT_WR)
        except (OSError, ValueError) as e:
            err = err or (str(e) or type(e).__name__)
        out = p.stdout.read().decode(errors='replace').strip()
    else:
        out = ' '.join(first)                # EXISTS / REJECT / ... before any port was opened
        err = 'no LISTEN line'
    serr = p.stderr.read().decode(errors='replace').strip()[-300:]
    return n, digest, err, out, serr, p.wait()


def main():
    if MODE not in ('ssh', 'tcp'):
        print(f'PUSH_MODE must be ssh or tcp (got {MODE!r})')
        return 64
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9@._:\[\]-]*', DEST):
        print(f'PUSH_DEST must be the target as user@host (got {DEST!r})')
        return 64
    if TEST_DAY and not (TEST_DAY.startswith('1970/') and len(TEST_DAY) == 10):
        print(f'PUSH_TEST_DAY must look like 1970/MM/DD (got {TEST_DAY!r})')
        return 64
    os.nice(19)
    subprocess.run(['ionice', '-c3', '-p', str(os.getpid())], check=True)
    done = set()
    if os.path.exists(LEDGER):
        for line in open(LEDGER):
            r = json.loads(line)
            if r.get('result') == 'ok':
                done.add(r['id'])
    total = 0
    for line in open(sys.argv[1]):
        line = line.rstrip('\n')
        if not line:
            continue
        id_, folder, name, size = line.split('|')[:4]
        if id_ in done:
            continue
        size = int(size)
        parts = folder.split('/')
        if len(parts) != 7 or parts[1] not in ('srv', 'ssd1') or parts[2:4] != ['unifi-protect', 'video']:
            led(id=id_, folder=folder, result='fail', err='unexpected folder layout')
            return 1
        root, day = parts[1], TEST_DAY or '/'.join(parts[4:7])
        src = os.path.join(folder, name)
        if os.stat(src).st_size != size:
            led(id=id_, rel=src, result='fail', err='size differs from DB row')
            return 1
        cmd = f'put {root} {day}/{name} {size}'
        t0 = time.monotonic()
        n, local, broken, out, serr, rc = (send_tcp if MODE == 'tcp' else send_ssh)(cmd, src)
        secs = time.monotonic() - t0
        ok = (not broken) and rc == 0 and n == size and out == f'OK {n} {local}'
        led(id=id_, rel=f'{root}/{day}/{name}', size=n, sha256=local, remote=out, rc=rc, mode=MODE,
            err='' if ok else (broken or serr), secs=round(secs, 1),
            mbps=round(n / secs / 1e6, 1) if secs else None, result='ok' if ok else 'fail')
        if not ok:
            return 1
        total += n
    print(f'DONE {total}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
