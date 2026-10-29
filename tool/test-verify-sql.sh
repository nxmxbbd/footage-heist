#!/usr/bin/env bash
# test-verify-sql.sh --- verify.sql's recordingFiles verdict on synthetic rows, and gen.py --refresh-verify. Runs the whole
# generated verify.sql (gen.verify_sql) in a throw-away database of the controller's container PG_CONTAINER, built from
# stub tables: one batch b1 with a rotating, a thumbnails and two timelapse files, one row of another batch and one
# native row. Each case resets the rows, changes some, then runs this gen.py's verify.sql and the earlier one (any change
# a FAIL). Needs no device and no batch. Exit 0 = no FAIL.
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
need PG_CONTAINER LEDGER_SCHEMA
T=$(mktemp -d /tmp/test-verify-sql.XXXXXX)
DB=verify_sql_test
LS=$LEDGER_SCHEMA; SCH=${LEDGER_SCHEMA}_b1
PSQL=(docker exec -i "$PG_CONTAINER" psql -U postgres -d "$DB" -X -At -F '|' -v ON_ERROR_STOP=1)
cleanup() { docker exec "$PG_CONTAINER" psql -U postgres -qc "drop database if exists $DB with (force)" > /dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
q()   { "${PSQL[@]}" -c "$1" 2>&1; }

# the two verify.sql versions of batch b1 (camera cam1, recordingFiles 4, everything else 0)
python3 - "$TOOL" "$T" "$LS" "$SCH" << 'EOF' || { echo "ABORT: cannot generate verify.sql"; exit 70; }
import sys
tool, t, ls, sch = sys.argv[1:]
sys.path.insert(0, tool)
import gen
counts = {x: 0 for x in gen.TABLES + ['detectionLabels']}
counts['recordingFiles'] = 4
new = gen.verify_sql(ls, sch, 'b1', counts, 'oldcam1', 'cam1')
v1 = new.replace(gen.rf_check_sql(ls, sch, 'b1'), gen.rf_check_sql_v1(ls, sch, 'b1'))
assert new.count(gen.rf_check_sql(ls, sch, 'b1')) == 1 and v1 != new
open(f'{t}/verify-new.sql', 'w').write(new)
open(f'{t}/verify-v1.sql', 'w').write(v1)
EOF

docker exec "$PG_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -qc "drop database if exists $DB with (force)" -c "create database $DB" > /dev/null 2>&1 \
  || { echo "ABORT: cannot create database $DB in $PG_CONTAINER"; exit 70; }
F=00005E005301_0
setup=$(q "
create schema $LS; create schema $SCH;
create table $LS.ledger (batch text, tbl text, id text, at timestamptz default now());
create table public.\"recordingFiles\" (id text primary key, \"cameraId\" text, folder text, file text, start bigint, \"end\" bigint,
  size bigint, type text, channel int, free boolean, \"updatedAt\" timestamptz);
create table $SCH.\"recordingFiles\" (id text, \"cameraId\" text, folder text, file text, start bigint, \"end\" bigint, size bigint,
  type text, channel int);
create table public.events (id text, \"cameraId\" text);
create table public.\"smartDetectObjects\" (id text); create table public.\"smartDetectObjectAreas\" (id text);
create table public.heatmaps (id text); create table public.\"smartDetectTracks\" (id text);
create table public.\"ramDetections\" (id text); create table public.\"detectionLabels\" (id text);
create table public.\"enhancedImages\" (id text); create table public.transcriptions (id text);
insert into $SCH.\"recordingFiles\" values
  ('rot', 'cam1', '2023/11/14', '${F}_rotating_1700000000000.ubv', 1700000000000, 1700086400000, 1073741824, 'rotating', 0),
  ('thu', 'cam1', '2023/11/14', '${F}_thumbnails_1700000000000.ubv', 1700000000000, 1700086400000, 1073741824, 'thumbnails', 0),
  ('tl0', 'cam1', '2023/11/14', '${F}_timelapse_1700000000000.ubv', 1700000000000, 1700086400000, 536870912, 'timelapse', 0),
  ('tl1', 'cam1', '2023/11/14', '00005E005301_1_timelapse_1700000000000.ubv', 1700000000000, 1700086400000, 536870912, 'timelapse', 1),
  ('oth', 'cam1', '2023/11/14', '${F}_rotating_1700090000000.ubv', 1700090000000, 1700100000000, 1073741824, 'rotating', 0);
insert into $LS.ledger (batch, tbl, id) values ('b1', 'recordingFiles', 'rot'), ('b1', 'recordingFiles', 'thu'),
  ('b1', 'recordingFiles', 'tl0'), ('b1', 'recordingFiles', 'tl1'), ('b2', 'recordingFiles', 'oth');
create table base as select *, false free, now() \"updatedAt\" from $SCH.\"recordingFiles\"
  union all select 'nat', 'cam1', '2023/11/16', '${F}_thumbnails_1700200000000.ubv', 1700200000000, 1700210000000, 1073741824, 'thumbnails', 0, false, now();
select 'setup ok';")
[ "$(printf '%s\n' "$setup" | tail -1)" = 'setup ok' ] || { echo "ABORT: fixture setup failed: $setup"; exit 70; }

# case <label> <sql changing public."recordingFiles"> <want new verdict> <want v1 verdict> [<want INFO lines, ';'-joined>]
#   verdict = the "imported recordingFiles unchanged" line from PASS / FAIL on (prefix match)
case_() {
  local label=$1 change=$2 want_new=$3 want_v1=$4 want_info=${5:-} r out_new out_v1 got_info present
  r=$(q "truncate public.\"recordingFiles\"; insert into public.\"recordingFiles\" select * from base; $change; select 'reset ok'")
  [ "$(printf '%s\n' "$r" | tail -1)" = 'reset ok' ] || { bad "$label: fixture change failed: $r"; return; }
  out_new=$("${PSQL[@]}" < "$T/verify-new.sql" 2>&1); out_v1=$("${PSQL[@]}" < "$T/verify-v1.sql" 2>&1)
  local vn vo; vn=$(printf '%s\n' "$out_new" | grep 'imported recordingFiles unchanged'); vo=$(printf '%s\n' "$out_v1" | grep 'imported recordingFiles unchanged')
  got_info=$(printf '%s\n' "$out_new" | grep '^INFO' | paste -sd ';')
  present=$(printf '%s\n' "$out_new" | grep 'present recordingFiles')
  case $vn in "$want_new"*) ;; *) bad "$label: new verify '$vn', want '$want_new...'"; return ;; esac
  case $vo in "$want_v1"*) ;; *) bad "$label: earlier verify '$vo', want '$want_v1...'"; return ;; esac
  [ "$got_info" = "$want_info" ] || { bad "$label: INFO '$got_info', want '$want_info'"; return; }
  local want_present=PASS nfail=0; [ "${CASE_PRESENT:-}" = fail ] && want_present=FAIL
  case $present in "$want_present"*) ;; *) bad "$label: present check '$present', want $want_present"; return ;; esac
  case $vn in FAIL*) nfail=$((nfail + 1)) ;; esac; [ $want_present = FAIL ] && nfail=$((nfail + 1))
  [ "$(printf '%s\n' "$out_new" | grep -c '^FAIL')" = $nfail ] || { bad "$label: other FAIL lines: $(printf '%s\n' "$out_new" | grep '^FAIL' | paste -sd ';')"; return; }
  ok "$label -> $vn${got_info:+ + $(printf '%s\n' "$got_info" | tr ';' '\n' | grep -c .) INFO}; earlier: ${vo%% imported*}${CASE_PRESENT:+; $present}"
}
RF='update public."recordingFiles" set'
D=86400000
I_THU="INFO imported thumbnails file ${F}_thumbnails_1700000000000.ubv continued by the recorder: end 2023-11-15 22:13:20Z -> 2023-11-16 22:13:20Z"
I_TL0="INFO imported timelapse file ${F}_timelapse_1700000000000.ubv continued by the recorder: end 2023-11-15 22:13:20Z -> 2023-11-16 22:13:20Z"

