#!/usr/bin/env python3
"""copyq-top --- read-only live TUI for the source -> target copy queue (tool/copyq.py). Run as root: `sudo copyq-top`
(install/copyq-top.sh.in + install/copyq-top.sudoers.in make that passwordless for one user). q / Esc quits.
`copyq-top --once` prints one plain-text frame.

Reads only: <copyq>/state.json + runner.log (local), `systemctl is-active`, optionally the last journal line of
TOP_TEMP_JOURNAL_TAG carrying "hdd_temp=<n>C" (local), the in-flight `.part` file on the target (ssh, every 3 s) and the
tail of the source push ledger (ssh, every 10 s). Remote reads run in a background thread, so a slow / unreachable host
never freezes the screen. Never writes anything.
Finish times are projected with the copy / verify rates measured on this queue's finished items (fallback 170 / 250
MB/s), item by item in queue order.
"""
import curses
import datetime
import importlib.util
import json
import locale
import os
import re
import subprocess
import sys
import threading
import time
import unicodedata

HERE = os.path.dirname(os.path.realpath(__file__))
_spec = importlib.util.spec_from_file_location('copyq', os.path.join(HERE, 'copyq.py'))
cq = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cq)

DEF_COPY, DEF_VERIFY = 170e6, 250e6
DONE = ('copied', 'ready', 'imported')
STATE_EN = {'queued': 'queued', 'listing': 'listing', 'copying': 'copying', 'verifying': 'verifying', 'copied': 'copied',
            'ready': 'ready', 'imported': 'imported', 'error': 'ERROR'}


def dname(i):
    return i['name'] if i['name'].isascii() else i['slug']     # wide / non-ASCII names would break the column layout
MARK = {'queued': '·', 'listing': '◔', 'copying': '▶', 'verifying': '◐', 'copied': '✓', 'ready': '✓',
        'imported': '✓', 'error': '✗'}
SPARK = '▁▂▃▄▅▆▇█'


# ---------------------------------------------------------------- text helpers (CJK-aware widths)
def width(s):
    return sum(2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 0 if unicodedata.combining(ch) else 1 for ch in s)


def fit(s, n, right=False):
    out, w = '', 0
    for ch in s:
        cw = width(ch)
        if w + cw > n:
            break
        out, w = out + ch, w + cw
    pad = ' ' * (n - w)
    return pad + out if right else out + pad


def bar(frac, n):
    frac = max(0.0, min(1.0, frac))
    full = int(frac * n)
    return '█' * full + '░' * (n - full)


def hm(t):
    return datetime.datetime.fromtimestamp(t).strftime('%H:%M') if t else '--:--'


def gbs(b):
    return f'{(b or 0) / 1e9:,.1f}'


# ---------------------------------------------------------------- remote / slow reads (background thread)
class Live:
    def __init__(self):
        self.lock = threading.Lock()
        self.part = None           # (rel path, size, t) of the in-flight file on the target
        self.part_rate = None      # bytes/s from consecutive samples of the same file
        self.parts = None          # number of .part files on the target
        self.target_err = ''
        self.speeds = []           # MB/s of the last ok ledger entries (source)
        self.source_err = ''
        self.hdd = None            # source HDD temperature (optional journal line, TOP_TEMP_JOURNAL_TAG)
        self.stop = threading.Event()

    def poll_target(self):
        rc, out, err = cq.ssh(cq.TARGET, f"find {cq.STAGE} -name '*.part' -printf '%s %P\\n'", timeout=20)
        now = time.time()
        with self.lock:
            if rc != 0:
                self.target_err = (err.strip().splitlines() or ['ssh failed'])[-1][:60]
                return
            self.target_err = ''
            lines = [l.split(' ', 1) for l in out.splitlines() if ' ' in l]
            self.parts = len(lines)
            if not lines:
                self.part, self.part_rate = None, None
                return
            size, rel = int(lines[0][0]), lines[0][1]
            if self.part and self.part[0] == rel and now > self.part[2] and size >= self.part[1]:
                r = (size - self.part[1]) / (now - self.part[2])
                self.part_rate = r if self.part_rate is None else 0.5 * self.part_rate + 0.5 * r
            elif not self.part or self.part[0] != rel:
                self.part_rate = None
            self.part = (rel, size, now)

    def poll_source(self):
        rc, out, err = cq.ssh(cq.SOURCE, f'tail -n 40 {cq.LEDGER}', timeout=20)
        with self.lock:
            if rc != 0:
                self.source_err = (err.strip().splitlines() or ['ssh failed'])[-1][:60]
                return
            self.source_err = ''
            sp = []
            for l in out.splitlines():
                try:
                    r = json.loads(l)
                except ValueError:
                    continue
                if r.get('result') == 'ok' and r.get('mbps'):
                    sp.append(float(r['mbps']))
            self.speeds = sp[-24:]

    def poll_temp(self):
        tag = cq.SITE['TOP_TEMP_JOURNAL_TAG']
        if not tag:
            return
        try:
            out = subprocess.run(['journalctl', '-t', tag, '-n', '1', '-o', 'cat', '--no-pager'],
                                 capture_output=True, text=True, timeout=10).stdout
            m = re.search(r'hdd_temp=(\d+)C', out)
            with self.lock:
                self.hdd = int(m.group(1)) if m else None
        except (OSError, subprocess.SubprocessError):
            pass

    def run(self):
        k = 0
        while not self.stop.is_set():
            self.poll_target()
            if k % 3 == 0:
                self.poll_source()
            if k % 20 == 0:
                self.poll_temp()
            k += 1
            self.stop.wait(3)

    def once(self):
        self.poll_target()
        self.poll_source()
        self.poll_temp()


