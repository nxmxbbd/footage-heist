#!/usr/bin/env bash
# test-unit-graph.sh --- offline tests of the unit graph guard: tool/unit-graph.py against the bundled model and
# systemctl show samples (tool/testdata/unit-graph-target.txt = the validated target's dependency properties, with the
# properties that were not captured there filled in as the model assumes them; plus mutations made here), and night.sh's use of it (prep / go / rollback refuse, recover warns) with fake
# ssh / scp / curl and a throw-away site configuration whose hosts are *.invalid. Needs no docker, no batch, no device.
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd)
G="python3 $TOOL/unit-graph.py"
MODEL=$TOOL/unit-model.txt
FIX=$TOOL/testdata/unit-graph-target.txt
T=$(mktemp -d /tmp/test-unit-graph.XXXXXX); pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
# mut <name> <sed script>: a mutated copy of the fixture; a mutation that changes nothing is a test bug, not a pass
mut() { sed "$2" "$FIX" > "$T/$1.txt"; cmp -s "$FIX" "$T/$1.txt" && { bad "mutation $1 did not apply"; return 1; }; return 0; }
chk() { $G check "$MODEL" "$1" > "$T/out" 2>&1; echo $?; }      # rc; output in $T/out
has() { grep -qF -- "$1" "$T/out"; }

echo "U1 the bundled model parses; query names every window unit and the compared properties"
$G lint "$MODEL" > "$T/out" 2>&1 && ok "lint: $(cat "$T/out")" || bad "lint: $(cat "$T/out")"
q=$($G query "$MODEL")
[ "$q" = "unifi-protect.service postgresql@14-protect.service msr.service msp.service mst.service ms.service -p Id -p LoadState -p Requires -p Requisite -p BindsTo -p PartOf -p Wants -p Conflicts -p OnFailure -p ConflictedBy -p Upholds -p UpheldBy -p PropagatesStopTo -p StopPropagatedFrom -p OnSuccess" ] \
  && ok "query: units + -p list" || bad "query: $q"

echo "U2 the validated target's output matches; unit / entry order does not matter"
rc=$(chk "$FIX"); [ "$rc" = 0 ] && has "matches" && ok "rc 0, matches" || bad "rc=$rc $(cat "$T/out")"
python3 - "$FIX" > "$T/shuffled.txt" << 'EOF'
import sys
blocks = open(sys.argv[1]).read().strip().split('\n\n')
out = []
for b in reversed(blocks):
    lines = [l.split('=', 1) for l in b.split('\n')]
    out.append('\n'.join(f"{k}={' '.join(reversed(v.split()))}" for k, v in reversed(lines)))
print('\n\n'.join(out))
EOF
cmp -s "$FIX" "$T/shuffled.txt" && bad "shuffle did not change the sample" || { rc=$(chk "$T/shuffled.txt"); [ "$rc" = 0 ] && ok "blocks, properties and entries reversed: rc 0" || bad "rc=$rc $(cat "$T/out")"; }

echo "U3 every kind of difference refuses (rc 1) and is named"
mut added '/^Id=msr.service$/,/^$/ s/^BindsTo=$/BindsTo=unifi-protect.service/' \
  && { rc=$(chk "$T/added.txt"); [ "$rc" = 1 ] && has "DIFFERS msr.service BindsTo: target adds unifi-protect.service" && ok "new BindsTo edge" || bad "rc=$rc $(cat "$T/out")"; }
mut removed 's/^PartOf=unifi-protect.service postgresql.service$/PartOf=postgresql.service/' \
  && { rc=$(chk "$T/removed.txt"); [ "$rc" = 1 ] && has "DIFFERS postgresql@14-protect.service PartOf: target lacks unifi-protect.service" && ok "PostgreSQL no longer PartOf Protect" || bad "rc=$rc $(cat "$T/out")"; }
mut default '/^Id=unifi-protect.service$/,/^$/ s/^Requires=\(.*\)$/Requires=\1 network-online.target/' \
  && { rc=$(chk "$T/default.txt"); [ "$rc" = 1 ] && has "unifi-protect.service Requires: target adds network-online.target" && ok "a changed default dependency (complete lists, every unit type)" || bad "rc=$rc $(cat "$T/out")"; }
