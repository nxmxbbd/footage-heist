#!/usr/bin/env bash
# window-remote.sh <batch_dir_on_target> go|rollback|recover --- runs ON THE TARGET console (transient systemd unit,
# see night.sh).
#
# State machine (state file journaled BEFORE each phase; every exit path ends in recover()):
#   go:       stopping -> linking -> sql -> [recover: ledger decides] -> done | failed-sql | committed-start-failed
#   rollback: rb-stopping -> rb-sql -> [recover: ledger decides] -> rolled-back | rollback-failed | rb-start-failed
# recover() is the ONLY cleanup path (normal end, failure, signal, set -u death, ExecStopPost after SIGKILL):
#   - outcome of our SQL is read from the ledger (<LEDGER_SCHEMA>.ledger) on a fresh connection after our sessions are gone,
#     never inferred from psql's exit code;
#   - links are removed only if the inode still equals the staged file AND no recordingFiles row references the path;
#   - Protect is never stopped or started while <protect dir>/data/.corrupted-db exists (Protect would drop its
#     database and restore its latest backup on the next start): the guard stays, state blocked-flag, a human decides.
set -uo pipefail
B=$1; MODE=$2
# $B/remote.env (written by night.sh prep from the controller's site configuration): STAGE, PROTECT_DIR,
# LEDGER_SCHEMA, NAME_PREFIX. Parsed as KEY=VALUE, never sourced; a variable already set in the environment wins
# (the controller-side sandbox test, tool/test-window.sh, sets them that way).
load_remote_env() {
  local line k v
  [ -f "$B/remote.env" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in ''|'#'*) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    case $k in STAGE|PROTECT_DIR|LEDGER_SCHEMA|NAME_PREFIX) ;; *) echo "remote.env: unexpected key '$k'" >&2; exit 64 ;; esac
    [ -n "${!k+x}" ] || printf -v "$k" '%s' "$v"
  done < "$B/remote.env"
}
load_remote_env
[[ ${STAGE:-} == /* ]] || { echo "STAGE (staged files dir) not set --- remote.env missing?" >&2; exit 64; }
[[ ${LEDGER_SCHEMA:-} =~ ^[a-z][a-z0-9_]{0,22}$ ]] || { echo "LEDGER_SCHEMA missing or invalid" >&2; exit 64; }
[[ ${NAME_PREFIX:-} =~ ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ ]] || { echo "NAME_PREFIX missing or invalid" >&2; exit 64; }
PROTECT_DIR=${PROTECT_DIR:-/srv/unifi-protect}
VIDEO=${VIDEO:-$PROTECT_DIR/video}
FLAG=${FLAG:-$PROTECT_DIR/data/.corrupted-db}                 # the flag Protect's own recovery hook acts on;
FLAG2=${FLAG2:-/data/unifi-protect/data/.corrupted-db}         # checked under both possible Protect mounts
HEALTH_WAIT=${HEALTH_WAIT:-20}                                 # seconds msr/msp/mst must stay up (same PID, no restarts)
GUARD_DIR=${GUARD_DIR:-/run/systemd/system/unifi-protect.service.d}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
OWNER=${OWNER:-ms}; GROUP=${GROUP:-unifi-streaming}
GUARD=$GUARD_DIR/$NAME_PREFIX-guard.conf
. "$B/batch.env"                       # SLUG, UCAM, ...
if [ -n "${PSQL_CMD:-}" ]; then read -r -a PSQL <<< "$PSQL_CMD"; else PSQL=(psql -U postgres -p 5433 -h 127.0.0.1 -d unifi-protect -X -v ON_ERROR_STOP=1); fi
APPNAME="$NAME_PREFIX-$SLUG"           # set by apply.sql / rollback.sql (SET application_name)
# PostgreSQL keeps 63 bytes of application_name: a longer one never matches below and recovery would miss our session
[ "$(printf %s "$APPNAME" | wc -c)" -le 63 ] || { echo "application_name '$APPNAME' longer than 63 bytes" >&2; exit 64; }
LINKS=$B/links.tsv                     # staged_path \t target_path \t staged_inode  (planned + synced BEFORE any ln)
DIRS=$B/created-dirs.txt               # journaled BEFORE each mkdir
STATE=$B/state
MEDIA=(msr.service msp.service mst.service)    # stopped for the window (msr = recorder, msp = playback, mst = transcoder)
# Restarted by us before Protect: only msr (it owns recordingFiles and recordingStart). msp / mst / ms are consumers of
# Protect: msx-monitor stops them after ~2 checks (60 s apart) while Protect is down, and Protect's Wants= starts them.
PRE=(msr.service)
# unifi-protect ConsistsOf= postgresql@14-protect (+ the oneshot postgresql-cluster@14-protect + ai-feature-console):
# stopping Protect stops its PostgreSQL. We start only the server unit ourselves; the guard keeps Protect itself down
# meanwhile. The cluster oneshot is never started by us directly: restarting msr pulls it in through msr's Wants=, as
# every msr start on the console does. (An earlier version assumed PostgreSQL stays up while Protect is stopped:
# test-window.sh T17 replays the state that left behind, T18 fails if the explicit PostgreSQL start is ever dropped.)
PGUNIT=${PGUNIT:-postgresql@14-protect.service}
TERMINAL=" none done failed-sql failed-linking committed-start-failed committed-media-unhealthy auto-rolled-back auto-rolled-back-media-unhealthy aborted aborted-start-failed aborted-flag blocked-flag unresolved rolled-back rollback-failed rb-start-failed "

log() { echo "$(date -Is) $*"; }
flag_present() { [ -e "$FLAG" ] || [ -e "$FLAG2" ]; }
prop() { $SYSTEMCTL show "$1" -p "$2" --value; }
setstate() { printf '%s\n' "$1" > "$STATE.tmp" && sync "$STATE.tmp" && mv "$STATE.tmp" "$STATE" && sync "$B"; log "STATE $1"; }
getstate() { cat "$STATE" 2>/dev/null || echo none; }
is_terminal() { [[ "$TERMINAL" == *" $1 "* ]]; }
sq() { "${PSQL[@]}" -At -c "$1" 2>/dev/null; }      # single-value query; empty output = query failed

exec 9>>"$B/.lock"
flock -n 9 || { log "ABORT: another window-remote.sh holds $B/.lock"; exit 75; }

# ---------------------------------------------------------------- services
guard_on() {
  mkdir -p "$GUARD_DIR" || return 1
  # empty ExecStartPre= first: a start attempt during the window must not run the unit's own pre-start hooks
  printf '[Service]\nExecStartPre=\nExecStartPre=/bin/sh -c "echo %s window in progress, refusing start >&2; exit 1"\n' "$NAME_PREFIX" > "$GUARD" || return 1
  sync "$GUARD"; $SYSTEMCTL daemon-reload || return 1
  [ -s "$GUARD" ] || return 1
  log "guard installed"
}
guard_off() {
  rm -f "$GUARD"; rmdir "$GUARD_DIR" 2>/dev/null
  $SYSTEMCTL daemon-reload || { log "daemon-reload failed"; return 1; }
  [ -e "$GUARD" ] && { log "guard still present"; return 1; }
  log "guard removed"
}
# is-active prints "inactive" for a unit that does not exist: require LoadState=loaded as well
is_down() { local st; st=$($SYSTEMCTL is-active "$1"); [ "$(prop "$1" LoadState)" = loaded ] && { [ "$st" = inactive ] || [ "$st" = failed ]; }; }
is_up()   { [ "$(prop "$1" LoadState)" = loaded ] && [ "$($SYSTEMCTL is-active "$1")" = active ]; }
media_down() { local u; for u in "${MEDIA[@]}"; do is_down "$u" || { log "$u is not down ($($SYSTEMCTL is-active "$u"))"; return 1; }; done; }
# PostgreSQL reachable? start the server unit if not, wait up to 60 s for "select 1"
pg_up() {   # 0 = up; 9 = corrupted-db flag present (nothing started); 1 = unreachable
  flag_present && { log "corrupted-db FLAG present --- not starting PostgreSQL"; return 9; }
  [ "$(sq "select 1")" = 1 ] && return 0
  log "PostgreSQL not reachable --- starting $PGUNIT"
  $SYSTEMCTL start "$PGUNIT"
  local i; for i in $(seq 1 60); do [ "$(sq "select 1")" = 1 ] && { log "PostgreSQL up"; return 0; }; sleep 1; done
  log "PostgreSQL still unreachable"; return 1
}
# restart msr and prove it is a NEW process (start timestamp advanced) that stays up HEALTH_WAIT s
media_up() {
  local u rc=0; declare -A t0 pid nr
  for u in "${PRE[@]}"; do
    t0[$u]=$(prop "$u" ExecMainStartTimestampMonotonic)
    $SYSTEMCTL restart "$u"
    if is_up "$u" && [ "$(prop "$u" ExecMainStartTimestampMonotonic)" -gt "${t0[$u]:-0}" ]; then
      pid[$u]=$(prop "$u" MainPID); nr[$u]=$(prop "$u" NRestarts); log "$u restarted (pid ${pid[$u]})"
    else log "$u NOT restarted ($($SYSTEMCTL is-active "$u"))"; rc=1; fi
  done
  [ $rc = 0 ] || return 1
  sleep "$HEALTH_WAIT"
  for u in "${PRE[@]}"; do
    if is_up "$u" && [ "$(prop "$u" MainPID)" = "${pid[$u]}" ] && [ "$(prop "$u" NRestarts)" = "${nr[$u]}" ]; then log "$u healthy after ${HEALTH_WAIT}s"
    else log "$u UNHEALTHY after ${HEALTH_WAIT}s ($($SYSTEMCTL is-active "$u"), pid $(prop "$u" MainPID), restarts $(prop "$u" NRestarts))"; rc=1; fi
  done
  return $rc
}

# 0 = Protect + msr/msp/mst stopped, PG up; 9 = flag present, NOTHING touched; 8 = flag appeared after we stopped
# things (leave everything as is, guard stays); 1 = failed part-way (recover() restarts)
stop_all() {
  flag_present && { log "ABORT: corrupted-db flag present --- not touching Protect"; return 9; }
  guard_on || { log "guard install failed"; return 1; }
  $SYSTEMCTL stop unifi-protect.service
  is_down unifi-protect.service || { log "Protect did not stop ($($SYSTEMCTL is-active unifi-protect.service))"; return 1; }
  log "unifi-protect stopped"
  local u; for u in "${MEDIA[@]}"; do
    $SYSTEMCTL stop "$u"
    is_down "$u" || { log "$u did not stop ($($SYSTEMCTL is-active "$u"))"; return 1; }
    log "$u stopped"
  done
  local r; pg_up; r=$?; [ $r = 9 ] && return 8; [ $r = 0 ] || return 1
}
# Protect itself: flag check, no leftover sessions of ours, guard off, start. 0 = active; 9 = flag (guard stays); 1 = failed
protect_up() {
  flag_present && { log "corrupted-db FLAG present --- NOT starting Protect, guard stays; human decision needed"; return 9; }
  end_sessions || { log "$APPNAME DB sessions still alive --- not starting Protect"; return 1; }
  guard_off || { log "guard removal failed --- Protect cannot start"; return 1; }
  $SYSTEMCTL reset-failed unifi-protect.service 2>/dev/null
  $SYSTEMCTL start unifi-protect.service
  if is_up unifi-protect.service; then
    log "unifi-protect active (consumers: $(for u in msp.service mst.service ms.service; do printf '%s=%s ' "$u" "$($SYSTEMCTL is-active "$u")"; done))"
    return 0
  fi
  log "unifi-protect NOT active"; return 1
}
# DB holds no imported rows (abort / failed / rolled back): media then Protect; Protect starts even if media is unhealthy
# (nothing imported can be purged). 0 = all up; 9 = flag; 1 = something not up
start_all() {
  flag_present && { log "corrupted-db FLAG present --- NOT starting anything, guard stays; human decision needed"; return 9; }
  local rc=0; media_up || rc=1
  protect_up; local p=$?; [ $p = 0 ] || return $p
  return $rc
}

# ---------------------------------------------------------------- database outcome
# terminate any leftover session of ours (killed client, hung statement) and wait until none remains,
# so that the ledger read afterwards is the final outcome (a terminated, uncommitted transaction rolls back)
end_sessions() {
  local i n
  [ "$(sq "select 1")" = 1 ] || { log "PostgreSQL down --- no session of ours can be alive"; return 0; }
  for i in $(seq 1 30); do
    n=$(sq "select count(*) from pg_stat_activity where application_name = '$APPNAME' and pid <> pg_backend_pid()")
    [ -z "$n" ] && { log "cannot query pg_stat_activity"; return 1; }
    [ "$n" = 0 ] && return 0
    [ "$i" = 1 ] && log "terminating $n leftover $APPNAME session(s)"
    sq "select count(pg_terminate_backend(pid)) from pg_stat_activity where application_name = '$APPNAME' and pid <> pg_backend_pid()" >/dev/null
    sleep 1
  done
  return 1
}
ledger_count() { sq "select count(*) from $LEDGER_SCHEMA.ledger where batch = '$SLUG'"; }

# ---------------------------------------------------------------- files
unlink_ours() {
  [ -s "$LINKS" ] || { log "no links journaled"; return 0; }
  local refs plan rc=0 n=0 kept=0 verdict s t ino
  refs=$(mktemp); plan=$(mktemp)
  # every path any recordingFiles row points at (relative to the video root) stays, whatever the inode says
  if ! "${PSQL[@]}" -At -c "select regexp_replace(folder, '^.*/unifi-protect/video/?', '') || '/' || file from public.\"recordingFiles\"" > "$refs" 2>/dev/null; then
    log "cannot read recordingFiles --- links left in place"; rm -f "$refs" "$plan"; return 1
  fi
  awk -F'\t' -v v="$VIDEO/" 'NR == FNR { ref[$0] = 1; next }
       { rel = substr($2, 1, length(v)) == v ? substr($2, length(v) + 1) : $2
         print ((rel in ref) ? "REF" : "OK") "\t" $0 }' "$refs" "$LINKS" > "$plan"
  while IFS=$'\t' read -r verdict s t ino; do
    [ -e "$t" ] || continue
    if [ "$verdict" = REF ]; then log "KEEP $t (referenced by a recordingFiles row)"; kept=$((kept+1)); continue; fi
    if [ "$(stat -c %i "$t")" = "$ino" ] && [ "$(stat -c %i "$s" 2>/dev/null)" = "$ino" ]; then
      rm -f "$t" && n=$((n+1))
    else log "KEEP $t (inode differs from the staged file)"; kept=$((kept+1)); fi
  done < "$plan"
  rm -f "$refs" "$plan"
  if [ -s "$DIRS" ]; then tac "$DIRS" | while read -r d; do rmdir "$d" 2>/dev/null && log "rmdir $d"; done; fi
  log "unlinked $n links, kept $kept"
  [ "$kept" = 0 ] || rc=1
  return $rc
}

# ---------------------------------------------------------------- recovery (single cleanup path)
IN_RECOVER=0
finish_start() {  # $1 = state on success, $2 = state if a service did not come up
  local rc; start_all; rc=$?
  case $rc in 0) setstate "$1";; 9) setstate blocked-flag;; *) setstate "$2";; esac
}
# import committed: Protect may only start once msr/msp/mst are fresh processes that stay up (msr's recordingStart must
# include the imported files before Protect's startup purge runs). Media unhealthy -> automatic LIFO rollback first.
finish_committed() {
  flag_present && { log "corrupted-db FLAG present --- NOT starting anything, guard stays"; setstate blocked-flag; return; }
  if media_up; then
    local p; protect_up; p=$?
    case $p in 0) setstate done;; 9) setstate blocked-flag;; *) setstate committed-start-failed;; esac
    return
  fi
  log "media services unhealthy after commit --- automatic rollback before Protect starts"
  if [ -e "$B/.auto-rollback-tried" ]; then log "automatic rollback already attempted once --- stopping here"; setstate committed-media-unhealthy; return; fi
  : > "$B/.auto-rollback-tried"
  local m; for m in "${PRE[@]}"; do $SYSTEMCTL stop "$m"; done
  media_down || { log "media did not stop for the automatic rollback"; setstate committed-media-unhealthy; return; }
  setstate rb-sql
  "${PSQL[@]}" < "$B/sql/rollback.sql" > "$B/rollback-auto.out" 2>&1
  log "automatic rollback psql rc=$? $(grep -m1 ERROR "$B/rollback-auto.out")"
  local c; c=$(ledger_count)
  if [ "$c" = 0 ]; then setstate rb-committed; unlink_ours; finish_start auto-rolled-back auto-rolled-back-media-unhealthy
  else log "automatic rollback did not commit ('$c' ledger rows)"; setstate committed-media-unhealthy; fi
}
recover() {
  [ "$IN_RECOVER" = 1 ] && return 0; IN_RECOVER=1
  local st c; st=$(getstate)
  if is_terminal "$st"; then log "recover: state '$st' is terminal, nothing to do"; return 0; fi
  log "RECOVER from state '$st'"
  case "$st" in linking|sql|committed|rb-sql|rb-committed)
    local r; pg_up; r=$?
    [ $r = 9 ] && { setstate blocked-flag; return 1; }
    [ $r = 0 ] || { log "PostgreSQL unreachable --- outcome unknown, leaving everything stopped"; setstate unresolved; return 1; } ;;
  esac
  case "$st" in
    stopping|rb-stopping) finish_start aborted aborted-start-failed ;;
    linking)              unlink_ours; finish_start failed-linking failed-linking ;;
    sql)
      end_sessions || { log "our session is still alive --- outcome unknown, leaving everything stopped"; setstate unresolved; return 1; }
      c=$(ledger_count)
      if [ -z "$c" ]; then log "cannot read the ledger --- outcome unknown"; setstate unresolved; return 1; fi
      if [ "$c" -gt 0 ]; then log "apply COMMITTED ($c ledger rows) --- keeping links"; setstate committed; finish_committed
      else log "apply NOT committed (ledger 0) --- removing links"; unlink_ours; finish_start failed-sql failed-sql; fi ;;
    committed)            finish_committed ;;
    rb-sql)
      end_sessions || { log "our session is still alive --- outcome unknown, leaving everything stopped"; setstate unresolved; return 1; }
      c=$(ledger_count)
      if [ -z "$c" ]; then log "cannot read the ledger --- outcome unknown"; setstate unresolved; return 1; fi
      if [ "$c" = 0 ]; then log "rollback COMMITTED --- removing links"; setstate rb-committed; unlink_ours; finish_start rolled-back rb-start-failed
      else log "rollback NOT committed ($c ledger rows remain) --- links stay"; finish_start rollback-failed rollback-failed; fi ;;
    rb-committed)         unlink_ours; finish_start rolled-back rb-start-failed ;;
    *)                    log "recover: unknown state '$st' --- leaving everything as is"; return 1 ;;
  esac
}
on_exit() { local rc=$?; is_terminal "$(getstate)" || { log "unexpected exit (rc $rc) in state $(getstate)"; recover; }; }
# armed only once THIS invocation is about to change something: an early refusal (lock, state, preconditions) exits
# without side effects; recovering someone else's interrupted window is an explicit "recover"
arm() { trap on_exit EXIT; trap 'log "signal received"; exit 130' TERM INT HUP; }