# ---------------------------------------------------------------- model
def runner_state():
    try:
        out = subprocess.run(['systemctl', 'is-active', cq.RUNNER_UNIT], capture_output=True, text=True, timeout=5).stdout
        return out.strip() or '?'
    except (OSError, subprocess.SubprocessError):
        return '?'


def rates(items):
    cb = ct = vb = vt = 0.0
    for i in items:
        if i.get('t_copy1') and i.get('t_copy0') and i['t_copy1'] > i['t_copy0']:
            cb += i.get('ok_bytes') or 0
            ct += i['t_copy1'] - i['t_copy0']
        if i.get('t_verify1') and i.get('t_verify0') and i['t_verify1'] > i['t_verify0']:
            vb += i.get('bytes') or 0
            vt += i['t_verify1'] - i['t_verify0']
    return (cb / ct if ct > 60 else DEF_COPY), (vb / vt if vt > 60 else DEF_VERIFY)


def project(st, now):
    """Per-item projected finish time (copy + verify), in queue order; None after an error / while paused."""
    items = st['items']
    crate, vrate = rates(items)
    t, out, halted = now, {}, bool(st.get('paused'))
    for i in items:
        s = i['state']
        if s in DONE:
            out[i['slug']] = i.get('t_verify1')
            continue
        if s == 'error' or halted:
            halted = True
            out[i['slug']] = None
            continue
        b = i.get('bytes') or i.get('est_bytes') or 0
        if s == 'copying':
            r = (i.get('rate') or 0) * 1e6 or crate
            t += max(0, b - (i.get('ok_bytes') or 0)) / r + b / vrate
        elif s == 'verifying':
            el = now - (i.get('t_verify0') or now)
            t += max(b / vrate - el, 30)
        else:
            t += b / crate + b / vrate + 15
        out[i['slug']] = t
    return out, crate, vrate