mut requisite '/^Id=mst.service$/,/^$/ s/^Requisite=$/Requisite=unifi-protect.service/' \
  && { rc=$(chk "$T/requisite.txt"); [ "$rc" = 1 ] && has "mst.service Requisite: target adds unifi-protect.service" && ok "a Requisite edge (assumed empty in the model)" || bad "rc=$rc $(cat "$T/out")"; }
mut conflict '/^Id=msr.service$/,/^$/ s/^Conflicts=shutdown.target$/Conflicts=shutdown.target postgresql@14-protect.service/' \
  && { rc=$(chk "$T/conflict.txt"); [ "$rc" = 1 ] && has "msr.service Conflicts: target adds postgresql@14-protect.service" && ok "a Conflicts edge inside the window set (restarting msr would stop PostgreSQL)" || bad "rc=$rc $(cat "$T/out")"; }
mut onfailure '/^Id=msp.service$/,/^$/ s/^OnFailure=$/OnFailure=reboot.target/' \
  && { rc=$(chk "$T/onfailure.txt"); [ "$rc" = 1 ] && has "msp.service OnFailure: target adds reboot.target" && ok "an OnFailure edge (not simulated by the fake)" || bad "rc=$rc $(cat "$T/out")"; }
mut notfound '/^Id=ms.service$/,/^$/ s/^LoadState=loaded$/LoadState=not-found/' \
  && { rc=$(chk "$T/notfound.txt"); [ "$rc" = 1 ] && has "ms.service: LoadState=not-found, expected loaded" && ok "a window unit that does not exist" || bad "rc=$rc $(cat "$T/out")"; }
mut alias 's/^Id=ms.service$/Id=ms-renamed.service/' \
  && { rc=$(chk "$T/alias.txt"); [ "$rc" = 1 ] && has "ms.service: not reported" && has "reported but not in the model: ms-renamed.service" && ok "a unit reported under another name (alias)" || bad "rc=$rc $(cat "$T/out")"; }
mut noprop '/^Id=msp.service$/,/^$/ { /^Requisite=$/d }' \
  && { rc=$(chk "$T/noprop.txt"); [ "$rc" = 1 ] && has "msp.service Requisite: not reported" && ok "a compared property missing from the output" || bad "rc=$rc $(cat "$T/out")"; }

echo "U4 Upholds / PropagatesStopTo / StopPropagatedFrom (newer systemd): compared when reported, absent = cannot exist"
mut upholds-empty 's/^LoadState=loaded$/LoadState=loaded\nUpholds=/' \
  && { rc=$(chk "$T/upholds-empty.txt"); [ "$rc" = 0 ] && ok "reported empty: rc 0" || bad "rc=$rc $(cat "$T/out")"; }
mut upholds '/^Id=unifi-protect.service$/,/^$/ s/^LoadState=loaded$/LoadState=loaded\nUpholds=msr.service/' \
  && { rc=$(chk "$T/upholds.txt"); [ "$rc" = 1 ] && has "unifi-protect.service Upholds: target adds msr.service" && ok "reported with an edge: rc 1" || bad "rc=$rc $(cat "$T/out")"; }

mut propstop '/^Id=unifi-protect.service$/,/^$/ s/^LoadState=loaded$/LoadState=loaded\nPropagatesStopTo=msr.service\nStopPropagatedFrom=/' \
  && { rc=$(chk "$T/propstop.txt"); [ "$rc" = 1 ] && has "unifi-protect.service PropagatesStopTo: target adds msr.service" && ! has "StopPropagatedFrom" && ok "PropagatesStopTo reported with an edge: rc 1 (an empty StopPropagatedFrom is fine)" || bad "rc=$rc $(cat "$T/out")"; }

echo "U4b ConflictedBy (always) and OnSuccess (when reported): a unit outside the model whose start stops a window unit"
mut conflictedby '/^Id=msr.service$/,/^$/ s/^ConflictedBy=$/ConflictedBy=ds.service/' \
  && { rc=$(chk "$T/conflictedby.txt"); [ "$rc" = 1 ] && has "msr.service ConflictedBy: target adds ds.service" && ok "a reverse Conflicts edge from outside the model: rc 1" || bad "rc=$rc $(cat "$T/out")"; }
