#!/usr/bin/env python3
"""siteconf.py --- the site configuration shared by every tool on the controller.

Everything that belongs to one installation (hosts, paths on both consoles, names of the units, schemas and the
container this tool creates, the notification hook) lives in one file, site.env. See site.env.example.

  File      $IMPORT_SITE, else ~/.config/footage-heist/site.env. A missing file is an error: nothing falls back to
            built-in host or path guesses.
  Format    KEY=VALUE lines, '#' comments, optional surrounding double quotes, no shell expansion. Unknown keys are
            an error (typos must not silently fall back to a default).
  Override  an environment variable with the same name as a key wins over the file (tests, one-off runs).
  Values    validated here, because they end up inside SQL, shell command lines and unit names.

Python tools: `import siteconf; S = siteconf.load(); S['TARGET_SSH']`. Bash tools source lib-site.sh, which runs
`siteconf.py shell` (prints the resolved values as shell assignments). `siteconf.py show` prints them for a human.
"""
import os
import re
import shlex
import sys

PROJECT = 'footage-heist'
DEFAULT_PATH = os.path.join('~', '.config', PROJECT, 'site.env')

_NAME = r'[a-z][a-z0-9-]{0,30}[a-z0-9]'
_HOST = r'[A-Za-z0-9_][A-Za-z0-9@._:\[\]-]*'
_PATH = r'/[A-Za-z0-9/._@+-]*'
_LABEL = r'[A-Za-z0-9][A-Za-z0-9-]{0,19}'

# key: (validation regex, default) --- default None = no default (required by the tools that use it);
# a callable default is computed from the other resolved values
KEYS = {
    # names this tool creates; keep them stable once something was imported (the ledger lives in the target's DB)
    'NAME_PREFIX':   (_NAME, PROJECT),                       # window units, psql application_name, guard drop-in
    'LEDGER_SCHEMA': (r'[a-z][a-z0-9_]{0,22}', lambda v: v['NAME_PREFIX'].replace('-', '_')),
    'PG_CONTAINER':  (r'[A-Za-z0-9][A-Za-z0-9_.-]{0,62}', lambda v: v['NAME_PREFIX'] + '-pg'),
    'PUSH_UNIT':     (r'[A-Za-z0-9][A-Za-z0-9_.-]{0,62}', lambda v: v['NAME_PREFIX'] + '-push'),
    'SOURCE_NAME':   (_LABEL, 'source'),                      # how messages call the two consoles
    'TARGET_NAME':   (_LABEL, 'target'),
    # controller
    'IMPORT_DIR':    (_PATH, None),                           # batch dirs, copy lists, queue state (mode 700)
    'IDMAP':         (_PATH, ''),                             # camera id map TSV (new-batch.sh, copyq.py names)
    'AI_SRC':        (r'[A-Za-z0-9_-]*', ''),                 # AI processor id on the source / on the target (new-batch.sh)
    'AI_DST':        (r'[A-Za-z0-9_-]*', ''),
    'NOTIFY_CMD':    (r'(' + _PATH + r')?', ''),              # notification hook (see README "Notifications")
    'TOP_TEMP_JOURNAL_TAG': (r'[A-Za-z0-9_.@-]*', ''),        # optional: journal tag carrying "hdd_temp=<n>C"
    'UNIT_MODEL':    (r'(' + _PATH + r')?', ''),              # unit graph model (default: tool/unit-model.txt)
    # source console
    'SOURCE_SSH':    (_HOST, None),                           # ssh destination (user@host or an ssh_config alias)
    'SOURCE_WORKDIR': (_PATH, None),                         # root-only dir on the source (ubv-push.py, key, ledger)
    # target console
    'TARGET_SSH':    (_HOST, None),
    'TARGET_URL':    (r'(https://[A-Za-z0-9.:\[\]-]+)?', ''),  # https://<host> of the target's web API
    'TARGET_TLS_PIN_FILE':    (r'(' + _PATH + r')?', ''),     # curl --pinnedpubkey value (sha256//...) in a file
    'TARGET_API_HEADER_FILE': (r'(' + _PATH + r')?', ''),     # curl -K file with the integration API key header
    'TARGET_LOGIN_FILE':      (r'(' + _PATH + r')?', ''),     # JSON body for the console login (local admin)
    'TARGET_STAGING': (_PATH, None),                          # staging dir on the SAME mount as Protect's video dir
    'TARGET_WORKDIR': (_PATH, None),                         # root-only dir on the target (batches, window logs)
    'TARGET_PROTECT_DIR': (r'/srv/unifi-protect', '/srv/unifi-protect'),  # fixed: extract.sql writes this path into the rows
    'PUSH_DEST':     (_HOST, lambda v: v['TARGET_SSH']),      # the target as the SOURCE console reaches it
    # copy channel
    'COPY_MODE':     (r'ssh|tcp', 'ssh'),                     # tcp: trusted LAN only (README "Copy channel")
    'COPY_RATE_MBPS': (r'[1-9][0-9]{0,4}', '80'),
    'COPY_MARGIN':   (r'[0-9]+(\.[0-9]+)?(e[0-9]+)?', '1e12'),  # bytes kept free on the target staging volume
}