# ---------------------------------------------------------------- modes
case "$MODE" in
go)
  st=$(getstate); [ "$st" = none ] || { log "ABORT: state file exists ($st) --- not a fresh window"; exit 2; }
  # hardlinks need one mount: link(2) is EXDEV across mount points even on the same filesystem
  [ "$(stat -L -c %m "$STAGE")" = "$(stat -L -c %m "$VIDEO")" ] || { log "ABORT: $STAGE and $VIDEO are on different mounts"; exit 2; }
  [ -e "$LINKS" ] && mv "$LINKS" "$LINKS.prev-$(date +%s)"
  [ -e "$DIRS" ] && mv "$DIRS" "$DIRS.prev-$(date +%s)"
  # every target absent + every staged file present, then plan the links (inode of the staged file) and sync the plan
  : > "$LINKS.tmp"
  while read -r rel; do
    s="$STAGE/$rel"; t="$VIDEO/${rel#*/}"
    [ -e "$t" ] && { log "ABORT: target exists $t"; rm -f "$LINKS.tmp"; exit 2; }
    [ -f "$s" ] || { log "ABORT: staged file missing $s"; rm -f "$LINKS.tmp"; exit 2; }
    printf '%s\t%s\t%s\n' "$s" "$t" "$(stat -c %i "$s")" >> "$LINKS.tmp"
  done < "$B/files.txt"
  [ "$(wc -l < "$LINKS.tmp")" = "$(wc -l < "$B/files.txt")" ] || { log "ABORT: link plan incomplete"; exit 2; }
  sync "$LINKS.tmp"; mv "$LINKS.tmp" "$LINKS"; : > "$DIRS"; rm -f "$B/.auto-rollback-tried"; sync "$B"
  arm
  setstate stopping
  stop_all; rc=$?
  [ $rc = 9 ] && { setstate aborted-flag; exit 3; }
  [ $rc = 8 ] && { setstate blocked-flag; exit 3; }
  [ $rc = 0 ] || { recover; exit 3; }
  setstate linking
  while IFS=$'\t' read -r s t ino; do
    d=$(dirname "$t")
    for p in "$(dirname "$(dirname "$d")")" "$(dirname "$d")" "$d"; do
      if [ ! -d "$p" ]; then echo "$p" >> "$DIRS"; sync "$DIRS"; install -d -o "$OWNER" -g "$GROUP" -m 770 "$p" || { log "mkdir failed $p"; recover; exit 4; }; fi
    done
    ln "$s" "$t" || { log "link failed $t"; recover; exit 4; }
  done < "$LINKS"
  sync
  log "linked $(wc -l < "$LINKS") files"
  media_down || { log "a media service came back during the window --- not applying"; recover; exit 4; }
  setstate sql
  "${PSQL[@]}" < "$B/sql/apply.sql" > "$B/apply.out" 2>&1; prc=$?
  log "apply psql rc=$prc $(grep -m1 ERROR "$B/apply.out")"
  recover
  [ "$(getstate)" = done ] && exit 0 || exit 5
  ;;
