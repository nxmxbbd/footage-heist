#!/usr/bin/env bash
# test-verify-rows.sh --- offline tests of the copy verify's rows check (verify-rows.py) and its successor re-read
# (verify-staged.sh step 1b). Synthetic rows of one documentation-MAC camera; verify-staged.sh runs with a fake ssh / scp
# first on PATH, a throw-away site configuration whose hosts are *.invalid, env -i. Needs no device, no docker.
#   V1-V16: verify-rows.py verdicts (the successor update of a deleted row is explained; anything near it is a FAIL)
#   S1-S5:  verify-staged.sh end to end: successor re-read OK / MISMATCH / deleted since, two successors, a plain FAIL
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d /tmp/test-verify-rows.XXXXXX); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
M=00005E005301
F=/srv/unifi-protect/video/2026/01/01
U0='2026-01-01 00:00:00+00'; U1='2026-01-02 03:00:00+00'
# row <id> <type> <channel> <start> <end> [size] [updatedAt] --- one rows.sql line
row() { echo "$1|$F|${M}_${3}_${2}_$1.ubv|${6:-100}|$2|$3|$4|$5|f|f|f||${7:-$U0}"; }   # file name from the id, not start
sha() { printf '%s' "$1" | sha256sum | cut -c1-64; }
# base set: rotating ch0 r1-r4 (r1/r2 touch, r2/r3 overlap 4 ms), rotating ch1 c1, thumbnails t1
base() {
  row r1 rotating 0 1000 2000; row r2 rotating 0 2000 3004; row r3 rotating 0 3000 4000; row r4 rotating 0 4000 5000
  row c1 rotating 1 1000 3004; row t1 thumbnails 0 1000 5000
}
mkdir -p "$T/bin" "$T/import" "$T/srcsha"
# ledger_from <rows file> [id to leave out]... --- a copied ledger entry for every row (rel = the staging path)
ledger_from() {
  local f=$1 id file; shift
  while IFS='|' read -r id _ file _; do
    case " $* " in *" $id "*) continue ;; esac
    printf '{"id": "%s", "rel": "srv/2026/01/01/%s", "size": 100, "sha256": "%s", "remote": "OK 100 %s", "rc": 0, "err": "", "secs": 1, "mbps": 1, "result": "ok", "ts": "2026-01-01T00:00:00+0000"}\n' \
      "$id" "$file" "$(sha "$id")" "$(sha "$id")"
  done < "$f"
}
listof() { cut -d'|' -f1-4; }

# vr <label> <want rc> <grep pattern> --- runs verify-rows.py on $T/v.{pre,post,ledger,list,gone}
vr() {
  local out rc
  out=$(python3 "$TOOL/verify-rows.py" "$T/v.pre" "$T/v.post" "$T/v.ledger" "$T/v.list" "$T/v.gone" "$T/v.succ" 2>&1); rc=$?
  if [ "$rc" = "$2" ] && grep -qE -- "$3" <<< "$out"; then ok "$1"; else bad "$1 (rc=$rc want $2; pattern '$3')"; printf '%s\n' "$out" | sed 's/^/      /'; fi
}
setup() { base > "$T/v.pre"; base | listof > "$T/v.list"; ledger_from "$T/v.pre" > "$T/v.ledger"; rm -f "$T/v.gone" "$T/v.succ"; }
post_without() { local p=$1; shift; grep -v "^$p|" "$T/v.pre" | "$@" > "$T/v.post"; }
sub() { sed "s#^$1|.*#$2#"; }   # replace the row with id $1 by line $2

echo "== verify-rows.py"
setup; cp "$T/v.pre" "$T/v.post"
vr 'V1 unchanged rows pass' 0 '^rows: unchanged \(6\)$'

setup; post_without r2 sub r3 "$(row r3 rotating 0 3004 4000 100 "$U1")"
vr 'V2 overlap: r2 deleted, r3 start -> r2 end is the successor update' 0 'successor of a deleted file 1, other 0'
[ "$(cat "$T/v.succ")" = "r3|$F/${M}_0_rotating_r3.ubv|$(sha r3)" ] && ok 'V2 successor listed for the source re-read (path, ledger sha)' \
  || bad "V2 successors file: $(cat "$T/v.succ")"

setup; post_without r1 sub r2 "$(row r2 rotating 0 2000 3004 100 "$U1")"
vr 'V3 touch: r1 deleted, r2 only updatedAt changed is the successor update' 0 'successor of a deleted file 1, other 0'

setup; sub r3 "$(row r3 rotating 0 3004 4000 100 "$U1")" < "$T/v.pre" > "$T/v.post"
vr 'V4 start moved with nothing deleted is a FAIL' 1 '^FAIL: source rows changed'

