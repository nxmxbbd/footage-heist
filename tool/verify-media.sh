#!/usr/bin/env bash
# verify-media.sh <batch_dir> --- post-window media acceptance through the Protect API (read-only on the target):
#   - imported events visible through the events API
#   - for N events spread over the imported range: export ch0 + ch2 clips (MP4) and ffprobe them; event thumbnail.
#     An export that fails inside a hole of the camera's own recording (see hole()) is INFO, not FAIL, and that event
#     is replaced by the next imported event after the hole (SUBS, default 5 tries), so N events are always verified;
#     a slot that cannot be filled is a FAIL, and so is a sample in which no clip exported
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
pass=0; fail=0; info=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
note() { echo "  INFO $*"; info=$((info+1)); }

# hole <ch> <w0> <w1>: 0 (description in $hole) when the export window [w0, w1] (ms) lies in a hole of the camera's own
# recording on that channel: the one rotating file whose row covers the window has seek points (msr_ubvinfo -p, about
# every 5 s while the camera records) before and after the window, none inside it, and those two more than GAP_MS
# apart. Seen 10-29: three ~2 min holes right after a camera's adoption (its reboots); the sampled first event fell in
# one and Protect answered 404 {"error":502}. The file read is the imported one, whose bytes are the source's (the copy
# verify compared every sha256): the hole was already in the source. Anything else is 1 and the export stays a FAIL:
# no row or several, msr_ubvinfo failing, seek points that do not add up to the partition headers, no seek point after
# the window (a cut file), or a seek point inside the window (frames were there: the export should have worked).
GAP_MS=${GAP_MS:-10000}
hole() {
  local ch=$1 w0=$2 w1=$3 f out
  f=$(echo "select folder || '/' || file from \"recordingFiles\" where \"cameraId\" = '$UCAM' and channel = $ch and type = 'rotating' and start <= $w0 and \"end\" >= $w1;" | rq) || return 1
  [[ $f =~ ^/[A-Za-z0-9/_.-]+[.]ubv$ ]] || return 1     # exactly one row (a second line fails the match), a plain path
  out=$(ssh "$U" "msr_ubvinfo -f $f -p" < /dev/null) || return 1
  hole=$(python3 -c '
import re, sys, datetime
w0, w1, gap = map(int, sys.argv[1:4]); txt = sys.stdin.read()
sp = sorted(int(x) for x in re.findall(r"^ *[0-9]+[.] OFF: [0-9]+; WC: ([0-9]+)$", txt, re.M))
hdr = [int(x) for x in re.findall(r"^ *seek points: ([0-9]+)$", txt, re.M)]   # one header per partition (a camera
if not sp or not hdr or sum(hdr) != len(sp): sys.exit(1)                        # reconnect starts one: 21 seen in a file)
before = [s for s in sp if s <= w0]; after = [s for s in sp if s >= w0]
if not before or not after: sys.exit(1)
p, n = before[-1], after[0]
if n <= w1 or n - p <= gap: sys.exit(1)
f = lambda t: datetime.datetime.fromtimestamp(t / 1000, datetime.timezone.utc).strftime("%m-%d %H:%M:%S")
print(f"{n}|no frame between seek points {f(p)}Z and {f(n)}Z ({(n - p) / 1000:.0f} s)")
' "$w0" "$w1" "$GAP_MS" <<< "$out") || return 1
  hole_end=${hole%%|*}; hole="${hole#*|} in ${f##*/}"    # hole_end = the first seek point after the hole (ms)
}

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
exported=0
# probe_event <id> <start> <type>: ch0 + ch2 export (+ ffprobe) and the event thumbnail. hit=1 when an export fell in a
# hole of the camera's own recording (hit_end = the first seek point after it, the latest over the channels)
probe_event() {
  local id=$1 st=$2 ty=$3 d f code ch t
  d=$(date -u -d @$((st / 1000)) '+%m-%d %H:%M'); hit=0; hit_end=0
  for ch in 0 2; do
    f="$OUT/$id-ch$ch.mp4"
    code=$(c -m 180 -o "$f" -w '%{http_code}' "$H/proxy/protect/api/video/export?camera=$UCAM&channel=$ch&start=$((st - 1000))&end=$((st + 8000))")
    if [ "$code" = 200 ] && [ -s "$f" ]; then
      probe "$f" && { ok "$d $ty ch$ch export: $(stat -c %s "$f") B, $p"; exported=$((exported+1)); } || bad "$d $ty ch$ch ffprobe: $p"
    elif hole "$ch" $((st - 1000)) $((st + 8000)) < /dev/null; then
      note "$d $ty ch$ch export http=$code: the window lies in a hole of the camera's own recording ($hole) --- not an import fault"
      hit=1; [ "$hole_end" -gt "$hit_end" ] && hit_end=$hole_end
    else bad "$d $ty ch$ch export http=$code size=$(stat -c %s "$f" 2>/dev/null)"; fi
  done
  t=$(c -m 60 -o "$OUT/$id-thumb.jpg" -w '%{http_code} %{content_type}' "$H/proxy/protect/api/events/$id/thumbnail")
  case "$t" in "200 image/"*) ok "$d event thumbnail: $t $(stat -c %s "$OUT/$id-thumb.jpg") B";; *) bad "$d event thumbnail: $t";; esac
}
# A sampled event that fell in a hole is replaced by the next event of the SAME set ($EV: this batch's imported events,
# >= 3 s, none sampled or tried before) that starts after the hole, at most SUBS times per sampled event: the verdict
# rests on N exported events whether or not anyone reads the INFO lines. A slot that cannot be filled is a FAIL.
SUBS=${SUBS:-5}
tried=$(cut -d'|' -f1 "$OUT/events.txt" | sed "s/.*/'&'/" | paste -sd, -)
while IFS='|' read -r id st en ty; do
  k=0; slot=$(date -u -d @$((st / 1000)) '+%m-%d %H:%M')
  while :; do
    probe_event "$id" "$st" "$ty"
    [ "$hit" = 0 ] && break
    [ "$k" -lt "$SUBS" ] || { bad "slot $slot: still in a hole after $SUBS substitutes: no imported clip verified for it"; break; }
    k=$((k + 1))
    sub=$(echo "select id, start, \"end\", type from events e where e.id in ($EV) and e.\"end\" - e.start >= 3000 and e.start > $hit_end and e.id not in ($tried) order by e.start limit 1;" | rq) \
      || { bad "slot $slot: the substitute query failed"; break; }
    [[ $sub =~ ^[^|]+[|][0-9]+[|][0-9]+[|][^|]+$ ]] || { bad "slot $slot: no imported event after the hole to substitute"; break; }
    IFS='|' read -r id st en ty <<< "$sub"; tried="$tried,'$id'"
    note "slot $slot: substitute $k = the next imported event after the hole: $id at $(date -u -d @$((st / 1000)) '+%m-%d %H:%M:%S')Z"
  done
done < "$OUT/events.txt"
# a sample whose every clip fell in holes verified no imported video at all: not a pass
[ -s "$OUT/events.txt" ] && [ "$exported" = 0 ] && bad "no clip of the sample exported: no imported video was checked"

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

echo "RESULT pass=$pass fail=$fail info=$info (artifacts: $OUT)"
[ "$fail" = 0 ]