rollback)
  st=$(getstate); is_terminal "$st" || { log "ABORT: state '$st' is not terminal --- run recover first"; exit 2; }
  c=$(ledger_count)
  { [ -n "$c" ] && [ "$c" -gt 0 ]; } || { log "ABORT: no ledger rows for $SLUG ('$c') --- nothing to roll back (interrupted go: use recover)"; exit 2; }
  [ -s "$LINKS" ] || { log "ABORT: $LINKS missing --- cannot reconcile files"; exit 2; }
  mv "$STATE" "$STATE.prev-$(date +%s)" 2>/dev/null
  arm
  setstate rb-stopping
  stop_all; rc=$?
  [ $rc = 9 ] && { setstate aborted-flag; exit 3; }
  [ $rc = 8 ] && { setstate blocked-flag; exit 3; }
  [ $rc = 0 ] || { recover; exit 3; }
  setstate rb-sql
  if [ "${FORCE:-}" = 1 ]; then F=(-v force=true); else F=(); fi
  "${PSQL[@]}" "${F[@]}" < "$B/sql/rollback.sql" > "$B/rollback.out" 2>&1; prc=$?
  log "rollback psql rc=$prc $(grep -m1 ERROR "$B/rollback.out")"
  recover
  [ "$(getstate)" = rolled-back ] && exit 0 || exit 5
  ;;
recover)
  recover
  is_terminal "$(getstate)" && [ "$(getstate)" != unresolved ] && exit 0 || exit 5
  ;;
*) echo "usage: $0 <batch_dir> go|rollback|recover"; exit 64;;
esac