echo "== recordingFiles verdict (this gen.py vs. the earlier verify.sql)"
case_ "C0 nothing changed" "select 1" \
  'PASS imported recordingFiles unchanged since import (changed: 0; continued by the recorder: 0)' 'PASS imported recordingFiles unchanged since import (changed: 0)'
case_ "C1 thumbnails: only end later (the recorder continues it)" "$RF \"end\" = \"end\" + $D, \"updatedAt\" = now() + interval '1 day' where id = 'thu'" \
  'PASS imported recordingFiles unchanged since import (changed: 0; continued by the recorder: 1)' 'FAIL imported recordingFiles unchanged since import (changed: 1)' "$I_THU"
case_ "C2 timelapse: only end later" "$RF \"end\" = \"end\" + $D where id = 'tl0'" \
  'PASS imported recordingFiles unchanged since import (changed: 0; continued by the recorder: 1)' 'FAIL' "$I_TL0"
case_ "C3 thumbnails + timelapse both continued" "$RF \"end\" = \"end\" + $D where id in ('thu', 'tl0')" \
  'PASS imported recordingFiles unchanged since import (changed: 0; continued by the recorder: 2)' 'FAIL' "$I_THU;$I_TL0"
case_ "C4 rotating: end later" "$RF \"end\" = \"end\" + $D where id = 'rot'" \
  'FAIL imported recordingFiles unchanged since import (changed: 1; continued by the recorder: 0)' 'FAIL'