def frame(st, live, now, cols):
    """List of (text, colour-key) lines."""
    items = st['items']
    proj, crate, vrate = project(st, now)
    rs = runner_state()
    L = []
    pending = [i for i in items if i['state'] not in DONE]
    last = proj.get(items[-1]['slug']) if items else None
    if st.get('paused'):
        eta = f"PAUSED ({st.get('pause_reason') or '-'})"
    elif any(i['state'] == 'error' for i in items):
        eta = 'queue STOPPED on an error'
    elif not pending:
        eta = f"all done ({hm(last)})"
    elif last:
        eta = f"all done ~{hm(last)} ({cq.dur(last - now)} left)"
    else:
        eta = ''
    rz = {'active': 'running', 'inactive': 'NOT running', 'failed': 'FAILED', 'activating': 'starting'}.get(rs, rs)
    L.append((f" Copy {cq.SRC} -> {cq.DST}   {datetime.datetime.fromtimestamp(now).strftime('%m-%d %H:%M:%S')}   "
              f"runner {rz}   {eta}", 'title'))
    L.append(('─' * cols, 'dim'))
    # current item + in-flight file
    cur = next((i for i in items if i['state'] in ('listing', 'copying', 'verifying')), None)
    with live.lock:
        part, prate, parts, speeds, hdd = live.part, live.part_rate, live.parts, list(live.speeds), live.hdd
        terr, serr = live.target_err, live.source_err
    if cur:
        if cur['state'] == 'verifying':
            exp = (cur.get('bytes') or 0) / vrate
            el = now - (cur.get('t_verify0') or now)
            L.append((f" Now     {dname(cur)}  verifying ({cq.DST} re-read {gbs(cur.get('bytes'))} GB)  {cq.dur(el)} of ~{cq.dur(exp)}  "
                      f"[{bar(el / exp if exp else 0, 24)}]", 'verify'))
        elif cur['state'] == 'copying':
            ob, b = cur.get('ok_bytes') or 0, cur.get('bytes') or 1
            L.append((f" Now     {dname(cur)}  copying  {cur.get('ok_files', 0)}/{cur.get('files', '?')} files  "
                      f"{gbs(ob)}/{gbs(b)} GB  [{bar(ob / b, 24)}] {ob / b * 100:.0f}%", 'copy'))
        else:
            L.append((f" Now     {dname(cur)}  building the list", 'copy'))
        if part and cur['state'] == 'copying':
            name = part[0].rsplit('/', 1)[-1].replace('.part', '')
            size = 0
            try:
                for l in open(f"{cq.IMPORT}/{cur['slug']}.list"):
                    p = l.rstrip('\n').split('|')
                    if len(p) >= 4 and p[2] == name:
                        size = int(p[3])
                        break
            except OSError:
                pass
            frac = part[1] / size if size else 0
            L.append((f" File    {name}  {part[1] / 1e6:,.0f}/{size / 1e6:,.0f} MB  [{bar(frac, 16)}]"
                      + (f"  {prate / 1e6:.0f} MB/s" if prate else ''), 'copy'))
        elif cur.get('note'):
            L.append((f" Note    {cur['note']}", 'dim'))
    else:
        L.append((' Now     (nothing copying / verifying)', 'dim'))
    L.append(('─' * cols, 'dim'))
    # table
    compact = cols < 100                 # narrow terminal: drop the file count and the bar, keep speed + finish
    nw = 18 if compact else 26
    bw = max(10, min(24, cols - 78))
    if compact:
        L.append((f" {fit('STATE', 11)} {fit('CAMERA', nw)} {fit('GB', 17, True)} {fit('%', 5, True)} {fit('SPEED', 8, True)}  "
                  f"{fit('DONE', 6)}", 'head'))
    else:
        L.append((f" {fit('STATE', 11)} {fit('CAMERA', nw)} {fit('FILES', 11, True)} {fit('GB', 17, True)}  {fit('PROGRESS', bw + 2)} "
                  f"{fit('SPEED', 8, True)}  {fit('DONE', 6)}", 'head'))
    for i in items:
        s = i['state']
        files = i.get('files') or i.get('est_files') or 0
        b = i.get('bytes') or i.get('est_bytes') or 0
        ok_b = i.get('ok_bytes') or 0
        if s in DONE:
            prog, speed = 1.0, (ok_b / (i['t_copy1'] - i['t_copy0']) / 1e6 if i.get('t_copy1') and i.get('t_copy0') else 0)
        elif s == 'verifying':
            prog, speed = 1.0, (ok_b / ((i.get('t_copy1') or now) - (i.get('t_copy0') or now) or 1) / 1e6)
        else:
            prog, speed = (ok_b / b if b else 0), (i.get('rate') or 0)
        fin = proj.get(i['slug'])
        fin_s = hm(fin) if fin else ('stop' if s == 'error' else '--:--')
        if s not in DONE and fin:
            fin_s = '~' + fin_s
        key = {'copying': 'copy', 'verifying': 'verify', 'error': 'err', 'queued': 'dim', 'listing': 'copy'}.get(s, 'ok')
        cnt = f"{i.get('ok_files') or 0}/{files}"
        size = f'{gbs(ok_b)}/{gbs(b)}'
        spd = f'{speed:.0f} MB/s' if speed else ''
        head = f" {fit(MARK.get(s, ' ') + ' ' + STATE_EN.get(s, s), 11)} {fit(dname(i), nw)} "
        if compact:
            L.append((head + f"{fit(size, 17, True)} {fit(f'{prog * 100:.0f}%', 5, True)} {fit(spd, 8, True)}  {fit(fin_s, 6)}", key))
        else:
            L.append((head + f"{fit(cnt, 11, True)} {fit(size, 17, True)}  [{bar(prog, bw)}] {fit(spd, 8, True)}  {fit(fin_s, 6)}", key))
        if s == 'error':
            L.append((f"     ✗ {(i.get('error') or '')[:cols - 8]}", 'err'))
    L.append(('─' * cols, 'dim'))
    tot = sum(i.get('bytes') or i.get('est_bytes') or 0 for i in items)
    okt = sum((i.get('ok_bytes') or 0) for i in items)
    L.append((f" Total   {gbs(okt)} / {gbs(tot)} GB copied ({okt / tot * 100 if tot else 0:.0f}%)   measured this run: copy {crate / 1e6:.0f} MB/s, "
              f"verify {vrate / 1e6:.0f} MB/s", 'plain'))
    if speeds:
        lo, hi = min(speeds), max(speeds)
        sp = ''.join(SPARK[int((v - lo) / (hi - lo) * 7) if hi > lo else 7] for v in speeds)
        L.append((f" Speed   last {len(speeds)} files  {sp}   {lo:.0f}-{hi:.0f} MB/s", 'plain'))
    t_s = (f"{cq.SRC} HDD {hdd}°C" if hdd else f"{cq.SRC} HDD ?°C") if cq.SITE['TOP_TEMP_JOURNAL_TAG'] else ''
    t_s += '   ' if t_s else ''
    copying = bool(cur and cur['state'] == 'copying')
    if parts is None:
        p_s = f'{cq.DST} .part ?'
    elif copying and parts == 1:
        p_s = f'{cq.DST} .part 1 (the file in flight)'
    else:
        p_s = f'{cq.DST} .part {parts}' + (' (⚠ leftover partial file)' if parts > (1 if copying else 0) else '')
    L.append((f" Health  {t_s}{p_s}"
              + (f"   ⚠ {cq.DST}: {terr}" if terr else '') + (f"   ⚠ {cq.SRC}: {serr}" if serr else ''), 'warn' if (terr or serr) else 'plain'))
    L.append(('─' * cols, 'dim'))
    try:
        log = open(cq.QDIR + '/runner.log').read().splitlines()[-6:]
    except OSError:
        log = []
    for l in log:
        m = re.match(r'\S+T(\d\d:\d\d:\d\d)\S*\s+(.*)', l)
        L.append((f" {m.group(1)}  {m.group(2)}" if m else f" {l}", 'dim'))
    return L