mut nocb '/^Id=msr.service$/,/^$/ { /^ConflictedBy=$/d }' \
  && { rc=$(chk "$T/nocb.txt"); [ "$rc" = 1 ] && has "msr.service ConflictedBy: not reported" && ok "ConflictedBy missing from the output: rc 1" || bad "rc=$rc $(cat "$T/out")"; }
# a Conflicts edge between two window units: systemd reports the reverse ConflictedBy; a model with both lines matches
sed -e 's/^msr.service Conflicts shutdown.target$/msr.service Conflicts shutdown.target postgresql@14-protect.service/' \
    -e 's/^postgresql@14-protect.service ConflictedBy$/postgresql@14-protect.service ConflictedBy msr.service/' "$MODEL" > "$T/m-conf.txt"
mut cbpair '/^Id=msr.service$/,/^$/ s/^Conflicts=shutdown.target$/Conflicts=shutdown.target postgresql@14-protect.service/; /^Id=postgresql@14-protect.service$/,/^$/ s/^ConflictedBy=$/ConflictedBy=msr.service/' \
  && { $G check "$T/m-conf.txt" "$T/cbpair.txt" > "$T/out" 2>&1; rc=$?; [ "$rc" = 0 ] && has "matches" && ok "Conflicts between window units + the reverse ConflictedBy, modelled both ways: rc 0" || bad "rc=$rc $(cat "$T/out")"; }
mut onsuccess '/^Id=mst.service$/,/^$/ s/^LoadState=loaded$/LoadState=loaded\nOnSuccess=reboot.target/' \
  && { rc=$(chk "$T/onsuccess.txt"); [ "$rc" = 1 ] && has "mst.service OnSuccess: target adds reboot.target" && ok "OnSuccess reported with an edge: rc 1" || bad "rc=$rc $(cat "$T/out")"; }

echo "U5 output that cannot be judged (ssh failure, error text, malformed) is rc 2, never a match"
: > "$T/empty.txt"; rc=$(chk "$T/empty.txt"); [ "$rc" = 2 ] && ok "empty output: rc 2" || bad "empty: rc=$rc"
echo "ssh: Could not resolve hostname target.invalid: Name or service not known" > "$T/err.txt"
rc=$(chk "$T/err.txt"); [ "$rc" = 2 ] && ok "an error message: rc 2" || bad "error text: rc=$rc"
{ cat "$FIX"; echo; sed -n '/^Id=ms.service$/,$p' "$FIX"; } > "$T/dup.txt"
rc=$(chk "$T/dup.txt"); [ "$rc" = 2 ] && has "reported twice" && ok "a unit reported twice: rc 2" || bad "dup: rc=$rc $(cat "$T/out")"
mut noblank '/^$/{N;s/^\nId=mst.service$/Id=mst.service/}' \
  && { rc=$(chk "$T/noblank.txt"); [ "$rc" = 2 ] && ok "blocks not separated: rc 2" || bad "noblank: rc=$rc $(cat "$T/out")"; }

echo "U6 propagation the fake applies (systemd semantics on the model)"
cl() { $G closure "$MODEL" "$1" "$2" | tr '\n' ' '; }
[ "$(cl stop unifi-protect.service)" = "postgresql@14-protect.service " ] && ok "stop Protect -> its PostgreSQL (PartOf)" || bad "stop protect: $(cl stop unifi-protect.service)"
[ "$(cl stop postgresql@14-protect.service)" = "" ] && ok "stop PostgreSQL -> nothing (msr / msp only Want it)" || bad "stop pg: $(cl stop postgresql@14-protect.service)"
[ "$(cl start unifi-protect.service)" = "ms.service msp.service msr.service mst.service postgresql@14-protect.service " ] && ok "start Protect -> ms msp msr mst + PostgreSQL (via msr / msp Wants)" || bad "start protect: $(cl start unifi-protect.service)"
[ "$(cl start msr.service)" = "postgresql@14-protect.service " ] && ok "start msr -> PostgreSQL" || bad "start msr: $(cl start msr.service)"
[ "$(cl start postgresql@14-protect.service)" = "" ] && ok "start PostgreSQL alone pulls in nothing (never Protect)" || bad "start pg: $(cl start postgresql@14-protect.service)"
[ "$(cl restart unifi-protect.service)" = "postgresql@14-protect.service ms.service msp.service msr.service mst.service " ] && ok "restart Protect -> PostgreSQL restarted along, consumers pulled in" || bad "restart protect: $(cl restart unifi-protect.service)"
$G tables "$MODEL" "$T/tables" && [ "$(tr '\n' ' ' < "$T/tables/observed-stop.unifi-protect.service")" = "msr.service ms.service " ] \
  && [ "$(cat "$T/tables/stop.unifi-protect.service")" = postgresql@14-protect.service ] && [ ! -s "$T/tables/requisite.msr.service" ] \
  && [ "$(wc -l < "$T/tables/units")" = 6 ] && ok "tables: units, stop, observed-stop, requisite" || bad "tables: $(ls "$T/tables" | tr '\n' ' ')"
