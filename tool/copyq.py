#!/usr/bin/env python3
"""copyq.py --- queued source -> target copy runner for the recording import (controller side).

The runner (systemd <NAME_PREFIX>-copy.service -> `copyq.py run`) works the queue in order, one camera list at a time:
  listing   make-list.sh (read-only on the source) -> <slug>.list (+ optional filter, the unfiltered list kept as .full)
  copying   source-side transient unit PUSH_UNIT (systemd-run; run-push.sh -> ubv-push.py with PUSH_MODE=COPY_MODE,
            RATE_MBPS=COPY_RATE_MBPS): one push at a time, survives controller / ssh loss, resumes from the ledger.
            Before every (re)start: no import window running on the target, enough space, and list files whose source
            row Protect has deleted since the list was made are moved to <slug>.gone (Protect deletes the oldest
            recordings first, and the oldest files are the first to be copied). Transport failures retry with backoff;
            anything else stops.
  verifying verify-staged.sh (rows / target re-read / source sample re-read) -> copied
Any error stops the queue in a safe state (no push running, the receiver dropped the partial file) and calls the
notification hook. State: <copyq>/state.json (source of truth) + status.txt (rendered): `copyq.py status`.

Subcommands:
  run                         the runner (service ExecStart)
  add <slug> <mac> [--name N] [--filter before=YYYY-MM-DD,ch=0|2,type=rotating,max=N]   queue an item
  status                      print the status (state + live progress)
  pause                       stop the runner and the source push (resumable; do this before an import window)
  resume                      clear pause and start the runner
  retry <slug>                clear an error (resume from the ledger) and start the runner
  ready <slug> <note>         batch prepared for its window: notification (note = e.g. "recording stops ~3 min")
  imported <slug>             the batch's window is done
  drop <slug>                 remove a queued item, or one stopped in error (abandon it)
  summary [--print]           daily summary + heartbeat (<NAME_PREFIX>-copy-summary.timer); --print = no notification
  estimate [--filter ...] [mac ...]   live estimate per camera from the source (files, GB, copy / verify time)

Site configuration (siteconf.py): IMPORT_DIR, SOURCE_SSH, TARGET_SSH, TARGET_STAGING, TARGET_WORKDIR, SOURCE_WORKDIR,
PUSH_UNIT, PUSH_DEST, COPY_MODE, COPY_RATE_MBPS, COPY_MARGIN, IDMAP, NOTIFY_CMD, NAME_PREFIX, SOURCE_NAME, TARGET_NAME.
Env (tests only): COPYQ_DIR, COPYQ_TEST_DAY=1970/MM/DD (test ledger + remote 1970 day dir; requires an IMPORT_DIR /
COPYQ_DIR other than the site file's and copyq-test-* slugs), COPYQ_POLL, COPYQ_BACKOFF, COPYQ_UNIT (runner unit name),
COPYQ_VERIFY_SLACK.
Times are shown in the controller's local time zone.
"""
import contextlib
import datetime
import fcntl
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time

TOOL = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, TOOL)
import siteconf  # noqa: E402

SITE = siteconf.load_or_exit()
try:   # every path / host below is used in remote commands: an empty value must never become '/...'
    IMPORT, SOURCE, TARGET, H, STAGE_BASE, TARGET_WD = SITE.need('IMPORT_DIR', 'SOURCE_SSH', 'TARGET_SSH', 'SOURCE_WORKDIR',
                                                           'TARGET_STAGING', 'TARGET_WORKDIR')
except siteconf.SiteError as e:
    sys.exit(f'site configuration: {e}')
QDIR = os.environ.get('COPYQ_DIR', IMPORT + '/copyq')
FILE_IMPORT = SITE.filevals.get('IMPORT_DIR', '')         # the production dir (test mode must not use it)
STATE = QDIR + '/state.json'
SRC, DST = SITE['SOURCE_NAME'], SITE['TARGET_NAME']       # how messages call the two consoles
STAGE = STAGE_BASE + '/files'
IDMAP = SITE['IDMAP']
TEST_DAY = os.environ.get('COPYQ_TEST_DAY', '')
LEDGER = H + ('/copyq-test-ledger.jsonl' if TEST_DAY else '/ledger.jsonl')
PUSH_ENV = {'PUSH_MODE': SITE['COPY_MODE'], 'RATE_MBPS': SITE['COPY_RATE_MBPS'], 'PUSH_DEST': SITE['PUSH_DEST']}
if TEST_DAY:
    PUSH_ENV.update(PUSH_LEDGER=LEDGER, PUSH_TEST_DAY=TEST_DAY)
PUSH_UNIT = SITE['PUSH_UNIT']
PROD_RUNNER_UNIT = SITE['NAME_PREFIX'] + '-copy'
RUNNER_UNIT = os.environ.get('COPYQ_UNIT', PROD_RUNNER_UNIT)
NOTIFY_CMD = SITE['NOTIFY_CMD']
POLL = int(os.environ.get('COPYQ_POLL', '30'))
BACKOFF = [int(x) for x in os.environ.get('COPYQ_BACKOFF', '120,600,1800').split(',')]
VERIFY_SLACK = float(os.environ.get('COPYQ_VERIFY_SLACK', '1800'))   # verify timeout = 3 x expected + this
MARGIN = float(SITE['COPY_MARGIN'])     # bytes kept free on the target staging volume (it also holds live recordings)
COPY_MBS, VERIFY_MBS = 180, 340     # estimates only (measured on a 10 GbE LAN: tcp channel ~180 MB/s, HDD re-read ~340 MB/s)
PENDING = ('queued', 'listing', 'copying', 'verifying')
UNREACH = 'unreachable'             # window_busy(): the target did not answer
SLUG_RE = re.compile(r'^[a-z0-9][a-z0-9-]{0,38}$')
TRANSPORT = re.compile(r'broken pipe|timed out|errno (32|104|110|111|113)\b|connection (reset|refused|timed out|closed)'
                       r'|no listen line', re.I)


class Hard(Exception):
    """Stop the queue: needs a human."""


class Stop(Exception):
    """SIGTERM: leave the source push alone and exit."""