case_ "C5 thumbnails: size changed" "$RF size = size + 1 where id = 'thu'" 'FAIL imported recordingFiles unchanged since import (changed: 1;' 'FAIL'
case_ "C6 thumbnails: end later + size changed" "$RF \"end\" = \"end\" + $D, size = size + 1 where id = 'thu'" 'FAIL imported recordingFiles unchanged since import (changed: 1;' 'FAIL'
case_ "C7 thumbnails: end earlier" "$RF \"end\" = \"end\" - 1 where id = 'thu'" 'FAIL imported recordingFiles unchanged since import (changed: 1;' 'FAIL'
case_ "C8 thumbnails: end missing" "$RF \"end\" = null where id = 'thu'" 'FAIL imported recordingFiles unchanged since import (changed: 1;' 'FAIL'
case_ "C9 thumbnails: end later + free" "$RF \"end\" = \"end\" + $D, free = true where id = 'thu'" 'FAIL imported recordingFiles unchanged since import (changed: 1;' 'FAIL'
case_ "C10 timelapse: free only" "$RF free = true where id = 'tl1'" 'FAIL imported recordingFiles unchanged since import (changed: 1;' 'FAIL'
for c in "start = start + 1" "file = file || 'x'" "folder = '2023/11/15'" "\"cameraId\" = 'cam2'" "channel = 1" "type = 'timelapse'"; do
  case_ "C11 thumbnails: end later + ${c%% =*} changed" "$RF \"end\" = \"end\" + $D, $c where id = 'thu'" 'FAIL imported recordingFiles unchanged since import (changed: 1;' 'FAIL'
done
case_ "C12 rotating type 'thumbnails' + end later (the imported type counts, not the new one)" "$RF \"end\" = \"end\" + $D, type = 'thumbnails' where id = 'rot'" \
  'FAIL imported recordingFiles unchanged since import (changed: 1;' 'FAIL'
case_ "C13 thumbnails continued + rotating end changed" "$RF \"end\" = \"end\" + $D where id in ('thu', 'rot')" \
  'FAIL imported recordingFiles unchanged since import (changed: 1; continued by the recorder: 1)' 'FAIL imported recordingFiles unchanged since import (changed: 2)' "$I_THU"
case_ "C14 rows outside the batch changed (other batch, native)" "$RF \"end\" = \"end\" + $D, size = 1 where id in ('oth', 'nat')" \
  'PASS imported recordingFiles unchanged since import (changed: 0; continued by the recorder: 0)' 'PASS'
CASE_PRESENT=fail case_ "C15 imported thumbnails row gone (present check fails)" "delete from public.\"recordingFiles\" where id = 'thu'" \
  'PASS imported recordingFiles unchanged since import (changed: 0; continued by the recorder: 0)' 'PASS'