[ -z "$(cl conflicts msr.service)" ] && [ ! -s "$T/tables/conflicts.unifi-protect.service" ] && ok "conflicts: none inside the window set (shutdown.target is outside)" || bad "conflicts: $(cl conflicts msr.service)"
[ "$(diff "$MODEL" "$T/m-conf.txt" | grep -c '^>')" != 2 ] && bad "conflict model mutation did not apply" || { [ "$($G closure "$T/m-conf.txt" conflicts postgresql@14-protect.service)" = msr.service ] && [ "$($G closure "$T/m-conf.txt" conflicts msr.service)" = postgresql@14-protect.service ] && ok "a modelled Conflicts edge works in both directions" || bad "conflict closure wrong"; }
# a model edge removed -> the closure changes: the fake really follows the model
grep -v '^postgresql@14-protect.service PartOf' "$MODEL" > "$T/m-nopart.txt"; echo 'postgresql@14-protect.service PartOf postgresql.service' >> "$T/m-nopart.txt"
[ "$($G closure "$T/m-nopart.txt" stop unifi-protect.service)" = "" ] && ok "model without PartOf=unifi-protect: stop Protect leaves PostgreSQL alone" || bad "closure ignores the model"

echo "U7 the model parser refuses broken models (rc 2)"
lintbad() {  # <label> <model text>
  printf '%s\n' "$2" > "$T/m.txt"; $G lint "$T/m.txt" > "$T/out" 2>&1; local rc=$?
  [ "$rc" = 2 ] && ok "$1: rc 2 ($(head -c 90 "$T/out"))" || bad "$1: rc=$rc $(cat "$T/out")"
}
P='a.service Requires
a.service Requisite
a.service BindsTo
a.service PartOf
a.service Wants
a.service Conflicts
a.service OnFailure
a.service ConflictedBy'
printf '%s\n' "unit a.service" "$P" > "$T/m.txt"; $G lint "$T/m.txt" > "$T/out" 2>&1 && ok "control: the minimal model used below is valid" || bad "control model refused: $(cat "$T/out")"
lintbad "property line missing"   "unit a.service
a.service Requires
a.service BindsTo
a.service PartOf
a.service Wants"
lintbad "unknown property"        "unit a.service
$P
a.service After b.service"
lintbad "unit declared twice"     "unit a.service
unit a.service
$P"
lintbad "property listed twice"   "unit a.service
$P
a.service Wants"
lintbad "line for an undeclared unit" "unit a.service
$P
b.service Wants"
lintbad "observed-stop outside the window set" "unit a.service
$P
observed-stop a.service b.service"
lintbad "window unit name not shell-safe" 'unit a\x2db.service'
lintbad "not a unit name"         "unit a.service
$P
a.service Wants \$(id)"
lintbad "no units"                "# empty"
lintbad "OnFailure in the model (not simulated)" "unit a.service
$(echo "$P" | sed 's/^a.service OnFailure$/a.service OnFailure b.service/')"
lintbad "ConflictedBy from a unit outside the window set (not simulated)" "unit a.service
$(echo "$P" | sed 's/^a.service ConflictedBy$/a.service ConflictedBy b.service/')"
PB=$(echo "$P" | sed 's/^a\./b./')
lintbad "Conflicts between window units without the reverse ConflictedBy" "unit a.service
unit b.service
$(echo "$P" | sed 's/^a.service Conflicts$/a.service Conflicts b.service/')
$PB"
lintbad "ConflictedBy naming a window unit that does not conflict" "unit a.service
unit b.service
$P
$(echo "$PB" | sed 's/^b.service ConflictedBy$/b.service ConflictedBy a.service/')"
printf '%s\n' "unit a.service" "unit b.service" "$(echo "$P" | sed 's/^a.service Conflicts$/a.service Conflicts b.service shutdown.target/')" \
  "$(echo "$PB" | sed 's/^b.service ConflictedBy$/b.service ConflictedBy a.service/')" > "$T/m.txt"