setup; post_without r2 sub r3 "$(row r3 rotating 0 3002 4000 100 "$U1")"
vr 'V5 start moved, but not to the deleted end, is a FAIL' 1 'other 1'

setup; post_without r2 sub r3 "$(row r3 rotating 0 3004 4000 99 "$U1")"
vr 'V6a successor with a changed size is a FAIL' 1 'other 1'
setup; post_without r2 sub r3 "$(row r3 rotating 0 3004 4100 100 "$U1")"
vr 'V6b successor with a changed end is a FAIL' 1 'other 1'
setup; post_without r2 sub r3 "$(row r3 rotating 0 3004 4000 100 "$U1" | sed 's/|f|f|f|/|t|f|f|/')"
vr 'V6c successor with a changed active flag is a FAIL' 1 'other 1'

setup; post_without c1 sub r3 "$(row r3 rotating 0 3004 4000 100 "$U1")"
vr 'V7 deleted row of another channel (same end) does not explain it' 1 'other 1'

setup; sed -i "s#^r3|.*#$(row r3 rotating 0 3010 4000)#" "$T/v.pre"
post_without r2 sub r3 "$(row r3 rotating 0 3004 4000 100 "$U1")"
vr 'V8 start moved back to the deleted end is a FAIL' 1 'other 1'

setup; { cat "$T/v.pre"; row r5 rotating 0 5000 6000; } > "$T/v.post"
vr 'V9 an added row is a FAIL' 1 '^  added: r5'

setup; grep -v '^r1|' "$T/v.pre" > "$T/v.post"; ledger_from "$T/v.pre" r1 > "$T/v.ledger"
vr 'V10 disappeared, listed, not copied, not in .gone is a FAIL' 1 'unexplained disappearance: r1'
echo "r1|$F|x|100|2026-01-01" > "$T/v.gone"
vr 'V11a disappeared and in .gone passes' 0 'in \.gone 1'
rm -f "$T/v.gone"; grep -v '^r1|' "$T/v.list" > "$T/v.list2"; mv "$T/v.list2" "$T/v.list"
vr 'V11b disappeared outside the list passes' 0 'outside this list 1'

setup; grep -v '^r3|' "$T/v.list" > "$T/v.list2"; mv "$T/v.list2" "$T/v.list"
post_without r2 sub r3 "$(row r3 rotating 0 3004 4000 100 "$U1")"
vr 'V12 successor outside the list passes' 0 'not copied \(outside this list\)'
[ -s "$T/v.succ" ] && bad 'V12 a successor outside the list must not be re-read' || ok 'V12 nothing to re-read'

setup; sed -i "s#^r4|.*#$(row r4 rotating 0 3000 5000)#" "$T/v.pre"
post_without r2 sh -c "sed -e 's#^r3|.*#$(row r3 rotating 0 3004 4000 100 "$U1")#' -e 's#^r4|.*#$(row r4 rotating 0 3004 5000 100 "$U1")#'"
vr 'V13 one deleted row cannot explain two successors' 1 'successor of a deleted file 1, other 1'

setup; cp "$T/v.pre" "$T/v.post"; echo 'r9|only|three' >> "$T/v.post"
vr 'V14 a malformed row is a FAIL' 1 'FAIL: .*a row with 3 columns'

setup; ledger_from "$T/v.pre" r3 > "$T/v.ledger"
post_without r2 sub r3 "$(row r3 rotating 0 3004 4000 100 "$U1")"
vr 'V15 successor listed but not copied: explained here, nothing to re-read' 0 'not in the ledger'
[ -s "$T/v.succ" ] && bad 'V15 an uncopied successor must not be re-read' || ok 'V15 nothing to re-read'

setup; post_without r2 sh -c "sed -e 's#^r3|.*#$(row r3 rotating 0 3004 4000 100 "$U1")#' -e 's#^r1|.*#$(row r1 rotating 0 1000 2000 100 "$U1")#'"
vr 'V16 a successor next to an unrelated change still fails the camera' 1 'successor of a deleted file 1, other 1'

echo "== verify-staged.sh (fake ssh / scp)"
cat > "$T/bin/ssh" << EOF
#!/usr/bin/env bash
while [ "\${1:-}" = -o ]; do shift 2; done
host=\$1; shift; cmd="\$*"
echo "\$host \$cmd" >> "$T/ssh.log"
cat > /dev/null   # like the real client: it reads its stdin (a while-read loop around it loses its input unless < /dev/null)
case \$host:\$cmd in
  source.invalid:psql*) cat "$T/s.post" ;;
  source.invalid:*'sha256sum '*) f=\${cmd##* }; f=\${f##*/}
    [ -e "$T/srcsha/\$f" ] || { echo "sha256sum: \$f: No such file" >&2; exit 1; }; echo "\$(cat "$T/srcsha/\$f")  \${cmd##* }" ;;
  source.invalid:'test -e '*) f=\${cmd##* }; [ -e "$T/srcsha/\${f##*/}" ] ;;
  target.invalid:'install -d'*) ;;
  target.invalid:*'sha256sum -c'*) ;;
  target.invalid:find*) echo 'stray .part files: 0'; echo 'staged files for mac: 6' ;;
  *) echo "fake ssh: unexpected \$host \$cmd" >&2; exit 255 ;;
