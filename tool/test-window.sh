#!/usr/bin/env bash
# test-window.sh <batch_dir> --- sandbox test of window-remote.sh on the controller: fake systemctl (with fault
# injection), temp dirs, docker dst DB (clone: see lib-test.sh). Expected counts come from the batch; never touches a
# device. The fake systemctl follows the unit model (UNIT_MODEL, default tool/unit-model.txt; the same model night.sh
# compares with the target): what a stop / start / restart takes along comes from the model's dependencies and its
# observed-stop lines, never from code here. WINDOW_SCRIPT=<file> runs another version of the window script against the
# same fake (an older version must fail here the way it failed on a real target).
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
BSRC=$(cd "$1" && pwd)
. "$BSRC/batch.env"
B=$BSRC; . "$TOOL/lib-test.sh"; batch_check; resolve_clone
LS=$LEDGER_SCHEMA
MODEL=${UNIT_MODEL:-$TOOL/unit-model.txt}
WINDOW=${WINDOW_SCRIPT:-$TOOL/window-remote.sh}
PGUNIT=postgresql@14-protect.service      # the window script's PostgreSQL unit (its PGUNIT default)
NF=$(grep -c . "$BSRC/files.txt"); WANT_EV=$(mj events)
WROOT=$(mktemp -d /tmp/test-window.XXXXXX); W=$WROOT/w; pass=0; fail=0   # per run: concurrent runs never share a sandbox
G=$WROOT/graph                           # closure tables of the model (tool/unit-graph.py tables)
python3 "$TOOL/unit-graph.py" tables "$MODEL" "$G" || { echo "ABORT: unit model $MODEL unusable"; exit 64; }
grep -qxF "$PGUNIT" "$G/units" || { echo "ABORT: $PGUNIT is not a unit of $MODEL"; exit 64; }
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
dq()  { docker exec -i "$PG_CONTAINER" psql -U postgres -d dst -At -c "$1" 2>&1; }
st()  { cat "$W/batch/state" 2>/dev/null; }
calls() { grep -E "^($1) " "$W/systemctl.calls" 2>/dev/null | tr '\n' ','; }
nfiles() { find "$W/video" -type f | wc -l; }
reset_dst() {
  restore_clone
  docker exec -i "$PG_CONTAINER" psql -U postgres -d dst -At -v ON_ERROR_STOP=1 < "$BSRC/sql/load-docker.sql" >/dev/null 2>&1
}
led() { dq "select count(*) from $LS.ledger where batch = '$SLUG'${1:+ and tbl = '$1'}"; }
GUARDF=$W/guard/unifi-protect.service.d/$NAME_PREFIX-guard.conf
cnt() { dq "select count(*) from public.events where \"cameraId\"='$UCAM'"; }
setup() {
  [ -d "$W" ] && mv "$W" "$WROOT/old.$(date +%s%N)"
  mkdir -p "$W"/{stage,video/2026/10/27,data,data2,guard,batch/sql}
  cp "$BSRC"/sql/*.sql "$W/batch/sql/"; cp "$BSRC/batch.env" "$BSRC/files.txt" "$W/batch/"
  while read -r rel; do mkdir -p "$W/stage/$(dirname "$rel")"; echo "fake $rel" > "$W/stage/$rel"; done < "$W/batch/files.txt"
  echo 1000 > "$W/clock"
  while read -r u; do echo active > "$W/state-$u"; echo 1 > "$W/ts-$u"; echo 100 > "$W/pid-$u"; echo 0 > "$W/nr-$u"; done < "$G/units"
  sed -e "s#@GUARD@#$GUARDF#g" -e "s#@W@#$W#g" -e "s#@G@#$G#g" > "$W/fake-systemctl" << 'EOF'
#!/usr/bin/env bash
# fake systemctl: unit states in files under W; dependencies from the unit model's closure tables under G
W=@W@; G=@G@; echo "$*" >> $W/systemctl.calls
u=${2:-}
known() { grep -qxF -- "$1" $G/units; }
[ -e "$W/flag-on-$1-$u" ] && touch "$W/data/.corrupted-db"
bump() { local c; c=$(( $(cat $W/clock) + 1 )); echo $c > $W/clock; echo $c > "$W/ts-$1"; echo $(( c * 7 )) > "$W/pid-$1"; }
act() {   # one unit comes up; crash-<unit> = N -> its next N activations end in a restart loop (state activating)
  bump "$1"
  if [ -s "$W/crash-$1" ] && [ "$(cat "$W/crash-$1")" -gt 0 ]; then echo $(( $(cat "$W/crash-$1") - 1 )) > "$W/crash-$1"; echo activating > "$W/state-$1"; return; fi
  echo active > "$W/state-$1"
}
down() { [ -e "$W/fail-stop-$1" ] || echo inactive > "$W/state-$1"; }
stopu() {   # a stop of $1 (explicit, caused by Conflicts, or the stop half of a restart): every unit that goes down takes
            # along its stop closure (units that Require / Requisite / BindsTo / PartOf it) and its observed-stop line,
            # to a fixed point (an observed-stop line's units go down as if stopped; a unit that was already down
            # still propagates, as a stop job does)
  local todo=("$1") seen=' ' y
  while [ ${#todo[@]} -gt 0 ]; do
    y=${todo[0]}; todo=("${todo[@]:1}")
    case $seen in *" $y "*) continue;; esac
    seen="$seen$y "; down "$y"; todo+=($(cat "$G/stop.$y" "$G/observed-stop.$y"))
  done
}
unconflict() { local x; while read -r x; do stopu "$x"; done < "$G/conflicts.$1"; }   # what a start of $1 stops
start1() {  # the start job of ONE unit: Requisite met, not blocked by the guard; stops what it conflicts with
  local x; while read -r x; do [ "$(cat "$W/state-$x" 2>/dev/null)" = active ] || { echo "$1: requisite $x not active" >&2; return 1; }; done < "$G/requisite.$1"
  if [ "$1" = unifi-protect.service ] && [ -e @GUARD@ ]; then echo guarded >&2; return 1; fi
  unconflict "$1"
  act "$1"
}
pull() {  # start jobs for what $1 pulls in (Requires / BindsTo / Wants): every inactive one gets its own start job
  local x; while read -r x; do [ "$(cat "$W/state-$x")" = active ] || start1 "$x"; done < "$G/pull.$1"
}
up() {    # start / restart of $u; pulled-in units start even when $u then fails (the guard fails ExecStartPre)
  pull "$u"
  start1 "$u"
}
case "$1" in stop|start|restart) known "$u" || { echo "Failed to $1 $u: Unit $u not loaded." >&2; exit 5; };; esac
case "$1" in
  daemon-reload) [ -e @GUARD@ ] && cp @GUARD@ $W/guard-snapshot; exit 0;;
  reset-failed) exit 0;;
  is-active) known "$u" && cat "$W/state-$u" || echo inactive;;
  show) p=$4; if ! known "$u"; then [ "$p" = LoadState ] && echo not-found || echo; exit 0; fi
        case "$p" in LoadState) echo loaded;; ExecMainStartTimestampMonotonic) cat "$W/ts-$u";; MainPID) cat "$W/pid-$u";; NRestarts) cat "$W/nr-$u";; esac;;
  stop) [ -e "$W/fail-stop-$u" ] && exit 1; stopu "$u";;
  start) [ -e "$W/fail-start-$u" ] && exit 1      # fail-start-<u>: the next explicit start fails before any job runs
         # already active: no start job for $u itself, but its pull-ins and its Conflicts stops still happen
         [ "$(cat "$W/state-$u")" = active ] && { pull "$u"; unconflict "$u"; exit 0; }; up;;
  # restart = stop half, then start half. Propagated restarts are try-restarts: only the units of $u's stop closure that
  # are active now restart. Stop half: $u and what its stop reaches go down (stopu); start half: $u (pull-ins, Requisite,
  # guard, Conflicts), then each try-restarted unit that is still down, through the same start path with its pull-ins
  # (systemd orders dependents after $u through After=, which the model does not hold: the fake always starts $u first).
  # The exit status is $u's start.
  restart) again=; for x in $(cat "$G/stop.$u"); do [ "$(cat "$W/state-$x")" = active ] && again="$again $x"; done
           stopu "$u"; up; r=$?
           for x in $again; do [ "$(cat "$W/state-$x")" = active ] || { pull "$x"; start1 "$x"; }; done; exit $r;;
esac
EOF
  chmod +x "$W/fake-systemctl"; : > "$W/systemctl.calls"
  printf '#!/usr/bin/env bash\n[ "$(cat %s/state-%s)" = active ] || { echo "psql: error: connection to server at \\"127.0.0.1\\", port 5433 failed: Connection refused" >&2; exit 2; }\nexec %s "$@"\n' "$W" "$PGUNIT" "$PSQL_DOCKER" > "$W/psql-wrap"
  chmod +x "$W/psql-wrap"
}
ENVV() { echo STAGE=$W/stage VIDEO=$W/video FLAG=$W/data/.corrupted-db FLAG2=$W/data2/.corrupted-db \
  GUARD_DIR=$W/guard/unifi-protect.service.d SYSTEMCTL=$W/fake-systemctl OWNER=root GROUP=root HEALTH_WAIT=0 \
  LEDGER_SCHEMA=$LS NAME_PREFIX=$NAME_PREFIX; }
PSQL_DOCKER="docker exec -i $PG_CONTAINER psql -U postgres -d dst -X -v ON_ERROR_STOP=1"
PSQL_REAL=$W/psql-wrap      # refuses connections while the fake PostgreSQL unit is not active
runw() { env $(ENVV) PSQL_CMD="${PSQL_OVERRIDE:-$PSQL_REAL}" "${WINDOW_RUN:-$WINDOW}" "$W/batch" "$@" > "$W/run.log" 2>&1; }
slow_apply() {  # insert a long sleep into the apply transaction (application_name is already set by then)
  sed "s/^-- 3. labels missing on the target/select pg_sleep($1);\n-- 3. labels missing on the target/" "$BSRC/sql/apply.sql" > "$W/batch/sql/apply.sql"
}
# wait_state <state> <worker pid>: 0 once the window script has journaled <state>; 1 when the worker exits first or the
# deadline passes. No fixed 30 s: the stop phase plus linking 883 files took 25-40 s on the controller, and T9 then
# killed the worker in state linking instead of sql (seen 10-29)
wait_state() { local end=$(( $(date +%s) + ${WAIT_STATE_S:-900} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    [ "$(st)" = "$1" ] && return 0
    kill -0 "$2" 2>/dev/null || { [ "$(st)" = "$1" ]; return; }
    sleep 0.5
  done; return 1; }
EXPECT_GO="stop unifi-protect.service,stop msr.service,stop msp.service,stop mst.service,start postgresql@14-protect.service,restart msr.service,start unifi-protect.service,"

echo "T0 the window script refuses without its remote.env values, and refuses an unexpected remote.env key"
setup
env SYSTEMCTL=$W/fake-systemctl PSQL_CMD=/bin/false "$WINDOW" "$W/batch" go > "$W/run.log" 2>&1; rc=$?
[ $rc = 64 ] && [ ! -s "$W/systemctl.calls" ] && [ "$(st)" = "" ] && ok "no STAGE / LEDGER_SCHEMA / NAME_PREFIX: rc 64, nothing touched" || bad "rc=$rc calls=$(tr '\n' ',' < $W/systemctl.calls)"
printf 'STAGE=%s\nLEDGER_SCHEMA=%s\nNAME_PREFIX=%s\nPSQL_CMD=/bin/true\n' "$W/stage" "$LS" "$NAME_PREFIX" > "$W/batch/remote.env"
env SYSTEMCTL=$W/fake-systemctl "$WINDOW" "$W/batch" go > "$W/run.log" 2>&1; rc=$?
[ $rc = 64 ] && grep -q "unexpected key 'PSQL_CMD'" "$W/run.log" && [ ! -s "$W/systemctl.calls" ] && ok "remote.env with an unexpected key: rc 64, nothing touched" || bad "rc=$rc $(tail -1 $W/run.log)"

echo "T0b every unit the window script names is a unit of the model (the fake knows only the model's units)"
miss=$(grep -oE '[A-Za-z0-9][A-Za-z0-9@_.-]*[.]service' "$WINDOW" | sort -u | grep -vxFf "$G/units")
[ -z "$miss" ] && ok "$(grep -oE '[A-Za-z0-9][A-Za-z0-9@_.-]*[.]service' "$WINDOW" | sort -u | wc -l) units, all in $(basename "$MODEL")" || bad "not in the model: $(echo $miss)"

echo "T1 go (happy path)"
reset_dst; NATIVE0=$(cnt); echo "  info: batch $SLUG: $NF files, $WANT_EV events; clone has $NATIVE0 native events on the camera"
setup; runw go; rc=$?
[ $rc = 0 ] && [ "$(st)" = done ] && ok "rc 0, state done" || bad "rc=$rc state=$(st); $(tail -3 $W/run.log)"
n=$(wc -l < "$W/batch/links.tsv"); [ "$n" = "$NF" ] && ok "$NF links planned" || bad "links=$n"
same=0; while IFS=$'\t' read -r s t ino; do [ "$(stat -c %i "$t")" = "$ino" ] && same=$((same+1)); done < "$W/batch/links.tsv"
[ "$same" = "$NF" ] && ok "all $NF targets share the staged inode" || bad "inode matches $same/$NF"
[ "$(led events)" = "$WANT_EV" ] && ok "$WANT_EV events committed" || bad "events not committed"
[ ! -e "$GUARDF" ] && ok "guard removed" || bad "guard left behind"
[ "$(sed -n 2p "$W/guard-snapshot")" = "ExecStartPre=" ] && ok "guard resets the unit's ExecStartPre list" || bad "guard content: $(tr '\n' '|' < "$W/guard-snapshot")"
[ "$(calls 'stop|start|restart')" = "$EXPECT_GO" ] && ok "order: protect down (takes PG along), media down, PG up, msr restarted, protect up" || bad "order: $(calls 'stop|start|restart')"
grep -q 'msr.service healthy' "$W/run.log" && ok "msr verified as a new, stable process before Protect" || bad "no msr health line"
[ "$(cat $W/state-unifi-protect.service)" = active ] && ok "protect active at end" || bad "protect not active"

echo "T2 rollback"
: > "$W/systemctl.calls"; runw rollback; rc=$?
[ $rc = 0 ] && [ "$(st)" = rolled-back ] && ok "rc 0, state rolled-back" || bad "rc=$rc state=$(st); $(tail -3 $W/run.log)"
[ "$(nfiles)" = 0 ] && ok "no imported files left in video dir" || bad "$(nfiles) files left"
[ "$(find "$W/video" -mindepth 1 -type d | sort | tr '\n' ' ')" = "$W/video/2026 $W/video/2026/10 $W/video/2026/10/27 " ] && ok "only pre-existing dirs remain" || bad "dirs: $(find "$W/video" -mindepth 1 -type d | tr '\n' ' ')"
[ "$(find "$W/stage" -type f | wc -l)" = "$NF" ] && ok "staged files intact" || bad "staged files touched"
[ "$(cnt)" = "$NATIVE0" ] && ok "imported events gone ($NATIVE0 native remain)" || bad "events after rollback: $(cnt)"

echo "T3 target already exists -> abort before touching anything"
reset_dst; setup
first=$(head -1 "$W/batch/files.txt"); mkdir -p "$W/video/$(dirname "${first#*/}")"; echo native > "$W/video/${first#*/}"
runw go; rc=$?
[ $rc = 2 ] && ok "rc 2" || bad "rc=$rc"
[ ! -s "$W/systemctl.calls" ] && ok "no systemctl calls at all" || bad "systemctl called: $(tr '\n' ',' < $W/systemctl.calls)"
[ "$(cat "$W/video/${first#*/}")" = native ] && ok "existing file untouched" || bad "existing file changed"

echo "T4 apply fails -> links removed, Protect restarted, DB unchanged"
reset_dst; setup
sid=$(dq "select s.id from $SCHEMA.\"smartDetectObjectGroups\" s where not exists (select 1 from public.\"smartDetectObjectGroups\" d where d.id = s.id) order by (s.\"externalId\" is not null), s.id limit 1")
dq "insert into public.\"smartDetectObjectGroups\" (\"externalId\",type,\"isImageFixed\",\"detectionsCount\",\"isNotificationEnabled\",\"createdAt\",tags,id,\"updatedAt\",metadata,\"isDegraded\") values ('dryrun77777','face',false,1,false,now(),'{}','$sid',now(),'{}',false)" >/dev/null
runw go; rc=$?
[ $rc = 5 ] && [ "$(st)" = failed-sql ] && ok "rc 5, state failed-sql" || bad "rc=$rc state=$(st)"
[ "$(nfiles)" = 0 ] && ok "all links removed" || bad "links left"
[ "$(led)" = 0 ] && ok "ledger empty" || bad "ledger has rows"
[ "$(cat $W/state-unifi-protect.service)" = active ] && [ ! -e "$GUARDF" ] && ok "protect restarted, guard removed" || bad "protect/guard state wrong"

for fl in data data2; do
echo "T5 corrupted-db flag present ($fl) -> no service operation at all"
reset_dst; setup; touch "$W/$fl/.corrupted-db"; echo inactive > "$W/state-unifi-protect.service"
runw go; rc=$?
[ $rc = 3 ] && [ "$(st)" = aborted-flag ] && ok "rc 3, state aborted-flag" || bad "rc=$rc state=$(st)"
[ -z "$(calls 'stop|start|restart|daemon-reload')" ] && ok "no stop / start / restart / daemon-reload" || bad "service calls: $(calls 'stop|start|restart|daemon-reload')"
[ "$(nfiles)" = 0 ] && ok "nothing linked" || bad "files linked"
done

echo "T6 msr does not stop -> abort, nothing applied, everything back up"
reset_dst; setup; touch "$W/fail-stop-msr.service"
runw go; rc=$?
[ $rc = 3 ] && [ "$(st)" = aborted ] && ok "rc 3, state aborted" || bad "rc=$rc state=$(st); $(tail -3 $W/run.log)"
[ "$(led)" = 0 ] && [ "$(nfiles)" = 0 ] && ok "ledger 0, nothing linked" || bad "changes made"
[ "$(cat $W/state-unifi-protect.service)" = active ] && [ ! -e "$GUARDF" ] && ok "protect up, guard removed" || bad "protect/guard wrong"

echo "T7 flag appears while stopping -> blocked before linking: nothing started (not even PG), guard kept"
reset_dst; setup; touch "$W/flag-on-stop-mst.service"
runw go; rc=$?
[ "$(st)" = blocked-flag ] && [ $rc = 3 ] && ok "rc 3, state blocked-flag" || bad "rc=$rc state=$(st)"
[ -z "$(calls 'start|restart')" ] && ok "nothing started" || bad "started: $(calls 'start|restart')"
[ -e "$GUARDF" ] && [ "$(nfiles)" = 0 ] && ok "guard kept, nothing linked" || bad "guard/links wrong"

echo "T7b flag appears after the commit -> committed, Protect NOT started, guard kept"
reset_dst; setup; touch "$W/flag-on-restart-msr.service"
runw go; rc=$?
[ "$(st)" = blocked-flag ] && [ $rc = 5 ] && ok "rc 5, state blocked-flag" || bad "rc=$rc state=$(st)"
[ -z "$(calls 'start unifi-protect.service')" ] && ok "Protect not started" || bad "protect started"
[ -e "$GUARDF" ] && [ "$(nfiles)" = "$NF" ] && [ "$(led events)" = "$WANT_EV" ] && ok "guard kept, $NF links + commit kept" || bad "guard/links/commit wrong"

echo "T8 psql reports failure although COMMIT happened -> ledger decides: committed, links kept"
reset_dst; setup
cat > "$W/lying-psql" << EOF
#!/usr/bin/env bash
if [[ " \$* " == *" -c "* ]]; then exec $W/psql-wrap "\$@"; fi
$W/psql-wrap "\$@"; echo "simulated connection loss after commit" >&2; exit 2
EOF
chmod +x "$W/lying-psql"
PSQL_OVERRIDE="$W/lying-psql" runw go; rc=$?
[ $rc = 0 ] && [ "$(st)" = done ] && ok "rc 0, state done" || bad "rc=$rc state=$(st); $(grep -E 'psql rc|COMMIT' $W/run.log | tail -2)"
grep -q 'apply psql rc=2' "$W/run.log" && ok "psql failure was seen and overruled by the ledger" || bad "psql rc not 2"
[ "$(nfiles)" = "$NF" ] && ok "$NF links kept" || bad "links removed for committed rows"

echo "T9 worker SIGKILLed during the SQL, then recover -> session terminated, not committed, links removed"
reset_dst; setup; slow_apply 60
( env $(ENVV) PSQL_CMD="$PSQL_REAL" "$WINDOW" "$W/batch" go > "$W/run.log" 2>&1 & echo $! > "$W/pid" )
pid=$(cat "$W/pid"); wait_state sql "$pid" && sleep 1; pkill -9 -P "$pid"; kill -9 "$pid"
# recover as an operator would: once the killed worker's processes are gone (a child that outlives the SIGKILL keeps the
# inherited lock, and recover then refuses with rc 75 by design, as T12 checks)
flock -w 60 "$W/batch/.lock" true || bad "lock still held 60 s after the kill"
[ "$(st)" = sql ] && ok "worker died in state sql" || bad "state=$(st)"
[ -e "$GUARDF" ] && ok "guard still there (outage until recover)" || bad "guard gone?"
runw recover; rc=$?
[ $rc = 0 ] && [ "$(st)" = failed-sql ] && ok "recover: rc 0, state failed-sql" || bad "rc=$rc state=$(st); $(tail -4 $W/run.log)"
grep -q 'terminating 1 leftover' "$W/run.log" && ok "leftover apply session terminated" || bad "no session termination logged"
[ "$(led)" = 0 ] && [ "$(nfiles)" = 0 ] && ok "ledger 0, links removed" || bad "ledger/links wrong"
[ "$(cat $W/state-unifi-protect.service)" = active ] && [ ! -e "$GUARDF" ] && ok "protect up, guard removed" || bad "protect/guard wrong"

echo "T10 SIGTERM during the SQL (KillMode=mixed) -> psql finishes, the EXIT trap recovers to done"
reset_dst; setup; slow_apply 4
( env $(ENVV) PSQL_CMD="$PSQL_REAL" "$WINDOW" "$W/batch" go > "$W/run.log" 2>&1 & echo $! > "$W/pid" )
wait_state sql "$(cat "$W/pid")" && sleep 1; kill -TERM "$(cat "$W/pid")"
# psql must finish the whole apply first: poll until the worker exits (big batches run well past 20 s)
t10_end=$(( $(date +%s) + ${T10_WAIT_S:-900} ))
while kill -0 "$(cat "$W/pid")" 2>/dev/null && [ "$(date +%s)" -lt "$t10_end" ]; do sleep 0.5; done
# a worker still running after the wait must not live on under the next scenario's sandbox
kill -0 "$(cat "$W/pid")" 2>/dev/null && { bad "worker still running after ${T10_WAIT_S:-900} s: killed"; kill -KILL "$(cat "$W/pid")"; }
[ "$(st)" = done ] && ok "state done after SIGTERM" || bad "state=$(st); $(tail -4 $W/run.log)"
grep -q 'signal received' "$W/run.log" && ok "signal logged" || bad "no signal line"
[ "$(nfiles)" = "$NF" ] && [ "$(cat $W/state-unifi-protect.service)" = active ] && ok "links kept, protect up" || bad "links/protect wrong"

echo "T11 msr unhealthy after commit -> automatic rollback before Protect starts"
reset_dst; setup; echo 1 > "$W/crash-msr.service"
runw go; rc=$?
[ "$(st)" = auto-rolled-back ] && [ $rc = 5 ] && ok "rc 5, state auto-rolled-back" || bad "rc=$rc state=$(st); $(tail -4 $W/run.log)"
grep -q 'NOT restarted\|UNHEALTHY' "$W/run.log" && ok "unhealthy msr detected" || bad "no unhealthy line"
[ "$(led)" = 0 ] && [ "$(nfiles)" = 0 ] && [ "$(cnt)" = "$NATIVE0" ] \
  && ok "import rolled back (ledger 0, links gone, $NATIVE0 native events)" || bad "rollback incomplete"
[ "$(grep -c '^start unifi-protect.service$' "$W/systemctl.calls")" = 1 ] && [ "$(cat $W/state-unifi-protect.service)" = active ] && ok "Protect started once, after the rollback" || bad "protect starts: $(calls 'start')"

echo "T12 another window-remote holds the lock -> refused without any action"
reset_dst; setup
( flock "$W/batch/.lock" sleep 4 & ); sleep 0.5
runw go; rc=$?
[ $rc = 75 ] && [ ! -s "$W/systemctl.calls" ] && [ "$(st)" = "" ] && ok "rc 75, no systemctl calls, no state" || bad "rc=$rc calls=$(tr '\n' ',' < $W/systemctl.calls) state=$(st)"
sleep 4

echo "T13 rollback blocked by user data -> rollback-failed, links kept; FORCE=0 still blocked; FORCE=1 rolls back"
reset_dst; setup; runw go
iev=$(dq "select id from $LS.ledger where batch = '$SLUG' and tbl='events' limit 1")
dq "insert into public.\"criticalEvents\" (id, \"eventId\", \"createdAt\") values (gen_random_uuid(), '$iev', 1)" >/dev/null
runw rollback; rc=$?
[ $rc = 5 ] && [ "$(st)" = rollback-failed ] && ok "rc 5, state rollback-failed" || bad "rc=$rc state=$(st)"
[ "$(nfiles)" = "$NF" ] && [ "$(led events)" = "$WANT_EV" ] && ok "links + import intact" || bad "partial rollback"
[ "$(cat $W/state-unifi-protect.service)" = active ] && ok "protect back up" || bad "protect down"
FORCE=0 runw rollback; [ "$(st)" = rollback-failed ] && ok "FORCE=0 does not force" || bad "FORCE=0 forced: $(st)"
FORCE=1 runw rollback; rc=$?
[ $rc = 0 ] && [ "$(st)" = rolled-back ] && [ "$(nfiles)" = 0 ] && ok "FORCE=1 rolled back" || bad "rc=$rc state=$(st)"

echo "T14 a file referenced by a recordingFiles row is never unlinked"
reset_dst; setup; runw go
rel=$(dq "select regexp_replace(folder, '^.*/unifi-protect/video/?', '') || '/' || file from public.\"recordingFiles\" where id = (select id from $LS.ledger where batch = '$SLUG' and tbl='recordingFiles' order by id limit 1)")
dq "insert into public.\"recordingFiles\" (\"cameraId\", channel, type, start, \"end\", file, folder, size, locked, free, active, id, \"createdAt\", \"updatedAt\", mac)
    select \"cameraId\", channel, type, start, \"end\", file, folder, size, locked, true, false, 'test-native-rf', now(), now(), mac from public.\"recordingFiles\" where id = (select id from $LS.ledger where batch = '$SLUG' and tbl='recordingFiles' order by id limit 1)" >/dev/null
runw rollback; rc=$?
[ -e "$W/video/$rel" ] && [ "$(nfiles)" = 1 ] && ok "referenced file kept, $((NF - 1)) others removed" || bad "files left: $(nfiles); $(grep KEEP $W/run.log | head -2)"
grep -q 'KEEP .*referenced by a recordingFiles row' "$W/run.log" && ok "KEEP logged" || bad "no KEEP line"

echo "T15 rollback while a window is mid-flight (state not terminal) -> refused"
reset_dst; setup; echo sql > "$W/batch/state"
runw rollback; rc=$?
[ $rc = 2 ] && [ ! -s "$W/systemctl.calls" ] && ok "rc 2, untouched" || bad "rc=$rc calls=$(tr '\n' ',' < $W/systemctl.calls)"

echo "T16 PostgreSQL cannot be started in the window -> abort before linking, Protect brings everything back"
reset_dst; setup; touch "$W/fail-start-postgresql@14-protect.service"
runw go; rc=$?
[ $rc = 3 ] && [ "$(st)" = aborted ] && ok "rc 3, state aborted" || bad "rc=$rc state=$(st); $(tail -3 $W/run.log)"
[ "$(nfiles)" = 0 ] && [ "$(led)" = 0 ] && ok "nothing linked, ledger 0" || bad "changes made"
[ "$(cat $W/state-unifi-protect.service)" = active ] && [ ! -e "$GUARDF" ] && [ "$(cat "$W/state-$PGUNIT")" = active ] && ok "protect + PG up, guard removed" || bad "protect/guard/pg wrong"

echo "T17 regression of a field failure: worker gone in state sql, PG down, all $NF links present -> recover starts PG, ledger 0, links removed"
reset_dst; setup
while read -r rel; do s="$W/stage/$rel"; t="$W/video/${rel#*/}"; mkdir -p "$(dirname "$t")"; ln "$s" "$t"; printf '%s\t%s\t%s\n' "$s" "$t" "$(stat -c %i "$s")"; done < "$W/batch/files.txt" > "$W/batch/links.tsv"
: > "$W/batch/created-dirs.txt"; echo sql > "$W/batch/state"
mkdir -p "$W/guard/unifi-protect.service.d"; printf '[Service]\nExecStartPre=\nExecStartPre=/bin/false\n' > "$GUARDF"
while read -r x; do echo inactive > "$W/state-$x"; done < "$G/units"
runw recover; rc=$?
[ $rc = 0 ] && [ "$(st)" = failed-sql ] && ok "rc 0, state failed-sql" || bad "rc=$rc state=$(st); $(tail -4 $W/run.log)"
grep -q 'PostgreSQL not reachable --- starting' "$W/run.log" && ok "recover started PostgreSQL itself" || bad "no PG start logged"
[ "$(nfiles)" = 0 ] && ok "links removed" || bad "links left: $(nfiles)"
[ "$(cat $W/state-unifi-protect.service)" = active ] && [ ! -e "$GUARDF" ] && ok "protect up, guard removed" || bad "protect/guard wrong"

echo "T18 fake fidelity: the window script without its explicit PostgreSQL start (how it failed in the field) must fail here"
reset_dst; setup
PGLINE='  local r; pg_up; r=$?; [ $r = 9 ] && return 8; [ $r = 0 ] || return 1'
grep -cxF -- "$PGLINE" "$WINDOW" > "$W/pgline.n"; grep -vxF -- "$PGLINE" "$WINDOW" > "$W/window-nopg.sh"; chmod +x "$W/window-nopg.sh"
if [ "$(cat "$W/pgline.n")" != 1 ] || grep -qF 'pg_up; r=$?; [ $r = 9 ] && return 8' "$W/window-nopg.sh"; then
  bad "mutation did not apply (stop_all's PostgreSQL start line not found exactly once in $(basename "$WINDOW"))"
else
  WINDOW_RUN=$W/window-nopg.sh runw go; rc=$?
  [ $rc != 0 ] && [ "$(st)" != done ] && ok "go does not succeed (rc $rc, state $(st))" || bad "the mutated script succeeded: the fake does not take PostgreSQL down with Protect"
  grep -q 'Connection refused' "$W/batch/apply.out" && ok "apply could not connect: PostgreSQL went down with Protect (model: PartOf)" || bad "apply.out: $(head -2 "$W/batch/apply.out")"
  [ "$(led)" = 0 ] && [ "$(nfiles)" = 0 ] && ok "nothing committed, links removed" || bad "ledger $(led), $(nfiles) files"
fi

echo "T19 fake fidelity on a mutated model (mst Conflicts Protect, msp + Protect PartOf msr): a stop takes along what an explicit stop does, to a fixed point; a restart stops before it starts; propagated restarts are try-restarts"
MUT=$WROOT/model-mut.txt
sed -e 's/^mst.service Conflicts shutdown.target$/mst.service Conflicts shutdown.target unifi-protect.service/' \
    -e 's/^unifi-protect.service ConflictedBy$/unifi-protect.service ConflictedBy mst.service/' \
    -e 's/^msp.service PartOf$/msp.service PartOf msr.service/' \
    -e 's/^unifi-protect.service PartOf$/unifi-protect.service PartOf msr.service/' "$MODEL" > "$MUT"
if [ "$(diff "$MODEL" "$MUT" | grep -c '^>')" != 4 ] || ! python3 "$TOOL/unit-graph.py" tables "$MUT" "$WROOT/graph-mut"; then
  bad "model mutation did not apply (expected 4 changed lines in $(basename "$MODEL"))"
else
  G0=$G; G=$WROOT/graph-mut; setup; G=$G0              # this sandbox's fake follows the mutated model
  F=$W/fake-systemctl; P=unifi-protect.service
  sts() { local x o=; for x; do o="$o $(cat "$W/state-$x")"; done; echo $o; }
  allup() { local x; while read -r x; do echo active > "$W/state-$x"; done < "$WROOT/graph-mut/units"; }
  echo inactive > "$W/state-mst.service"; "$F" start mst.service
  [ "$(sts $P $PGUNIT mst.service)" = "inactive inactive active" ] && ok "start mst: Protect stopped and, through PartOf, its PostgreSQL" || bad "Protect / PG / mst: $(sts $P $PGUNIT mst.service)"
  [ "$(sts msr.service msp.service)" = "inactive inactive" ] && ok "Protect's observed-stop line took msr down, and msr's stop took msp (PartOf msr) along: a fixed point" || bad "msr / msp: $(sts msr.service msp.service)"
  allup; "$F" start mst.service
  [ "$(sts $P $PGUNIT mst.service)" = "inactive inactive active" ] && ok "start of an already-active mst still stops what it conflicts with" || bad "Protect / PG / mst: $(sts $P $PGUNIT mst.service)"
  allup; t0=$(cat "$W/ts-msp.service"); t1=$(cat "$W/ts-$P"); "$F" restart msr.service
  [ "$(sts msp.service $P)" = "active active" ] && [ "$(cat "$W/ts-msp.service")" != "$t0" ] && [ "$(cat "$W/ts-$P")" != "$t1" ] \
    && ok "restart msr restarts the active msp and Protect (PartOf)" || bad "msp / Protect: $(sts msp.service $P), ts $t0 -> $(cat "$W/ts-msp.service"), $t1 -> $(cat "$W/ts-$P")"
  # Protect inactive too: a restarted Protect would pull msp in again through its Wants (as on a real target)
  allup; echo inactive > "$W/state-msp.service"; echo inactive > "$W/state-$P"; "$F" restart msr.service
  [ "$(sts msp.service $P)" = "inactive inactive" ] && ok "restart msr leaves an inactive msp and an inactive Protect inactive (try-restart)" || bad "msp / Protect: $(sts msp.service $P)"
  allup; mkdir -p "$(dirname "$GUARDF")"; echo '[Service]' > "$GUARDF"; "$F" restart msr.service; rc=$?
  [ "$(sts $P msr.service)" = "inactive active" ] && [ $rc = 0 ] \
    && ok "restart msr with the guard in place: Protect (PartOf msr) goes down and stays down; rc 0 (msr's start)" || bad "Protect / msr: $(sts $P msr.service), rc $rc"
  mv "$GUARDF" "$W/guard-T19.used"
fi

echo "RESULT pass=$pass fail=$fail (sandbox: $WROOT)"
[ "$fail" = 0 ]