$G lint "$T/m.txt" > "$T/out" 2>&1 && [ "$($G closure "$T/m.txt" conflicts b.service)" = a.service ] \
  && ok "Conflicts between window units with the matching ConflictedBy: valid, simulated both ways" || bad "consistent ConflictedBy refused: $(cat "$T/out")"
lintbad "Upholds in the model (not simulated)" "unit a.service
$P
a.service Upholds b.service"

echo "N0 night.sh wiring: offline harness (fake ssh / scp / curl, *.invalid hosts, own site file)"
mkdir -p "$T/bin" "$T/import/b1"
for x in ssh scp curl; do
  # fake: log the call, never connect; ssh answers the few remote commands these tests need
  cat > "$T/bin/$x" << EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/$x.log"
[ "$x" = ssh ] || exit 1
c=\${@: -1}
case \$c in
  "systemctl show "*) cat "$T/show.txt"; exit \$(cat "$T/show.rc") ;;
  *"string_agg(distinct version"*) echo 7.3.70 ;;
  *"&& sha256sum sql/"*) cd "$T/target-b1" && bash -c "\${c#*&& }"; exit \$(cat "$T/hash.rc") ;;
  "cat "*/prep.done) cat "$T/target-b1/prep.done" 2> /dev/null ;;
  *"rm -f "*/prep.done) rm -f "$T/target-b1/prep.done" ;;
  "cat > "*/prep.done.tmp*) cat > "$T/target-b1/prep.done" ;;
  "n=0; m=0;"*) [ -e "$T/staged.ok" ] && { cat > /dev/null; echo "staged=1 targets_existing=0"; } ;;
  "systemctl is-active "*) echo inactive ;;
  *systemd-run*) echo launched ;;
esac
exit 0
EOF
  chmod +x "$T/bin/$x"
done
printf 'NAME_PREFIX=footage-heist\nIMPORT_DIR=%s/import\nSOURCE_SSH=source.invalid\nTARGET_SSH=target.invalid\nTARGET_STAGING=/volume/test/import-staging\nTARGET_WORKDIR=/var/lib/footage-heist\n' "$T" > "$T/site.env"
printf 'SLUG=b1\nSCHEMA=footage_heist_b1\nUCAM=cam0\n' > "$T/import/b1/batch.env"; echo 'cam0/2026/01/01/x.ubv' > "$T/import/b1/files.txt"; echo '{}' > "$T/import/b1/manifest.json"
mkdir -p "$T/import/b1/sql"; env -i "PATH=$PATH" "HOME=$T" "IMPORT_SITE=$T/site.env" python3 "$TOOL/gen.py" --version-guard-sql > "$T/import/b1/sql/apply.sql"
# the session name gen.py writes into apply / rollback, a data file, and the target's copy of both as prep uploaded them
echo "set application_name = 'footage-heist-b1';" >> "$T/import/b1/sql/apply.sql"
echo "set application_name = 'footage-heist-b1';" > "$T/import/b1/sql/rollback.sql"
mkdir -p "$T/import/b1/data" "$T/target-b1"; echo 'row' > "$T/import/b1/data/t.copy"
printf '#!/bin/bash\n' > "$T/import/b1/run.sh"
# remote.env as prep writes it from the site configuration (go requires it unchanged)
scv() { env -i "PATH=$PATH" "HOME=$T" "IMPORT_SITE=$T/site.env" python3 "$TOOL/siteconf.py" shell | sed -n "s/^$1=//p"; }
printf 'STAGE=%s/files\nPROTECT_DIR=%s\nLEDGER_SCHEMA=%s\nNAME_PREFIX=%s\n' "$(scv TARGET_STAGING)" "$(scv TARGET_PROTECT_DIR)" \
  "$(scv LEDGER_SCHEMA)" "$(scv NAME_PREFIX)" > "$T/import/b1/remote.env"