# ---------------------------------------------------------------- small helpers
def now():
    return time.time()


def ts(t=None):
    return datetime.datetime.fromtimestamp(t or now()).strftime('%m-%d %H:%M')


def gb(b):
    return f'{(b or 0) / 1e9:,.1f} GB'


def dur(s):
    s = int(s or 0)
    if s < 60:
        return f'{s} s'
    if s < 3600:
        return f'{round(s / 60)} min'
    h, m = divmod(round(s / 60), 60)
    return f'{h} h {m:02d} min' if m else f'{h} h'


def stamp():
    return datetime.datetime.now().astimezone().isoformat(timespec='seconds')


def log(msg):
    line = f'{stamp()} {msg}'
    print(line, flush=True)
    with open(QDIR + '/runner.log', 'a') as f:
        f.write(line + '\n')


def run(cmd, timeout=120, input=None, env=None):
    try:
        p = subprocess.run(cmd, input=input, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, '', f'timeout after {timeout}s'


# kill_verify's target-side script (bash -s -- <sha file>): stop every sha256sum that has exactly that argument
KILL_SHA = r'''want=$1
for p in $(pgrep -x sha256sum); do
  while IFS= read -r -d '' a; do [ "$a" = "$want" ] && { kill "$p"; break; }; done < "/proc/$p/cmdline"
done 2> /dev/null; true
'''


def ssh(host, cmd, timeout=120, input=None):
    return run(['ssh', '-o', 'ConnectTimeout=10', '-o', 'BatchMode=yes', '-o', 'ServerAliveInterval=15',
                '-o', 'ServerAliveCountMax=4', host, cmd], timeout=timeout, input=input)


def tool_env():
    e = dict(os.environ, IMPORT_DIR=IMPORT)
    if TEST_DAY:
        e['PUSH_LEDGER'] = LEDGER
    return e


def check_mode(slug=None):
    if TEST_DAY:
        if not re.fullmatch(r'1970/\d\d/\d\d', TEST_DAY):
            sys.exit('COPYQ_TEST_DAY must look like 1970/MM/DD')
        prod = os.path.realpath(FILE_IMPORT) if FILE_IMPORT else None
        if (os.path.realpath(IMPORT) == prod or os.path.realpath(QDIR) == (prod and prod + '/copyq')
                or RUNNER_UNIT == PROD_RUNNER_UNIT):
            sys.exit('test mode needs an IMPORT_DIR / COPYQ_DIR other than the site file\'s, and COPYQ_UNIT')
        if slug and not slug.startswith('copyq-test-'):
            sys.exit('test mode only takes copyq-test-* slugs')
    elif slug and slug.startswith('copyq-test-'):
        sys.exit('copyq-test-* slugs only in test mode')


# ---------------------------------------------------------------- state
def load():
    if not os.path.exists(STATE):
        return {'paused': False, 'pause_reason': '', 'items': []}
    with open(STATE) as f:
        return json.load(f)


@contextlib.contextmanager
def locked():
    os.makedirs(QDIR, mode=0o700, exist_ok=True)
    with open(QDIR + '/state.lock', 'w') as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        st = load()
        yield st
        tmp = STATE + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(st, f, indent=1, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, STATE)


def find(st, slug):
    for it in st['items']:
        if it['slug'] == slug:
            return it
    return None


def upd(slug, **kw):
    with locked() as st:
        it = find(st, slug)
        if it is None:
            raise Hard(f'item {slug} vanished from the queue')
        it.update(kw)
        it['updated'] = now()
        snap = dict(it)
    return snap


def write_status():
    try:
        txt = render(load())
        tmp = QDIR + '/status.txt.tmp'
        with open(tmp, 'w') as f:
            f.write(txt)
        os.replace(tmp, QDIR + '/status.txt')
    except OSError:
        pass


def runner_active():
    rc, out, _ = run(['systemctl', 'is-active', RUNNER_UNIT], timeout=15)
    return out.strip() in ('active', 'activating', 'reloading')


# ---------------------------------------------------------------- lists
def parse_filter(s):
    f = {}
    for kv in filter(None, (s or '').split(',')):
        k, _, v = kv.partition('=')
        if k == 'before' and re.fullmatch(r'\d{4}-\d\d-\d\d', v):
            f[k] = int(datetime.datetime.strptime(v, '%Y-%m-%d').timestamp() * 1000)     # local midnight
        elif k == 'ch' and v in ('0', '2'):
            f[k] = v
        elif k == 'type' and re.fullmatch(r'[a-z]+', v):
            f[k] = v
        elif k == 'max' and v.isdigit() and int(v) > 0:
            f[k] = int(v)
        else:
            sys.exit(f'bad filter term {kv!r} (before=YYYY-MM-DD, ch=0|2, type=<name>, max=N)')
    return f


def apply_filter(lines, mac, fs):
    f = parse_filter(fs)
    out = []
    for l in lines:
        name = l.split('|')[2]
        m = re.fullmatch(rf'{mac}_([02])_([a-z]+)_(\d{{13}})\.ubv', name)
        if not m:
            raise Hard(f'unexpected file name in list: {name}')
        ch, typ, ms = m.group(1), m.group(2), int(m.group(3))
        if ('before' in f and ms >= f['before']) or ('ch' in f and ch != f['ch']) or ('type' in f and typ != f['type']):
            continue
        out.append(l)
        if 'max' in f and len(out) >= f['max']:
            break
    return out


def read_lines(p):
    with open(p) as f:
        return [l.rstrip('\n') for l in f if l.strip()]


def write_lines(p, lines):
    tmp = p + '.tmp'
    with open(tmp, 'w') as f:
        f.write(''.join(l + '\n' for l in lines))
    os.replace(tmp, p)


def rows_now(mac):
    with open(TOOL + '/rows.sql') as f:
        sql = f.read()
    rc, out, err = ssh(SOURCE, f"psql -U postgres -p 5433 -h 127.0.0.1 -d unifi-protect -X -At -F '|' -v ON_ERROR_STOP=1 "
                            f"-v mac={mac} -f -", input=sql, timeout=300)
    if rc != 0:
        raise Hard(f'rows query on the {SRC} failed: rc={rc} {err.strip()[-200:]}')
    return [l for l in out.split('\n') if l.strip()]


# ---------------------------------------------------------------- ledger (source side, mirrored incrementally)
class Ledger:
    def __init__(self):
        self.pos = 0
        self.ok = {}        # id -> entry
        self.entries = []   # every entry, in order, with its position in the file

    def _feed(self, data, base):
        end = data.rfind('\n') + 1          # a line being written right now is picked up next time
        off = base
        for line in data[:end].split('\n'):
            if line:
                e = json.loads(line)
                e['_off'] = off
                self.entries.append(e)
                if e.get('result') == 'ok' and e.get('remote') == 'OK %d %s' % (e.get('size', -1), e.get('sha256')):
                    self.ok[e['id']] = e
            off += len(line.encode()) + 1
        self.pos = base + len(data[:end].encode())

    def refresh(self):
        rc, out, err = ssh(SOURCE, f'tail -c +{self.pos + 1} {LEDGER} 2>/dev/null; true', timeout=120)
        if rc != 0:
            return False
        self._feed(out, self.pos)
        return True

    def since(self, off):
        return [e for e in self.entries if e['_off'] >= off]


# ---------------------------------------------------------------- runner
class Runner:
    def __init__(self):
        self.led = Ledger()
        self.poll_fail = 0

    def sleep(self, secs, slug=None, note=None):
        end = now() + secs
        while now() < end:
            if note and slug:
                upd(slug, note=f'{note}, {dur(end - now())} left')
                write_status()
            time.sleep(min(5, max(0.1, end - now())))

    # -- target side checks
    def window_busy(self):
        rc, out, _ = ssh(TARGET, f"systemctl list-units --all --plain --no-legend '{SITE['NAME_PREFIX']}-*' 2>/dev/null | "
                                 "awk '$3 ~ /^(active|activating|deactivating|reloading)$/ {print $1}'", timeout=60)
        if rc != 0:
            return UNREACH
        return out.strip().replace('\n', ' ')

    def target_avail(self):
        # the staging base, not files/: the receiver creates files/ only with the first put, which this check precedes
        rc, out, _ = ssh(TARGET, f'df -B1 --output=avail {STAGE_BASE} | tail -1', timeout=60)
        return int(out.strip()) if rc == 0 and out.strip().isdigit() else None

    def target_parts(self):
        rc, out, _ = ssh(TARGET, f"find {STAGE} -name '*.part' | wc -l", timeout=120)
        return out.strip() if rc == 0 else '?'

    # -- source push unit
    def push_state(self, slug):
        rc, out, err = ssh(SOURCE, f'systemctl is-active {PUSH_UNIT}; echo @@; cat {H}/current 2>/dev/null; echo @@; '
                                f'cat {H}/{slug}.push.exit 2>/dev/null; true', timeout=60)
        if rc != 0 or out.count('@@') != 2:
            return None
        a, cur, ex = (x.strip() for x in out.split('@@'))
        return {'active': a in ('active', 'activating', 'deactivating', 'reloading'), 'state': a, 'current': cur,
                'exit': ex if ex else None}

    def stop_push(self):
        ssh(SOURCE, f'systemctl stop {PUSH_UNIT} 2>/dev/null; true', timeout=120)
        st = self.push_state('-')
        return st is not None and not st['active']

    def push_log_tail(self, slug):
        rc, out, _ = ssh(SOURCE, f"tail -n 40 {H}/{slug}.push.log 2>/dev/null; true", timeout=60)
        sec = out.split('\n=== ')[-1] if out else ''
        return sec.strip()

    # -- phases
    def do_list(self, it):
        slug, mac = it['slug'], it['mac']
        listf = f'{IMPORT}/{slug}.list'
        upd(slug, state='listing', note=f'building the list ({SRC} read-only)', t_list=now())
        write_status()
        if not os.path.exists(f'{listf}.full' if it.get('filter') else listf):
            if os.path.exists(listf):
                raise Hard(f'{listf} exists without its .full (filter {it["filter"]}): check by hand')
            rc, out, err = run([TOOL + '/make-list.sh', slug, mac], timeout=900, env=tool_env())
            log(f'{slug}: make-list rc={rc} {out.strip()} {err.strip()[-300:]}')
            if rc != 0:
                raise Hard(f'make-list failed: {(out + err).strip()[-300:]}')
            if it.get('filter'):
                os.replace(listf, listf + '.full')
        if it.get('filter') and not os.path.exists(listf):
            lines = apply_filter(read_lines(listf + '.full'), mac, it['filter'])
            if not lines:
                raise Hard(f'filter {it["filter"]} leaves no files')
            write_lines(listf, lines)
        lines = read_lines(listf)
        upd(slug, state='copying', files=len(lines), bytes=sum(int(l.split('|')[3]) for l in lines), note='')
        log(f'{slug}: list {len(lines)} files')

    def drop_gone(self, it, listf):
        """List files not copied yet whose source row is gone (Protect deleted them) -> <slug>.gone."""
        now_ids = {l.split('|')[0] for l in rows_now(it['mac'])}
        if not now_ids:
            raise Hard('rows query returned no rows for this camera')
        lines = read_lines(listf)
        todo = [l for l in lines if l.split('|')[0] not in self.led.ok]
        gone = [l for l in todo if l.split('|')[0] not in now_ids]
        if not gone:
            return
        if len(gone) > max(5, 0.02 * len(todo)):
            raise Hard(f'{len(gone)} of {len(todo)} remaining files have no source row any more --- too many to be the '
                       f'normal oldest-first deletion, check the {SRC}')
        st = stamp()
        with open(f'{IMPORT}/{it["slug"]}.gone', 'a') as f:
            f.writelines(f'{l}|{st}\n' for l in gone)
        gids = {l.split('|')[0] for l in gone}
        keep = [l for l in lines if l.split('|')[0] not in gids]
        write_lines(listf, keep)
        upd(it['slug'], gone=it.get('gone', 0) + len(gone), files=len(keep),
            bytes=sum(int(l.split('|')[3]) for l in keep))
        log(f'{it["slug"]}: {len(gone)} file(s) deleted by Protect before they could be copied -> .gone: '
            + ' '.join(l.split('|')[2] for l in gone))

    def launch(self, it):
        slug = it['slug']
        listf = f'{IMPORT}/{slug}.list'
        unreach = 0
        while True:
            busy = self.window_busy()
            if not busy:
                break
            unreach = unreach + 1 if busy == UNREACH else 0
            if unreach * POLL > 600:
                raise Hard(f'{DST} unreachable for 10 min before starting the push')
            upd(slug, note=f'waiting for the import window to end ({busy})' if not unreach else f'{DST} unreachable, waiting')
            write_status()
            self.sleep(POLL)
        if not self.led.refresh():
            raise Hard(f'cannot read the {SRC} ledger')
        self.drop_gone(it, listf)
        lines = read_lines(listf)
        remaining = sum(int(l.split('|')[3]) for l in lines if l.split('|')[0] not in self.led.ok)
        avail = self.target_avail()
        if avail is None:
            raise Hard(f'cannot read free space on the {DST} staging volume')
        if avail < remaining + MARGIN:
            raise Hard(f'{DST} staging volume: {gb(avail)} free < {gb(remaining)} to copy + {gb(MARGIN)} margin')
        rc, _, err = run(['scp', '-q', listf, f'{SOURCE}:{H}/{slug}.list'], timeout=120)
        if rc != 0:
            raise Hard(f'scp list to the {SRC} failed: {err.strip()[-200:]}')
        envs = ' '.join(f'--setenv={k}={v}' for k, v in PUSH_ENV.items())
        rc, out, err = ssh(SOURCE, f'rm -f {H}/{slug}.push.exit && systemd-run --unit={PUSH_UNIT} --collect --quiet '
                                f'{envs} {H}/run-push.sh {slug}', timeout=60)
        if rc != 0:
            raise Hard(f'systemd-run on the {SRC} failed: {(out + err).strip()[-300:]}')
        upd(slug, launched=now(), led_off=self.led.pos, t_copy0=it.get('t_copy0') or now(),
            note=f'pushing ({PUSH_ENV["PUSH_MODE"]})')
        log(f'{slug}: push started ({envs}; ledger position {self.led.pos}; {gb(remaining)} to go)')

    def progress(self, slug):
        it = find(load(), slug)
        ids = {l.split('|')[0]: int(l.split('|')[3]) for l in read_lines(f'{IMPORT}/{slug}.list')}
        done = [self.led.ok[i] for i in ids if i in self.led.ok]
        okb = sum(e['size'] for e in done)
        recent = sorted((e for e in done if e.get('secs')), key=lambda e: e['_off'])[-10:]
        rate = sum(e['size'] for e in recent) / sum(e['secs'] for e in recent) if recent else 0
        left = sum(ids.values()) - okb
        upd(slug, ok_files=len(done), ok_bytes=okb, rate=round(rate / 1e6, 1),
            eta=now() + left / rate if rate else None)
        return it

    def outcome(self, it, ex):
        """('done'|'retry'|'hard', reason) for a finished push attempt."""
        slug = it['slug']
        self.led.refresh()
        new = self.led.since(it.get('led_off', 0))
        tail = self.push_log_tail(slug)
        ids = [l.split('|')[0] for l in read_lines(f'{IMPORT}/{slug}.list')]
        if ex == '0':
            missing = [i for i in ids if i not in self.led.ok]
            if 'DONE' in tail and not missing:
                return 'done', ''
            return 'hard', f'push exited 0 but {len(missing)} list file(s) have no ok ledger entry'
        if ex is None:
            return 'retry', f'push stopped without an exit status (killed / {SRC} restart)'
        fails = [e for e in new if e.get('result') == 'fail']
        if fails:
            f = fails[-1]
            remote = f.get('remote') or ''
            reason = (f'{f.get("rel") or f.get("folder")}: remote={remote!r} rc={f.get("rc")} '
                      f'err={(f.get("err") or "")[:200]!r}')
            hard_remote = remote.startswith(('OK', 'EXISTS', 'REJECT', 'WERR'))
            if not hard_remote and (TRANSPORT.search(f.get('err') or '') or f.get('rc') == 255):
                return 'retry', reason
            return 'hard', reason
        if 'FileNotFoundError' in tail:
            return 'retry', 'source file vanished (Protect deleted it?): ' + tail.splitlines()[-1][:200]
        return 'hard', f'push exit {ex}: ' + ' | '.join(tail.splitlines()[-3:])[:300]

    def do_copy(self, it):
        slug = it['slug']
        t0 = now()
        while not self.led.refresh():
            if now() - t0 > 600:
                raise Hard(f'cannot read the {SRC} ledger for 10 min')
            upd(slug, note=f'{SRC} unreachable, waiting')
            write_status()
            self.sleep(POLL)
        while True:
            it = find(load(), slug)
            ps = self.push_state(slug)
            if ps is None:
                self.poll_fail += 1
                if self.poll_fail * POLL > 600:
                    raise Hard(f'{SRC} unreachable for 10 min while starting the copy')
                upd(slug, note=f'{SRC} unreachable ({self.poll_fail} polls)')
                write_status()
                self.sleep(POLL)
                continue
            self.poll_fail = 0
            if ps['active']:
                if ps['current'] != slug:
                    raise Hard(f'another push is running on the {SRC} ({ps["current"] or "unknown"})')
                if not it.get('launched'):
                    upd(slug, launched=now(), led_off=it.get('led_off') or 0)
                log(f'{slug}: push already running on the {SRC} --- adopting it')
            elif it.get('launched') and ps['exit'] is None and ps['current'] != slug:
                upd(slug, launched=None)        # launch never got as far as run-push.sh
                continue
            elif not it.get('launched'):
                self.launch(it)
            # monitor
            while True:
                ps = self.push_state(slug)
                if ps is None:
                    self.poll_fail += 1
                    upd(slug, note=f'{SRC} unreachable ({self.poll_fail} polls)')
                    if self.poll_fail * POLL > 600:
                        raise Hard(f'{SRC} unreachable for 10 min (the push may still be running there)')
                    self.sleep(POLL)
                    continue
                self.poll_fail = 0
                if not ps['active']:
                    break
                busy = self.window_busy()
                if busy and busy != UNREACH:
                    log(f'{slug}: import window started during the copy ({busy}) --- stopping the push')
                    self.stop_push()
                    upd(slug, launched=None, note=f'import window running ({busy}): push stopped, resumes after it')
                    break
                if self.led.refresh():
                    self.progress(slug)
                upd(slug, note=f'pushing ({PUSH_ENV["PUSH_MODE"]})')
                write_status()
                self.sleep(POLL)
            it = find(load(), slug)
            if not it.get('launched'):          # stopped for a window: back to launch (waits for the window)
                continue
            kind, reason = self.outcome(it, ps['exit'])
            self.progress(slug)
            it = find(load(), slug)
            upd(slug, launched=None)
            if kind == 'done':
                upd(slug, state='verifying', t_copy1=now(), note='', retries=0)
                log(f'{slug}: copy complete ({it.get("ok_files")} files, {gb(it.get("ok_bytes"))})')
                return
            if kind == 'hard':
                raise Hard(reason)
            retries = 0 if it.get('ok_files', 0) > it.get('ok_at_fail', -1) else it.get('retries', 0)
            retries += 1
            upd(slug, retries=retries, ok_at_fail=it.get('ok_files', 0), last_retry_reason=reason)
            log(f'{slug}: push failed (retryable, attempt {retries}/{len(BACKOFF)}): {reason}')
            if retries > len(BACKOFF):
                raise Hard(f'{len(BACKOFF)} retries without progress; last: {reason}')
            self.sleep(BACKOFF[retries - 1], slug, f'transfer error, retry {retries} waits')

    def kill_verify(self, p, slug):
        """verify-staged.sh runs in its own process group; also stop its target re-read (sha256sum keeps reading after its
        ssh client is gone). Locate by exact process name + one argument equal to the batch's sha file: the NUL-separated
        arguments are compared whole (no regex, no substring, a newline inside an argument stays inside it), never
        pkill -f. The script goes over stdin, the file name as its one argument."""
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        ssh(TARGET, f'bash -s -- {shlex.quote(f"{TARGET_WD}/{slug}.sha256")}', input=KILL_SHA, timeout=60)

    def do_verify(self, it):
        slug, mac = it['slug'], it['mac']
        expect = (it.get('bytes') or 0) / VERIFY_MBS / 1e6
        limit = 3 * expect + VERIFY_SLACK
        vlog = f'{QDIR}/{slug}.verify.log'
        for attempt in (1, 2):
            t0 = now()
            if attempt == 1:
                upd(slug, t_verify0=t0)
            upd(slug, note=f'verifying ({DST} re-read {gb(it.get("bytes"))}, ~{dur(expect)})')
            write_status()
            with open(vlog, 'a') as f:
                f.write(f'=== {stamp()} attempt {attempt}\n')
            timed_out = False
            with open(vlog, 'a') as f:
                p = subprocess.Popen([TOOL + '/verify-staged.sh', slug, mac], stdout=f, stderr=subprocess.STDOUT,
                                     env=tool_env(), start_new_session=True)
                try:
                    while True:
                        try:
                            rc = p.wait(timeout=POLL)
                            break
                        except subprocess.TimeoutExpired:
                            el = now() - t0
                            if el > limit:
                                self.kill_verify(p, slug)
                                rc, timed_out = p.wait(), True
                                break
                            upd(slug, note=f'verifying (attempt {attempt}, {dur(el)} of ~{dur(expect)})')
                            write_status()
                except Stop:
                    self.kill_verify(p, slug)
                    raise
            out = open(vlog).read().split('\n=== ')[-1]
            fails = [l for l in out.splitlines() if 'FAIL' in l or 'MISSING' in l]
            log(f'{slug}: verify attempt {attempt} rc={rc}{" (timed out after " + dur(limit) + ")" if timed_out else ""}')
            if rc == 0 and not timed_out:
                rows = next((l for l in out.splitlines() if l.startswith('rows:')), '')
                upd(slug, state='copied', t_verify1=now(), note='', verify_rows=rows)
                return
            reason = (f'timed out after {dur(limit)}' if timed_out
                      else ' | '.join(fails) or ' | '.join(out.splitlines()[-3:]))
            if fails or attempt == 2:
                raise Hard(f'verify failed (attempt {attempt}): {reason[:300]}')
            log(f'{slug}: verify failed without a FAIL line (transport?) --- retrying once: {reason[:200]}')
            self.sleep(BACKOFF[0], slug, 'verify interrupted (not a mismatch), retry waits')

    def notify_done(self, slug):
        st = load()
        it = find(st, slug)
        took = (it.get('t_copy1') or 0) - (it.get('t_copy0') or 0)
        vt = (it.get('t_verify1') or 0) - (it.get('t_verify0') or 0)
        avg = (it.get('ok_bytes') or 0) / took / 1e6 if took > 0 else 0
        gone = f'; {it["gone"]} file(s) deleted on the {SRC} before they could be copied (listed in .gone)' if it.get('gone') else ''
        nxt = next((i for i in st['items'] if i['state'] in PENDING and i['slug'] != slug), None)
        q = (f'Next in the queue: {nxt["name"]} (~{gb(nxt.get("est_bytes"))}, ~{dur((nxt.get("est_bytes") or 0) / COPY_MBS / 1e6)})'
             if nxt else 'Nothing else in the queue.')
        msg = (f'Copy {SRC} -> {DST}: {it["name"]} copied and verified ({it.get("ok_files")} files / {gb(it.get("ok_bytes"))}, '
               f'copy {dur(took)} at {avg:.0f} MB/s, verify {dur(vt)}{gone}).\n'
               f'Next step: generate, dry-run and trial the import, then mark it ready (copyq.py ready).\n{q}')
        notify(f'copy:done:{slug}', 'copy-done', msg)

    def fail(self, it, reason):
        slug = it['slug']
        st = find(load(), slug)
        ps = self.push_state(slug)
        stopped = ps is not None and not (ps['active'] and ps['current'] == slug)
        if ps and ps['active'] and ps['current'] == slug:
            stopped = self.stop_push()
        parts = self.target_parts()
        errors = st.get('errors', 0) + 1
        upd(slug, state='error', err_phase=st['state'], error=reason, errors=errors, t_error=now(),
            launched=None if stopped else st.get('launched'), note='')
        log(f'{slug}: ERROR in {st["state"]}: {reason} (push stopped={stopped}, {DST} .part={parts})')
        safe = (f'{SRC} push {"stopped" if stopped else f"may still be running ({SRC} unreachable, cannot confirm)"}, '
                f'{DST} partial files: {parts}; the {st.get("ok_files", 0)}/{st.get("files", "?")} files already copied '
                f'are kept, the copy resumes from there once fixed')
        msg = (f'Copy {SRC} -> {DST} stopped on an error ({st["name"]}, {st["state"]}, {ts()}):\n{reason[:400]}\n'
               f'{safe}. Needs a human (copyq.py retry {slug} once fixed).\nDetails: {QDIR}/runner.log')
        notify(f'copy:error:{slug}:{errors}', 'copy-error', msg)

    def main(self):
        os.makedirs(QDIR, mode=0o700, exist_ok=True)
        lk = open(QDIR + '/runner.lock', 'w')
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print('another runner holds the lock')
            return 1

        def term(sig, frm):
            raise Stop()
        signal.signal(signal.SIGTERM, term)
        log(f'runner start (pid {os.getpid()}, push env {PUSH_ENV}, test_day {TEST_DAY or "-"})')
        try:
            while True:
                st = load()
                if st.get('paused'):
                    log(f'paused ({st.get("pause_reason") or "-"}) --- exiting')
                    return 0
                errs = [i['slug'] for i in st['items'] if i['state'] == 'error']
                if errs:
                    log(f'queue stopped on error: {" ".join(errs)} --- exiting (copyq.py retry <slug>)')
                    return 0
                it = (next((i for i in st['items'] if i['state'] in ('listing', 'copying', 'verifying')), None)
                      or next((i for i in st['items'] if i['state'] == 'queued'), None))
                if not it:
                    log('queue empty --- exiting')
                    return 0
                try:
                    if it['state'] in ('queued', 'listing'):
                        self.do_list(it)
                    elif it['state'] == 'copying':
                        self.do_copy(it)
                    elif it['state'] == 'verifying':
                        self.do_verify(it)
                        self.notify_done(it['slug'])
                except Hard as e:
                    self.fail(find(load(), it['slug']), str(e))
                finally:
                    write_status()
        except Stop:
            log(f'SIGTERM --- exiting (the {SRC} push, if any, keeps running; the next runner adopts it)')
            return 0
        finally:
            write_status()


# ---------------------------------------------------------------- notifications
def notify(key, event, msg):
    """One call of the site's hook: NOTIFY_CMD <event-key> <message>, env NOTIFY_EVENT=<event>; exit 0 = delivered.
    The key is stable per event (safe as an idempotency key); retries and dedup are the hook's job."""
    if not NOTIFY_CMD:
        log(f'notify {key}: no NOTIFY_CMD configured --- {msg[:200]!r}')
        return False
    try:   # a missing / non-executable hook must not crash the runner (it would crash-loop with nobody notified)
        rc, out, err = run([NOTIFY_CMD, key, msg], timeout=300, env=dict(os.environ, NOTIFY_EVENT=event))
    except OSError as e:
        rc, out, err = 127, '', f'cannot run NOTIFY_CMD: {e}'
    log(f'notify {key} rc={rc} {(out + err).strip()[-300:]}')
    return rc == 0


# ---------------------------------------------------------------- rendering
STATE_LABEL = {'queued': 'queued', 'listing': 'listing', 'copying': 'copying', 'verifying': 'verifying',
               'copied': 'copied, import not prepared yet', 'ready': 'ready for its window', 'imported': 'imported',
               'error': 'STOPPED ON AN ERROR'}


def render(st, live=True):
    act = runner_active() if live else None
    out = [f'Copy queue {SRC} -> {DST} --- {datetime.datetime.now().strftime("%m-%d %H:%M:%S")}',
           f'runner ({RUNNER_UNIT}): {"running" if act else "not running" if act is not None else "?"}'
           + (f' | paused: {st.get("pause_reason") or "-"}' if st.get('paused') else '')]
    for it in st['items']:
        s = it['state']
        line = f'- [{STATE_LABEL.get(s, s)}] {it["name"]} ({it["slug"]}{", " + it["filter"] if it.get("filter") else ""})'
        if s in ('listing', 'copying', 'verifying') or (s == 'error' and it.get('files')):
            line += f': {it.get("ok_files", 0)}/{it.get("files", "?")} files, {gb(it.get("ok_bytes"))} / {gb(it.get("bytes"))}'
            if s == 'copying' and it.get('rate'):
                line += f', {it["rate"]:.0f} MB/s'
                if it.get('eta'):
                    line += f', done ~{ts(it["eta"])}'
        elif s == 'queued':
            line += f': ~{gb(it.get("est_bytes"))} / {it.get("est_files", "?")} files, copy ~{dur((it.get("est_bytes") or 0) / COPY_MBS / 1e6)}'
        elif s in ('copied', 'ready', 'imported'):
            line += f': {it.get("ok_files")} files / {gb(it.get("ok_bytes"))}, verified {ts(it.get("t_verify1"))}'
            if s == 'ready':
                line += f'; {it.get("ready_note", "")}'
        if it.get('gone'):
            line += f'; {it["gone"]} deleted on the {SRC} before the copy'
        if it.get('note'):
            line += f' ({it["note"]})'
        if s == 'error':
            line += f'\n    error ({it.get("err_phase")}, {ts(it.get("t_error"))}): {it.get("error")}'
        if it.get('updated') and s in ('listing', 'copying', 'verifying') and now() - it['updated'] > 5 * POLL + 120:
            line += f'\n    WARNING: state not updated for {dur(now() - it["updated"])}'
        out.append(line)
    if not st['items']:
        out.append('(queue empty)')
    return '\n'.join(out) + '\n'


def observe_status():
    p = IMPORT + '/observe.list'
    if not os.path.exists(p):
        return []
    today = datetime.datetime.now().strftime('%Y-%m-%d')
    res = []
    for line in read_lines(p):
        parts = line.split()
        if not parts or parts[0].startswith('#') or len(parts) < 2 or today > parts[1]:
            continue
        slug, last = parts[0], parts[1]
        logf = f'{IMPORT}/{slug}/observe.log'
        blk = open(logf).read().split('\n=== ')[-1] if os.path.exists(logf) else ''
        first = blk.split('\n', 1)[0]
        fresh = today in first[:40]
        okay = fresh and re.search(r'^PASS', blk, re.M) and not re.search(r'^FAIL|FLAG PRESENT', blk, re.M)
        res.append((slug, last, 'ok' if okay else ('stale' if not fresh else 'problem')))
    return res


def source_front(macs):
    """(free bytes on the source's recording volume /srv, oldest remaining start ms, file count) for these cameras;
    None if unreachable."""
    macs = sorted(m for m in macs if re.fullmatch(r'[0-9A-F]{12}', m))
    if not macs:
        return None
    sql = ('select coalesce(min(r.start), 0), count(*) from "recordingFiles" r join cameras c on c.id = r."cameraId" '
           'where not r.free and c.mac in (' + ','.join(f"'{m}'" for m in macs) + ');\n')
    rc, out, _ = ssh(SOURCE, "df -B1 --output=avail /srv | tail -1; psql -U postgres -p 5433 -h 127.0.0.1 -d unifi-protect "
                          "-X -At -F '|' -v ON_ERROR_STOP=1 -f -", input=sql, timeout=120)
    lines = out.split()
    if rc != 0 or len(lines) != 2 or not lines[0].isdigit():
        return None
    oldest, n = lines[1].split('|')
    return int(lines[0]), int(oldest), int(n)


def summary(send=True):
    st = load()
    items = st['items']
    pend = [i for i in items if i['state'] in PENDING]
    errs = [i for i in items if i['state'] == 'error']
    copied = [i for i in items if i['state'] == 'copied']
    ready = [i for i in items if i['state'] == 'ready']
    obs = observe_status()
    if not (pend or errs or copied or ready or obs):
        print('nothing to report')
        return 0
    act = runner_active()
    L = [f'Recording import {SRC} -> {DST} --- daily summary ({datetime.datetime.now().strftime("%m-%d %H:%M")})']
    if errs:
        for i in errs:
            L.append(f'ERROR: copy stopped: {i["name"]} ({ts(i.get("t_error"))}): {(i.get("error") or "")[:200]} --- needs a human')
    elif pend:
        cur = next((i for i in pend if i['state'] != 'queued'), None)
        if st.get('paused'):
            L.append(f'Copy paused ({st.get("pause_reason") or "-"}), {len(pend)} camera(s) still queued')
        elif not act:
            L.append(f'WARNING: the copy runner is not running but {len(pend)} camera(s) are queued --- needs a look')
        elif cur:
            s = f'Copy: {cur["name"]} {STATE_LABEL[cur["state"]]}, {cur.get("ok_files", 0)}/{cur.get("files", "?")} files, ' \
                f'{gb(cur.get("ok_bytes"))} / {gb(cur.get("bytes"))}'
            if cur['state'] == 'copying' and cur.get('eta'):
                s += f', {cur.get("rate", 0):.0f} MB/s, done ~{ts(cur["eta"])}'
            if cur.get('updated') and now() - cur['updated'] > 5 * POLL + 120:
                s += f' (WARNING: state not updated for {dur(now() - cur["updated"])})'
            L.append(s)
        q = [i for i in pend if i['state'] == 'queued']
        if q:
            tot = sum(i.get('est_bytes') or 0 for i in q)
            L.append(f'Queued: {", ".join(i["name"] for i in q)} (~{gb(tot)}, copy ~{dur(tot / COPY_MBS / 1e6)})')
    if copied:
        L.append(f'Copied, import not prepared yet: {", ".join(i["name"] for i in copied)}')
    if ready:
        L.append('Ready for a window: ' + '; '.join(f'{i["name"]} ({i.get("ready_note", "")})' for i in ready))
    todo = sorted({i['mac'] for i in pend + errs})
    fr = source_front(todo) if todo else None
    if todo and fr is None:
        L.append(f'{SRC}: free space / oldest file unknown (unreachable?)')
    elif fr:
        avail, oldest, n = fr
        day = datetime.datetime.now().strftime('%Y-%m-%d')
        od = datetime.datetime.fromtimestamp(oldest / 1000).strftime('%Y-%m-%d') if oldest else '-'
        prev = st.get('source_front') or {}
        s = f'{SRC}: {gb(avail)} free; oldest file of the cameras still to copy: {od} ({n} files)'
        if prev.get('macs') == todo and prev.get('day') != day:
            if oldest > prev.get('oldest', 0) or n < prev.get('n', 0):
                s += f' --- WARNING: fewer than on {prev["day"][5:]} (oldest {prev.get("od")}, {prev.get("n")} files): the {SRC} has started deleting the oldest recordings'
            else:
                s += f', same as on {prev["day"][5:]} (nothing deleted yet)'
        L.append(s)
        if send and prev.get('day') != day:
            with locked() as s2:
                s2['source_front'] = {'day': day, 'macs': todo, 'oldest': oldest, 'od': od, 'n': n, 'avail': avail}
    if obs:
        bad = [o for o in obs if o[2] != 'ok']
        last = max(o[1] for o in obs)
        if not bad:
            L.append(f'Observation: {len(obs)} camera(s) (until {last[5:]}): all checks passed this morning')
        else:
            L.append(f'Observation: {len(obs)} camera(s): ' + ', '.join(f'{o[0]} {"check did not run today" if o[2] == "stale" else "PROBLEM"}' for o in bad)
                     + ' (see observe.log)')
    msg = '\n'.join(L)
    print(msg)
    if send:
        day = datetime.datetime.now().strftime('%Y-%m-%d')
        ok = notify(f'copy:summary:{day}', 'copy-summary', msg)
        return 0 if ok or not NOTIFY_CMD else 1     # no hook configured: logged only, not a failure
    return 0


# ---------------------------------------------------------------- CLI
def idmap_name(mac):
    if not IDMAP or not os.path.exists(IDMAP):
        return None
    for line in open(IDMAP):
        p = line.rstrip('\n').split('\t')
        if p and p[0] == mac:
            return p[1].strip()
    return None


def estimate(macs, fs):
    rows = {}
    if not macs:
        if not IDMAP:
            sys.exit('give the camera MACs (no IDMAP configured)')
        macs = [l.split('\t')[0] for l in open(IDMAP) if l.strip()]
    for mac in macs:
        lines = rows_now(mac)
        if fs:
            lines = apply_filter(lines, mac, fs)
        b = sum(int(l.split('|')[3]) for l in lines)
        oldest = min((int(l.split('|')[6]) for l in lines), default=None)
        rows[mac] = (len(lines), b, oldest)
    res = sorted(rows.items(), key=lambda kv: kv[1][1])
    for mac, (n, b, old) in res:
        o = datetime.datetime.fromtimestamp(old / 1000).strftime('%Y-%m-%d') if old else '-'
        print(f'{mac}\t{idmap_name(mac) or "?"}\t{n}\t{b}\t{gb(b)}\toldest {o}\tcopy {dur(b / COPY_MBS / 1e6)}'
              f'\tverify {dur(b / VERIFY_MBS / 1e6)}')
    return 0


def main(argv):
    if not argv:
        print(__doc__)
        return 64
    cmd, args = argv[0], argv[1:]
    os.makedirs(QDIR, mode=0o700, exist_ok=True)

    def opt(name, default=None):
        if name in args:
            i = args.index(name)
            v = args[i + 1]
            del args[i:i + 2]
            return v
        return default

    if cmd == 'run':
        check_mode()
        return Runner().main()
    if cmd == 'add':
        name, fs = opt('--name'), opt('--filter', '')
        slug, mac = args
        check_mode(slug)
        if not SLUG_RE.match(slug) or not re.fullmatch(r'[0-9A-F]{12}', mac):
            sys.exit('bad slug / mac')
        parse_filter(fs)
        name = name or idmap_name(mac)
        if not name:
            sys.exit(f'{mac} not in the camera id map ({IDMAP or "none configured"}): give --name')
        lines = rows_now(mac)
        if fs:
            lines = apply_filter(lines, mac, fs)
        with locked() as st:
            if find(st, slug):
                sys.exit(f'{slug} already in the queue')
            st['items'].append({'slug': slug, 'mac': mac, 'name': name, 'filter': fs, 'state': 'queued',
                                'added': now(), 'est_files': len(lines),
                                'est_bytes': sum(int(l.split('|')[3]) for l in lines), 'gone': 0, 'errors': 0})
        print(f'queued {slug} ({name}{", " + fs if fs else ""}): {len(lines)} files, '
              f'{gb(sum(int(l.split("|")[3]) for l in lines))}')
        write_status()
        return 0
    if cmd == 'status':
        print(render(load()), end='')
        return 0
    if cmd == 'pause':
        reason = opt('--reason', 'pause')
        with locked() as st:
            st['paused'], st['pause_reason'] = True, f'{reason} ({ts()})'
        run(['systemctl', 'stop', RUNNER_UNIT], timeout=120)
        r = Runner()
        ps = r.push_state('-')
        stopped = r.stop_push() if ps and ps['active'] else ps is not None
        with locked() as st:
            for it in st['items']:
                if it['state'] == 'copying' and it.get('launched'):
                    it['launched'] = None
                    it['note'] = 'paused: push stopped'
        print(f'paused; {SRC} push stopped={stopped}; {DST} .part={r.target_parts()}')
        write_status()
        return 0 if stopped else 1
    if cmd == 'resume':
        with locked() as st:
            st['paused'], st['pause_reason'] = False, ''
        rc, out, err = run(['systemctl', 'start', RUNNER_UNIT], timeout=60)
        print(f'resume: systemctl start rc={rc} {err.strip()}')
        return rc
    if cmd == 'retry':
        slug, = args
        with locked() as st:
            it = find(st, slug)
            if not it or it['state'] != 'error':
                sys.exit(f'{slug} is not in error')
            it['state'], it['error'], it['retries'], it['note'] = it.get('err_phase') or 'queued', '', 0, ''
            if it['state'] == 'listing':
                it['state'] = 'queued'
        rc, out, err = run(['systemctl', 'start', RUNNER_UNIT], timeout=60)
        print(f'{slug} back to {it["state"]}; systemctl start rc={rc} {err.strip()}')
        return rc
    if cmd == 'ready':
        slug, note = args[0], ' '.join(args[1:])
        with locked() as st:
            it = find(st, slug)
            if not it or it['state'] not in ('copied', 'ready'):
                sys.exit(f'{slug} is not copied')
            it['state'], it['ready_note'], it['t_ready'] = 'ready', note, now()
        notify(f'copy:ready:{slug}', 'copy-ready', f'Recording import: {it["name"]} is prepared and ready for its window ({note}).')
        write_status()
        return 0
    if cmd == 'imported':
        slug, = args
        with locked() as st:
            it = find(st, slug)
            if not it or it['state'] not in ('copied', 'ready'):
                sys.exit(f'{slug} is not copied / ready')
            it['state'], it['t_imported'] = 'imported', now()
        write_status()
        return 0
    if cmd == 'drop':
        slug, = args
        with locked() as st:
            it = find(st, slug)
            if not it or it['state'] not in ('queued', 'error'):
                sys.exit(f'{slug} is neither queued nor in error')
            if it['state'] == 'error' and it.get('launched'):
                sys.exit(f'{slug}: its push may still run on the {SRC} (launched, never confirmed stopped) --- pause first')
            st['items'].remove(it)
        write_status()
        return 0
    if cmd == 'summary':
        return summary(send='--print' not in args)
    if cmd == 'estimate':
        fs = opt('--filter', '')
        return estimate(args, fs)
    print(__doc__)
    return 64


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
