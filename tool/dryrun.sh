#!/usr/bin/env bash
# dryrun.sh <batch_dir> --- scenario tests of load/apply/rollback against a fresh clone of the target DB per scenario.
# Expected values come from the batch (manifest.json) and from the clone itself; fixtures (groups, files, events) are
# picked from the batch's own data. A scenario whose fixture does not exist in this batch is SKIPped (not passed).
# Clone: TARGET_DUMP env > CLONE in batch.env > newest <batch>/<target label>-clone-*.dump (night.sh clone-dump).
# Disposable: runs only inside the controller's container PG_CONTAINER; never touches a device. Exit 0 = no FAIL.
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
B=$(cd "$1" && pwd); SQL=$B/sql
. "$B/batch.env"
. "$TOOL/lib-test.sh"
LS=$LEDGER_SCHEMA
PSQL=(docker exec -i "$PG_CONTAINER" psql -U postgres -d dst -At -F '|' -v ON_ERROR_STOP=1)
pass=0; fail=0; skip=0
ok()   { echo "  PASS $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL $*"; fail=$((fail+1)); }
skp()  { echo "  SKIP $*"; skip=$((skip+1)); }
q()    { "${PSQL[@]}" -c "$1" 2>&1; }
run()  { "${PSQL[@]}" "$@" 2>&1; }   # stdin = sql file
reset_dst() { restore_clone; }
# content fingerprint of every public table (row text sorted), sequences excluded
fingerprint() {
  q "select string_agg(t || ':' || h, ',' order by t) from (
       select c.relname t, (xpath('/row/h/text()', query_to_xml(format(
         'select md5(coalesce(string_agg(x::text, chr(10) order by x::text), %L)) h from public.%I x', '', c.relname), false, true, '')))[1]::text h
       from pg_class c join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public' where c.relkind = 'r') z" | md5sum | cut -c1-12
}
load()     { run < "$SQL/load-docker.sql" | grep -E 'staged ok|ERROR' ; }
apply()    { run < "$SQL/apply.sql"; }
rollback() { run "$@" < "$SQL/rollback.sql"; }
cnt()      { q "select count(*) from public.events where \"cameraId\"='$UCAM'"; }
led()      { q "select count(*) from $LS.ledger where batch = '$SLUG'${1:+ and tbl = '$1'}"; }
GRP='public."smartDetectObjectGroups"'; SG="$SCHEMA.\"smartDetectObjectGroups\""; SO="$SCHEMA.\"smartDetectObjects\""
ginsert() {   # $1 externalId, $2 id, $3 type --- a group the target "created before the window"
  q "insert into $GRP (\"externalId\",type,\"isImageFixed\",\"detectionsCount\",\"isNotificationEnabled\",\"createdAt\",tags,id,\"updatedAt\",metadata,\"isDegraded\")
     values ('$1','$3',false,1,false,now(),'{}','$2',now(),'{}',false)"
}
hasgrp() { echo "strpos(metadata::text, '\"group:$1\"') > 0"; }   # exact label token in events.metadata

batch_check; resolve_clone
WANT_EV=$(mj events)
VAL=$(cd "$TOOL" && python3 -c 'import gen; print(gen.VALIDATED_VERSION)')
echo "batch $SLUG schema $SCHEMA: events $WANT_EV, recordingFiles $(mj recordingFiles), groups $(mj smartDetectObjectGroups), objects $(mj smartDetectObjects)"

