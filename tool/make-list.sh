#!/usr/bin/env bash
# make-list.sh <slug> <mac> --- read-only on the source console (SOURCE_SSH): snapshot the camera's recordingFiles rows
# (<slug>.rows.pre) and derive the copy list (<slug>.list = id|folder|file|size, oldest first) for ubv-push.py.
set -euo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
need IMPORT_DIR SOURCE_SSH
slug=$1; mac=$2
D=$IMPORT_DIR
[ -e "$D/$slug.list" ] && { echo "refusing: $D/$slug.list exists (rotate it first)"; exit 1; }
ssh "$SOURCE_SSH" "psql -U postgres -p 5433 -h 127.0.0.1 -d unifi-protect -X -At -F '|' -v ON_ERROR_STOP=1 -v mac=$mac -f -" < "$TOOL/rows.sql" > "$D/$slug.rows.pre"
cut -d'|' -f1-4 "$D/$slug.rows.pre" > "$D/$slug.list.tmp"     # the list appears only once it passed the checks
n=$(wc -l < "$D/$slug.list.tmp"); bytes=$(awk -F'|' '{s += $4} END {printf "%.0f", s}' "$D/$slug.list.tmp")
[ "$n" -gt 0 ] || { echo "no rows for $mac"; exit 1; }
grep -qv "^[0-9a-f-]*|/\(srv\|ssd1\)/unifi-protect/video/[0-9]\{4\}/[0-9]\{2\}/[0-9]\{2\}|${mac}_[02]_[a-z]*_[0-9]\{13\}\.ubv|[0-9]*$" "$D/$slug.list.tmp" && { echo "unexpected list line(s)"; exit 1; }
mv "$D/$slug.list.tmp" "$D/$slug.list"
echo "$slug: $n files, $(awk -v b="$bytes" 'BEGIN{printf "%.1f GB", b/1e9}'), $(head -1 "$D/$slug.list" | cut -d'|' -f2 | grep -o '[0-9]\{4\}/[0-9]\{2\}/[0-9]\{2\}') .. $(tail -1 "$D/$slug.list" | cut -d'|' -f2 | grep -o '[0-9]\{4\}/[0-9]\{2\}/[0-9]\{2\}')"
