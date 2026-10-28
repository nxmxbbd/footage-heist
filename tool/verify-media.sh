#!/usr/bin/env bash
# verify-media.sh <batch_dir> --- post-window media acceptance through the Protect API (read-only on the target):
#   - imported events visible through the events API
#   - for N events spread over the imported range: export ch0 + ch2 clips (MP4) and ffprobe them; event thumbnail
#   - object thumbnails (<MAC>-<ms> ids, served by MSP from the imported thumbnails .ubv)
# UI session from TARGET_LOGIN_FILE (never on argv), TLS key pinned (TARGET_TLS_PIN_FILE), logout + shred at the end.
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
need TARGET_SSH TARGET_URL TARGET_TLS_PIN_FILE TARGET_LOGIN_FILE
B=$(cd "$1" && pwd); . "$B/batch.env"
N=${N:-5}
U=$TARGET_SSH; H=$TARGET_URL
PIN=$(cat "$TARGET_TLS_PIN_FILE")
# rq: SQL on stdin -> rows (|-separated). The set of rows to probe: imported (ledger) or, with TEST_NATIVE=1, the
# camera's native rows (dry check of the API / ffprobe chain before the window)
rq() { ssh "$U" "psql -U postgres -p 5433 -h 127.0.0.1 -d unifi-protect -X -At -F '|' -v ON_ERROR_STOP=1 -f -"; }
if [ "${TEST_NATIVE:-}" = 1 ]; then
  EV="select id from events where \"cameraId\" = '$UCAM'"
  OB="select id from \"smartDetectObjects\" where \"cameraId\" = '$UCAM'"
else
  EV="select id from $LEDGER_SCHEMA.ledger where batch = '$SLUG' and tbl = 'events'"
  OB="select id from $LEDGER_SCHEMA.ledger where batch = '$SLUG' and tbl = 'smartDetectObjects'"
fi
OUT=$B/verify-media-$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"; chmod 700 "$OUT"
J=$(mktemp); HD=$(mktemp)
cleanup() { [ -n "${CSRF:-}" ] && curl -s -k --pinnedpubkey "$PIN" -b "$J" -H "X-CSRF-Token: $CSRF" -X POST $H/api/auth/logout -o /dev/null -w 'logout http=%{http_code}\n'; shred -u "$J" "$HD" 2>/dev/null; }
trap cleanup EXIT
c() { curl -s -k --pinnedpubkey "$PIN" -b "$J" -H "X-CSRF-Token: $CSRF" "$@"; }
pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

curl -s -k --pinnedpubkey "$PIN" -c "$J" -D "$HD" -H 'Content-Type: application/json' --data @"$TARGET_LOGIN_FILE" $H/api/auth/login -o /dev/null -w 'login http=%{http_code}\n'
CSRF=$(grep -i '^x-csrf-token:' "$HD" | awk '{print $2}' | tr -d '\r')
[ -n "$CSRF" ] || { echo "login failed"; exit 1; }

# probe <mp4>: ffprobe exits 0 and the first video stream is one of the codecs the cameras record (h264 / hevc); p = the
# stream / format lines it reported, or its exit code and error text (stderr is never read as a result)
probe() {
  local o r
  o=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,nb_frames:format=duration \
      -of default=nw=1 "$1" 2> "$OUT/ffprobe.err"); r=$?
  if [ $r != 0 ]; then p="rc $r: $(head -c 300 "$OUT/ffprobe.err" | tr '\n' ' ')"; return 1; fi
  p=$(echo "$o" | tr '\n' ' ')
  grep -qxE 'codec_name=(h264|hevc)' <<< "$o"
}

