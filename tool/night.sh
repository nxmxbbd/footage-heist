#!/usr/bin/env bash
# night.sh <batch_dir> preflight|clone-dump|prep|backup|trial|go|status|verify|refresh-verify|rollback|recover|drop-staging
# --- the controller-side driver for one batch. preflight / clone-dump / status / verify are read-only; refresh-verify
# replaces only an imported batch's sql/verify.sql (local + target). prep / trial load staging
# + dry-run on the live DB (Protect keeps running). go / rollback / recover stop Protect: only in an agreed window.
# prep makes an independent copy of the staged files only with COPY=1 (default off: the staged files sit on the same
# disks as the import, and the transfer is hash-verified against the source ledger).
# go / rollback / recover run window-remote.sh as a transient unit on the target (SSH loss does not matter) with
# KillMode=mixed (a stop request lets the running psql finish, then the script's own recovery runs) and
# ExecStopPost=recover (runs even after SIGKILL / OOM; a no-op once the state is terminal).
# Before anything stops: prep / go refuse when the target's Protect version is not the one the batch accepts; prep / go /
# rollback refuse when the target's unit graph differs from tool/unit-model.txt (recover only warns about the graph);
# prep refuses SQL whose session name is not NAME_PREFIX-<slug>; go refuses unless the target holds exactly the bundle
# a completed prep left from this batch dir (prep.done, see BUNDLE).
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
B=$(cd "$1" && pwd); CMD=$2
. "$B/batch.env"
[ -n "${SCHEMA:-}" ] || { echo "batch.env has no SCHEMA (new-batch.sh writes it)"; exit 64; }
[[ $SCHEMA =~ ^${LEDGER_SCHEMA}(_[a-z0-9_]{1,40})?$ ]] || { echo "batch.env SCHEMA '$SCHEMA' is not $LEDGER_SCHEMA or ${LEDGER_SCHEMA}_<slug>"; exit 64; }
need TARGET_SSH TARGET_STAGING TARGET_WORKDIR
U=$TARGET_SSH
R=$TARGET_WORKDIR/$SLUG                                    # batch dir on the target
VOL=$TARGET_STAGING
PD=$TARGET_PROTECT_DIR
PG14=/usr/lib/postgresql/14/bin
RPSQL="psql -U postgres -p 5433 -h 127.0.0.1 -d unifi-protect -X -v ON_ERROR_STOP=1"
TS=$(date +%Y%m%d-%H%M%S)
UNIT=$NAME_PREFIX-$SLUG
MODEL=${UNIT_MODEL:-$TOOL/unit-model.txt}
rs() { ssh -o ConnectTimeout=10 "$U" "$@"; }
ucurl() {       # the target's web API: self-signed certificate, so the TLS public key is pinned instead of CA-checked
  need TARGET_URL TARGET_TLS_PIN_FILE
  curl -s -k --pinnedpubkey "$(cat "$TARGET_TLS_PIN_FILE")" "$@"
}
cams() {
  [ -n "$TARGET_API_HEADER_FILE" ] || { echo "(no TARGET_API_HEADER_FILE configured)"; return 0; }
  ucurl -K "$TARGET_API_HEADER_FILE" "$TARGET_URL/proxy/protect/integration/v1/cameras" \
    | python3 -c "import sys,json,collections; d=json.load(sys.stdin); print(dict(collections.Counter(c.get('state') for c in d)))"
}
unit_busy() {   # any window / rollback / recover unit of ANY batch still loaded and not finished? (one window at a time:
                # every batch shares the same guard drop-in and the same Protect stop)
  rs "systemctl list-units --all --plain --no-legend '$NAME_PREFIX-*' 2>/dev/null | awk '\$3 ~ /^(active|activating|deactivating|reloading)\$/ {print \$1, \$3}'"
}
others_need_human() {   # a batch left in a state that needs a human (flag, unresolved, committed but unhealthy, ...)
  rs "for f in $TARGET_WORKDIR/*/state; do [ -e \$f ] || continue; s=\$(cat \$f); case \$s in done|none|failed-sql|failed-linking|auto-rolled-back|aborted|rolled-back|rollback-failed) ;; *) echo \"\$f \$s\";; esac; done"
}
launch() {      # $1 = unit name, $2 = mode
  local busy; busy=$(unit_busy); [ -z "$busy" ] || { echo "REFUSED: still running: $busy"; exit 1; }
  rs "systemd-run --unit=$1 --collect --quiet -p KillMode=mixed -p TimeoutStopSec=900 \
        -p ExecStopPost='$R/run.sh recover' ${FORCE_ENV:-} $R/run.sh $2; sleep 2; systemctl is-active $1; cat $R/state 2>/dev/null"
}