# ---------------------------------------------------------------- UI
COLORS = {}


def draw(scr, live):
    curses.curs_set(0)
    scr.nodelay(True)
    scr.timeout(1000)
    if curses.has_colors():
        curses.start_color()
        curses.use_default_colors()
        for n, (k, c) in enumerate([('title', curses.COLOR_CYAN), ('ok', curses.COLOR_GREEN), ('copy', curses.COLOR_CYAN),
                                    ('verify', curses.COLOR_YELLOW), ('err', curses.COLOR_RED), ('warn', curses.COLOR_RED),
                                    ('head', curses.COLOR_WHITE)], start=1):
            curses.init_pair(n, c, -1)
            COLORS[k] = curses.color_pair(n) | (curses.A_BOLD if k in ('title', 'head', 'err') else 0)
    COLORS['dim'] = curses.A_DIM
    COLORS['plain'] = curses.A_NORMAL
    while True:
        rows, cols = scr.getmaxyx()
        try:
            st = cq.load()
            lines = frame(st, live, time.time(), max(40, cols - 1))
        except Exception as e:                     # a torn read or bad state must not kill the viewer
            lines = [(f' cannot read the state: {type(e).__name__}: {e}', 'err')]
        scr.erase()
        for y, (text, key) in enumerate(lines[:rows - 1]):
            try:
                scr.addstr(y, 0, fit(text, cols - 1), COLORS.get(key, 0))
            except curses.error:
                pass
        try:
            scr.addstr(rows - 1, 0, fit(' q quit   read-only: never touches the queue or the push', cols - 1), curses.A_DIM)
        except curses.error:
            pass
        scr.refresh()
        ch = scr.getch()
        if ch in (ord('q'), ord('Q'), 27):
            return


def main():
    if os.geteuid() != 0:
        print('copyq-top reads root-owned state and ssh keys: run it as root (sudo copyq-top)')
        return 1
    locale.setlocale(locale.LC_ALL, '')
    if 'utf' not in (locale.getpreferredencoding(False) or '').lower():
        for loc in ('C.UTF-8', 'C.utf8', 'en_US.UTF-8'):
            try:
                locale.setlocale(locale.LC_ALL, loc)
                break
            except locale.Error:
                continue
    live = Live()
    if '--once' in sys.argv:
        live.once()
        cols = 110
        for text, _ in frame(cq.load(), live, time.time(), cols):
            print(text)
        return 0
    th = threading.Thread(target=live.run, daemon=True)
    th.start()
    try:
        curses.wrapper(draw, live)
    except KeyboardInterrupt:
        pass
    finally:
        live.stop.set()
    return 0


if __name__ == '__main__':
    sys.exit(main())