echo "== events API over the imported range"
range=$(echo "select min(e.start), max(e.\"end\") from events e where e.id in ($EV);" | rq) || range=''
[[ $range =~ ^[0-9]+\|[0-9]+$ ]] || { bad "range query failed or found no events ('$range'): nothing to verify"; echo "RESULT pass=$pass fail=$fail"; exit 1; }
s0=${range%|*}; e0=${range#*|}
want=$(echo "select count(*) from events where \"cameraId\" = '$UCAM' and start >= $s0 and \"end\" <= $e0;" | rq) || want=''
# the range comes from the imported events, so the DB counts at least one; the API must return >= 95 % (rounded up).
# The limit follows the batch (a fixed 5000 truncated a batch of 5,581 events): a reply that fills it proves nothing
# about the rest
if ! [[ $want =~ ^[0-9]+$ ]] || [ "$want" = 0 ]; then
  bad "event count query failed or counted none ('$want'): the API count was not checked"
else
  lim=$(( want * 2 + 100 ))
  n=$(c "$H/proxy/protect/api/events?cameras=$UCAM&start=$s0&end=$e0&limit=$lim" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
  if [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge $(( (want * 95 + 99) / 100 )) ] && [ "$n" -lt "$lim" ]; then
    ok "events API returns $n events in the imported range (DB has $want)"
  else bad "events API returned '$n' (limit $lim), DB has $want"; fi
fi

echo "== $N events spread over the range: export ch0 + ch2, ffprobe, event thumbnail"
if ! rq > "$OUT/events.txt" << EOF
with ev as (select e.id, e.start, e."end", e.type, row_number() over (order by e.start) rn, count(*) over () cnt
            from events e where e.id in ($EV) and e."end" - e.start >= 3000)
select id, start, "end", type from ev
where rn in (select distinct greatest(1, (cnt * k / greatest($N - 1, 1))::int) from ev, generate_series(0, $N - 1) k) order by start;
EOF
then bad "event sample query failed: no clip, no event thumbnail was checked"; : > "$OUT/events.txt"
elif [ ! -s "$OUT/events.txt" ]; then bad "no event of >= 3 s to export: no clip, no event thumbnail was checked"; fi
while IFS='|' read -r id st en ty; do
  d=$(date -u -d @$((st / 1000)) '+%m-%d %H:%M')
  for ch in 0 2; do
    f="$OUT/$id-ch$ch.mp4"
    code=$(c -m 180 -o "$f" -w '%{http_code}' "$H/proxy/protect/api/video/export?camera=$UCAM&channel=$ch&start=$((st - 1000))&end=$((st + 8000))")
    if [ "$code" = 200 ] && [ -s "$f" ]; then
      probe "$f" && ok "$d $ty ch$ch export: $(stat -c %s "$f") B, $p" || bad "$d $ty ch$ch ffprobe: $p"
    else bad "$d $ty ch$ch export http=$code size=$(stat -c %s "$f" 2>/dev/null)"; fi
  done
  t=$(c -m 60 -o "$OUT/$id-thumb.jpg" -w '%{http_code} %{content_type}' "$H/proxy/protect/api/events/$id/thumbnail")
  case "$t" in "200 image/"*) ok "$d event thumbnail: $t $(stat -c %s "$OUT/$id-thumb.jpg") B";; *) bad "$d event thumbnail: $t";; esac
done < "$OUT/events.txt"

if [ "${TEST_NATIVE:-}" = 1 ]; then
  echo "== positive control: the newest finished >= 3 s detection event of any camera"
  ctl=$(echo "select e.\"cameraId\", e.start, c.name from events e join cameras c on c.id = e.\"cameraId\" where e.\"end\" is not null and e.\"end\" - e.start >= 3000 and e.type in ('smartDetectZone','motion') order by e.start desc limit 1;" | rq) || ctl=''
  IFS='|' read -r pcam t pname <<< "$ctl"
  if [ -n "${pcam:-}" ] && [[ ${t:-} =~ ^[0-9]+$ ]]; then
    echo "  control: $pname at $(date -d @$((t / 1000)) '+%T')"
    for ch in 0 2; do
      f="$OUT/native-ch$ch.mp4"
      code=$(c -m 180 -o "$f" -w '%{http_code}' "$H/proxy/protect/api/video/export?camera=$pcam&channel=$ch&start=$((t - 1000))&end=$((t + 8000))")
      probe "$f"; r=$?
      [ "$code" = 200 ] && [ $r = 0 ] && ok "native ch$ch export: $(stat -c %s "$f") B, $p" || bad "native ch$ch export http=$code ffprobe: $p"
    done
  else bad "positive control query failed or found no event ('$ctl'): the control was not checked"; fi
fi
echo "== object thumbnails (MSR snapshot ids from the imported thumbnails file)"
if ! rq > "$OUT/thumbs.txt" << EOF
(select o."thumbnailId" from "smartDetectObjects" o where o.id in ($OB) and o."thumbnailId" is not null order by o."detectedAt" limit 3)
union all
(select o."thumbnailId" from "smartDetectObjects" o where o.id in ($OB) and o."thumbnailId" is not null order by o."detectedAt" desc limit 3);
EOF
then bad "object thumbnail query failed: no object thumbnail was checked"; : > "$OUT/thumbs.txt"
elif [ ! -s "$OUT/thumbs.txt" ]; then echo "  INFO no object with a thumbnail in this batch: no object thumbnail to check"; fi
while read -r tid; do
  [ -n "$tid" ] || continue
  t=$(c -m 60 -o "$OUT/obj-$tid.jpg" -w '%{http_code} %{content_type}' "$H/proxy/protect/api/thumbnails/$tid")
  case "$t" in "200 image/"*) ok "object thumbnail $tid: $t $(stat -c %s "$OUT/obj-$tid.jpg") B";; *) bad "object thumbnail $tid: $t";; esac
done < "$OUT/thumbs.txt"

echo "RESULT pass=$pass fail=$fail (artifacts: $OUT)"
[ "$fail" = 0 ]
