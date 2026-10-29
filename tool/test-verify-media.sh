#!/usr/bin/env bash
# test-verify-media.sh --- offline tests of verify-media.sh's verdict: fake ssh (answers the SQL it is sent), fake curl
# (login / events / export / thumbnails) and fake ffprobe first on PATH, a throw-away site configuration whose hosts are
# *.invalid, env -i. Checks that a query failure or an empty sample is a failure (nothing verified is not a pass), and
# that the happy path still passes. Needs no device, no docker.
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d /tmp/test-verify-media.XXXXXX); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
mkdir -p "$T/bin" "$T/mode" "$T/import" "$T/b1"
cat > "$T/bin/ssh" << EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/ssh.log"
sql=\$(cat); m() { cat "$T/mode/\$1" 2> /dev/null; }
# msr_ubvinfo -p of the file covering ev1's export window [1699999999000, 1700000008000]: partitions (separated by /,
# mode ubv), each printed as msr_ubvinfo does: a "seek points: N" header, then its seek points. hole (default) = 170 s
# without a seek point around the window, across two partitions (a file of a camera that reconnected has several)
case "\$*" in *msr_ubvinfo*)
  bad1=
  case \$(m ubv) in
    fail) echo 'cannot open file' >&2; exit 2 ;;
    inside) parts='1699999885000 1699999890000/1700000003000 1700000060000' ;;   # wide apart, one inside the window
    tail) parts='1699999980000 1699999985000 1699999990000' ;;
    badhdr) parts='1699999885000 1699999890000/1700000060000 1700000065000'; bad1=1 ;;   # first header one short
    onepart) parts='1699999885000 1699999890000 1700000060000 1700000065000' ;;
    *) parts='1699999885000 1699999890000/1700000060000 1700000065000' ;;
  esac
  i=0; IFS=/ read -ra pa <<< "\$parts"
  for part in "\${pa[@]}"; do
    set -- \$part; echo '----------------------'; echo "     seek points: \$(( \$# - \${bad1:-0} ))"; bad1=
    j=0; for p in \$part; do echo "      \$j. OFF: \$((i * 1000 + 52)); WC: \$p"; i=\$((i + 1)); j=\$((j + 1)); done
  done; exit 0 ;;
esac
case \$sql in
  *'from "recordingFiles"'*) case \$(m files) in fail) exit 255 ;; none) exit 0 ;;
                               two) printf '/srv/unifi-protect/video/2023/11/14/00005E005301_0_rotating_1699990000000.ubv\n/srv/unifi-protect/video/2023/11/14/00005E005301_0_rotating_1699995000000.ubv\n' ;;
                               *) echo '/srv/unifi-protect/video/2023/11/14/00005E005301_0_rotating_1699990000000.ubv' ;; esac ;;
  *'min(e.start)'*) [ "\$(m range)" = fail ] && exit 255; echo '1700000000000|1700000100000' ;;
  *'count(*) from events'*) case \$(m count) in fail) exit 255 ;; zero) echo 0 ;; one) echo 1 ;; *) echo 2 ;; esac ;;
  *'with ev as'*) [ "\$(m events)" = fail ] && exit 255; [ "\$(m events)" = empty ] && exit 0
                  printf 'ev1|1700000000000|1700000010000|motion\nev2|1700000050000|1700000060000|smartDetectZone\n' ;;
  *'thumbnailId'*) [ "\$(m thumbs)" = fail ] && exit 255; [ "\$(m thumbs)" = empty ] && exit 0
                   echo '00005E005301-1700000000001' ;;
  *'desc limit 1'*) [ "\$(m ctl)" = fail ] && exit 255; echo 'cam9|1700000200000|Control cam' ;;
  *) exit 255 ;;