echo "== gen.py --refresh-verify"
mkdir -p "$T/b1/sql"
printf 'SLUG=b1\nSCHEMA=%s\n' "$SCH" > "$T/b1/batch.env"
cp "$T/verify-v1.sql" "$T/b1/sql/verify.sql"; chmod 644 "$T/b1/sql/verify.sql"
out=$(python3 "$TOOL/gen.py" --refresh-verify "$T/b1" 2>&1); rc=$?
[ $rc = 0 ] && cmp -s "$T/b1/sql/verify.sql" "$T/verify-new.sql" && [ "$(stat -c %a "$T/b1/sql/verify.sql")" = 600 ] && [ ! -e "$T/b1/sql/verify.sql.tmp" ] \
  && ok "R1 an earlier verify.sql becomes exactly this gen.py's (mode 600): $out" || bad "R1 rc=$rc '$out' mode $(stat -c %a "$T/b1/sql/verify.sql")"
s0=$(sha256sum < "$T/b1/sql/verify.sql")
out=$(python3 "$TOOL/gen.py" --refresh-verify "$T/b1" 2>&1); rc=$?
[ $rc = 0 ] && [ "$(sha256sum < "$T/b1/sql/verify.sql")" = "$s0" ] && case $out in *'already current') true ;; *) false ;; esac \
  && ok "R2 a second run changes nothing: $out" || bad "R2 rc=$rc '$out'"
sed 's/is distinct from (s\."cameraId"/is distinct from ( s."cameraId"/' "$T/verify-v1.sql" > "$T/b1/sql/verify.sql"   # a hand-edited check
s0=$(sha256sum < "$T/b1/sql/verify.sql")
out=$(python3 "$TOOL/gen.py" --refresh-verify "$T/b1" 2>&1); rc=$?
[ $rc != 0 ] && [ "$(sha256sum < "$T/b1/sql/verify.sql")" = "$s0" ] && ! cmp -s "$T/b1/sql/verify.sql" "$T/verify-v1.sql" \
  && ok "R3 a check that is neither version is refused, file unchanged: ${out##*: }" || bad "R3 rc=$rc '$out'"
cp "$T/verify-v1.sql" "$T/b1/sql/verify.sql"; printf 'SLUG=b2\nSCHEMA=%s\n' "$SCH" > "$T/b1/batch.env"
out=$(python3 "$TOOL/gen.py" --refresh-verify "$T/b1" 2>&1); rc=$?
[ $rc != 0 ] && cmp -s "$T/b1/sql/verify.sql" "$T/verify-v1.sql" && ok "R4 another batch's verify.sql is refused: ${out##*: }" || bad "R4 rc=$rc '$out'"
printf 'SLUG=b1\nSCHEMA=%s_other\n' "$LS" > "$T/b1/batch.env"
out=$(python3 "$TOOL/gen.py" --refresh-verify "$T/b1" 2>&1); rc=$?
[ $rc != 0 ] && cmp -s "$T/b1/sql/verify.sql" "$T/verify-v1.sql" && ok "R5 a check for another staging schema is refused: ${out##*: }" || bad "R5 rc=$rc '$out'"

