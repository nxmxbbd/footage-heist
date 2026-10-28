#!/usr/bin/env bash
# verify-staged.sh <slug> <mac> --- post-copy reconciliation for one camera's source -> target staging copy.
# Three independent paths: (1) source recordingFiles rows vs the pre-copy snapshot (verify-rows.py): no row may be added
# or changed; a row may only have disappeared (Protect deletes the oldest recordings) if its file was copied before that,
# or it is in <slug>.gone (deleted before it could be copied: the copy runner drops those from the list), or it is
# outside <slug>.list (e.g. a filtered list); the one change allowed is the successor update such a deletion brings
# (MECHANISM.md 5: next row of the same type + channel, `start` = the deleted row's `end`, only `updatedAt` besides),
# and (1b) re-reads every copied successor on the source against the ledger; (2) target coreutils sha256sum re-read of
# every staged file vs the source-side streaming ledger, (3) source coreutils sha256sum re-read of 2 sampled source
# files vs the ledger.
# Env: PUSH_LEDGER (source-side ledger path; test runs only).
set -euo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
need IMPORT_DIR SOURCE_SSH TARGET_SSH TARGET_STAGING SOURCE_WORKDIR TARGET_WORKDIR
slug=$1; mac=$2
D=$IMPORT_DIR
LEDGER=${PUSH_LEDGER:-$SOURCE_WORKDIR/ledger.jsonl}
STAGE=$TARGET_STAGING/files
# a router between controller and consoles may drop an idle established TCP flow (connection tracking timeout); the
# target re-read prints nothing for hours on a big camera (~3.9 h for 4.75 TB) -> keepalives keep the flow alive and
# detect a dead one within 5 min instead of hanging forever
ssh() { command ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=5 "$@"; }

# ledger (source side) -> controller
scp -q "$SOURCE_SSH:$LEDGER" "$D/$slug.ledger.jsonl"

# (1) rows
ssh "$SOURCE_SSH" "psql -U postgres -p 5433 -h 127.0.0.1 -d unifi-protect -X -At -F '|' -v ON_ERROR_STOP=1 -v mac=$mac -f -" < "$TOOL/rows.sql" > "$D/$slug.rows.post"
[ -s "$D/$slug.rows.post" ] || { echo "FAIL: post-copy rows query returned nothing"; exit 1; }
python3 "$TOOL/verify-rows.py" "$D/$slug.rows.pre" "$D/$slug.rows.post" "$D/$slug.ledger.jsonl" "$D/$slug.list" \
  "$D/$slug.gone" "$D/$slug.successors"

# (1b) a successor's file must still be the bytes the ledger holds: its row changed, the file must not have
while IFS='|' read -r id src want; do
  got=$(ssh "$SOURCE_SSH" "nice -n19 ionice -c3 sha256sum $src" < /dev/null | cut -c1-64) || got=''
  if [ "$want" = "$got" ]; then echo "successor re-read OK: ${src##*/}"
  elif ssh "$SOURCE_SSH" "test -e $src" < /dev/null; then echo "FAIL successor re-read MISMATCH: ${src##*/}"; exit 1
  else echo "successor re-read skipped (deleted on the source since): ${src##*/}"; fi
done < "$D/$slug.successors"

python3 - "$D/$slug.ledger.jsonl" "$D/$slug.list" > "$D/$slug.expected" << 'EOF'
import json, sys
led = {}
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r['result'] == 'ok' and r['remote'] == 'OK %d %s' % (r['size'], r['sha256']):
        led[r['id']] = r
ids = [l.split('|')[0] for l in open(sys.argv[2]) if l.strip()]
missing = [i for i in ids if i not in led]
if missing:
    print('MISSING', *missing, file=sys.stderr)
    sys.exit(1)
for i in ids:
    print(led[i]['sha256'], led[i]['rel'], i)
EOF
echo "ledger ok entries for list: $(wc -l < "$D/$slug.expected") / $(grep -c . "$D/$slug.list")"

# (2) target re-read
awk -v s="$STAGE" '{print $1 "  " s "/" $2}' "$D/$slug.expected" > "$D/$slug.sha256"
ssh "$TARGET_SSH" "install -d -m 700 $TARGET_WORKDIR"
scp -q "$D/$slug.sha256" "$TARGET_SSH:$TARGET_WORKDIR/$slug.sha256"
[ "$(wc -l < "$D/$slug.expected")" = "$(grep -c . "$D/$slug.list")" ] || { echo "FAIL: expected list incomplete"; exit 1; }
ssh "$TARGET_SSH" "nice -n19 ionice -c3 sha256sum -c --quiet $TARGET_WORKDIR/$slug.sha256" || { echo "FAIL: target re-read mismatch"; exit 1; }
echo 'target re-read: all match'
ssh "$TARGET_SSH" "find $STAGE -name '*.part' | wc -l | sed 's/^/stray .part files: /'; find $STAGE -type f -name '$mac*' | wc -l | sed 's/^/staged files for mac: /'"

# (3) source re-read, 2 samples (first rotating + the thumbnails file); source path = the list's folder/file
#     (the ledger's rel names the staging path, which differs from the source in test runs)
for id in $(awk '{print $2 "|" $3}' "$D/$slug.expected" | grep -E '_0_rotating_|_thumbnails_' | sort -t_ -k4 | awk 'NR==1 || /thumbnails/' | head -2 | cut -d'|' -f2); do
  src=$(awk -F'|' -v i="$id" '$1==i {print $2 "/" $3}' "$D/$slug.list")
  want=$(awk -v i="$id" '$3==i {print $1}' "$D/$slug.expected")
  got=$(ssh "$SOURCE_SSH" "nice -n19 ionice -c3 sha256sum $src" | cut -c1-64) || got=''
  if [ "$want" = "$got" ]; then echo "source re-read OK: ${src##*/}"
  elif ssh "$SOURCE_SSH" "test -e $src"; then echo "FAIL source re-read MISMATCH: ${src##*/}"; exit 1
  else echo "source re-read skipped (deleted on the source since the copy): ${src##*/}"; fi
done
