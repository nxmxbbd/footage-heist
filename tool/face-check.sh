#!/usr/bin/env bash
# face-check.sh snapshot [label] | compare <snapshot.tsv> | snapshot-docker <db> --- read-only check of the target's
# face samples (smart_detect_face.ui_face_db: uid, camera_id, created_at --- never embeddings or names).
# Why: after a restart Protect may expire a camera's face samples that are older than the camera's earliest recording
# still on disk (MECHANISM.md). Importing moves an imported camera's earliest recording back into the source era (its
# samples are protected); samples of cameras not imported yet stay exposed. Take a snapshot right before a window,
# compare right after verify: every snapshot uid must still exist (the uid sequence only grows); missing rows are
# listed per camera. Exit 1 = FAIL.
# snapshot-docker: the same snapshot from a restored face-DB dump in the controller's container (e.g. a pre-window backup).
set -euo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
need IMPORT_DIR TARGET_SSH
D=$IMPORT_DIR/face; mkdir -p -m 700 "$D"
SQL="select uid, coalesce(camera_id, ''), extract(epoch from created_at)::bigint from ui_face_db order by uid"
live() { need TARGET_SSH; ssh -o ConnectTimeout=10 "$TARGET_SSH" "psql -U postgres -p 5433 -h 127.0.0.1 -d smart_detect_face -X -At -F '|' -v ON_ERROR_STOP=1 -c \"$SQL\""; }
save() {   # $1 label, stdin = rows
  local f; f=$D/face-$(date +%Y%m%d-%H%M%S)${1:+-$1}.tsv
  ( umask 077; cat > "$f" ); [ -s "$f" ] || { echo "empty snapshot $f"; exit 1; }
  echo "snapshot $f: $(wc -l < "$f") rows, $(cut -d'|' -f2 "$f" | sort -u | wc -l) camera ids"
}
case ${1:-} in
snapshot) live | save "${2:-}" ;;
snapshot-docker) docker exec "$PG_CONTAINER" psql -U postgres -d "${2:?db}" -X -At -F '|' -v ON_ERROR_STOP=1 -c "$SQL" | save "docker-$2" ;;
compare)
  base=${2:?snapshot.tsv}; [ -s "$base" ] || { echo "no snapshot $base"; exit 64; }
  now=$(mktemp); trap 'rm -f "$now"' EXIT
  live > "$now"; [ -s "$now" ] || { echo "FAIL could not read the live face DB"; exit 1; }
  python3 - "$base" "$now" << 'PY'
import sys, collections, datetime
def rows(p):
    d = {}
    for l in open(p):
        uid, cam, ts = l.rstrip('\n').split('|')
        d[int(uid)] = (cam or '<none>', int(ts))
    return d
b, n = rows(sys.argv[1]), rows(sys.argv[2])
gone = {u: v for u, v in b.items() if u not in n}
new = len([u for u in n if u not in b])
fmt = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime('%m-%d %H:%MZ')
print(f'info snapshot {len(b)} rows, live {len(n)} rows, new since snapshot {new}, missing {len(gone)}')
if not gone:
    print('PASS every face sample of the snapshot still exists')
    sys.exit(0)
per = collections.defaultdict(list)
for u, (cam, ts) in gone.items():
    per[cam].append(ts)
for cam, ts in sorted(per.items(), key=lambda x: -len(x[1])):
    print(f'FAIL {cam}: {len(ts)} samples missing (created {fmt(min(ts))} .. {fmt(max(ts))})')
sys.exit(1)
PY
  ;;
*) echo "usage: $0 snapshot [label] | compare <snapshot.tsv> | snapshot-docker <db>"; exit 64 ;;
esac