echo "== night.sh refresh-verify (fake ssh / scp: the target is a local directory, hosts *.invalid, own site file)"
N=$T/n; mkdir -p "$N/bin" "$N/import/b1/sql" "$N/target/b1/sql"
cat > "$N/bin/ssh" << EOF
#!/usr/bin/env bash
echo "\$*" >> "$N/ssh.log"
exec bash -c "\${@: -1}"
EOF
cat > "$N/bin/scp" << EOF
#!/usr/bin/env bash
echo "\$*" >> "$N/scp.log"
a=(); for x in "\$@"; do case \$x in -*) ;; *) a+=("\${x#*.invalid:}") ;; esac; done
exec cp -p "\${a[@]}"
EOF
chmod +x "$N/bin/ssh" "$N/bin/scp"
printf 'NAME_PREFIX=footage-heist\nIMPORT_DIR=%s/import\nTARGET_SSH=target.invalid\nTARGET_STAGING=/volume/test/import-staging\nTARGET_WORKDIR=%s/target\n' "$N" "$N" > "$N/site.env"
NENV=(env -i "PATH=$N/bin:$PATH" "HOME=$N" "IMPORT_SITE=$N/site.env")
NLS=$("${NENV[@]}" python3 "$TOOL/siteconf.py" shell | sed -n 's/^LEDGER_SCHEMA=//p')
printf 'SLUG=b1\nSCHEMA=%s_b1\nUCAM=cam1\nCAM=oldcam1\n' "$NLS" > "$N/import/b1/batch.env"
"${NENV[@]}" python3 - "$TOOL" "$N" "$NLS" << 'EOF' || { echo "ABORT: cannot generate the night.sh fixtures"; exit 70; }
import sys
tool, n, ls = sys.argv[1:]
sys.path.insert(0, tool)
import gen
counts = {x: 0 for x in gen.TABLES + ['detectionLabels']}
new = gen.verify_sql(ls, ls + '_b1', 'b1', counts, 'oldcam1', 'cam1')
open(f'{n}/verify-new.sql', 'w').write(new)
open(f'{n}/verify-v1.sql', 'w').write(new.replace(gen.rf_check_sql(ls, ls + '_b1', 'b1'), gen.rf_check_sql_v1(ls, ls + '_b1', 'b1')))
EOF
nreset() {  # <target state or "-" for no state file>: both copies of verify.sql as an earlier gen.py wrote them
  install -m 600 "$N/verify-v1.sql" "$N/import/b1/sql/verify.sql"; install -m 600 "$N/verify-v1.sql" "$N/target/b1/sql/verify.sql"
  if [ "$1" = - ]; then rm -f "$N/target/b1/state"; else echo "$1" > "$N/target/b1/state"; fi
  rm -f "$N/ssh.log" "$N/scp.log"
}
nrun() { "${NENV[@]}" bash "$TOOL/night.sh" "$N/import/b1" refresh-verify > "$N/out" 2>&1; echo $?; }
if [ "$("${NENV[@]}" bash -c 'command -v ssh; command -v scp' | tr '\n' ' ')" = "$N/bin/ssh $N/bin/scp " ]; then
  nreset done; rc=$(nrun)
  [ "$rc" = 0 ] && cmp -s "$N/import/b1/sql/verify.sql" "$N/verify-new.sql" && cmp -s "$N/target/b1/sql/verify.sql" "$N/verify-new.sql" \
    && [ "$(stat -c %a "$N/target/b1/sql/verify.sql")" = 600 ] && [ ! -e "$N/target/b1/sql/verify.sql.tmp" ] && grep -q '^verify.sql on the target = local' "$N/out" \
    && ok "N1 imported batch (state done): local and target verify.sql = this gen.py's, mode 600" || bad "N1 rc=$rc $(tail -3 "$N/out")"
  rc=$(nrun)
  [ "$rc" = 0 ] && grep -q 'already current' "$N/out" && cmp -s "$N/target/b1/sql/verify.sql" "$N/verify-new.sql" \
    && ok "N2 a second run: already current, target unchanged" || bad "N2 rc=$rc $(tail -3 "$N/out")"
  for st in none prepared -; do
    nreset "$st"; rc=$(nrun)
    [ "$rc" = 1 ] && grep -q '^REFUSED: refresh-verify is for an imported batch' "$N/out" && [ ! -s "$N/scp.log" ] \
      && cmp -s "$N/import/b1/sql/verify.sql" "$N/verify-v1.sql" && cmp -s "$N/target/b1/sql/verify.sql" "$N/verify-v1.sql" \
      && ok "N3 target state '$st': refused, nothing copied, both files unchanged" || bad "N3 '$st' rc=$rc $(tail -3 "$N/out")"
  done
  nreset done; sed -i 's/is distinct from (s\."cameraId"/is distinct from ( s."cameraId"/' "$N/import/b1/sql/verify.sql"; rc=$(nrun)
  [ "$rc" = 1 ] && [ ! -s "$N/scp.log" ] && cmp -s "$N/target/b1/sql/verify.sql" "$N/verify-v1.sql" \
    && ok "N4 a local check gen.py does not recognise: refused, target unchanged" || bad "N4 rc=$rc $(tail -3 "$N/out")"
else
  bad "night.sh harness: the fakes are not what night.sh resolves --- N tests skipped"
fi

echo "== $pass PASS, $fail FAIL"
[ $fail = 0 ]
