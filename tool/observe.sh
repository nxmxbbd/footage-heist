#!/usr/bin/env bash
# observe.sh <batch_dir> --- read-only daily check during the post-import observation period (observe-all.sh, run by
# the <NAME_PREFIX>-observe timer). Appends one block to <batch_dir>/observe.log; on any problem writes
# <batch_dir>/OBSERVE-FAIL and calls the notification hook (NOTIFY_CMD, event observe-fail).
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
need TARGET_SSH
B=$(cd "$1" && pwd); . "$B/batch.env"
LOG=$B/observe.log
PD=$TARGET_PROTECT_DIR
{
  echo "=== $(date -Is) observe $SLUG"
  out=$(timeout 300 "$TOOL/night.sh" "$B" verify 2>&1)
  # every verdict line, uncut: the problem check below reads this block (INFO = a thumbnails / timelapse file the
  # recorder continued, not a problem)
  echo "$out" | grep -E '^(PASS|FAIL|INFO)|FLAG|cameras:|Startup purge'
  # the recorder's behaviour on this camera's thumbnails / timelapse: new native file vs. continuing the imported one
  ssh -o ConnectTimeout=10 "$TARGET_SSH" "psql -U postgres -p 5433 -h 127.0.0.1 -d unifi-protect -X -At -F ' ' -c \"select 'files ' || type || ' ch' || channel || ': ' || count(*) || ' (imported ' || count(*) filter (where id in (select id from $LEDGER_SCHEMA.ledger where batch = '$SLUG')) || ', newest start ' || to_char(to_timestamp(max(start) / 1000) at time zone 'UTC', 'MM-DD HH24:MI') || 'Z)' from \\\"recordingFiles\\\" where \\\"cameraId\\\" = '$UCAM' and not free group by type, channel order by type, channel\"; psql -U postgres -p 5433 -h 127.0.0.1 -d smart_detect_face -X -At -c \"select 'face rows ' || count(*) || ' / subjects ' || count(distinct subject_id) from ui_face_db\"; grep -c 'Failed to expire face' $PD/logs/service.log | sed 's/^/expire-face error lines in current log: /'" 2>&1
} >> "$LOG"
# problem = any FAIL / corrupted-db flag, or the check produced no PASS at all (ssh / DB down)
blk=$(awk '/^=== /{b=""} {b=b $0 "\n"} END{printf "%s", b}' "$LOG")
if [ "${OBSERVE_FORCE_FAIL:-}" = 1 ] || echo "$blk" | grep -q '^FAIL\|FLAG PRESENT' || ! echo "$blk" | grep -q '^PASS'; then
  date -Is > "$B/OBSERVE-FAIL"
  bad=$(echo "$blk" | grep -E '^FAIL|FLAG PRESENT' | head -4 | sed 's/^/- /')
  [ -n "$bad" ] || bad="- the check itself did not complete (target or its database unreachable)"
  msg="Import observation of $SLUG ($(date '+%m-%d %H:%M')) found a problem:
$bad
Details: $LOG"
  key="observe:fail:$SLUG:$(date +%F)"
  if [ -n "$NOTIFY_CMD" ]; then
    out=$(NOTIFY_EVENT=observe-fail timeout 300 "$NOTIFY_CMD" "$key" "$msg" 2>&1); rc=$?
    echo "$(date -Is) notify $key rc=$rc $(printf '%s' "$out" | tail -c 300 | tr '\n' ' ')" >> "$LOG"
  else
    echo "$(date -Is) notify $key: no NOTIFY_CMD configured" >> "$LOG"
  fi
  exit 1
fi
