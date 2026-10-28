#!/usr/bin/env bash
# new-batch.sh <slug> <mac> [apply_timeout] --- create <IMPORT_DIR>/<slug>/batch.env for one camera from the camera id map
# (site configuration: IDMAP = TSV mac | name | model | source camera id | target camera id | takeover time ISO 8601,
# the moment the target console took the camera over; AI_SRC / AI_DST = AI processor ids on source / target).
# Cross-checks the source camera id against the restored source DB (docker PG_CONTAINER, db src). Each batch gets its
# own staging schema <LEDGER_SCHEMA>_<slug>.
set -euo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
need IMPORT_DIR IDMAP AI_SRC AI_DST
slug=${1:?slug}; mac=${2:?mac}; timeout=${3:-600s}
D=$IMPORT_DIR
[ ${#NAME_PREFIX} -le $((62 - ${#slug})) ] || { echo "'$NAME_PREFIX-$slug' is longer than 63 bytes (psql application_name): shorter slug"; exit 64; }
[[ $slug =~ ^[a-z0-9][a-z0-9-]{0,38}$ ]] || { echo "bad slug '$slug'"; exit 64; }
[[ $mac =~ ^[0-9A-F]{12}$ ]] || { echo "bad mac '$mac'"; exit 64; }
[[ $timeout =~ ^[1-9][0-9]{0,4}s$ ]] || { echo "bad apply timeout '$timeout'"; exit 64; }
B=$D/$slug; [ -e "$B/batch.env" ] && { echo "refusing: $B/batch.env exists"; exit 1; }
line=$(awk -F'\t' -v m="$mac" '$1 == m' "$IDMAP")
[ "$(printf '%s\n' "$line" | grep -c .)" = 1 ] || { echo "need exactly one id-map row for $mac"; exit 1; }
IFS=$'\t' read -r _ name model cam ucam tm <<< "$line"
case $tm in *'('*|'') echo "takeover time '$tm' is empty or carries a note --- review before using it as CUT"; exit 1 ;; esac
cut=$(python3 -c "import sys, datetime; print(round(datetime.datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00')).timestamp() * 1000))" "$tm")
src=$(docker exec "$PG_CONTAINER" psql -U postgres -d src -At -c "select id from cameras where mac = '$mac'")
[ "$src" = "$cam" ] || { echo "id map source id $cam != source DB camera id for $mac ('$src')"; exit 1; }
schema=${LEDGER_SCHEMA}_${slug//-/_}
mkdir -p -m 700 "$B"
( umask 077; printf 'SLUG=%s\nMAC=%s\nCAM=%s\nUCAM=%s\nCUT=%s\nAI_SRC=%s\nAI_DST=%s\nSCHEMA=%s\nAPPLY_TIMEOUT=%s\n' \
    "$slug" "$mac" "$cam" "$ucam" "$cut" "$AI_SRC" "$AI_DST" "$schema" "$timeout" > "$B/batch.env" )
echo "$slug ($name, $model): CAM=$cam UCAM=$ucam CUT=$cut ($tm) SCHEMA=$schema APPLY_TIMEOUT=$timeout"
