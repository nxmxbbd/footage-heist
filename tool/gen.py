#!/usr/bin/env python3
"""gen.py <batch_dir> --- generate load / apply / rollback / verify SQL for one import batch.

Reads <batch_dir>/batch.env and the column lists + row counts of schema "stage" in the controller's disposable
source DB (docker container PG_CONTAINER, db src), exports every stage table as COPY text into <batch_dir>/data/,
and writes <batch_dir>/sql/{load-docker,load-<target>,apply,rollback,verify}.sql. Names and paths come from the
site configuration (siteconf.py).

load.sql takes psql var :datadir (directory holding the .copy files as seen by the target psql).
Every INSERT names its columns explicitly; load.sql first checks the target's public column lists
match the ones captured here and aborts otherwise.
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import siteconf  # noqa: E402

SITE = siteconf.load_or_exit()
CONTAINER = SITE['PG_CONTAINER']
LS = SITE['LEDGER_SCHEMA']           # ledger schema on the target (shared by all batches); staging = <LS>_<slug>
VALIDATED_VERSION = '7.3.70'   # the Protect version this tool's behaviour was validated on; apply refuses any other
                               # unless gen.py ran with --unvalidated-version <that exact version>
USAGE = ('usage: gen.py <batch_dir> [--unvalidated-version X.Y.Z]\n'
         '       gen.py --accepted-version <batch_dir>       (the Protect version this batch\'s apply.sql accepts)\n'
         '       gen.py --refresh-verify <batch_dir>         (an imported batch\'s verify.sql: this gen.py\'s recordingFiles check)\n'
         '       gen.py --version-guard-sql [--unvalidated-version X.Y.Z]   (the version check alone, for tests)')


def unvalidated_arg(args):
    """--unvalidated-version X.Y.Z out of args (removed from the list); None if absent. Refuses the validated version."""
    if '--unvalidated-version' not in args:
        return None
    i = args.index('--unvalidated-version')
    v = args[i + 1] if i + 1 < len(args) else ''
    del args[i:i + 2]
    if not re.fullmatch(r'[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,4}', v):
        sys.exit(f'--unvalidated-version needs an exact version like 7.3.71 (got {v!r})')
    if v == VALIDATED_VERSION:
        sys.exit(f'{v} is the validated version: drop --unvalidated-version')
    return v


def version_guard(unvalidated):
    """The version check inside apply.sql's first DO block: the validated version, or exactly the version given with
    --unvalidated-version."""
    cur = "(select string_agg(distinct version, ',') from public.nvrs)"
    if unvalidated is None:
        return (f"  if {cur} is distinct from '{VALIDATED_VERSION}' then\n"
                f"    raise exception 'Protect version % is not the validated {VALIDATED_VERSION}', {cur};\n"
                f"  end if;")
    return (f"  if {cur} is distinct from '{unvalidated}' then\n"
            f"    raise exception 'Protect version % is not {unvalidated}, the unvalidated version this batch was generated for', {cur};\n"
            f"  end if;")

# ---- verify.sql
# On a camera that has no native file of these types the recorder continues the imported one: it moves that row's end
# forward and keeps size (preallocated), start, name, folder (seen on a thumbnails file the first day after a window;
# the thumbnails imported in it still served). verify.sql reports that as INFO; rollback.sql still refuses on it.
RF_CONTINUED_TYPES = ('thumbnails', 'timelapse')


def rf_check_sql_v1(ls, sch, slug):
    """verify.sql's recordingFiles check as gen.py wrote it before RF_CONTINUED_TYPES (any change a FAIL): the exact
    text --refresh-verify replaces in a batch generated then."""
    return f"""select case when count(*) = 0 then 'PASS' else 'FAIL' end || ' imported recordingFiles unchanged since import (changed: ' || count(*) || ')'
from public."recordingFiles" p join {sch}."recordingFiles" s on s.id = p.id
where p.id in (select id from {ls}.ledger where batch = '{slug}' and tbl = 'recordingFiles')
  and (p."cameraId", p.folder, p.file, p.start, p."end", p.size, p.type, p.channel, p.free)
      is distinct from (s."cameraId", s.folder, s.file, s.start, s."end", s.size, s.type, s.channel, false);
