#!/usr/bin/env bash
# extract.sh <batch_dir> --- run extract.sql for this batch on the controller's disposable source DB (docker container
# PG_CONTAINER, db src) into the shared schema "stage" (replaced on every run: run gen.py for the same batch right
# after; gen.py checks the camera). Exit status = psql's (extract.sql is one transaction: on error the previous stage
# stays untouched).
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd); . "$TOOL/lib-site.sh"
B=$(cd "$1" && pwd); . "$B/batch.env"
out=$(docker exec -i "$PG_CONTAINER" psql -U postgres -d src -X -At -F '|' -v ON_ERROR_STOP=1 \
  -v cam="$CAM" -v ucam="$UCAM" -v cut="$CUT" -v ai_src="$AI_SRC" -v ai_dst="$AI_DST" < "$TOOL/extract.sql" 2>&1); rc=$?
printf '%s\n' "$out" | grep -vE '^(BEGIN|COMMIT|SET|DO|SELECT [0-9]+|UPDATE [0-9]+|CREATE SCHEMA|DROP SCHEMA|NOTICE: +drop cascades.*|DETAIL: +drop cascades.*|drop cascades to .*)$'
[ $rc = 0 ] || echo "extract FAILED (psql rc=$rc) --- stage is replaced only if the transaction reached COMMIT"
exit $rc