preflight() {
  echo "== preflight (read-only)"
  rs "for f in $PD/data/.corrupted-db /data/unifi-protect/data/.corrupted-db; do test -e \$f && echo \"FLAG PRESENT \$f\"; done; echo flags-checked;
      for u in unifi-protect msr msp mst; do printf '%s=%s ' \$u \$(systemctl is-active \$u); done; echo;
      ls /run/systemd/system/unifi-protect.service.d/ 2>/dev/null && echo 'GUARD DIR PRESENT' || echo 'no guard';
      echo \"protect version: \$(dpkg-query -W -f='\${Version}' unifi-protect 2>/dev/null)\";
      echo \"mounts: \$(stat -L -c %m $PD/video) \$(stat -L -c %m $VOL/files)\";
      df -h $PD | tail -1; cat $R/state 2>/dev/null | sed 's/^/batch state: /'"
  echo "cameras: $(cams)"
  rs "n=0; m=0; while read -r rel; do [ -f $VOL/files/\$rel ] && n=\$((n+1)); [ -e $PD/video/\${rel#*/} ] && m=\$((m+1)); done; echo staged=\$n targets_existing=\$m" < "$B/files.txt"
  rs "$RPSQL -At -c \"select 'ledger rows for $SLUG: ' || count(*) from $LEDGER_SCHEMA.ledger where batch='$SLUG'\" 2>/dev/null || echo '$LEDGER_SCHEMA not created yet'"
  echo "protect version (DB): $(db_version); this batch's apply.sql accepts: $(python3 "$TOOL/gen.py" --accepted-version "$B" 2>/dev/null || echo '? (run gen.py)')"
  graph_check
  local busy; busy=$(unit_busy); echo "units: ${busy:-none running}"
  local other; other=$(others_need_human); echo "batches needing a human: ${other:-none}"
}
db_version() { rs "$RPSQL -At -c \"select string_agg(distinct version, ',') from public.nvrs\"" 2>/dev/null; }
version_ok() {  # the target must run the Protect version this batch's apply.sql accepts: refuse BEFORE anything stops
  local dv av; dv=$(db_version) || dv=''; av=$(python3 "$TOOL/gen.py" --accepted-version "$B") || av=''
  [ -n "$dv" ] && [ "$dv" = "$av" ] && return 0
  echo "REFUSED: Protect version on the target is '${dv:-unknown}', this batch's apply.sql accepts '${av:-unknown}' (README: --unvalidated-version)"
  return 1
}
# the target's systemd dependencies of the window units vs the model tool/test-window.sh simulates (UNIT_MODEL, default
# tool/unit-model.txt); prints the verdict, rc 0 = same, anything else = different or unreadable
graph_check() {
  local q out rc; q=$(python3 "$TOOL/unit-graph.py" query "$MODEL") || return 2
  out=$(rs "systemctl show $q" 2>/dev/null); rc=$?
  [ $rc = 0 ] || { echo "unit graph: cannot read the target's units (ssh rc $rc)"; return 2; }
  printf '%s\n' "$out" | python3 "$TOOL/unit-graph.py" check "$MODEL" - 2>&1
}
graph_ok() {    # prep / go / rollback: refuse BEFORE anything stops (silent when the graph matches)
  local out; out=$(graph_check) && return 0
  echo "$out"
  echo "REFUSED: the target's unit graph is not the one tool/test-window.sh simulates (README: Unit graph)"
  return 1
}
appname_ok() {  # prep: the psql session name gen.py baked into apply / rollback must be the one the window script looks
                # for (NAME_PREFIX from the site configuration, written to remote.env below); a changed NAME_PREFIX since
                # gen.py would make recovery's "no session of ours is alive" check match nothing
  # exactly one line names it, it is that line, and no block comment could hide it (gen.py writes neither)
  local f a="set application_name = '$NAME_PREFIX-$SLUG';"
  for f in apply rollback; do
    [ "$(grep -ci 'application_name' "$B/sql/$f.sql" 2>/dev/null)" = 1 ] && grep -qxF "$a" "$B/sql/$f.sql" && ! grep -qF '/*' "$B/sql/$f.sql" \
      || { echo "REFUSED: sql/$f.sql does not set exactly application_name '$NAME_PREFIX-$SLUG' (NAME_PREFIX changed since gen.py? run it again)"; return 1; }
  done
}
# the execution bundle prep puts in $R: what the window runs and reads. prep removes $R/prep.done before it uploads
# anything and writes it (= this manifest) only after the uploads and the staging load succeeded; go requires
# target files = prep.done = this batch dir (+ this tool's window-remote.sh)
BUNDLE='sql/*.sql data/*.copy files.txt batch.env run.sh remote.env window-remote.sh'
# the window script's site values (it never sees the controller's site configuration): written by prep, and go
# requires them unchanged (the controller's recover / rollback / verify use the site configuration as it is now)
remote_env() { printf 'STAGE=%s\nPROTECT_DIR=%s\nLEDGER_SCHEMA=%s\nNAME_PREFIX=%s\n' "$VOL/files" "$PD" "$LEDGER_SCHEMA" "$NAME_PREFIX"; }
bundle_local() { { (cd "$B" && sha256sum sql/*.sql data/*.copy files.txt batch.env run.sh remote.env) && (cd "$TOOL" && sha256sum window-remote.sh); } | LC_ALL=C sort -k2; }
bundle_remote() { rs "cd $R && sha256sum $BUNDLE | LC_ALL=C sort -k2"; }
deployed_ok() { # go: refuse BEFORE anything stops unless the target holds exactly the bundle a completed prep left
  local l r d
  [ "$(cat "$B/remote.env" 2> /dev/null)" = "$(remote_env)" ] \
    || { echo "REFUSED: the site configuration changed since prep (remote.env: STAGE / PROTECT_DIR / LEDGER_SCHEMA / NAME_PREFIX): run prep again"; return 1; }
  l=$(bundle_local) || l=''
  r=$(bundle_remote) || r=''
  d=$(rs "cat $R/prep.done") || d=''
  [ -n "$d" ] || { echo "REFUSED: no completed prep on the target ($R/prep.done missing: prep interrupted, failed, or from an older tool): run prep"; return 1; }
  [ -n "$l" ] && [ "$l" = "$r" ] && [ "$r" = "$d" ] && return 0
  echo "REFUSED: the batch on the target ($R) is not the one a completed prep left from this batch dir (regenerated, re-prepped partly, or the tool changed since prep): run prep again"
  return 1
}

backup() {      # pre-window safety net: PG14 dumps of unifi-protect + smart_detect_face (target + controller copy),
                # Protect API backup
  need TARGET_URL TARGET_TLS_PIN_FILE TARGET_LOGIN_FILE
  rs "install -d -m 700 $VOL/backup" || return 1
  echo "== backups: pg_dump (PG 14 binaries) of unifi-protect + smart_detect_face, then a Protect backup via API"
  rs "set -e; umask 077; $PG14/pg_dump -U postgres -p 5433 -h 127.0.0.1 -Fc unifi-protect > $VOL/backup/unifi-protect-$TS.dump;
      $PG14/pg_dump -U postgres -p 5433 -h 127.0.0.1 -Fc smart_detect_face > $VOL/backup/smart_detect_face-$TS.dump;
      $PG14/pg_restore -l $VOL/backup/unifi-protect-$TS.dump | wc -l | sed 's/^/toc entries unifi-protect: /';
      $PG14/pg_restore -l $VOL/backup/smart_detect_face-$TS.dump | wc -l | sed 's/^/toc entries smart_detect_face: /';
      ls -l $VOL/backup/*-$TS.dump" || return 1
  ( umask 077; scp -q "$U:$VOL/backup/unifi-protect-$TS.dump" "$U:$VOL/backup/smart_detect_face-$TS.dump" "$B/" ) && echo "copied dumps to $B"
  local J H CSRF; J=$(mktemp); H=$(mktemp)
  ucurl -c "$J" -D "$H" -H 'Content-Type: application/json' --data @"$TARGET_LOGIN_FILE" "$TARGET_URL/api/auth/login" -o /dev/null -w 'login http=%{http_code}\n'
  CSRF=$(grep -i '^x-csrf-token:' "$H" | awk '{print $2}' | tr -d '\r')
  ucurl -b "$J" -H "X-CSRF-Token: $CSRF" -X POST "$TARGET_URL/proxy/protect/api/backups" -o "$B/protect-backup-$TS.json" -w 'backup http=%{http_code}\n'
  python3 -c "import json; d=json.load(open('$B/protect-backup-$TS.json')); print('protect backup id', d.get('id'), d.get('type'))" 2>/dev/null
  ucurl -b "$J" -H "X-CSRF-Token: $CSRF" -X POST "$TARGET_URL/api/auth/logout" -o /dev/null -w 'logout http=%{http_code}\n'
  shred -u "$J" "$H"
}

NF=$(cat "$B/files.txt" 2>/dev/null | grep -c .)     # 0 before gen.py (clone-dump may run first)
case "$CMD" in
preflight) preflight ;;
clone-dump)
  # read-only on the target: a fresh dump of unifi-protect (PG 14 binaries) as the clone for dryrun.sh / test-window.sh
  f=$B/$TARGET_LABEL-clone-$TS.dump
  ( umask 077; rs "$PG14/pg_dump -U postgres -p 5433 -h 127.0.0.1 -Fc unifi-protect" > "$f" ) || { echo "clone dump failed"; exit 1; }
  n=$(docker exec -i "$PG_CONTAINER" pg_restore -l < "$f" | grep -c .)
  [ "$n" -gt 100 ] || { echo "clone dump unreadable ($n TOC lines): $f"; exit 1; }
  echo "clone dump: $f ($(stat -c %s "$f") B, $n TOC lines)"
  ;;
prep)
  need IMPORT_DIR
  COPY=${COPY:-0}; case $COPY in 0|1) ;; *) echo "COPY must be 0 or 1 (got '$COPY')"; exit 64 ;; esac
  appname_ok || exit 1          # local files only: before anything reaches the target
  pf=$(preflight); echo "$pf"
  echo "$pf" | grep -q 'FLAG PRESENT' && { echo "ABORT: corrupted-db flag present"; exit 1; }
  version_ok || exit 1
  graph_ok || exit 1
  echo "$pf" | grep -qx "staged=$NF targets_existing=0" || { echo "ABORT: expected staged=$NF targets_existing=0"; exit 1; }
  # the sha list must cover exactly the files of this batch
  diff <(sed "s#^[0-9a-f]\{64\}  $VOL/files/##" "$IMPORT_DIR/$SLUG.sha256" | sort) <(sort "$B/files.txt") > /dev/null \
    || { echo "ABORT: $SLUG.sha256 does not cover exactly files.txt"; exit 1; }
  echo "== push batch to $R"
  rs "install -d -m 700 $R $R/sql $R/data $VOL/copy $VOL/backup && rm -f $R/prep.done" || { echo "ABORT: cannot prepare $R"; exit 1; }
  printf '#!/bin/bash\nexec %s/window-remote.sh %s "$1" >> %s/window.log 2>&1\n' "$R" "$R" "$R" > "$B/run.sh"
  remote_env > "$B/remote.env"
  scp -q -p "$B"/sql/*.sql "$U:$R/sql/" && scp -q -p "$B"/data/*.copy "$U:$R/data/" \
    && scp -q -p "$B/files.txt" "$B/batch.env" "$B/run.sh" "$B/remote.env" "$TOOL/window-remote.sh" "$U:$R/" || exit 1
  rs "chmod 700 $R/window-remote.sh $R/run.sh; ls $R/data | wc -l"
  echo "== chown staged files ms:unifi-streaming 660"
  rs "set -e; n=0; while read -r rel; do f=$VOL/files/\$rel; chown ms:unifi-streaming \$f; chmod 660 \$f; n=\$((n+1)); done; echo chowned=\$n" < "$B/files.txt" || exit 1
  if [ "$COPY" = 1 ]; then
    echo "== independent copy to $VOL/copy (nice/ionice)"
    rs "set -e; while read -r rel; do f=$VOL/files/\$rel; c=$VOL/copy/\$rel; mkdir -p \$(dirname \$c); [ -e \$c ] || nice -n19 ionice -c3 cp --preserve=mode,ownership,timestamps \$f \$c; done; echo copies=\$(find $VOL/copy -type f -name '*.ubv' | wc -l)" < "$B/files.txt" || exit 1
    echo "== verify copies against the transfer ledger hashes"
    sed "s#$VOL/files/#$VOL/copy/#" "$IMPORT_DIR/$SLUG.sha256" > "$B/copy.sha256"
    scp -q "$B/copy.sha256" "$U:$R/copy.sha256" && rs "nice -n19 ionice -c3 sha256sum -c --quiet $R/copy.sha256 && echo 'copies: all match'" || { echo "ABORT: copy hash mismatch"; exit 1; }
  else echo "== no independent copy (COPY=0)"; fi
  backup || exit 1
  echo "== load staging schema $SCHEMA (Protect keeps running)"
  out=$(rs "$RPSQL -At -F '|' -f $R/sql/load-$TARGET_LABEL.sql 2>&1"); rc=$?
  printf '%s\n' "$out" | grep -E 'staged ok|ERROR'
  [ $rc = 0 ] && printf '%s\n' "$out" | grep -qx 'staged ok' || { echo "ABORT: the staging load did not finish (psql rc $rc): no prep.done, go will refuse"; exit 1; }
  # the completion record, last: what go will require (the target's files, as they are now, = this batch dir)
  m=$(bundle_local) && [ "$m" = "$(bundle_remote)" ] || { echo "ABORT: the files on the target differ from this batch dir after the upload"; exit 1; }
  printf '%s\n' "$m" | rs "cat > $R/prep.done.tmp && mv $R/prep.done.tmp $R/prep.done" || { echo "ABORT: cannot write $R/prep.done"; exit 1; }
  echo "prep complete: $R/prep.done ($(printf '%s\n' "$m" | grep -c .) files)"
  ;;
backup) backup ;;   # re-take right before a window when prep ran before another batch's window
trial)
  echo "== trial apply on the live DB inside one transaction, ending in ROLLBACK (psql -v trial=1; Protect running)"
  rs "s=\$(date +%s.%N); $RPSQL -v trial=1 -At -F '|' -f $R/sql/apply.sql > $R/trial.out 2>&1; rc=\$?;
      echo trial_rc=\$rc trial_secs=\$(awk -v a=\$s -v b=\$(date +%s.%N) 'BEGIN{printf \"%.2f\", b-a}');
      grep -vE '^(BEGIN|SET|DO|CREATE (TABLE|INDEX)|ALTER TABLE|UPDATE [0-9]+|INSERT 0 [0-9]+|SELECT [0-9]+|ROLLBACK)\$' $R/trial.out;
      grep -qx 'TRIAL ROLLED BACK' $R/trial.out && echo 'trial: rolled back (confirmed)' || echo 'TRIAL DID NOT REPORT ROLLBACK';
      $RPSQL -At -c \"select 'ledger after trial: ' || count(*) from $LEDGER_SCHEMA.ledger where batch='$SLUG'\""
  ;;
go)
  preflight
  other=$(others_need_human); [ -z "$other" ] || { echo "REFUSED: a batch needs a human first: $other"; exit 1; }
  # no window while the source -> target copy writes to the same disks (longer apply = longer outage): pause it first
  need SOURCE_SSH
  copy=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$SOURCE_SSH" "systemctl is-active $PUSH_UNIT" 2>/dev/null)
  case $copy in
    active|activating|deactivating|reloading) echo "REFUSED: the $SOURCE_NAME -> $TARGET_NAME copy is running (tool/copyq.py pause first)"; exit 1 ;;
    inactive|failed) echo "$SOURCE_NAME copy unit $PUSH_UNIT: $copy" ;;
    *) [ "${NO_COPY_CHECK:-}" = 1 ] || { echo "REFUSED: cannot check the $SOURCE_NAME copy ('$copy'; NO_COPY_CHECK=1 overrides)"; exit 1; } ;;
  esac
  version_ok || exit 1
  deployed_ok || exit 1
  graph_ok || exit 1
  echo "== WINDOW: transient unit $UNIT on the target"
  launch "$UNIT" go
  ;;
status)
  rs "for u in $UNIT $UNIT-rb $UNIT-recover; do printf '%s=%s ' \$u \$(systemctl is-active \$u 2>/dev/null); done; echo;
      echo state=\$(cat $R/state 2>/dev/null); tail -n 40 $R/window.log 2>/dev/null"
  ;;
verify)
  rs "$RPSQL -At -F '|' -f $R/sql/verify.sql;
      for f in $PD/data/.corrupted-db /data/unifi-protect/data/.corrupted-db; do test -e \$f && echo \"FLAG PRESENT \$f\"; done; echo flags-checked;
      grep -h 'Startup purge completed' $PD/logs/*.log 2>/dev/null | sort | tail -2; systemctl is-active unifi-protect msr msp mst | tr '\n' ' '; echo"
  echo "cameras: $(cams)"
  ;;
refresh-verify)
  # an imported batch's verify.sql after gen.py changed its recordingFiles check: gen.py --refresh-verify rewrites that
  # check alone in the local file (a full gen.py run would need the batch back in the shared stage schema), then the
  # target's copy is replaced with it (verify runs the target's). Nothing in a window or a rollback reads verify.sql;
  # go compares the whole bundle with prep.done, so a batch not imported yet is regenerated + prepped instead
  st=$(rs "cat $R/state") || st=''
  [ "$st" = done ] || { echo "REFUSED: refresh-verify is for an imported batch (target state '${st:-unreadable}', want done): regenerate + prep instead"; exit 1; }
  python3 "$TOOL/gen.py" --refresh-verify "$B" || exit 1
  scp -q -p "$B/sql/verify.sql" "$U:$R/sql/verify.sql.tmp" && rs "chmod 600 $R/sql/verify.sql.tmp && mv $R/sql/verify.sql.tmp $R/sql/verify.sql" \
    || { echo "FAIL: could not replace $R/sql/verify.sql on the target"; exit 1; }
  l=$(sha256sum < "$B/sql/verify.sql" | cut -c1-64); r=$(rs "sha256sum < $R/sql/verify.sql" | cut -c1-64) || r=''
  [ "$l" = "$r" ] || { echo "FAIL: the target's verify.sql ($r) differs from the local one ($l)"; exit 1; }
  echo "verify.sql on the target = local ($l)"
  ;;
rollback)
  if [ "${FORCE:-}" = 1 ]; then FORCE_ENV='--setenv=FORCE=1'; else FORCE_ENV=''; fi
  [ -n "${FORCE:-}" ] && [ "${FORCE}" != 1 ] && { echo "FORCE must be exactly 1 (got '$FORCE')"; exit 64; }
  graph_ok || exit 1
  launch "$UNIT-rb" rollback
  ;;
recover)
  # recover only cleans up and brings services back: a different unit graph is reported, never a reason to stay down
  graph_check || echo "WARNING: the target's unit graph is not the modelled one --- recovering anyway"
  launch "$UNIT-recover" recover
  ;;
drop-staging)
  # after verify: drop the staging DATA tables (ramDetections staging depends on pgvector's type; a later Protect migration
  # must not trip over it). Kept: ledger, ledger_history, recordingFiles + smartDetectObjectGroups staging (rollback.sql needs them).
  # enhancedImages / transcriptions with "if exists": a batch generated before they were imported has no staging table for them
  rs "$RPSQL -At -c \"select count(*) from $LEDGER_SCHEMA.ledger where batch='$SLUG'\"" | grep -qx '[1-9][0-9]*' || { echo "no committed batch --- nothing to drop"; exit 1; }
  S=$SCHEMA
  rs "$RPSQL -c 'drop table if exists $S.\"enhancedImages\", $S.transcriptions' -c 'drop table $S.\"events\", $S.\"smartDetectObjects\", $S.\"smartDetectObjectAreas\", $S.heatmaps,
      $S.\"smartDetectTracks\", $S.\"ramDetections\", $S.\"detectionLabels\", $S.labels' -c \"select string_agg(c.relname, ' ') from pg_class c where c.relnamespace = '$S'::regnamespace and c.relkind = 'r'\""
  ;;
*) echo "usage: $0 <batch_dir> preflight|clone-dump|prep|backup|trial|go|status|verify|refresh-verify|rollback|recover|drop-staging"; exit 64 ;;
esac