"""


def utc_ms(col):
    return f"""to_char(to_timestamp({col} / 1000.0) at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS"Z"')"""


def rf_check_sql(ls, sch, slug):
    """verify.sql's check that every imported recordingFiles row is still the imported file. A changed row is
    'continued' --- one INFO line naming the file and its end before / after, not a FAIL --- only when it is a
    RF_CONTINUED_TYPES file whose end is later than imported and every other compared column (camera, folder, file,
    start, size, type, channel, free = false) is unchanged. Anything else is a FAIL: a rotating file's end, size, an
    earlier or missing end, free, ...; a vanished row fails the present check."""
    types = ', '.join(f"'{t}'" for t in RF_CONTINUED_TYPES)
    return f"""-- imported recordingFiles still the imported files; a {' / '.join(RF_CONTINUED_TYPES)} file the recorder continued
-- (later end, every other column unchanged) is an INFO line, any other change a FAIL
with d as (
  select p.type, p.file, s."end" as imported_end, p."end" as now_end,
         coalesce(s.type in ({types}) and p."end" > s."end"
                  and (p."cameraId", p.folder, p.file, p.start, p.size, p.type, p.channel, p.free)
                      is not distinct from (s."cameraId", s.folder, s.file, s.start, s.size, s.type, s.channel, false), false) as continued
  from public."recordingFiles" p join {sch}."recordingFiles" s on s.id = p.id
  where p.id in (select id from {ls}.ledger where batch = '{slug}' and tbl = 'recordingFiles')
    and (p."cameraId", p.folder, p.file, p.start, p."end", p.size, p.type, p.channel, p.free)
        is distinct from (s."cameraId", s.folder, s.file, s.start, s."end", s.size, s.type, s.channel, false))
select line from (
  select 0 k, '' f, case when count(*) filter (where not continued) = 0 then 'PASS' else 'FAIL' end
         || ' imported recordingFiles unchanged since import (changed: ' || count(*) filter (where not continued)
         || '; continued by the recorder: ' || count(*) filter (where continued) || ')' as line from d
  union all
  select 1, file, 'INFO imported ' || type || ' file ' || file || ' continued by the recorder: end '
         || {utc_ms('imported_end')} || ' -> ' || {utc_ms('now_end')} from d where continued
) z order by k, f;
"""


def verify_sql(ls, sch, slug, counts, cam, ucam):
    """sql/verify.sql of a batch (read-only post-window checks; night.sh verify runs the target's copy)."""
    present = '\nunion all '.join(
        f"select '{t}' t, {counts[t]} want, (select count(*) from {ls}.ledger where batch = '{slug}' and tbl = '{t}') ledger, "
        f"(select count(*) from public.{q(t)} x where x.id in (select id from {ls}.ledger where batch = '{slug}' and tbl = '{t}')) present"
        for t in TABLES + ['detectionLabels'])
    return f"""-- verify.sql ({slug}) --- read-only post-window checks on the target
\\set ON_ERROR_STOP on
select tbl, count(*) from {ls}.ledger where batch = '{slug}' group by tbl order by tbl;
-- every imported row still present (startup purge / retention / cleanup jobs would show up here)
select case when ledger = present and ledger = want then 'PASS' else 'FAIL' end || ' present ' || t || ' ' || present || '/' || ledger || ' (batch ' || want || ')'
from ({present}) z;
{rf_check_sql(ls, sch, slug)}select case when count(*) = 0 then 'PASS' else 'FAIL' end || ' old camera id in imported events (' || count(*) || ')'
from public.events where id in (select id from {ls}.ledger where batch = '{slug}' and tbl = 'events') and to_jsonb(events)::text like '%{cam}%';
select 'info events on camera (all) ' || count(*) from public.events where "cameraId" = '{ucam}';
select 'info recordingFiles on camera ' || type || ' ch' || channel || ': ' || count(*) || ' earliest ' || to_timestamp(min(start) / 1000)
from public."recordingFiles" where "cameraId" = '{ucam}' and not free group by type, channel order by type, channel;
select 'info ' || id from {ls}.ledger where batch = '{slug}' and tbl like 'note:%';

"""


def batch_schema(env):
    """the batch's staging schema from batch.env: <LS> or <LS>_<slug> (exits otherwise)"""
    sch = env.get('SCHEMA', '')
    if not re.fullmatch(re.escape(LS) + r'(_[a-z0-9_]{1,40})?', sch) or len(sch) > 63:
        sys.exit(f"batch.env SCHEMA must be {LS} or {LS}_<slug> (got '{sch}')")
    return sch


def read_env(bdir):
    return dict(l.strip().split('=', 1) for l in open(os.path.join(bdir, 'batch.env')) if '=' in l)


def refresh_verify(bdir):
    """--refresh-verify: bring an imported batch's sql/verify.sql to this gen.py's recordingFiles check and change
    nothing else (a full gen.py run would need the batch back in the shared stage schema). The file must be this
    batch's verify.sql holding exactly one copy of the check as gen.py wrote it before (or already the current one:
    nothing to do)."""
    env = read_env(bdir)
    slug, sch = env['SLUG'], batch_schema(env)
    path = os.path.join(bdir, 'sql', 'verify.sql')
    text = open(path).read()
    if not text.startswith(f'-- verify.sql ({slug}) --- '):
        sys.exit(f'{path}: not the verify.sql of batch {slug}')
    old, new = rf_check_sql_v1(LS, sch, slug), rf_check_sql(LS, sch, slug)
    n_old, n_new = text.count(old), text.count(new)
    if (n_old, n_new) == (0, 1):
        print(f'{path}: already current')
        return
    if (n_old, n_new) != (1, 0):
        sys.exit(f'{path}: {n_old} earlier / {n_new} current recordingFiles checks for batch {slug} (schema {sch}, '
                 f'ledger {LS}), expected exactly one earlier one: regenerate the batch instead')
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        os.chmod(tmp, 0o600)
        f.write(text.replace(old, new))
    os.replace(tmp, path)
    print(f'{path}: recordingFiles check refreshed ({", ".join(RF_CONTINUED_TYPES)} continued by the recorder = INFO)')


# FK order for inserts (groups / labels are handled separately before these)
TABLES = ['recordingFiles', 'events', 'smartDetectObjects', 'smartDetectObjectAreas',
          'heatmaps', 'smartDetectTracks', 'ramDetections']
STAGED = ['smartDetectObjectGroups'] + TABLES + ['detectionLabels', 'labels']


def psql(sql):
    r = subprocess.run(['docker', 'exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-d', 'src', '-At', '-F', '|',
                        '-v', 'ON_ERROR_STOP=1', '-c', sql], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f'psql failed: {r.stderr}')
    return r.stdout


def cols(table):
    out = psql(f"select column_name from information_schema.columns where table_schema='stage' "
               f"and table_name='{table}' order by ordinal_position")
    return [c for c in out.split('\n') if c]


def q(c):
    return '"' + c.replace('"', '""') + '"'


def main():
    args = sys.argv[1:]
    if args[:1] == ['--version-guard-sql']:
        v = unvalidated_arg(args[1:])
        print(f'do $$ begin\n{version_guard(v)}\nend $$;')
        return
    if args[:1] == ['--refresh-verify'] and len(args) == 2:
        refresh_verify(os.path.abspath(args[1]))
        return
    if args[:1] == ['--accepted-version'] and len(args) == 2:
        # what the apply SQL that will run accepts; the manifest must agree (a regeneration that failed half-way can
        # leave them apart, and night.sh must refuse before anything stops rather than inside the window)
        try:
            sql = open(os.path.join(args[1], 'sql', 'apply.sql')).read()
            m = json.load(open(os.path.join(args[1], 'manifest.json')))
        except (OSError, ValueError) as e:
            sys.exit(f'cannot read the batch: {e}')
        found = re.findall(r"is distinct from '([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,4})' then\n    raise exception 'Protect version %", sql)
        if len(found) != 1:
            sys.exit(f'apply.sql: {len(found)} version checks found, expected 1')
        if found[0] != (m.get('unvalidated_version') or VALIDATED_VERSION):
            sys.exit(f"apply.sql accepts {found[0]}, manifest.json says {m.get('unvalidated_version') or VALIDATED_VERSION}: regenerate the batch")
        print(found[0])
        return
    unvalidated = unvalidated_arg(args)
    if len(args) != 1 or args[0].startswith('-'):
        sys.exit(USAGE)
    bdir = os.path.abspath(args[0])
    env = read_env(bdir)
    slug = env['SLUG']
    # staging schema of THIS batch (the ledger is shared in <LS>): every batch keeps its own staging tables,
    # because rollback.sql / verify.sql of an imported batch read its recordingFiles + groups staging long after.
    # Written into batch.env by new-batch.sh (<LS>_<slug>); the ledger schema itself is accepted as well (an
    # installation's first batches may have staged there).
    SCH = batch_schema(env)
    APP = f"{SITE['NAME_PREFIX']}-{slug}"     # psql application_name of apply / rollback (the window script waits on it)
    if len(APP.encode()) > 63:                # PostgreSQL keeps 63 bytes: a longer name would never match in pg_stat_activity
        sys.exit(f"application_name '{APP}' is longer than 63 bytes: shorten NAME_PREFIX or the slug")
    timeout = env.get('APPLY_TIMEOUT', '600s')    # statement_timeout of the apply transaction (scale with batch size)
    if not re.fullmatch(r'[1-9][0-9]{0,4}s', timeout):
        sys.exit(f"batch.env APPLY_TIMEOUT must look like 600s (got '{timeout}')")
    os.makedirs(os.path.join(bdir, 'data'), mode=0o700, exist_ok=True)
    os.makedirs(os.path.join(bdir, 'sql'), mode=0o700, exist_ok=True)

    # schema "stage" is shared by all batches (extract.sql replaces it): it must hold THIS batch's camera
    for t in ['events', 'recordingFiles', 'smartDetectObjects']:
        other = psql(f'select count(*) || \'/\' || count(*) filter (where "cameraId" <> \'{env["UCAM"]}\') from stage.{q(t)}').strip()
        total, wrong = other.split('/')
        if wrong != '0' or (t != 'smartDetectObjects' and total == '0'):
            sys.exit(f'stage.{t} does not hold batch {slug} (camera {env["UCAM"]}): {wrong} of {total} rows on another camera --- run extract.sh for this batch first')
    colmap = {t: cols(t) for t in STAGED}
    textcols = {}
    for t in STAGED:
        out = psql(f"select column_name, data_type from information_schema.columns where table_schema='stage' "
                   f"and table_name='{t}' and data_type in ('json','jsonb','text','character varying') and column_name <> 'id' "
                   f"order by ordinal_position")
        textcols[t] = [tuple(l.split('|')) for l in out.split('\n') if l]
    counts = {t: int(psql(f'select count(*) from stage.{q(t)}').strip()) for t in STAGED}
    # public column lists (target must match; detectionLabels / labels have staging-only shapes)
    pub = {t: [c for c in colmap[t]] for t in ['smartDetectObjectGroups'] + TABLES}
    pub['detectionLabels'] = [c for c in colmap['detectionLabels'] if c != 'label_names']

    # export COPY text
    for t in STAGED:
        clist = ', '.join(q(c) for c in colmap[t])
        path = os.path.join(bdir, 'data', f'{t}.copy')
        with open(path, 'wb') as f:
            r = subprocess.run(['docker', 'exec', CONTAINER, 'psql', '-U', 'postgres', '-d', 'src', '-v', 'ON_ERROR_STOP=1',
                                '-c', f'copy (select {clist} from stage.{q(t)}) to stdout'], stdout=f, stderr=subprocess.PIPE)
        if r.returncode != 0:
            sys.exit(f'export {t} failed: {r.stderr.decode()}')
        os.chmod(path, 0o600)
    manifest = {'slug': slug, 'schema': SCH, 'counts': counts, 'columns': colmap}
    if unvalidated:
        manifest['unvalidated_version'] = unvalidated     # night.sh refuses a window when the target runs another version
    json.dump(manifest, open(os.path.join(bdir, 'manifest.json'), 'w'), indent=1)
    # files.txt: <srv|ssd1>/<YYYY/MM/DD>/<file> for window-remote.sh (from the staged recordingFiles of the source rows)
    rows = psql("select r.file, s.folder from stage.\"recordingFiles\" r join public.\"recordingFiles\" s on s.id = r.id order by r.start")
    with open(os.path.join(bdir, 'files.txt'), 'w') as f:
        for l in rows.split('\n'):
            if l:
                file, folder = l.split('|'); parts = folder.split('/')
                f.write(f"{parts[1]}/{'/'.join(parts[4:7])}/{file}\n")

    colchecks = []
    for t, cl in pub.items():
        arr = ','.join("'" + c + "'" for c in cl)
        colchecks.append(f"""do $$ begin
  if (select array_agg(column_name::text order by ordinal_position) from information_schema.columns
      where table_schema = 'public' and table_name = '{t}') is distinct from array[{arr}]::text[] then
    raise exception 'target public.{t} columns differ from the staged batch';
  end if;
end $$;""")
    COLCHECK = '\n'.join(colchecks)
    targets = {'docker': f'/in/{os.path.basename(bdir)}/data', SITE.target_label: f"{SITE.need('TARGET_WORKDIR')}/{slug}/data"}
    mk_schema = '' if SCH == LS else f'create schema if not exists {SCH};\n'
    for tname, datadir in targets.items():
      S = []  # ---------------- load-<target>.sql
      S.append(f"""-- load-{tname}.sql ({slug}) --- stage the batch in schema {SCH} on the TARGET. Protect may keep running.
\\set ON_ERROR_STOP on
begin;
create schema if not exists {LS};
{mk_schema}create table if not exists {LS}.ledger (batch text not null, tbl text not null, id text not null,
  at timestamptz not null default now());
create table if not exists {LS}.ledger_history (batch text not null, tbl text not null, id text not null,
  at timestamptz not null, rolled_back_at timestamptz not null default now());
do $$ begin
  if exists (select 1 from {LS}.ledger where batch = '{slug}') then
    raise exception 'batch {slug} already has ledger rows on this target --- refuse to restage';
  end if;
end $$;
""")
      S.append(COLCHECK)   # target column check
      for t in STAGED:
          S.append(f'drop table if exists {SCH}.{q(t)};')
      for t in ['smartDetectObjectGroups'] + TABLES:
          S.append(f'create table {SCH}.{q(t)} (like public.{q(t)} including defaults);')
      S.append(f'create table {SCH}."detectionLabels" (like public."detectionLabels" including defaults);')
      S.append(f'alter table {SCH}."detectionLabels" add column label_names text[];')
      S.append(f'create table {SCH}.labels (name varchar(255), id varchar(255), "lastSeen" bigint, '
               '"createdAt" timestamptz, "updatedAt" timestamptz);')
      S.append('commit;')
      for t in STAGED:
          clist = ', '.join(q(c) for c in colmap[t])
          S.append(f"\\copy {SCH}.{q(t)} ({clist}) from '{datadir}/{t}.copy'")
      chk = ' union all '.join(f"select '{t}' t, count(*) n, {counts[t]} want from {SCH}.{q(t)}" for t in STAGED)
      S.append(f"""do $$ declare r record; begin
  for r in {chk} loop
    if r.n <> r.want then raise exception 'staged % rows % <> expected %', r.t, r.n, r.want; end if;
  end loop;
end $$;
select 'staged ok' as status;""")
      open(os.path.join(bdir, 'sql', f'load-{tname}.sql'), 'w').write('\n'.join(S) + '\n')

    # ---- group-reference rewrite (shared by the gen-time coverage check and apply.sql)
    # Works ONLY on temp working copies "w_<table>" and a temp mapping table m(src, dst) with src <> dst.
    # Exact tokens at whitelisted locations; anything else that still carries a renamed group id aborts (RESIDUAL).
    reft = TABLES + ['detectionLabels', 'labels']          # rows that may reference groups (group rows are never rewritten)
    def work_tables(schema):
        return '\n'.join(f'create temp table {q("w_" + t)} on commit drop as select * from {schema}.{q(t)};' for t in STAGED) + \
            '\ncreate index on "w_events" (id);'
    REWRITE = """update "w_smartDetectObjects" o set "smartDetectObjectGroupId" = m.dst from m where o."smartDetectObjectGroupId" = m.src;
update "w_smartDetectObjects" o
  set attributes = replace(o.attributes::text, '"_group_id":"' || m.src || '"', '"_group_id":"' || m.dst || '"')::json
  from m where o.attributes->>'_group_id' = m.src;
update w_labels l set name = 'group:' || m.dst from m where l.name = 'group:' || m.src;
update "w_detectionLabels" d
  set label_names = (select array_agg(coalesce('group:' || m.dst, u.x) order by u.o)
                     from unnest(d.label_names) with ordinality u(x, o) left join m on u.x = 'group:' || m.src)
  where d.label_names && (select array_agg('group:' || src) from m);
do $$ declare r record; begin
  for r in select distinct e.id, m.src, m.dst from "w_events" e
      cross join lateral json_array_elements(case when json_typeof(e.metadata->'detectedThumbnails') = 'array' then e.metadata->'detectedThumbnails' end) t
      cross join lateral json_array_elements_text(case when json_typeof(t->'labels') = 'array' then t->'labels' end) lab
      join m on lab = 'group:' || m.src loop
    update "w_events" set metadata = replace(metadata::text, '"group:' || r.src || '"', '"group:' || r.dst || '"')::json where id = r.id;
  end loop;
end $$;"""
    RESIDUAL = """do $$ declare n bigint; t text; begin
  if not exists (select 1 from m) then return; end if;
  foreach t in array array[%s] loop
    execute format('select count(*) from %%I x cross join lateral regexp_matches(to_jsonb(x)::text, ''[A-Za-z0-9_-]+'', ''g'') k(tok) join m on m.src = k.tok[1]', 'w_' || t) into n;
    if n > 0 then raise exception 'renamed group id still referenced in %% (%% tokens) --- reference form outside the rewrite whitelist', t, n; end if;
  end loop;
end $$;""" % ', '.join("'" + t + "'" for t in reft)

    # gen-time proof on THIS batch: rename every staged group to a sentinel; no group id token may survive the rewrite
    bad_ids = int(psql("select count(*) from stage.\"smartDetectObjectGroups\" where id !~ '^[A-Za-z0-9_-]+$'").strip())
    if bad_ids:
        sys.exit(f'{bad_ids} group ids outside [A-Za-z0-9_-] --- token rewrite not safe')
    chk_sql = '\n'.join(['begin;', work_tables('stage'),
                         "create temp table m on commit drop as select id as src, 'sentinel' || md5(id) as dst from stage.\"smartDetectObjectGroups\";",
                         REWRITE, RESIDUAL, 'rollback;'])
    r = subprocess.run(['docker', 'exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-d', 'src', '-X', '-q', '-v', 'ON_ERROR_STOP=1'],
                       input=chk_sql, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f'gen-time rewrite coverage check failed: {r.stderr}')
    print('rewrite coverage: every group reference in this batch is on the whitelist', file=sys.stderr)

    A = []  # ---------------- apply.sql
    A.append(f"""-- apply.sql ({slug}) --- ONE transaction; run only with unifi-protect STOPPED. Any conflict aborts everything.
-- Staging ({SCH}.*) is never modified: all decisions and rewrites happen on temp working copies w_*.
\\set ON_ERROR_STOP on
set application_name = '{APP}';
begin;
set local lock_timeout = '10s';
set local statement_timeout = '{timeout}';
do $$ begin
  if exists (select 1 from {LS}.ledger where batch = '{slug}') then raise exception 'batch {slug} already applied'; end if;
  if not exists (select 1 from public.cameras where id = '{env['UCAM']}' and "isAdopted") then
    raise exception 'target camera {env['UCAM']} missing or not adopted';
  end if;
{version_guard(unvalidated)}
end $$;
{COLCHECK}
do $$ declare r record; begin
  for r in {chk} loop
    if r.n <> r.want then raise exception 'staged % rows % <> expected %', r.t, r.n, r.want; end if;
  end loop;
end $$;
{work_tables(SCH)}

-- 1. face / vehicle groups: decide merges NOW (the target creates groups until the window)
create temp table gmap on commit drop as
  select s.id as src_id, s.type, s."externalId" as ext,
         (select d.id from public."smartDetectObjectGroups" d where s."externalId" is not null and d."externalId" = s."externalId") as ext_hit,
         (select d.id from public."smartDetectObjectGroups" d where d.id = s.id) as id_hit
  from "w_smartDetectObjectGroups" s;
do $$ begin
  if exists (select 1 from gmap where id_hit is not null and ext_hit is distinct from id_hit) then
    raise exception 'group id exists on target without the same externalId';
  end if;
  if exists (select 1 from gmap g join public."smartDetectObjectGroups" d on d.id = g.ext_hit where d.type <> g.type) then
    raise exception 'group type mismatch on externalId merge';
  end if;
end $$;
alter table gmap add column dst_id text;
update gmap set dst_id = coalesce(ext_hit, src_id);
create temp table m on commit drop as select src_id as src, dst_id as dst from gmap where src_id <> dst_id;
insert into {LS}.ledger (batch, tbl, id)
  select '{slug}', 'merge:smartDetectObjectGroups', src_id || '->' || dst_id from gmap where ext_hit is not null;
-- merges keep the TARGET group's name / settings: record where the source side differed
insert into {LS}.ledger (batch, tbl, id)
  select '{slug}', 'note:merge-name-differs', g.src_id || '->' || g.dst_id || ' source=' || coalesce(s.name, '<null>') || ' target=' || coalesce(d.name, '<null>')
  from gmap g join "w_smartDetectObjectGroups" s on s.id = g.src_id join public."smartDetectObjectGroups" d on d.id = g.dst_id
  where g.ext_hit is not null and s.name is distinct from d.name;
""")
    if unvalidated:   # visible in verify.sql's info lines and kept in ledger_history after a rollback
        A.append(f"insert into {LS}.ledger (batch, tbl, id) values ('{slug}', 'note:unvalidated-version', '{unvalidated}');\n")
    gcols = ', '.join(q(c) for c in pub['smartDetectObjectGroups'])
    A.append(f"""with ins as (
  insert into public."smartDetectObjectGroups" ({gcols})
  select {gcols} from "w_smartDetectObjectGroups" where id in (select src_id from gmap where ext_hit is null)
  returning id)
insert into {LS}.ledger (batch, tbl, id) select '{slug}', 'smartDetectObjectGroups', id from ins;

-- 2. rewrite references to groups merged under a different id (exact tokens, whitelisted locations), then prove none is left
{REWRITE}
{RESIDUAL}

-- 3. labels missing on the target (lid from the target sequence)
with ins as (
  insert into public.labels (name, "lastSeen", id, "createdAt", "updatedAt")
  select distinct on (l.name) l.name, l."lastSeen", l.id, l."createdAt", l."updatedAt" from w_labels l
  where not exists (select 1 from public.labels p where p.name = l.name)
  order by l.name, l."lastSeen" desc nulls last
  returning id)
insert into {LS}.ledger (batch, tbl, id) select '{slug}', 'labels', id from ins;
""")
    for t in TABLES:
        cl = ', '.join(q(c) for c in pub[t])
        A.append(f"""with ins as (insert into public.{q(t)} ({cl}) select {cl} from {q('w_' + t)} returning id)
insert into {LS}.ledger (batch, tbl, id) select '{slug}', '{t}', id from ins;""")
    dcols = pub['detectionLabels']
    sel = ', '.join('case when d.label_names is null then null else coalesce((select array_agg(p.lid::int order by u.o) '
                    'from unnest(d.label_names) with ordinality u(n, o) join public.labels p on p.name = u.n), '
                    "'{}'::int[]) end" if c == 'labels' else 'd.' + q(c) for c in dcols)
    A.append(f"""with ins as (
  insert into public."detectionLabels" ({', '.join(q(c) for c in dcols)})
  select {sel} from "w_detectionLabels" d
  returning id)
insert into {LS}.ledger (batch, tbl, id) select '{slug}', 'detectionLabels', id from ins;

-- 4. post-conditions
do $$ declare r record; n bigint; begin
  for r in select t, want from (values {', '.join(f"('{t}', {counts[t]})" for t in TABLES + ['detectionLabels'])}) v(t, want) loop
    select count(*) into n from {LS}.ledger where batch = '{slug}' and tbl = r.t;
    if n <> r.want then raise exception 'inserted % rows into % , expected %', n, r.t, r.want; end if;
  end loop;
  select count(*) into n from {LS}.ledger where batch = '{slug}' and tbl in ('smartDetectObjectGroups', 'merge:smartDetectObjectGroups');
  if n <> {counts['smartDetectObjectGroups']} then raise exception 'groups inserted + merged = % , expected {counts['smartDetectObjectGroups']}', n; end if;
  select count(*) into n from public."detectionLabels" d join "w_detectionLabels" s on s.id = d.id
    where coalesce(array_length(d.labels, 1), 0) <> coalesce(array_length(s.label_names, 1), 0);
  if n > 0 then raise exception '% detectionLabels lost labels while resolving lids', n; end if;
  select count(*) into n from public."smartDetectObjects" o
    where o.id in (select id from {LS}.ledger where batch = '{slug}' and tbl = 'smartDetectObjects')
      and o."smartDetectObjectGroupId" is not null
      and not exists (select 1 from public."smartDetectObjectGroups" g where g.id = o."smartDetectObjectGroupId");
  if n > 0 then raise exception '% imported objects point at a missing group', n; end if;
  -- at startup Protect deletes events that ended before the camera's earliest recording still on disk (observed on
  -- {VALIDATED_VERSION}): with a correct msr nothing imported may end before the camera's earliest rotating file
  select count(*) into n from public.events e
    where e.id in (select id from {LS}.ledger where batch = '{slug}' and tbl = 'events')
      and e."end" < (select min(start) from public."recordingFiles" where "cameraId" = '{env['UCAM']}' and type = 'rotating' and not free);
  if n > 0 then raise exception '% imported events end before the earliest rotating file --- startup purge would delete them', n; end if;
end $$;
select tbl, count(*) from {LS}.ledger where batch = '{slug}' group by tbl order by tbl;
\\if :{{?trial}}
rollback;
select 'TRIAL ROLLED BACK' as trial;
\\else
commit;
\\endif
""")
    open(os.path.join(bdir, 'sql', 'apply.sql'), 'w').write('\n'.join(A) + '\n')

    R = []  # ---------------- rollback.sql
    R.append(f"""-- rollback.sql ({slug}) --- delete exactly the ledger rows of this batch; run with unifi-protect STOPPED.
-- Refuses (always) if an imported recordingFiles row no longer describes the imported file (msr recycled / moved it).
-- Native rows hanging off imported events / recordings / objects (any FK, enumerated from pg_constraint) abort the
-- rollback unless :force is true. Groups / labels that native rows still reference are KEPT and reported.
\\set ON_ERROR_STOP on
\\if :{{?force}}
\\else
\\set force false
\\endif
set application_name = '{APP}';
begin;
set local lock_timeout = '10s';
create temp table led on commit drop as select tbl, id from {LS}.ledger where batch = '{slug}';
do $$ declare n bigint; begin
  select count(*) into n from led;
  if n = 0 then raise exception 'no ledger rows for batch {slug}'; end if;
end $$;
-- 1. every imported recording row that still exists must still be the imported file
create temp table rf_changed on commit drop as
  select p.id from public."recordingFiles" p join {SCH}."recordingFiles" s on s.id = p.id
  where p.id in (select id from led where tbl = 'recordingFiles')
    and (p."cameraId", p.folder, p.file, p.start, p."end", p.size, p.type, p.channel, p.free)
        is distinct from (s."cameraId", s.folder, s.file, s.start, s."end", s.size, s.type, s.channel, false);
do $$ declare n bigint; begin
  select count(*) into n from rf_changed;
  if n > 0 then raise exception '% imported recordingFiles rows changed since import (recycled / moved by msr) --- refusing rollback', n; end if;
end $$;
-- 2. native children of imported rows, every FK into the imported parent tables
create temp table fks on commit drop as
  select pc.relname::text parent, cc.relname::text child, a.attname::text col
  from pg_constraint c
  join pg_class pc on pc.oid = c.confrelid join pg_class cc on cc.oid = c.conrelid
  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
  where c.contype = 'f' and pc.relnamespace = 'public'::regnamespace and cc.relnamespace = 'public'::regnamespace
    and pc.relname in ('events', 'recordingFiles', 'smartDetectObjects', 'smartDetectObjectGroups');
create temp table native_children (parent text, child text, col text, nrows bigint) on commit drop;
do $$ declare r record; n bigint; begin
  for r in select * from fks loop
    execute format('select count(*) from public.%I x where x.%I in (select id from led where tbl = %L) '
                   'and not exists (select 1 from led where tbl = %L and id = to_jsonb(x)->>''id'')', r.child, r.col, r.parent, r.child) into n;
    if n > 0 then insert into native_children values (r.parent, r.child, r.col, n); end if;
  end loop;
end $$;
select 'native children' as report, parent, child, col, nrows from native_children order by parent, child;
select set_config('rollback.force', :'force', true);
do $$ declare n bigint; begin
  select coalesce(sum(nrows), 0) into n from native_children where parent <> 'smartDetectObjectGroups';
  if n > 0 and current_setting('rollback.force') <> 'true' then
    raise exception '% native rows hang off imported events / recordings / objects --- review the report, rerun with -v force=true', n;
  end if;
end $$;
delete from public."ramDetections" where id in (select id from led where tbl = 'ramDetections');
delete from public."smartDetectTracks" where id in (select id from led where tbl = 'smartDetectTracks');
delete from public.heatmaps where id in (select id from led where tbl = 'heatmaps');
delete from public."detectionLabels" where id in (select id from led where tbl = 'detectionLabels');
delete from public."smartDetectObjectAreas" where id in (select id from led where tbl = 'smartDetectObjectAreas');
delete from public."smartDetectObjects" where id in (select id from led where tbl = 'smartDetectObjects');
delete from public.events where id in (select id from led where tbl = 'events');
delete from public."recordingFiles" where id in (select id from led where tbl = 'recordingFiles');
-- 3. imported groups still referenced by anything (every FK into groups; all imported rows are gone now) or edited by
--    the user since the import (name / description / tags / notifications / fixed image) are kept
create temp table kept_groups (id text) on commit drop;
insert into kept_groups
  select g.id from public."smartDetectObjectGroups" g join {SCH}."smartDetectObjectGroups" s on s.id = g.id
  where g.id in (select id from led where tbl = 'smartDetectObjectGroups')
    and (g.name, g.description, g.tags, g."isNotificationEnabled", g."isImageFixed")
        is distinct from (s.name, s.description, s.tags, s."isNotificationEnabled", s."isImageFixed");
do $$ declare r record; begin
  for r in select * from fks where parent = 'smartDetectObjectGroups' loop
    execute format('insert into kept_groups select distinct x.%I from public.%I x where x.%I in (select id from led where tbl = ''smartDetectObjectGroups'')',
                   r.col, r.child, r.col);
  end loop;
end $$;
delete from public."smartDetectObjectGroups" where id in (select id from led where tbl = 'smartDetectObjectGroups')
  and id not in (select id from kept_groups);
create temp table kept_labels on commit drop as
  select l.id from public.labels l where l.id in (select id from led where tbl = 'labels')
  and exists (select 1 from public."detectionLabels" d where d.labels @> array[l.lid::int]);
delete from public.labels where id in (select id from led where tbl = 'labels') and id not in (select id from kept_labels);
select 'kept groups (native references)' as report, count(distinct id) from kept_groups
union all select 'kept labels (native references)', count(*) from kept_labels;
insert into {LS}.ledger_history (batch, tbl, id, at) select batch, tbl, id, at from {LS}.ledger where batch = '{slug}';
insert into {LS}.ledger_history (batch, tbl, id, at) select distinct '{slug}', 'kept:smartDetectObjectGroups', id, now() from kept_groups;
insert into {LS}.ledger_history (batch, tbl, id, at) select '{slug}', 'kept:labels', id, now() from kept_labels;
delete from {LS}.ledger where batch = '{slug}';
commit;
""")
    open(os.path.join(bdir, 'sql', 'rollback.sql'), 'w').write('\n'.join(R) + '\n')

    open(os.path.join(bdir, 'sql', 'verify.sql'), 'w').write(verify_sql(LS, SCH, slug, counts, env['CAM'], env['UCAM']))
    for f in os.listdir(os.path.join(bdir, 'sql')):
        os.chmod(os.path.join(bdir, 'sql', f), 0o600)
    print(json.dumps(counts))


if __name__ == '__main__':
    main()