esac
EOF
cat > "$T/bin/curl" << EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/curl.log"
o=; d=; url=
while [ \$# -gt 0 ]; do case \$1 in -o) o=\$2; shift ;; -D) d=\$2; shift ;; https://*) url=\$1 ;; esac; shift; done
case \$url in
  */api/auth/login) printf 'x-csrf-token: tok\r\n' > "\$d"; echo 'login http=200' ;;
  */api/auth/logout) echo 'logout http=200' ;;
  */api/events\?*) case \$(cat "$T/mode/api" 2> /dev/null) in empty) echo '[]' ;; fill) python3 -c "print([{}] * \${url##*limit=})" ;; *) echo '[{}, {}]' ;; esac ;;
  */video/export\?*) case \$(cat "$T/mode/export" 2> /dev/null) in   # Protect's answer for a window without frames
                      all404) echo '{"error":502}' > "\$o"; printf 404 ;;
                      404first) case \$url in *start=1699999999000*) echo '{"error":502}' > "\$o"; printf 404 ;; *) echo video > "\$o"; printf 200 ;; esac ;;
                      *) echo video > "\$o"; printf 200 ;;
                    esac ;;
  */thumbnail|*/thumbnails/*) echo jpeg > "\$o"; printf '200 image/jpeg' ;;
  *) exit 7 ;;
esac
EOF
cat > "$T/bin/ffprobe" << EOF
#!/usr/bin/env bash
# key=value lines as -of default=nw=1 prints them; errors on stderr with a non-zero exit, as ffprobe -v error does
m() { cat "$T/mode/\$1" 2> /dev/null; }
case "\${@: -1}" in *native-*) [ "\$(m native)" = bad ] && { echo 'Invalid data found when processing input' >&2; exit 1; } ;; esac
case \$(m probe) in
  errh264) echo '[h264 @ 0x55d0c0] Invalid NAL unit size (1234 > 567).' >&2; exit 1 ;;
  novideo) echo 'duration=9.0'; exit 0 ;;
esac
printf 'codec_name=h264\nwidth=1920\nheight=1080\nnb_frames=100\nduration=9.0\n'
EOF
chmod +x "$T"/bin/*
echo 'sha256//AAAA' > "$T/pin"; echo '{}' > "$T/login.json"; chmod 600 "$T/pin" "$T/login.json"
printf 'NAME_PREFIX=footage-heist\nIMPORT_DIR=%s/import\nSOURCE_SSH=source.invalid\nTARGET_SSH=target.invalid\nTARGET_STAGING=/volume/test/import-staging\nTARGET_WORKDIR=/var/lib/footage-heist\nSOURCE_WORKDIR=/var/lib/footage-heist\nTARGET_URL=https://target.invalid\nTARGET_TLS_PIN_FILE=%s/pin\nTARGET_LOGIN_FILE=%s/login.json\n' "$T" "$T" "$T" > "$T/site.env"
printf 'SLUG=b1\nSCHEMA=footage_heist_b1\nUCAM=cam0\n' > "$T/b1/batch.env"
E=(env -i "PATH=$T/bin:/usr/bin:/bin" "HOME=$T" "IMPORT_SITE=$T/site.env")
# preconditions before the first call: the fakes are what the script resolves, the hosts cannot resolve
[ "$("${E[@]}" bash -c 'command -v ssh; command -v curl; command -v ffprobe' | tr '\n' ' ')" = "$T/bin/ssh $T/bin/curl $T/bin/ffprobe " ] \
  && "${E[@]}" python3 "$TOOL/siteconf.py" shell | grep -qx "TARGET_URL=https://target.invalid" \
  && ok "fakes first on PATH, TARGET_URL / TARGET_SSH *.invalid" || { bad "harness preconditions not met"; echo "RESULT pass=$pass fail=$fail"; exit 1; }
# v <modes...> [-- env...]: run verify-media.sh with the given fake modes (name=value); rc echoed, output in $T/out
v() {
  rm -f "$T"/mode/*; local x e=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do echo "${1#*=}" > "$T/mode/${1%%=*}"; shift; done
  [ "${1:-}" = -- ] && { shift; e=("$@"); }
  "${E[@]}" "${e[@]}" N=2 bash "$TOOL/verify-media.sh" "$T/b1" > "$T/out" 2>&1; echo $?
}
has() { grep -qF -- "$1" "$T/out"; }
res() { grep -o 'RESULT pass=[0-9]* fail=[0-9]*' "$T/out"; }

echo "M1 the happy path passes: events API, 2 events x (ch0 + ch2 export + thumbnail), 1 object thumbnail"
rc=$(v); [ "$rc" = 0 ] && [ "$(res)" = "RESULT pass=8 fail=0" ] && ok "rc 0, $(res)" || bad "rc=$rc $(tail -4 "$T/out")"
echo "M2 a failed or empty event sample is a failure"
rc=$(v events=fail); [ "$rc" = 1 ] && has "FAIL event sample query failed" && ! has "no event of >= 3 s" && ok "sample query failed: rc 1, one failure for one cause" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v events=empty); [ "$rc" = 1 ] && has "FAIL no event of >= 3 s" && ! has "query failed" && ok "no event sampled: rc 1" || bad "rc=$rc $(tail -4 "$T/out")"
echo "M3 a failed range query stops before anything else is checked"
rc=$(v range=fail); [ "$rc" = 1 ] && has "range query failed or found no events" && ! has "events spread over the range" && ok "rc 1, nothing to verify" || bad "rc=$rc $(tail -4 "$T/out")"
echo "M4 both sample queries failing (every probe loop empty) is a failure"
rc=$(v events=fail thumbs=fail); [ "$rc" = 1 ] && has "FAIL object thumbnail query failed" && ok "rc 1, $(res)" || bad "rc=$rc $(tail -4 "$T/out")"
echo "M5 object thumbnails: a failed query fails, none in the batch is only reported"
rc=$(v thumbs=fail); [ "$rc" = 1 ] && has "FAIL object thumbnail query failed" && ! has "INFO no object" && ok "query failed: rc 1 (not reported as none in the batch)" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v thumbs=empty); [ "$rc" = 0 ] && has "INFO no object with a thumbnail" && ok "none in the batch: rc 0, reported" || bad "rc=$rc $(tail -4 "$T/out")"
echo "M6 TEST_NATIVE=1: the control clip must contain a video stream"
rc=$(v native=bad -- TEST_NATIVE=1); [ "$rc" = 1 ] && has "FAIL native ch0 export http=200 ffprobe: rc 1: Invalid data" && ok "control clip without video: rc 1" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v -- TEST_NATIVE=1); [ "$rc" = 0 ] && has "PASS native ch2 export" && ok "control clip with video: rc 0" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v ctl=fail -- TEST_NATIVE=1); [ "$rc" = 1 ] && has "FAIL positive control query failed" && ! has "PASS native" && ok "control query failed: rc 1, no control clip probed" || bad "rc=$rc $(tail -4 "$T/out")"
echo "M7 the events API check: a failed or zero DB count, too few API events, or a reply that fills the limit is a failure"
rc=$(v count=fail); [ "$rc" = 1 ] && has "FAIL event count query failed" && ! has "PASS events API" && ok "count query failed: rc 1" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v count=zero); [ "$rc" = 1 ] && has "FAIL event count query failed or counted none ('0')" && ok "count 0: rc 1" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v count=one api=empty); [ "$rc" = 1 ] && has "FAIL events API returned '0' (limit 102), DB has 1" && ok "DB 1, API 0: rc 1 (95 % rounds up)" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v api=fill); [ "$rc" = 1 ] && has "FAIL events API returned '104' (limit 104), DB has 2" && ok "a reply that fills the limit: rc 1" || bad "rc=$rc $(tail -4 "$T/out")"
echo "M8 ffprobe: only exit 0 with a h264 / hevc video stream counts"
rc=$(v probe=errh264); [ "$rc" = 1 ] && [ "$(grep -cF 'ffprobe: rc 1: [h264 @' "$T/out")" = 4 ] && ok "an error naming the codec, rc 1: all 4 clips FAIL" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v probe=novideo); [ "$rc" = 1 ] && has "ffprobe: duration=9.0" && ok "no video stream (rc 0): FAIL" || bad "rc=$rc $(tail -4 "$T/out")"
echo "M9 an export that fails in a hole of the camera's own recording is INFO; any other failed export stays a FAIL"
rc=$(v export=404first); [ "$rc" = 0 ] && [ "$(grep -c "INFO .*export http=404: the window lies in a hole of the camera's own recording (no frame between seek points 11-14 22:11:30Z and 11-14 22:14:20Z (170 s) in 00005E005301_0_rotating_1699990000000.ubv)" "$T/out")" = 2 ] \
  && [ "$(res)" = "RESULT pass=6 fail=0" ] && has "info=2" && ok "hole around the window: rc 0, ch0 + ch2 INFO, $(res)" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v export=404first ubv=onepart); [ "$rc" = 0 ] && [ "$(grep -c '^  INFO .*hole' "$T/out")" = 2 ] && ok "the same hole in a single-partition file: rc 0, INFO" || bad "rc=$rc $(tail -4 "$T/out")"
grep -qF 'msr_ubvinfo -f /srv/unifi-protect/video/2023/11/14/00005E005301_0_rotating_1699990000000.ubv -p' "$T/ssh.log" \
  && ok "msr_ubvinfo reads the file of the covering recordingFiles row" || bad "msr_ubvinfo call: $(grep msr_ubvinfo "$T/ssh.log" | tail -1)"
rc=$(v export=404first ubv=inside); [ "$rc" = 1 ] && [ "$(grep -c 'FAIL .*export http=404' "$T/out")" = 2 ] && ! has "INFO" && ok "a seek point inside the window (frames were there): FAIL" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v export=404first ubv=tail); [ "$rc" = 1 ] && [ "$(grep -c 'FAIL .*export http=404' "$T/out")" = 2 ] && ok "no seek point after the window (a cut file): FAIL" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v export=404first ubv=badhdr); [ "$rc" = 1 ] && [ "$(grep -c 'FAIL .*export http=404' "$T/out")" = 2 ] && ok "seek points not adding up to the partition headers: FAIL" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v export=404first ubv=fail); [ "$rc" = 1 ] && [ "$(grep -c 'FAIL .*export http=404' "$T/out")" = 2 ] && ok "msr_ubvinfo failing: FAIL" || bad "rc=$rc $(tail -4 "$T/out")"
for fm in none two fail; do
  n0=$(grep -c msr_ubvinfo "$T/ssh.log")
  rc=$(v export=404first files=$fm); [ "$rc" = 1 ] && [ "$(grep -c 'FAIL .*export http=404' "$T/out")" = 2 ] && [ "$(grep -c msr_ubvinfo "$T/ssh.log")" = "$n0" ] \
    && ok "covering row query: $fm -> FAIL, msr_ubvinfo not run" || bad "files=$fm rc=$rc $(tail -4 "$T/out")"
done
rc=$(v export=404first -- GAP_MS=200000); [ "$rc" = 1 ] && [ "$(grep -c 'FAIL .*export http=404' "$T/out")" = 2 ] && ok "a hole not above GAP_MS: FAIL" || bad "rc=$rc $(tail -4 "$T/out")"
rc=$(v export=all404); [ "$rc" = 1 ] && has "FAIL no clip of the sample exported" && [ "$(grep -c '^  INFO .*hole' "$T/out")" = 4 ] && [ "$(grep -c '^  FAIL' "$T/out")" = 1 ] \
  && ok "every clip of the sample in a hole (4 INFO): no imported video checked is still a FAIL" || bad "rc=$rc $(tail -6 "$T/out")"
other=$(cat "$T/ssh.log" "$T/curl.log" | grep -vF 'target.invalid')
[ -s "$T/ssh.log" ] && [ -s "$T/curl.log" ] && [ -z "$other" ] && ok "every ssh / curl call addressed target.invalid (fakes)" || bad "calls elsewhere: $(echo "$other" | head -2)"

echo "RESULT pass=$pass fail=$fail"
[ "$fail" = 0 ]