class SiteError(Exception):
    pass


def site_path():
    return os.path.expanduser(os.environ.get('IMPORT_SITE') or DEFAULT_PATH)


def parse(path):
    """KEY=VALUE file -> dict (no expansion)."""
    if not os.path.isfile(path):
        raise SiteError(f'no site configuration at {path} (set IMPORT_SITE, see site.env.example)')
    out = {}
    with open(path) as f:
        for n, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith('#'):
                continue
            m = re.fullmatch(r'([A-Z][A-Z0-9_]*)=(.*)', s)
            if not m:
                raise SiteError(f'{path}:{n}: not a KEY=VALUE line')
            k, v = m.group(1), m.group(2)
            if len(v) >= 2 and v[0] == v[-1] == '"':
                v = v[1:-1]
            if k not in KEYS:
                raise SiteError(f'{path}:{n}: unknown key {k}')
            if k in out:
                raise SiteError(f'{path}:{n}: {k} set twice')
            out[k] = v
    return out


class Site(dict):
    """Resolved values. S[key] -> str ('' = not configured); S.need(key) raises if empty."""

    def __init__(self, vals, path, filevals):
        super().__init__(vals)
        self.path = path
        self.filevals = filevals

    def need(self, *keys):
        missing = [k for k in keys if not self.get(k)]
        if missing:
            raise SiteError(f'{", ".join(missing)} not set in {self.path}')
        return self[keys[0]] if len(keys) == 1 else [self[k] for k in keys]

    @property
    def target_label(self):        # names the generated load-<label>.sql
        return self['TARGET_NAME'].lower()


def load(path=None, env=None):
    path = path or site_path()
    env = os.environ if env is None else env
    filevals = parse(path)
    vals = {}
    pending = list(KEYS)
    for _ in range(len(KEYS) + 1):             # callable defaults may depend on each other: resolve until stable
        left = []
        for k in pending:
            pat, default = KEYS[k]
            if k in env:
                v = env[k]
            elif k in filevals:
                v = filevals[k]
            elif callable(default):
                try:
                    v = default(vals)
                except KeyError:
                    left.append(k)
                    continue
            else:
                v = default if default is not None else ''
            vals[k] = v
        if not left:
            break
        pending = left
    else:
        raise SiteError('unresolvable defaults: ' + ', '.join(pending))
    for k, v in vals.items():
        src = "environment" if k in env else path
        if v == '' and (k in env or k in filevals) and KEYS[k][1] not in (None, ''):
            raise SiteError(f'{k} is empty (from {src}): remove it to use the default')
        if v != '' and not re.fullmatch(KEYS[k][0], v):
            raise SiteError(f'{k}={v!r} is not valid (from {src})')
    # 'pg' too: every batch's staging schema is <LEDGER_SCHEMA>_<slug>, and pg_* is PostgreSQL's
    if vals['LEDGER_SCHEMA'] in ('public', 'stage', 'information_schema', 'pg') or vals['LEDGER_SCHEMA'].startswith('pg_'):
        raise SiteError(f"LEDGER_SCHEMA={vals['LEDGER_SCHEMA']!r} is reserved (Protect's own schema, the extract stage, or PostgreSQL's)")
    if vals['TARGET_NAME'].lower() == 'docker':
        raise SiteError('TARGET_NAME must not be "docker" (that label is taken by the local test load)')
    return Site(vals, path, filevals)


def load_or_exit():
    try:
        return load()
    except SiteError as e:
        sys.exit(f'site configuration: {e}')


def main(argv):
    cmd = argv[0] if argv else 'show'
    try:
        S = load()
    except SiteError as e:
        print(f'site configuration: {e}', file=sys.stderr)
        return 64
    if cmd == 'shell':
        print(f'SITE_FILE={shlex.quote(S.path)}')
        for k in KEYS:
            print(f'{k}={shlex.quote(S[k])}')
        print(f'TARGET_LABEL={shlex.quote(S.target_label)}')
        return 0
    if cmd == 'show':
        print(f'# {S.path}')
        for k in KEYS:
            src = 'env' if k in os.environ else 'file' if k in S.filevals else 'default'
            print(f'{k}={S[k]}  # {src}')
        return 0
    print('usage: siteconf.py [show|shell]', file=sys.stderr)
    return 64


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
