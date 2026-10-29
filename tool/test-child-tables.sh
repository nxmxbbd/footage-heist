#!/usr/bin/env bash
# test-child-tables.sh --- the child tables enhancedImages and transcriptions through the whole SQL path: extract.sh,
# gen.py, load, apply, verify.sql, rollback.sql. Two throw-away databases in the controller's container PG_CONTAINER
# stand in for the restored source (extract.sh / gen.py reach it through a fake docker that turns db src into it) and
# the target. Both get the same stub tables: the two tables under test with their columns, indexes and FKs as on Protect
# 7.3.70 (enhancedImages -> smartDetectObjects ON DELETE SET NULL, transcriptions -> events / cameras ON DELETE
# CASCADE), the other tables with the columns the SQL reads and FKs without any action (a wrong delete order fails).
# Also: extract.sql's guard still refuses the tables that are not imported. Needs no device and no batch. Exit 0 = no FAIL.
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
need PG_CONTAINER LEDGER_SCHEMA
T=$(mktemp -d /tmp/test-child-tables.XXXXXX)
SRC=child_tables_src; DST=child_tables_dst
LS=$LEDGER_SCHEMA; SCH=${LEDGER_SCHEMA}_b1
CT=/tmp/${T##*/}                                     # in the container: the batch's .copy files for load-docker.sql
REAL_DOCKER=$(command -v docker) || { echo "ABORT: no docker"; exit 70; }
cleanup() {
  "$REAL_DOCKER" exec "$PG_CONTAINER" psql -U postgres -qc "drop database if exists $SRC with (force)" -c "drop database if exists $DST with (force)" > /dev/null 2>&1
  "$REAL_DOCKER" exec "$PG_CONTAINER" rm -rf "$CT"; rm -rf "$T"
}
trap cleanup EXIT
pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
sq()  { "$REAL_DOCKER" exec -i "$PG_CONTAINER" psql -U postgres -d $SRC -X -At -F '|' -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
dq()  { "$REAL_DOCKER" exec -i "$PG_CONTAINER" psql -U postgres -d $DST -X -At -F '|' -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
drun() { "$REAL_DOCKER" exec -i "$PG_CONTAINER" psql -U postgres -d $DST -X -At -F '|' -v ON_ERROR_STOP=1 "$@" 2>&1; }   # stdin = sql
VAL=$(cd "$TOOL" && python3 -c 'import gen; print(gen.VALIDATED_VERSION)') || { echo "ABORT: cannot import gen.py"; exit 70; }

# fake docker: every "-d src" becomes "-d $SRC"; anything else goes to the real docker unchanged
mkdir -p "$T/bin"
cat > "$T/bin/docker" << EOF
#!/usr/bin/env bash
a=(); p=
for x in "\$@"; do [ "\$p" = -d ] && [ "\$x" = src ] && x=$SRC; a+=("\$x"); p=\$x; done
echo "\${a[*]}" >> "$T/docker.log"
exec "$REAL_DOCKER" "\${a[@]}"
EOF
chmod +x "$T/bin/docker"
FPATH=$T/bin:$PATH
# the tools must resolve the fake, never the real docker: they would read (extract.sh: replace) the real source's stage
[ "$(PATH=$FPATH bash -c 'command -v docker')" = "$T/bin/docker" ] \
  && [ "$(PATH=$FPATH python3 -c 'import shutil; print(shutil.which("docker"))')" = "$T/bin/docker" ] \
  || { echo "ABORT: the fake docker is not what bash / python3 resolve"; exit 70; }

CS=aaaaaaaaaaaaaaaaaaaa0a01   # source camera (the batch)
CD=bbbbbbbbbbbbbbbbbbbb0b02   # target camera
CO=cccccccccccccccccccc0c03   # another source camera
D0=1704153600000              # 2024-01-02 00:00Z: the batch's recording day
CUT=1706000000000             # takeover: events from here on stay behind
mkdir -p -m 700 "$T/b1"
printf 'SLUG=b1\nMAC=00005E005301\nCAM=%s\nUCAM=%s\nCUT=%s\nAI_SRC=aisrc0001\nAI_DST=aidst0002\nSCHEMA=%s\nAPPLY_TIMEOUT=60s\n' \
  "$CS" "$CD" "$CUT" "$SCH" > "$T/b1/batch.env"

DDL='
create table cameras (id varchar(255) primary key, "isAdopted" boolean);
create table nvrs (id varchar(255) primary key, version varchar(255));
create table "recordingFiles" (id varchar(255) primary key, "cameraId" varchar(255) references cameras(id), folder varchar(255),
  file varchar(255), start bigint, "end" bigint, size bigint, type varchar(255), channel int, free boolean, active boolean);
create table events (id varchar(255) primary key, type varchar(255), start bigint, "end" bigint,
  "cameraId" varchar(255) references cameras(id), "userId" varchar(255), "partitionId" varchar(255), "deletedAt" bigint, metadata json);
create table detections (id varchar(255) primary key, "recordingFileId" varchar(255) references "recordingFiles"(id));
create table partitions (id varchar(255) primary key, "recordingFileId" varchar(255) references "recordingFiles"(id));
create table "savedRecordingFiles" (id varchar(255) primary key, "recordingFileId" varchar(255) references "recordingFiles"(id));
create table "smartDetectObjectGroups" (id varchar(255) primary key, type varchar(255), "externalId" varchar(255), name varchar(255),
  description varchar(255), tags jsonb, "isNotificationEnabled" boolean, "isImageFixed" boolean);
create table "smartDetectObjects" (id varchar(255) primary key, "eventId" varchar(255) references events(id),
  "cameraId" varchar(255) references cameras(id), type varchar(255), attributes json,
  "smartDetectObjectGroupId" varchar(255) references "smartDetectObjectGroups"(id), metadata json);
create table "smartDetectObjectAreas" (id varchar(255) primary key, "smartDetectObjectId" varchar(255) references "smartDetectObjects"(id));
create table heatmaps (id varchar(255) primary key, "eventId" varchar(255) references events(id), "cameraId" varchar(255) references cameras(id));
create table "smartDetectTracks" (id varchar(255) primary key, "eventId" varchar(255) references events(id),
  "cameraId" varchar(255) references cameras(id));
create table "ramDetections" (id varchar(255) primary key, "eventId" varchar(255) references events(id),
  "cameraId" varchar(255) references cameras(id), "aiprocessorId" varchar(255),
  "smartDetectObjectId" varchar(255) references "smartDetectObjects"(id));
create table labels (lid serial, name varchar(255) unique, id varchar(255) primary key, "lastSeen" bigint,
  "createdAt" timestamptz, "updatedAt" timestamptz);
create table "detectionLabels" ("eventId" varchar(255) references events(id), labels integer[], id varchar(255) primary key,
  "createdAt" timestamptz, "updatedAt" timestamptz);
-- under test: as on Protect 7.3.70
create table "enhancedImages" (type varchar(255) not null,
  "smartDetectObjectId" varchar(255) references "smartDetectObjects"(id) on update cascade on delete set null,
  content bytea, id varchar(255) primary key, "createdAt" timestamptz not null, "updatedAt" timestamptz not null);
create unique index "enhancedImages_smartDetectObjectId_index" on "enhancedImages" ("smartDetectObjectId");
create table transcriptions ("eventId" varchar(255) references events(id) on update cascade on delete cascade,
  "cameraId" varchar(255) references cameras(id) on update cascade on delete cascade, start bigint not null, "end" bigint not null,
  text text not null, id varchar(255) primary key, "createdAt" timestamptz not null, "updatedAt" timestamptz not null);
create index "transcriptions_eventId_start_index" on transcriptions ("eventId", start);
-- not imported: extract.sql refuses a batch that has any of these
create table "smartDetectSessionObjects" (id varchar(255) primary key, "smartDetectObjectId" varchar(255) references "smartDetectObjects"(id));
create table "smartDetectSessions" (id varchar(255) primary key, "eventId" varchar(255) references events(id));
create table "favoriteEvents" (id varchar(255) primary key, "eventId" varchar(255) references events(id));
create table thumbnails (id varchar(255) primary key, "eventId" varchar(255) references events(id));
create table "packageThumbnails" (id varchar(255) primary key, "eventId" varchar(255) references events(id));
'
F=00005E005301_0_rotating
SRC_ROWS="
insert into cameras values ('$CS', true), ('$CO', true);
insert into \"recordingFiles\" values
  ('rf1', '$CS', '/srv/unifi-protect/video/2024/01/02', '${F}_$D0.ubv', $D0, $D0 + 86400000, 1000, 'rotating', 0, false, true),
  ('rf-free', '$CS', '/srv/unifi-protect/video/2024/01/03', '${F}_1704240000000.ubv', 1704240000000, 1704326400000, 1000, 'rotating', 0, true, false);
insert into events values
  ('ev-audio', 'smartAudioDetect', $D0 + 1000, $D0 + 5000, '$CS', null, null, null, '{\"sttState\":\"done\"}'),
  ('ev-zone', 'smartDetectZone', $D0 + 10000, $D0 + 20000, '$CS', null, null, null, '{\"detectedThumbnails\":[{\"labels\":[\"group:grp1\"]}]}'),
  ('ev-late', 'smartAudioDetect', $CUT + 1000, $CUT + 2000, '$CS', null, null, null, '{}'),
  ('ev-other', 'smartAudioDetect', $D0 + 1000, $D0 + 5000, '$CO', null, null, null, '{}');
insert into \"smartDetectObjectGroups\" values ('grp1', 'face', 'ext1', 'A face', null, '[]', false, false);
insert into \"smartDetectObjects\" values
  ('obj-face', 'ev-zone', '$CS', 'face', '{\"_group_id\":\"grp1\"}', 'grp1', '{}'),
  ('obj-person', 'ev-zone', '$CS', 'person', '{}', null, '{}'),
  ('obj-other', 'ev-other', '$CO', 'face', '{}', null, '{}');
insert into \"smartDetectObjectAreas\" values ('area1', 'obj-face');
insert into heatmaps values ('hm1', 'ev-zone', '$CS');
insert into \"smartDetectTracks\" values ('trk1', 'ev-zone', '$CS');
insert into \"ramDetections\" values ('ram1', 'ev-zone', '$CS', 'aisrc0001', 'obj-face');
insert into labels values (1, 'person', 'lab-person', 1, now(), now()), (2, 'group:grp1', 'lab-grp1', 1, now(), now());
insert into \"detectionLabels\" values ('ev-zone', '{1,2}', 'dl1', now(), now());
insert into \"enhancedImages\" values ('face', 'obj-face', decode('ffd8ffe000104a46494600', 'hex'), 'img1', now(), now()),
  ('face', 'obj-other', decode('ffd8ff01', 'hex'), 'img-other', now(), now());
insert into transcriptions values
  ('ev-audio', '$CS', $D0 + 1200, $D0 + 2400, 'synthetic words one', 'tr1', now(), now()),
  ('ev-audio', '$CS', $D0 + 2500, $D0 + 4000, 'synthetic words two', 'tr2', now(), now()),
  ('ev-late', '$CS', $CUT + 1100, $CUT + 1900, 'after the takeover', 'tr-late', now(), now()),
  ('ev-other', '$CO', $D0 + 1100, $D0 + 1900, 'another camera', 'tr-other', now(), now());
select 'setup ok';"
DST_ROWS="
insert into cameras values ('$CD', true);
insert into nvrs values ('nvr1', '$VAL');
insert into \"recordingFiles\" values
  ('rf-native', '$CD', '/srv/unifi-protect/video/2024/03/01', '${F}_1709251200000.ubv', 1709251200000, 1709337600000, 1000, 'rotating', 0, false, true);
insert into events values ('ev-native', 'smartAudioDetect', 1709251300000, 1709251400000, '$CD', null, null, null, '{}');
insert into \"smartDetectObjects\" values ('obj-native', 'ev-native', '$CD', 'face', '{}', null, '{}');
insert into \"enhancedImages\" values ('face', 'obj-native', decode('ffd8ff02', 'hex'), 'img-native', now(), now());
insert into transcriptions values ('ev-native', '$CD', 1709251310000, 1709251320000, 'native words', 'tr-native', now(), now());
insert into labels values (7, 'person', 'lab-person-target', 1, now(), now());
select setval('labels_lid_seq', 7);
select 'setup ok';"

newdb() { "$REAL_DOCKER" exec "$PG_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -qc "drop database if exists $1 with (force)" -c "create database $1" > /dev/null 2>&1; }
newdb $SRC || { echo "ABORT: cannot create database $SRC in $PG_CONTAINER"; exit 70; }
r=$(sq "$DDL $SRC_ROWS"); [ "$(printf '%s\n' "$r" | tail -1)" = 'setup ok' ] || { echo "ABORT: source fixture: $r"; exit 70; }

extract() { PATH=$FPATH bash "$TOOL/extract.sh" "$T/b1" > "$T/extract.out" 2>&1; }
staged() { sq "select (select string_agg(id || ':' || coalesce(\"cameraId\", 'null'), ',' order by id collate \"C\") from stage.transcriptions) || ' / ' ||
                      (select string_agg(id || ':' || \"smartDetectObjectId\", ',' order by id collate \"C\") from stage.\"enhancedImages\")"; }
WANT_STAGED="tr1:$CD,tr2:$CD / img1:obj-face"

echo "== extract.sql"
extract; rc=$?
if [ $rc = 0 ] && [ "$(staged)" = "$WANT_STAGED" ] && grep -qx 'enhancedImages|1' "$T/extract.out" && grep -qx 'transcriptions|2' "$T/extract.out"; then
  ok "X1 the batch's enhanced image and transcriptions staged, camera id rewritten ($(staged)); other camera / after the takeover left behind"
else bad "X1 rc=$rc staged '$(staged)', want '$WANT_STAGED'; $(tail -3 "$T/extract.out" | tr '\n' ' ')"; fi
[ "$(sq "select md5(s.content) = md5(p.content) from stage.\"enhancedImages\" s join public.\"enhancedImages\" p using (id)")" = t ] \
  && ok "X2 image content staged byte for byte" || bad "X2 content differs"
for g in "\"smartDetectSessionObjects\"|'sso1', 'obj-face'" "\"smartDetectSessions\"|'ss1', 'ev-zone'" "\"favoriteEvents\"|'fav1', 'ev-audio'" \
         "thumbnails|'th1', 'ev-zone'" "\"packageThumbnails\"|'pt1', 'ev-zone'"; do
  t=${g%%|*}; v=${g#*|}; n=${t//\"/}
  r=$(sq "insert into $t values ($v)"); extract; rc=$?; sq "delete from $t" > /dev/null
  [ "$r" = 'INSERT 0 1' ] && [ $rc != 0 ] && grep -q "$n: 1 rows, not handled" "$T/extract.out" && [ "$(staged)" = "$WANT_STAGED" ] \
    && ok "X3 $n on the batch: refused, the previous stage untouched" || bad "X3 $n: insert '$r' rc=$rc $(grep -m1 ERROR "$T/extract.out")"
done
r=$(sq "insert into transcriptions values ('ev-audio', '$CO', $D0 + 1300, $D0 + 1400, 'misfiled', 'tr-x', now(), now())"); extract; rc=$?
sq "delete from transcriptions where id = 'tr-x'" > /dev/null
[ "$r" = 'INSERT 0 1' ] && [ $rc != 0 ] && grep -q 'transcriptions on another camera than the batch camera' "$T/extract.out" && [ "$(staged)" = "$WANT_STAGED" ] \
  && ok "X4 a batch event's transcription on another camera: refused" || bad "X4 insert '$r' rc=$rc $(grep -m1 ERROR "$T/extract.out")"
r=$(sq "insert into transcriptions values ('ev-audio', null, $D0 + 1300, $D0 + 1400, 'no camera', 'tr-n', now(), now())"); extract; rc=$?
sq "delete from transcriptions where id = 'tr-n'" > /dev/null
[ "$r" = 'INSERT 0 1' ] && [ $rc = 0 ] && [ "$(staged)" = "tr-n:null,tr1:$CD,tr2:$CD / img1:obj-face" ] \
  && ok "X5 a transcription without a camera stays without one" || bad "X5 insert '$r' rc=$rc staged '$(staged)'"
extract || { bad "extract of the clean fixture failed: $(tail -3 "$T/extract.out" | tr '\n' ' ')"; echo "== $pass PASS, $fail FAIL"; exit 1; }

echo "== gen.py"
out=$(PATH=$FPATH python3 "$TOOL/gen.py" "$T/b1" 2>&1); rc=$?
cnt=$(python3 -c "import json,sys; c=json.load(open(sys.argv[1]))['counts']; print(c['enhancedImages'], c['transcriptions'])" "$T/b1/manifest.json" 2>&1)
[ $rc = 0 ] && [ "$cnt" = '1 2' ] && [ "$(wc -l < "$T/b1/data/enhancedImages.copy")" = 1 ] && [ "$(wc -l < "$T/b1/data/transcriptions.copy")" = 2 ] \
  && ok "G1 manifest counts enhancedImages 1, transcriptions 2; both exported" || bad "G1 rc=$rc counts '$cnt': $(printf '%s\n' "$out" | tail -2)"
RB=$T/b1/sql/rollback.sql
# static: transcriptions (ON DELETE CASCADE) would vanish with their events even without their own delete, so only the
# text shows a missing one; the images (ON DELETE SET NULL) are also checked by the effect (R3)
delline() { grep -n "^delete from public\.$1 where id in (select id from led where tbl = '${1//\"/}')" "$RB" | cut -d: -f1; }
miss=$(cd "$TOOL" && python3 -c 'import gen; print(" ".join(gen.TABLES))' | tr ' ' '\n' | while read -r t; do
  q=$t; case $t in *[A-Z]*) q="\"$t\"" ;; esac; [ -n "$(delline "$q")" ] || echo "$t"; done)
[ -z "$miss" ] && ok "G2 rollback.sql deletes every imported table explicitly by its ledger rows" || bad "G2 no explicit delete for: $(echo $miss)"
e=$(delline '"enhancedImages"'); o=$(delline '"smartDetectObjects"'); tr=$(delline transcriptions); ev=$(delline events)
[ -n "$e" ] && [ -n "$o" ] && [ -n "$tr" ] && [ -n "$ev" ] && [ "$e" -lt "$o" ] && [ "$tr" -lt "$ev" ] \
  && ok "G3 children first: rollback.sql deletes enhancedImages before smartDetectObjects, transcriptions before events" || bad "G3 lines: images $e objects $o transcriptions $tr events $ev"

echo "== load / apply / verify / rollback on the stub target"
"$REAL_DOCKER" exec "$PG_CONTAINER" mkdir -p "$CT" && "$REAL_DOCKER" cp "$T/b1/data" "$PG_CONTAINER:$CT/data" \
  || { echo "ABORT: cannot copy the batch data into $PG_CONTAINER"; exit 70; }
sed "s#'/in/b1/data/#'$CT/data/#" "$T/b1/sql/load-docker.sql" > "$T/load.sql"
fingerprint() {   # content of every public table (row text sorted), sequences excluded
  dq "select string_agg(t || ':' || h, ',' order by t) from (
       select c.relname t, (xpath('/row/h/text()', query_to_xml(format(
         'select md5(coalesce(string_agg(x::text, chr(10) order by x::text), %L)) h from public.%I x', '', c.relname), false, true, '')))[1]::text h
       from pg_class c join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public' where c.relkind = 'r') z" | md5sum | cut -c1-12
}
reset_dst() {
  newdb $DST || { echo "ABORT: cannot create database $DST"; exit 70; }
  local r; r=$(dq "$DDL $DST_ROWS"); [ "$(printf '%s\n' "$r" | tail -1)" = 'setup ok' ] || { echo "ABORT: target fixture: $r"; exit 70; }
  r=$(drun < "$T/load.sql"); printf '%s\n' "$r" | grep -qx 'staged ok' || { echo "ABORT: load: $(printf '%s\n' "$r" | grep -m1 ERROR)"; exit 70; }
}
apply()    { drun < "$T/b1/sql/apply.sql"; }
rollback() { drun "$@" < "$RB"; }
verify()   { drun < "$T/b1/sql/verify.sql"; }
led()      { dq "select count(*) from $LS.ledger where batch = 'b1'${1:+ and tbl = '$1'}"; }
imported() { dq "select (select string_agg(id || ':' || \"cameraId\", ',' order by id collate \"C\") from transcriptions) || ' / ' ||
                        (select string_agg(id || ':' || coalesce(\"smartDetectObjectId\", 'null'), ',' order by id collate \"C\") from \"enhancedImages\")"; }

reset_dst; f0=$(fingerprint)
out=$(apply)
printf '%s\n' "$out" | grep -qx 'enhancedImages|1' && printf '%s\n' "$out" | grep -qx 'transcriptions|2' && ! printf '%s\n' "$out" | grep -q ERROR \
  && [ "$(imported)" = "tr-native:$CD,tr1:$CD,tr2:$CD / img-native:obj-native,img1:obj-face" ] \
  && ok "A1 apply: ledger enhancedImages 1, transcriptions 2; rows on the target camera ($(imported))" || bad "A1 $(printf '%s\n' "$out" | grep -m1 ERROR) rows '$(imported)'"
[ "$(dq "select md5(content) from \"enhancedImages\" where id = 'img1'")" = "$(sq "select md5(content) from public.\"enhancedImages\" where id = 'img1'")" ] \
  && ok "A2 image content imported byte for byte" || bad "A2 content differs"
v=$(verify)
printf '%s\n' "$v" | grep -qx 'PASS present enhancedImages 1/1 (batch 1)' && printf '%s\n' "$v" | grep -qx 'PASS present transcriptions 2/2 (batch 2)' \
  && ! printf '%s\n' "$v" | grep -q '^FAIL\|ERROR' && ok "V1 verify.sql: both present, $(printf '%s\n' "$v" | grep -c '^PASS') PASS, 0 FAIL" \
  || bad "V1 $(printf '%s\n' "$v" | grep -E '^FAIL|ERROR|present (enhancedImages|transcriptions)' | tr '\n' ' ')"
out=$(apply); printf '%s\n' "$out" | grep -q 'batch b1 already applied' && ok "A3 second apply refused" || bad "A3 $(printf '%s\n' "$out" | tail -1)"

f1=$(fingerprint)
dq "insert into \"enhancedImages\" values ('face', 'obj-person', decode('ffd8ff03', 'hex'), 'img-new', now(), now())" > /dev/null
out=$(rollback); dq "delete from \"enhancedImages\" where id = 'img-new'" > /dev/null
printf '%s\n' "$out" | grep -q 'native children|smartDetectObjects|enhancedImages|smartDetectObjectId|1' && printf '%s\n' "$out" | grep -q 'native rows hang off imported' \
  && [ "$(fingerprint)" = "$f1" ] && ok "R1 a native enhanced image on an imported object: reported, rollback refused" \
  || bad "R1 $(printf '%s\n' "$out" | grep -E 'native|ERROR' | head -2 | tr '\n' ' ')"
dq "insert into transcriptions values ('ev-audio', '$CD', $D0 + 4100, $D0 + 4500, 'native words', 'tr-new', now(), now())" > /dev/null
out=$(rollback); dq "delete from transcriptions where id = 'tr-new'" > /dev/null
printf '%s\n' "$out" | grep -q 'native children|events|transcriptions|eventId|1' && printf '%s\n' "$out" | grep -q 'native rows hang off imported' \
  && [ "$(fingerprint)" = "$f1" ] && ok "R2 a native transcription on an imported event: reported, rollback refused" \
  || bad "R2 $(printf '%s\n' "$out" | grep -E 'native|ERROR' | head -2 | tr '\n' ' ')"
out=$(rollback)
! printf '%s\n' "$out" | grep -q ERROR && [ "$(fingerprint)" = "$f0" ] && [ "$(led)" = 0 ] \
  && [ "$(imported)" = "tr-native:$CD / img-native:obj-native" ] \
  && ok "R3 rollback: every public table as before the apply, no image left behind ($(imported))" \
  || bad "R3 $(printf '%s\n' "$out" | grep -m1 ERROR) fingerprint $f0 -> $(fingerprint), rows '$(imported)'"
out=$(apply); printf '%s\n' "$out" | grep -qx 'transcriptions|2' && printf '%s\n' "$out" | grep -qx 'enhancedImages|1' \
  && ok "R4 re-apply after the rollback" || bad "R4 $(printf '%s\n' "$out" | grep -m1 ERROR)"

reset_dst
apply > /dev/null; dq "delete from transcriptions where id = 'tr1'; delete from \"enhancedImages\" where id = 'img1'" > /dev/null
v=$(verify)
printf '%s\n' "$v" | grep -qx 'FAIL present enhancedImages 0/1 (batch 1)' && printf '%s\n' "$v" | grep -qx 'FAIL present transcriptions 1/2 (batch 2)' \
  && ok "V2 an imported image and transcription gone since the import: verify.sql fails both" \
  || bad "V2 $(printf '%s\n' "$v" | grep -E 'present (enhancedImages|transcriptions)|ERROR' | tr '\n' ' ')"

for c in "enhancedImages|insert into \"smartDetectObjects\" values ('obj-native2', 'ev-native', '$CD', 'face', '{}', null, '{}');
          insert into \"enhancedImages\" values ('face', 'obj-native2', decode('ffd8ff04', 'hex'), 'img1', now(), now())" \
         "transcriptions|insert into transcriptions values ('ev-native', '$CD', 1709251330000, 1709251340000, 'native words', 'tr1', now(), now())"; do
  t=${c%%|*}; reset_dst; dq "${c#*|}" > /dev/null; f0=$(fingerprint)
  out=$(apply)
  printf '%s\n' "$out" | grep -q "duplicate key value violates unique constraint \"${t}_pkey\"" && [ "$(fingerprint)" = "$f0" ] && [ "$(led)" = 0 ] \
    && ok "C1 an imported $t id already on the target: apply aborts, nothing changed" || bad "C1 $t: $(printf '%s\n' "$out" | grep -m1 ERROR)"
done

echo "== $pass PASS, $fail FAIL"
[ $fail = 0 ]