echo "S1 happy path + idempotence guard"
reset_dst; NATIVE0=$(cnt)
lb=none; [ -n "$(q "select to_regclass('$LS.ledger')")" ] && lb=$(q "select coalesce(string_agg(batch || '=' || n, ' '), 'none') from (select batch, count(*) n from $LS.ledger group by batch) z")
echo "  info: clone has $NATIVE0 native events on the camera; ledger rows of earlier batches: $lb"
s=$(load); [ "$s" = 'staged ok' ] && ok "staged into $SCHEMA" || bad "load: $s"
out=$(apply); echo "$out" | grep -qx "events|$WANT_EV" && ok "apply inserted $WANT_EV events" || bad "apply: $(echo "$out" | grep -m1 ERROR)"
v=$(run < "$SQL/verify.sql"); echo "$v" | grep -q '^FAIL' && bad "verify.sql: $(echo "$v" | grep -m2 '^FAIL' | tr '\n' ' ')" || ok "verify.sql: $(echo "$v" | grep -c '^PASS') PASS, 0 FAIL"
M0=$(led merge:smartDetectObjectGroups)
RN=$(q "select string_agg(quote_literal(split_part(id, '->', 1)), ',') from $LS.ledger where batch = '$SLUG' and tbl = 'merge:smartDetectObjectGroups' and split_part(id, '->', 1) <> split_part(id, '->', 2)")
echo "  info: $M0 group merges on this clone; renamed (source id -> other target id): ${RN:-none}"
d=$(q "select count(*) from $SCHEMA.events s join public.events p using (id) where s.metadata::text <> p.metadata::text
       and not exists (select 1 from $LS.ledger l where l.batch = '$SLUG' and l.tbl = 'merge:smartDetectObjectGroups'
                       and split_part(l.id, '->', 1) <> split_part(l.id, '->', 2) and strpos(s.metadata::text, '\"group:' || split_part(l.id, '->', 1) || '\"') > 0)")
[ "$d" = 0 ] && ok "staging never rewritten; only events labelled with a renamed group differ" || bad "unexpected metadata differences ($d)"
if [ -n "$RN" ]; then
  [ "$(q "select count(*) from $SO where \"smartDetectObjectGroupId\" in ($RN)")" -gt 0 ] && ok "staging still holds the source group ids (apply worked on temp copies)" || bad "staging was rewritten"
else skp "no group renamed on this clone (S5 / S14 force renames)"; fi
out=$(apply); echo "$out" | grep -q 'already applied' && ok "second apply refused" || bad "second apply not refused"
purged=$(q "select count(*) from public.events e where e.id in (select id from $LS.ledger where batch = '$SLUG' and tbl='events') and e.\"end\" < (select min(start) from public.\"recordingFiles\" where \"cameraId\"='$UCAM' and type='rotating' and not free)")
[ "$purged" = 0 ] && ok "startup-purge simulation: 0 imported events end before the camera's earliest rotating file" || bad "startup purge would delete $purged imported events"

echo "S2 rollback restores every public table exactly"
reset_dst; f0=$(fingerprint); load >/dev/null; apply >/dev/null
f1=$(fingerprint); [ "$f0" != "$f1" ] && ok "fingerprint changed after apply" || bad "apply changed nothing?"
out=$(rollback); echo "$out" | grep -q ERROR && bad "rollback: $(echo "$out" | grep -m1 ERROR)"
f2=$(fingerprint); [ "$f0" = "$f2" ] && ok "fingerprint after rollback == before ($f0)" || bad "fingerprint differs: before $f0 after $f2"
[ "$(led)" = 0 ] && ok "ledger of $SLUG empty, history kept ($(q "select count(*) from $LS.ledger_history where batch = '$SLUG'") rows)" || bad "ledger not empty"

echo "S3 re-apply after rollback"
out=$(apply); echo "$out" | grep -qx "events|$WANT_EV" && ok "re-apply ok" || bad "re-apply: $(echo "$out" | grep -m1 ERROR)"

echo "S4 native object on an imported group survives rollback"
reset_dst; load >/dev/null; apply >/dev/null
IFS='|' read -r g gt < <(q "select g.id, g.type from $LS.ledger l join $GRP g on g.id = l.id where l.batch = '$SLUG' and l.tbl = 'smartDetectObjectGroups' and g.\"externalId\" is not null order by l.id limit 1")
if [ -z "${g:-}" ]; then skp "no inserted group with an externalId in this batch"; else
  ev=$(q "select id from public.events where \"cameraId\" <> '$UCAM' order by start desc limit 1")
  q "insert into public.\"smartDetectObjects\" (\"eventId\",\"cameraId\",type,attributes,\"smartDetectObjectGroupId\",\"detectedAt\",id,\"createdAt\",\"updatedAt\",metadata)
     select '$ev', \"cameraId\", '$gt', '{}', '$g', 1, 'test-native-obj', now(), now(), '{}' from public.events where id='$ev'" >/dev/null
  out=$(rollback); echo "$out" | grep -q 'kept groups (native references)|1' && ok "group $g kept" || bad "kept-group report: $(echo "$out" | grep -E 'kept|ERROR' | head -2)"
  [ "$(q "select count(*) from $GRP where id='$g'")" = 1 ] && ok "group still present" || bad "group deleted"
  out=$(apply); echo "$out" | grep -qx "merge:smartDetectObjectGroups|$((M0 + 1))" && ok "re-apply merges the kept group ($((M0 + 1)) merges)" || bad "re-apply after kept group: $(echo "$out" | grep -E 'merge|ERROR' | head -2)"
fi

echo "S5 target created a group with one of the batch's externalIds before the window -> merged (renamed)"
reset_dst; load >/dev/null
IFS='|' read -r e5 s5 t5 < <(q "select s.\"externalId\", s.id, s.type from $SG s where s.\"externalId\" is not null
                                  and not exists (select 1 from $GRP d where d.\"externalId\" = s.\"externalId\" or d.id = s.id) order by s.id limit 1")
if [ -z "${e5:-}" ]; then skp "every batch group with an externalId already exists on the target"; else
  n5=$(q "select count(*) from $SO where \"smartDetectObjectGroupId\" = '$s5'")
  ginsert "$e5" dryrun-s5 "$t5" >/dev/null
  out=$(apply); echo "$out" | grep -qx "merge:smartDetectObjectGroups|$((M0 + 1))" && ok "apply merged $((M0 + 1)) (incl. new externalId $e5)" || bad "S5: $(echo "$out" | grep -E 'merge|ERROR' | head -2)"
  [ "$(q "select count(*) from $GRP where \"externalId\"='$e5'")" = 1 ] && ok "exactly one group for externalId $e5" || bad "duplicate externalId $e5"
  [ "$(q "select count(*) from public.\"smartDetectObjects\" where \"smartDetectObjectGroupId\" = 'dryrun-s5'")" = "$n5" ] && ok "$n5 objects of $s5 now on the target's group" || bad "objects not moved to dryrun-s5"
fi

echo "S6 same group id with a different externalId -> abort, nothing changed"
reset_dst; load >/dev/null
sid=$(q "select s.id from $SG s where not exists (select 1 from $GRP d where d.id = s.id) order by (s.\"externalId\" is not null), s.id limit 1")
ginsert dryrun77777 "$sid" face >/dev/null
f0=$(fingerprint); out=$(apply)
echo "$out" | grep -q 'without the same externalId' && ok "apply aborted on id collision ($sid)" || bad "S6 not aborted: $(echo "$out" | tail -2)"
[ "$(fingerprint)" = "$f0" ] && ok "fingerprint unchanged after aborted apply" || bad "aborted apply left changes"

echo "S7 user-made child (critical event) on an imported event blocks rollback"
reset_dst; load >/dev/null; apply >/dev/null
iev=$(q "select id from $LS.ledger where batch = '$SLUG' and tbl='events' limit 1")
ins=$(q "insert into public.\"criticalEvents\" (id, \"eventId\", \"createdAt\") values (gen_random_uuid(), '$iev', 1)")
echo "$ins" | grep -q ERROR && bad "test setup: criticalEvents insert failed: $ins"
out=$(rollback); echo "$out" | grep -q 'native rows hang off imported' && ok "rollback refused without force" || bad "S7: $(echo "$out" | grep -m1 -E 'ERROR|report')"
out=$(rollback -v force=true); echo "$out" | grep -q ERROR && bad "forced rollback: $(echo "$out" | grep -m1 ERROR)" || ok "forced rollback ok"

echo "S8 apply killed mid-way commits nothing"
reset_dst; load >/dev/null; f0=$(fingerprint)
slow=$(mktemp /tmp/apply-slow.XXXXXX)
sed 's/^-- 3. labels missing on the target/select pg_sleep(30);\n-- 3. labels missing on the target/' "$SQL/apply.sql" > "$slow"
( docker exec -i "$PG_CONTAINER" psql -U postgres -d dst -v ON_ERROR_STOP=1 < "$slow" > "$slow.out" 2>&1 & )
# wait until the apply really sits in the injected sleep (big batches need far more than a few seconds to get there)
for i in $(seq 1 240); do [ "$(q "select count(*) from pg_stat_activity where datname='dst' and state='active' and query like '%pg_sleep(30)%' and pid <> pg_backend_pid()")" = 1 ] && break; sleep 0.5; done
k=$(q "select count(*) filter (where pg_terminate_backend(pid)) from pg_stat_activity where datname='dst' and query like '%pg_sleep(30)%' and pid <> pg_backend_pid()")
for i in $(seq 1 40); do [ "$(q "select count(*) from pg_stat_activity where datname='dst' and pid <> pg_backend_pid()")" = 0 ] && break; sleep 0.5; done
[ "$k" = 1 ] && ok "apply terminated inside its transaction (after the group / object rewrite)" || bad "S8 setup: terminated $k sessions"
[ "$(fingerprint)" = "$f0" ] && ok "fingerprint unchanged after killed apply" || bad "killed apply left changes"
[ "$(led)" = 0 ] && ok "ledger of $SLUG empty after killed apply" || bad "ledger has rows after kill"
out=$(apply); echo "$out" | grep -qx "events|$WANT_EV" && ok "apply after kill ok" || bad "apply after kill: $(echo "$out" | grep -m1 ERROR)"

echo "S9 native saved clip on an imported recording file blocks rollback (generic FK gate)"
reset_dst; load >/dev/null; apply >/dev/null
rf=$(q "select id from $LS.ledger where batch = '$SLUG' and tbl='recordingFiles' limit 1")
q "insert into public.\"savedRecordings\" (id, \"cameraId\", \"startTimestamp\", \"endTimestamp\", \"createdAt\", \"updatedAt\") values ('test-sr', '$UCAM', 1, 2, now(), now());
   insert into public.\"savedRecordingFiles\" (id, \"savedRecordingId\", \"recordingFileId\") values ('test-srf', 'test-sr', '$rf')" >/dev/null
f1=$(fingerprint); out=$(rollback)
echo "$out" | grep -q 'native children|recordingFiles|savedRecordingFiles|recordingFileId|1' && echo "$out" | grep -q 'native rows hang off imported' \
  && ok "savedRecordingFiles reported + rollback refused" || bad "S9: $(echo "$out" | grep -E 'native|ERROR' | head -3 | tr '\n' ' ')"
[ "$(fingerprint)" = "$f1" ] && ok "refused rollback changed nothing" || bad "refused rollback left changes"

echo "S10 imported recording row changed by msr (end/size) -> rollback refused even with force"
reset_dst; load >/dev/null; apply >/dev/null
q "update public.\"recordingFiles\" set \"end\" = \"end\" + 1000, size = size + 1 where id = (select id from $LS.ledger where batch = '$SLUG' and tbl='recordingFiles' order by id limit 1)" >/dev/null
f1=$(fingerprint); out=$(rollback -v force=true)
echo "$out" | grep -q 'changed since import' && ok "rollback refused (recycled / appended file)" || bad "S10: $(echo "$out" | grep -m1 -E 'ERROR|rolled')"
[ "$(fingerprint)" = "$f1" ] && ok "fingerprint unchanged" || bad "S10 left changes"

echo "S11 imported group renamed by the user / linked to a person -> kept on rollback"
reset_dst; load >/dev/null; apply >/dev/null
g1=$(q "select id from $LS.ledger where batch = '$SLUG' and tbl='smartDetectObjectGroups' order by id limit 1")
g2=$(q "select id from $LS.ledger where batch = '$SLUG' and tbl='smartDetectObjectGroups' order by id desc limit 1")
if [ -z "$g1" ] || [ "$g1" = "$g2" ]; then skp "fewer than 2 inserted groups in this batch"; else
  o1=$(q "update $GRP set name = 'Named after import' where id = '$g1'")
  ulp=$(q "select \"ulpId\" from public.\"ulpUsers\" where \"ulpId\" not in (select \"ulpId\" from public.\"ulpUserFaceGroupConnections\") limit 1")
  o2=$(q "insert into public.\"ulpUserFaceGroupConnections\" (id, \"ulpId\", \"faceGroupId\", \"createdAt\", \"updatedAt\") values ('test-ulp', '$ulp', '$g2', now(), now())")
  [ "$o1" = "UPDATE 1" ] && [ "$o2" = "INSERT 0 1" ] && ok "setup: group renamed, person ($ulp) linked to $g2" || bad "S11 setup: '$o1' '$o2' (ulp='$ulp')"
  out=$(rollback); echo "$out" | grep -q ERROR && bad "S11 rollback: $(echo "$out" | grep -m1 ERROR)"
  echo "$out" | grep -q 'kept groups (native references)|2' && ok "2 groups kept (renamed + person link)" || bad "S11 kept: $(echo "$out" | grep kept | tr '\n' ' ')"
  [ "$(q "select count(*) from $GRP where id in ('$g1','$g2')")" = 2 ] && [ "$(q "select count(*) from public.\"ulpUserFaceGroupConnections\" where id='test-ulp'")" = 1 ] \
    && ok "groups + person link survive" || bad "S11 group or link deleted"
  [ "$(cnt)" = "$NATIVE0" ] && ok "imported events gone ($NATIVE0 native remain)" || bad "S11 events left: $(cnt) vs $NATIVE0"
fi

echo "S12 trial mode (-v trial=1) ends in ROLLBACK"
reset_dst; load >/dev/null; f0=$(fingerprint)
out=$(run -v trial=1 < "$SQL/apply.sql"); echo "$out" | grep -qx 'TRIAL ROLLED BACK' && ok "trial reported rollback" || bad "S12: $(echo "$out" | tail -2 | tr '\n' ' ')"
[ "$(fingerprint)" = "$f0" ] && [ "$(led)" = 0 ] && ok "fingerprint unchanged, ledger 0" || bad "trial left changes"

echo "S13 Protect version differs -> apply refuses"
ACC=$(python3 "$TOOL/gen.py" --accepted-version "$B") || ACC=''; TV=0.0.1; [ "$ACC" = "$TV" ] && TV=0.0.2   # this batch's accepted version
[ -n "$ACC" ] || bad "S13: gen.py --accepted-version failed (an empty version would match any message below)"
reset_dst; load >/dev/null; q "update public.nvrs set version = '$TV'" >/dev/null; f0=$(fingerprint)
out=$(apply); [ -n "$ACC" ] && echo "$out" | grep -qF "Protect version $TV is not " && echo "$out" | grep -m1 'Protect version' | grep -qF "$ACC" \
  && ok "apply refused on $TV (accepts: $ACC)" || bad "S13: $(echo "$out" | grep -m1 ERROR)"
[ "$(fingerprint)" = "$f0" ] && ok "fingerprint unchanged" || bad "S13 left changes"

echo "S14 rename of a group id is token-exact (a prefix-sibling id keeps its objects and event labels)"
reset_dst; load >/dev/null
# fixture: an insertable group G (externalId set, unknown to the target) whose id is a prefix of another batch group H
# (H not renamed by the merge); prefer H / G that also appear as event labels (strongest check of the exact-token rewrite)
IFS='|' read -r g14 e14 t14 sib < <(q "with
    lab as materialized (select distinct m[1] g from $SCHEMA.events e cross join lateral regexp_matches(e.metadata::text, '\"group:([A-Za-z0-9_-]+)\"', 'g') m),
    obj as materialized (select distinct \"smartDetectObjectGroupId\" g from $SO where \"smartDetectObjectGroupId\" is not null),
    sibok as materialized (select h.id, h.id in (select g from lab) lab from $SG h where h.id in (select g from obj)
             and not exists (select 1 from $GRP d where d.\"externalId\" = h.\"externalId\" and d.id <> h.id)),
    cand as materialized (select s.id, s.\"externalId\" ext, s.type, s.id in (select g from lab) lab from $SG s
             where s.\"externalId\" is not null and s.id in (select g from obj)
             and not exists (select 1 from $GRP d where d.\"externalId\" = s.\"externalId\" or d.id = s.id))
  select c.id, c.ext, c.type, coalesce(h.id, '') from cand c left join sibok h on h.id <> c.id and left(h.id, length(c.id)) = c.id
  order by (h.id is null), h.lab desc nulls last, c.lab desc, length(c.id), c.id, h.id limit 1")
if [ -z "${g14:-}" ]; then skp "no insertable group with an externalId to force a rename"; else
  A24=aaaaaaaaaaaaaaaaaaaaaaaa
  moved=$(q "select count(*) from $SO where \"smartDetectObjectGroupId\" = '$g14'")
  evg=$(q "select count(*) from $SCHEMA.events where $(hasgrp "$g14")")
  if [ -n "$sib" ]; then
    so=$(( $(q "select count(*) from $SO where \"smartDetectObjectGroupId\" = '$sib'") + $(q "select count(*) from public.\"smartDetectObjects\" where \"smartDetectObjectGroupId\" = '$sib'") ))
    se=$(( $(q "select count(*) from $SCHEMA.events where $(hasgrp "$sib")") + $(q "select count(*) from public.events where $(hasgrp "$sib")") ))
  fi
  ginsert "$e14" "$A24" "$t14" >/dev/null
  out=$(apply); echo "$out" | grep -qx "events|$WANT_EV" && ok "apply ok with $g14 -> $A24 rename" || bad "S14: $(echo "$out" | grep -m1 ERROR)"
  r=$(q "select (select count(*) from public.\"smartDetectObjects\" where \"smartDetectObjectGroupId\"='$A24') || ',' ||
                (select count(*) from public.\"smartDetectObjects\" where \"smartDetectObjectGroupId\"='$g14') || ',' ||
                (select count(*) from $GRP where id='$g14') || ',' ||
                (select count(*) from public.events where $(hasgrp "$g14")) || ',' ||
                (select count(*) from public.events where $(hasgrp "$A24"))")
  [ "$r" = "$moved,0,0,0,$evg" ] && ok "$moved objects + $evg event labels moved to $A24; no $g14 left or inserted" || bad "S14 (moved,old,grp,evold,evnew) = $r, want $moved,0,0,0,$evg"
  if [ -n "$sib" ]; then
    r2=$(q "select (select count(*) from public.\"smartDetectObjects\" where \"smartDetectObjectGroupId\"='$sib') || ',' || (select count(*) from public.events where $(hasgrp "$sib"))")
    [ "$r2" = "$so,$se" ] && ok "prefix sibling $sib intact ($so objects, $se event labels)" || bad "S14 sibling $sib (objects,events) = $r2, want $so,$se"
  else skp "no prefix-sibling group id in this batch (exactness rests on the gen-time sentinel check)"; fi
fi

echo "S15 imported events ending before the earliest rotating file -> apply refuses (startup purge guard)"
reset_dst; load >/dev/null
q "update $SCHEMA.\"recordingFiles\" set start = start + 86400000::bigint * 400 where type = 'rotating'" >/dev/null; f0=$(fingerprint)
out=$(apply); echo "$out" | grep -q 'startup purge would delete' && ok "apply refused" || bad "S15: $(echo "$out" | grep -m1 ERROR)"
[ "$(fingerprint)" = "$f0" ] && ok "fingerprint unchanged" || bad "S15 left changes"

echo "S16 rollback with nothing applied is refused"
reset_dst; load >/dev/null
out=$(rollback); echo "$out" | grep -q 'no ledger rows' && ok "refused" || bad "S16: $(echo "$out" | grep -m1 ERROR)"

echo "S17 version guard: by default only $VAL passes; --unvalidated-version X passes exactly X"
reset_dst
for c in "-|$VAL|pass" "-|0.0.1|refuse" "0.0.1|0.0.1|pass" "0.0.1|$VAL|refuse" "0.0.1|0.0.2|refuse"; do
  IFS='|' read -r flag ver want <<< "$c"
  q "update public.nvrs set version = '$ver'" >/dev/null
  if [ "$flag" = - ]; then g=$(python3 "$TOOL/gen.py" --version-guard-sql); else g=$(python3 "$TOOL/gen.py" --version-guard-sql --unvalidated-version "$flag"); fi
  out=$(printf '%s\n' "$g" | run); got=pass; echo "$out" | grep -q ERROR && got=refuse
  [ "$got" = "$want" ] && ok "guard ${flag/-/(default)} on version $ver: $got" || bad "S17 guard ${flag/-/(default)} on $ver: $got, want $want ($(echo "$out" | grep -m1 ERROR))"
done
python3 "$TOOL/gen.py" --version-guard-sql --unvalidated-version "$VAL" >/dev/null 2>&1 && bad "S17 --unvalidated-version $VAL accepted" || ok "--unvalidated-version $VAL (the validated one) refused"

echo "RESULT pass=$pass fail=$fail skip=$skip"
[ "$fail" = 0 ]