esac
EOF
cat > "$T/bin/scp" << EOF
#!/usr/bin/env bash
[ "\$1" = -q ] && shift
case \$1 in source.invalid:*) cp "$T/s.ledger" "\$2" ;; *) ;; esac
EOF
chmod +x "$T/bin/ssh" "$T/bin/scp"
printf 'NAME_PREFIX=footage-heist\nIMPORT_DIR=%s/import\nSOURCE_SSH=source.invalid\nTARGET_SSH=target.invalid\nTARGET_STAGING=/volume/test/import-staging\nTARGET_WORKDIR=/var/lib/footage-heist\nSOURCE_WORKDIR=/var/lib/footage-heist\nTARGET_URL=https://target.invalid\nTARGET_TLS_PIN_FILE=%s/pin\nTARGET_LOGIN_FILE=%s/login.json\n' "$T" "$T" "$T" > "$T/site.env"
E=(env -i "PATH=$T/bin:/usr/bin:/bin" "HOME=$T" "IMPORT_SITE=$T/site.env")
# vs <label> <want rc> <grep pattern>... --- verify-staged.sh on slug cam1 (rows.pre / list from $T/v.*, rows.post $T/s.post)
vs() {
  local label=$1 want=$2 out rc p miss=''; shift 2
  cp "$T/v.pre" "$T/import/cam1.rows.pre"; cp "$T/v.list" "$T/import/cam1.list"; rm -f "$T/import/cam1.gone" "$T/import/cam1.successors"
  : > "$T/ssh.log"
  out=$("${E[@]}" bash "$TOOL/verify-staged.sh" cam1 "$M" 2>&1 < /dev/null); rc=$?
  for p in "$@"; do grep -qE -- "$p" <<< "$out" || miss="$miss '$p'"; done
  if [ "$rc" = "$want" ] && [ -z "$miss" ]; then ok "$label"; else bad "$label (rc=$rc want $want; missing$miss)"; printf '%s\n' "$out" | sed 's/^/      /'; fi
}
srcsha_all() { local id file; rm -f "$T/srcsha"/*; while IFS='|' read -r id _ file _; do sha "$id" > "$T/srcsha/$file"; done < "$T/v.pre"; }

setup; ledger_from "$T/v.pre" > "$T/s.ledger"; srcsha_all
grep -v '^r2|' "$T/v.pre" | sub r3 "$(row r3 rotating 0 3004 4000 100 "$U1")" > "$T/s.post"
vs 'S1 successor re-read OK, then the target re-read runs' 0 "successor re-read OK: ${M}_0_rotating_r3.ubv" '^target re-read: all match'

sha tampered > "$T/srcsha/${M}_0_rotating_r3.ubv"
vs 'S2 successor whose source bytes changed is a FAIL' 1 "^FAIL successor re-read MISMATCH: ${M}_0_rotating_r3.ubv"
grep -q 'target.invalid' "$T/ssh.log" && bad 'S2 must stop before the target re-read' || ok 'S2 stops before the target re-read'

rm -f "$T/srcsha/${M}_0_rotating_r3.ubv"
vs 'S3 successor deleted on the source since: skipped' 0 "successor re-read skipped \(deleted on the source since\): ${M}_0_rotating_r3.ubv"

setup; row c2 rotating 1 3000 4000 >> "$T/v.pre"; listof < "$T/v.pre" > "$T/v.list"
ledger_from "$T/v.pre" > "$T/s.ledger"; srcsha_all
grep -v -e '^r2|' -e '^c1|' "$T/v.pre" | sed -e "s#^r3|.*#$(row r3 rotating 0 3004 4000 100 "$U1")#" -e "s#^c2|.*#$(row c2 rotating 1 3004 4000 100 "$U1")#" > "$T/s.post"
vs 'S4 two successors are both re-read (the loop keeps its input)' 0 "successor re-read OK: ${M}_0_rotating_r3.ubv" "successor re-read OK: ${M}_1_rotating_c2.ubv"

setup; ledger_from "$T/v.pre" > "$T/s.ledger"; srcsha_all
sub r3 "$(row r3 rotating 0 3004 4000 100 "$U1")" < "$T/v.pre" > "$T/s.post"
vs 'S5 a change no deletion explains still fails the camera' 1 '^FAIL: source rows changed in a way the copy cannot account for'

echo "verify-rows: $pass passed, $fail failed"
[ "$fail" = 0 ]