cp -r "$T/import/b1/sql" "$T/import/b1/data" "$T/import/b1/files.txt" "$T/import/b1/batch.env" "$T/import/b1/run.sh" "$T/import/b1/remote.env" "$TOOL/window-remote.sh" "$T/target-b1/"
( cd "$T/target-b1" && sha256sum sql/*.sql data/*.copy files.txt batch.env run.sh remote.env window-remote.sh | LC_ALL=C sort -k2 ) > "$T/target-b1/prep.done"
cp "$T/target-b1/prep.done" "$T/prep.done.keep"; echo 0 > "$T/hash.rc"
NENV=(env -i "PATH=$T/bin:$PATH" "HOME=$T" "IMPORT_SITE=$T/site.env")
# preconditions, checked before the first night.sh call: the fakes are what night.sh resolves, the hosts cannot resolve
if [ "$("${NENV[@]}" bash -c 'command -v ssh; command -v scp; command -v curl' | tr '\n' ' ')" = "$T/bin/ssh $T/bin/scp $T/bin/curl " ] \
   && "${NENV[@]}" python3 "$TOOL/siteconf.py" shell | grep -qx "TARGET_SSH=target.invalid"; then
  ok "fake ssh / scp / curl first on PATH, TARGET_SSH=target.invalid"
  NIGHT=1
else
  bad "harness preconditions not met --- night.sh tests skipped"; NIGHT=0
fi
night() {  # <show sample> <show rc> <night.sh args...>; output in $T/out, calls in $T/*.log
  cp "$1" "$T/show.txt"; echo "$2" > "$T/show.rc"; shift 2
  rm -f "$T"/ssh.log "$T"/scp.log "$T"/curl.log
  "${NENV[@]}" bash "$TOOL/night.sh" "$T/import/b1" "$@" > "$T/out" 2>&1; echo $?
}
launched() { grep -q 'systemd-run' "$T/ssh.log" 2>/dev/null; }

if [ "$NIGHT" = 1 ]; then
echo "N1 preflight prints the verdict"
night "$FIX" 0 preflight > /dev/null; has "unit graph: matches unit-model.txt (6 units)" && ok "match shown" || bad "$(grep -i graph "$T/out")"
night "$T/added.txt" 0 preflight > /dev/null; has "DIFFERS msr.service BindsTo" && ok "difference shown" || bad "$(grep -i graph "$T/out")"

echo "N2 go: matching graph -> window launched; different / unreadable graph -> refused before anything stops"
rc=$(night "$FIX" 0 go); [ "$rc" = 0 ] && launched && ok "match: launched" || bad "rc=$rc launched=$(launched && echo y || echo n) $(tail -3 "$T/out")"
rc=$(night "$T/removed.txt" 0 go); [ "$rc" = 1 ] && has "REFUSED: the target's unit graph" && has "DIFFERS postgresql@14-protect.service PartOf" && ! launched && ok "difference: rc 1, refused, nothing launched" || bad "rc=$rc $(tail -3 "$T/out")"
: > "$T/none.txt"
rc=$(night "$T/none.txt" 255 go); [ "$rc" = 1 ] && has "REFUSED: the target's unit graph" && has "cannot read the target's units (ssh rc 255)" && ! launched && ok "ssh failure: rc 1, refused, nothing launched" || bad "rc=$rc $(tail -3 "$T/out")"
rc=$(night "$T/none.txt" 0 go); [ "$rc" = 1 ] && has "cannot check: empty systemctl show output" && ! launched && ok "no output at all: refused" || bad "rc=$rc $(tail -3 "$T/out")"
# a complete, matching answer from an ssh that still fails is not trusted either
rc=$(night "$FIX" 255 go); [ "$rc" = 1 ] && has "ssh rc 255" && ! launched && ok "matching text but ssh rc 255: refused" || bad "rc=$rc $(tail -3 "$T/out")"

echo "N3 prep: refused before anything is pushed; a matching graph passes on to the next check"
rc=$(night "$T/requisite.txt" 0 prep); [ "$rc" = 1 ] && has "REFUSED: the target's unit graph" && [ ! -s "$T/scp.log" ] && ! has "push batch" && ok "difference: refused, nothing pushed" || bad "rc=$rc $(tail -3 "$T/out")"
rc=$(night "$FIX" 0 prep); ! has "REFUSED: the target's unit graph" && has "ABORT: expected staged=1 targets_existing=0" && [ ! -s "$T/scp.log" ] && ok "match: graph check passed (stops at the staged-file check of this fake target)" || bad "rc=$rc $(tail -3 "$T/out")"

echo "N4 rollback refuses, recover warns and still runs"
rc=$(night "$T/notfound.txt" 0 rollback); [ "$rc" = 1 ] && has "REFUSED: the target's unit graph" && ! launched && ok "rollback: refused" || bad "rc=$rc $(tail -3 "$T/out")"
rc=$(night "$FIX" 0 rollback); launched && ok "rollback, match: launched" || bad "rc=$rc $(tail -3 "$T/out")"
rc=$(night "$T/notfound.txt" 0 recover); has "WARNING: the target's unit graph is not the modelled one" && has "DIFFERS ms.service" && ! has "REFUSED" && launched && ok "recover: difference shown, warned, launched" || bad "rc=$rc $(tail -3 "$T/out")"

echo "N5 UNIT_MODEL (site key / environment) selects the model"
grep -v '^msr.service BindsTo' "$MODEL" > "$T/m-site.txt"; echo 'msr.service BindsTo unifi-protect.service' >> "$T/m-site.txt"
cp "$FIX" "$T/show.txt"; echo 0 > "$T/show.rc"; rm -f "$T/ssh.log"
"${NENV[@]}" UNIT_MODEL="$T/m-site.txt" bash "$TOOL/night.sh" "$T/import/b1" go > "$T/out" 2>&1; rc=$?
[ "$rc" = 1 ] && has "msr.service BindsTo: target lacks unifi-protect.service" && ! launched && ok "a site model the target does not match: refused" || bad "rc=$rc $(tail -3 "$T/out")"
cp "$T/added.txt" "$T/show.txt"; rm -f "$T/ssh.log"
"${NENV[@]}" UNIT_MODEL="$T/m-site.txt" bash "$TOOL/night.sh" "$T/import/b1" go > "$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && launched && ok "the target that matches the site model: launched" || bad "rc=$rc $(tail -3 "$T/out")"

echo "N6 go: the SQL / data on the target must be the batch dir's (prep uploaded them); otherwise refused before anything stops"
cp "$T/import/b1/sql/apply.sql" "$T/apply.keep"; echo '-- regenerated' >> "$T/import/b1/sql/apply.sql"
rc=$(night "$FIX" 0 go); [ "$rc" = 1 ] && has "REFUSED: the batch on the target" && has "run prep again" && ! launched && ok "batch regenerated after prep: refused, nothing launched" || bad "rc=$rc $(tail -3 "$T/out")"
cp "$T/apply.keep" "$T/import/b1/sql/apply.sql"; mv "$T/target-b1/data/t.copy" "$T/t.copy.keep"
rc=$(night "$FIX" 0 go); [ "$rc" = 1 ] && has "REFUSED: the batch on the target" && ! launched && ok "a data file missing on the target: refused" || bad "rc=$rc $(tail -3 "$T/out")"
mv "$T/t.copy.keep" "$T/target-b1/data/t.copy"; echo 255 > "$T/hash.rc"
rc=$(night "$FIX" 0 go); [ "$rc" = 1 ] && has "REFUSED: the batch on the target" && ! launched && ok "the target's hashes unreadable (ssh rc 255): refused" || bad "rc=$rc $(tail -3 "$T/out")"
echo 0 > "$T/hash.rc"
rc=$(night "$FIX" 0 go); [ "$rc" = 0 ] && launched && ok "identical again: launched" || bad "rc=$rc $(tail -3 "$T/out")"
mv "$T/target-b1/prep.done" "$T/pd.keep"
rc=$(night "$FIX" 0 go); [ "$rc" = 1 ] && has "REFUSED: no completed prep on the target" && ! launched && ok "no prep.done (interrupted / older prep): refused" || bad "rc=$rc $(tail -3 "$T/out")"
mv "$T/pd.keep" "$T/target-b1/prep.done"; cp "$T/target-b1/remote.env" "$T/re.keep"; echo 'NAME_PREFIX=old-prefix' >> "$T/target-b1/remote.env"
rc=$(night "$FIX" 0 go); [ "$rc" = 1 ] && has "REFUSED: the batch on the target" && ! launched && ok "remote.env on the target from another prep (SQL / data match): refused" || bad "rc=$rc $(tail -3 "$T/out")"
cp "$T/re.keep" "$T/target-b1/remote.env"
echo "N6b go: the site configuration changed since prep (the window would run with the old remote.env values): refused"
cp "$T/site.env" "$T/site.keep"; sed -i 's#^TARGET_STAGING=.*#TARGET_STAGING=/volume/test/import-staging-2#' "$T/site.env"
rc=$(night "$FIX" 0 go); [ "$rc" = 1 ] && has "REFUSED: the site configuration changed since prep" && ! launched && ok "TARGET_STAGING changed after prep: refused, nothing launched" || bad "rc=$rc $(tail -3 "$T/out")"
cp "$T/site.keep" "$T/site.env"
rc=$(night "$FIX" 0 go); [ "$rc" = 0 ] && launched && ok "site configuration as at prep: launched" || bad "rc=$rc $(tail -3 "$T/out")"

echo "N7 prep: apply / rollback must set the session name NAME_PREFIX-<slug> (the one the window script waits on)"
sed -i "s/'footage-heist-b1'/'old-prefix-b1'/" "$T/import/b1/sql/rollback.sql"
rc=$(night "$FIX" 0 prep); [ "$rc" = 1 ] && has "REFUSED: sql/rollback.sql does not set exactly application_name 'footage-heist-b1'" && [ ! -s "$T/scp.log" ] && [ ! -s "$T/ssh.log" ] && ! has "push batch" && ok "rollback.sql from an older NAME_PREFIX: refused before any ssh (no preflight), nothing pushed" || bad "rc=$rc $(tail -3 "$T/out")"
sed -i "s/'old-prefix-b1'/'footage-heist-b1'/" "$T/import/b1/sql/rollback.sql"
rc=$(night "$FIX" 0 prep); ! has "REFUSED" && has "ABORT: expected staged=1 targets_existing=0" && ok "names match: passes on to the staged-file check" || bad "rc=$rc $(tail -3 "$T/out")"
cp "$T/import/b1/sql/apply.sql" "$T/apply.keep2"; echo "set application_name = 'other';" >> "$T/import/b1/sql/apply.sql"
rc=$(night "$FIX" 0 prep); [ "$rc" = 1 ] && has "REFUSED: sql/apply.sql does not set exactly" && ok "a second SET application_name: refused" || bad "rc=$rc $(tail -3 "$T/out")"
cp "$T/apply.keep2" "$T/import/b1/sql/apply.sql"; sed -i "s|^set application_name = 'footage-heist-b1';$|/*\\nset application_name = 'footage-heist-b1';\\n*/|" "$T/import/b1/sql/apply.sql"
rc=$(night "$FIX" 0 prep); [ "$rc" = 1 ] && has "REFUSED: sql/apply.sql does not set exactly" && ok "the line inside a block comment: refused" || bad "rc=$rc $(tail -3 "$T/out")"
cp "$T/apply.keep2" "$T/import/b1/sql/apply.sql"

echo "N8 an interrupted re-prep leaves no prep.done: go refuses until a prep completes"
printf '%064d  /volume/test/import-staging/files/cam0/2026/01/01/x.ubv\n' 0 > "$T/import/b1.sha256"; touch "$T/staged.ok"
rc=$(night "$FIX" 0 prep); [ "$rc" = 1 ] && has "== push batch" && [ -s "$T/scp.log" ] && [ ! -e "$T/target-b1/prep.done" ] \
  && ok "prep removed prep.done before its first upload; the upload failed (fake scp)" || bad "rc=$rc prep.done=$(test -e "$T/target-b1/prep.done" && echo present || echo gone) $(tail -3 "$T/out")"
rc=$(night "$FIX" 0 go); [ "$rc" = 1 ] && has "REFUSED: no completed prep on the target" && ! launched && ok "go after it: refused, nothing launched" || bad "rc=$rc $(tail -3 "$T/out")"
rm -f "$T/staged.ok"
fi
[ -s "$T/curl.log" ] && bad "curl was called: $(head -2 "$T/curl.log")"

echo "RESULT pass=$pass fail=$fail (sandbox: $T)"
[ "$fail" = 0 ]
