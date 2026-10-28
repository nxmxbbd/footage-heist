# lib-test.sh --- sourced by dryrun.sh / test-window.sh after lib-site.sh + batch.env (needs $B, $SLUG, $UCAM, $SCHEMA).
# Which target-DB dump to clone, the clone restore (with a sanity check), and batch-manifest readers.
# IMPORT_DIR (site configuration) is mounted read-only as /in in PG_CONTAINER and in the restore container.
need IMPORT_DIR

mj() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['counts'][sys.argv[2]])" "$B/manifest.json" "$1"; }

batch_check() {   # the batch must be generated, and generated for the schema batch.env names
  [ -n "${SCHEMA:-}" ] || { echo "ABORT: batch.env has no SCHEMA (new-batch.sh writes it)"; exit 64; }
  [ -s "$B/manifest.json" ] && [ -s "$B/sql/apply.sql" ] || { echo "ABORT: run gen.py on $B first"; exit 64; }
  local ms; ms=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('schema', ''))" "$B/manifest.json")
  [ "$ms" = "$SCHEMA" ] || { echo "ABORT: manifest schema '$ms' != batch.env SCHEMA '$SCHEMA' --- rerun gen.py"; exit 64; }
}

resolve_clone() { # TARGET_DUMP env > CLONE in batch.env > newest <batch>/<target label>-clone-*.dump (night.sh clone-dump)
  local p=${TARGET_DUMP:-${CLONE:-}}
  [ -n "$p" ] || p=$(ls -1t "$B/$TARGET_LABEL"-clone-*.dump 2>/dev/null | head -1)
  [ -n "$p" ] || { echo "ABORT: no target clone dump --- run night.sh $B clone-dump (or set CLONE= / TARGET_DUMP=)"; exit 64; }
  case $p in /*) ;; *) p=$IMPORT_DIR/$p ;; esac
  p=$(readlink -f "$p")
  case $p in "$IMPORT_DIR"/*) ;; *) echo "ABORT: clone dump must live under $IMPORT_DIR: $p"; exit 64 ;; esac
  [ -s "$p" ] || { echo "ABORT: clone dump missing: $p"; exit 64; }
  CLONE_IN=/in/${p#"$IMPORT_DIR"/}
  echo "clone: $p ($(date -r "$p" '+%m-%d %H:%M'))"
}

restore_clone() { # fresh db dst = the clone; aborts the whole run if dst cannot be recreated, the restore reports any
  # error (a partial restore must never become a fixture) or the clone lacks the target camera.
  # WITH (FORCE) ends leftover sessions (e.g. a test transaction that outlived its scenario); a failed drop must never
  # let the next scenario run on the previous one's data
  docker exec "$PG_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -qc 'drop database if exists dst with (force)' -c 'create database dst' >/dev/null 2>&1 \
    || { echo "ABORT: could not recreate database dst"; exit 70; }
  local err; err=$(docker run --rm --network "container:$PG_CONTAINER" -v "$IMPORT_DIR":/in:ro postgres:16-alpine \
    pg_restore -h 127.0.0.1 -U postgres -d dst --no-owner --no-privileges "$CLONE_IN" 2>&1 >/dev/null) \
    || { echo "ABORT: clone restore failed: $(printf '%s\n' "$err" | tail -3 | tr '\n' ' ')"; exit 70; }
  local n; n=$(docker exec "$PG_CONTAINER" psql -U postgres -d dst -At -c "select count(*) from public.cameras where id = '$UCAM'" 2>&1)
  [ "$n" = 1 ] || { echo "ABORT: clone restore did not produce camera $UCAM ('$n')"; exit 70; }
}
