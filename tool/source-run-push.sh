#!/bin/bash
# source-run-push.sh <slug> --- source side, installed as <SOURCE_WORKDIR>/run-push.sh next to ubv-push.py. Started by
# the controller's copy runner (tool/copyq.py) as the transient unit PUSH_UNIT (systemd-run: one push at a time,
# survives controller / ssh loss; stop = systemctl stop <PUSH_UNIT>, the receiver drops the partial file). Runs
# ubv-push.py on <SOURCE_WORKDIR>/<slug>.list (env from systemd-run: PUSH_DEST, PUSH_MODE, RATE_MBPS, test knobs),
# appends to <slug>.push.log, writes the exit status to <slug>.push.exit (absent after a stop / kill).
set -u
H=$(cd "$(dirname "$(readlink -f "$0")")" && pwd); s=${1:-}
[[ $s =~ ^[a-z0-9][a-z0-9-]{0,38}$ ]] || { echo "bad slug '$s'"; exit 64; }
[ -f "$H/$s.list" ] || { echo "no list $H/$s.list"; exit 64; }
rm -f "$H/$s.push.exit"
echo "$s" > "$H/current"
echo "=== $(date -Is) start mode=${PUSH_MODE:-ssh} rate=${RATE_MBPS:-80} ledger=${PUSH_LEDGER:-default} test_day=${PUSH_TEST_DAY:-}" >> "$H/$s.push.log"
PUSH_HOME=$H python3 "$H/ubv-push.py" "$H/$s.list" >> "$H/$s.push.log" 2>&1
rc=$?
echo "$rc" > "$H/$s.push.exit"
exit $rc
