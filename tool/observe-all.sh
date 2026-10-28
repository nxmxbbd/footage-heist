#!/usr/bin/env bash
# observe-all.sh --- daily driver for the <NAME_PREFIX>-observe timer: runs observe.sh (read-only checks, notification
# hook on a problem) for every batch in <IMPORT_DIR>/observe.list --- lines "<slug> <last day YYYY-MM-DD>", '#'
# comments --- whose observation period has not ended. Exit 1 if any batch failed or the list is malformed.
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
need IMPORT_DIR
D=$IMPORT_DIR
today=$(date +%F); rc=0; n=0
while read -r slug last _; do
  case $slug in ''|'#'*) continue ;; esac
  [[ $last =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "bad observe.list line: $slug $last"; rc=1; continue; }
  [[ "$today" > "$last" ]] && continue
  [ -f "$D/$slug/batch.env" ] || { echo "observe.list: no batch $slug"; rc=1; continue; }
  n=$((n + 1))
  "$TOOL/observe.sh" "$D/$slug" < /dev/null || { echo "$slug: problem (see $D/$slug/observe.log)"; rc=1; }   # ssh inside must not eat the list
done < "$D/observe.list"
echo "$(date -Is) observed $n batch(es), rc=$rc"
exit $rc
