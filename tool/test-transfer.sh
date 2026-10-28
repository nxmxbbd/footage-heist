#!/usr/bin/env bash
# test-transfer.sh --- local regression for the copy channel (ubv-recv.py + ubv-push.py), no console needed.
#   R0:    receiver without --base refuses everything; --base on the command line (the forced-command form) works
#   R1-R8: receiver with RECV_BASE (exact / exists / short / long / write error / 256 MiB / page cache dropped / log)
#   P0-P8: sender in a private mount namespace (temp dir over /srv; fake `ssh` = local receiver; PUSH_HOME = temp):
#          no PUSH_DEST / good / rerun skip / DB size mismatch / EXISTS / REJECT (no hang) / RATE_MBPS honoured
#   T1-T7: the same sender with PUSH_MODE=tcp (+ the PUSH_LEDGER / PUSH_TEST_DAY test knobs)
#   R9-R13: receiver tput gates driven directly: wrong token, wrong peer, sender gone mid-file, page cache
#   R14:   receiver on a fresh base without state/ creates it;  P9: a read error on the source file ends that file with
#          an error instead of hanging the push;  R15: a --base that does not exist refuses and creates nothing
#   V1:    copy runner's verify cleanup (copyq.py kill_verify, its remote snippet run locally): only the sha256sum
#          whose argument is exactly the batch's sha file is stopped
# Needs root (unshare -m). Exit 0 = all PASS.
set -uo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd)
X=$(mktemp -d /tmp/test-transfer.XXXX); trap 'rm -rf "$X"' EXIT
pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

cp "$TOOL/ubv-recv.py" "$TOOL/ubv-push.py" "$X/"
B=$X/recvbase; mkdir -p $B/files $B/state
MAC=00005E005301                  # RFC 7042 documentation MAC
NAME=${MAC}_0_rotating_1781600733195.ubv; NAME2=${MAC}_0_rotating_1781600733196.ubv
head -c 50000000 /dev/urandom > $X/src.bin; S=50000000
recv() { RECV_BASE=$B SSH_ORIGINAL_COMMAND="$1" python3 $X/ubv-recv.py; }

echo "== receiver"
out=$(SSH_ORIGINAL_COMMAND="put srv 2026/06/15/$NAME 5" python3 $X/ubv-recv.py < /dev/null 2>/dev/null; echo "rc=$?")
chk "$(echo $out)" "REJECT rc=2" "R0 no --base and no RECV_BASE -> REJECT"
B0=$X/recvbase0; mkdir -p $B0/files $B0/state
out=$(printf 'hello' | SSH_ORIGINAL_COMMAND="put srv 2026/06/15/$NAME 5" python3 $X/ubv-recv.py --base $B0)
chk "$out" "OK 5 $(printf 'hello' | sha256sum | cut -c1-64)" "R0 --base on the command line (forced-command form) -> OK"
out=$(recv "put srv 2026/06/16/$NAME $S" < $X/src.bin)
chk "$out" "OK $S $(sha256sum $X/src.bin | cut -c1-64)" "R1 exact size -> OK + sha256"
cmp -s $X/src.bin $B/files/srv/2026/06/16/$NAME && ok "R1 content identical" || bad "R1 content differs"
chk "$(recv "put srv 2026/06/16/$NAME $S" < $X/src.bin)" "EXISTS" "R2 existing target -> EXISTS"
chk "$(head -c 1000 $X/src.bin | recv "put srv 2026/06/17/$NAME2 $S")" "SIZE 1000" "R3 short input -> SIZE"
chk "$( (cat $X/src.bin; echo extra) | recv "put srv 2026/06/17/$NAME2 $S")" "SIZE 50000006" "R4 long input -> SIZE"
out=$(bash -c "ulimit -f 1024; RECV_BASE=$B SSH_ORIGINAL_COMMAND='put srv 2026/06/17/$NAME2 $S' python3 $X/ubv-recv.py < $X/src.bin"; echo "rc=$?")
chk "$(echo $out)" "WERR rc=5" "R5 write error -> WERR rc 5"
chk "$(ls $B/files/srv/2026/06/17 2>/dev/null | wc -l)" "0" "R3-R5 no file or .part left behind"
G=268435456
out=$(head -c $G /dev/zero | recv "put srv 2026/06/18/$NAME2 $G" | cut -d' ' -f1-2)
chk "$out" "OK $G" "R6 256 MiB through the pipeline"
cached=$(python3 - "$B/files/srv/2026/06/18/$NAME2" << 'EOF'
import ctypes, mmap, os, sys            # bytes of the file resident in the page cache (mincore(2))
fd = os.open(sys.argv[1], os.O_RDONLY); size = os.fstat(fd).st_size; ps = mmap.PAGESIZE
libc = ctypes.CDLL(None, use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
addr = libc.mmap(None, size, mmap.PROT_READ, mmap.MAP_SHARED, fd, 0)
vec = (ctypes.c_ubyte * ((size + ps - 1) // ps))()
libc.mincore(ctypes.c_void_p(addr), ctypes.c_size_t(size), vec)
print(sum(v & 1 for v in vec) * ps)
EOF
)
[ -n "$cached" ] && [ "$cached" -lt $((G / 8)) ] && ok "R7 page cache after put: $cached B of $G (dropped)" || bad "R7 page cache after put: '$cached' B of $G"
chk "$(python3 -c "import json; print(' '.join(json.loads(l)['result'] for l in open('$B/state/recv.log')))")" \
    "ok exists size-mismatch size-mismatch write-error ok" "R8 recv.log results"

echo "== sender (private mount namespace)"
D=$X/srv/unifi-protect/video/2026/06/16; mkdir -p $D $X/bin $X/pushhome $X/pushhome2; for i in 2 3 4 5 6; do mkdir -p $X/recvbase$i/files $X/recvbase$i/state; done
head -c 30000000 /dev/urandom > $D/$NAME; head -c 20000000 /dev/urandom > $D/$NAME2; head -c 5000000 /dev/urandom > $D/badname.ubv
printf '#!/bin/bash\nexport SSH_ORIGINAL_COMMAND="${@: -1}" SSH_CONNECTION="127.0.0.1 40000 127.0.0.1 22"\nexec python3 %s/ubv-recv.py\n' "$X" > $X/bin/ssh; chmod +x $X/bin/ssh
F=/srv/unifi-protect/video/2026/06/16
printf "id1|$F|$NAME|30000000\nid2|$F|$NAME2|20000000\n" > $X/list.good
printf "id3|$F|$NAME|29999999\n" > $X/list.sizebad
printf "id4|$F|$NAME|30000000\n" > $X/list.exists
printf "id5|$F|badname.ubv|5000000\n" > $X/list.reject
printf "id6|$F|$NAME2|20000000\n" > $X/list.rate
res=$(timeout 180 unshare -m --propagation private bash -c "
  mount --bind $X/srv /srv || exit 9
  export PATH=$X/bin:\$PATH RECV_BASE=$X/recvbase2 RATE_MBPS=1000 PUSH_HOME=$X/pushhome; P=$X/ubv-push.py
  echo \"P0 \$(python3 \$P $X/list.good) rc=\$?\"
  export PUSH_DEST=root@192.0.2.10
  echo \"P1 \$(python3 \$P $X/list.good) rc=\$?\"
  echo \"P2 \$(python3 \$P $X/list.good) rc=\$?\"
  echo \"P3 \$(python3 \$P $X/list.sizebad) rc=\$?\"
  echo \"P4 \$(python3 \$P $X/list.exists) rc=\$?\"
  echo \"P5 \$(timeout 30 python3 \$P $X/list.reject) rc=\$?\"
  t0=\$(date +%s%N); r=\$(RECV_BASE=$X/recvbase3 RATE_MBPS=10 python3 \$P $X/list.rate); echo \"P6 \$r rc=\$? ms=\$(( (\$(date +%s%N) - t0) / 1000000 ))\"
  python3 -c \"import json; print('LEDGER', ' '.join(r['id'] + ':' + r['result'] for r in map(json.loads, open('$X/pushhome/ledger.jsonl'))))\"
")
echo "$res" | sed 's/^/    /'
g() { echo "$res" | grep "^$1 " | sed "s/^$1 *//"; }
chk "$(g P0)" "PUSH_DEST must be the target as user@host (got '') rc=64" "P0 no PUSH_DEST -> refused"
chk "$(g P1)" "DONE 50000000 rc=0" "P1 two files pushed"
cmp -s $D/$NAME $X/recvbase2/files/srv/2026/06/16/$NAME && cmp -s $D/$NAME2 $X/recvbase2/files/srv/2026/06/16/$NAME2 \
  && ok "P1 received files identical" || bad "P1 received files differ"
chk "$(g P2)" "DONE 0 rc=0" "P2 rerun skips ids already ok"
chk "$(g P3)" "rc=1" "P3 DB size mismatch -> stop"
chk "$(g P4)" "rc=1" "P4 EXISTS on the receiver -> stop"
chk "$(g P5)" "rc=1" "P5 REJECT -> stop, no hang"
ms=$(g P6 | sed 's/.*ms=//')
[ "$(g P6 | cut -d' ' -f1-3)" = "DONE 20000000 rc=0" ] && [ "$ms" -ge 1800 ] && ok "P6 RATE_MBPS=10: 20 MB in ${ms} ms" || bad "P6 rate limit: $(g P6)"
chk "$(g LEDGER)" "id1:ok id2:ok id3:fail id4:fail id5:fail id6:ok" "P7 ledger results"
[ -f $X/pushhome/ledger.jsonl ] && [ ! -e $X/ledger.jsonl ] && ok "P8 ledger in PUSH_HOME, nothing next to the script" || bad "P8 ledger location wrong"


echo "== sender, PUSH_MODE=tcp (private mount namespace)"
printf "t1|$F|$NAME|30000000\nt2|$F|$NAME2|20000000\n" > $X/list.tgood
printf "t3|$F|$NAME|30000000\n" > $X/list.texists
printf "t4|$F|$NAME2|20000000\n" > $X/list.trate
printf "t5|$F|$NAME2|20000000\n" > $X/list.tday
res=$(timeout 180 unshare -m --propagation private bash -c "
  mount --bind $X/srv /srv || exit 9
  export PATH=$X/bin:\$PATH RECV_BASE=$X/recvbase4 RATE_MBPS=1000 PUSH_MODE=tcp PUSH_HOME=$X/pushhome2 PUSH_LEDGER=$X/pushhome2/test-ledger.jsonl PUSH_DEST=root@192.0.2.10
  P=$X/ubv-push.py
  echo \"T1 \$(python3 \$P $X/list.tgood) rc=\$?\"
  echo \"T2 \$(python3 \$P $X/list.tgood) rc=\$?\"
  t0=\$(date +%s%N); r=\$(timeout 60 python3 \$P $X/list.texists); echo \"T3 \$r rc=\$? ms=\$(( (\$(date +%s%N) - t0) / 1000000 ))\"
  t0=\$(date +%s%N); r=\$(RECV_BASE=$X/recvbase5 RATE_MBPS=10 python3 \$P $X/list.trate); echo \"T4 \$r rc=\$? ms=\$(( (\$(date +%s%N) - t0) / 1000000 ))\"
  echo \"T5 \$(RECV_BASE=$X/recvbase6 PUSH_TEST_DAY=1970/01/02 python3 \$P $X/list.tday) rc=\$?\"
  echo \"T6 \$(PUSH_TEST_DAY=2026/01/01 python3 \$P $X/list.tday) rc=\$?\"
  python3 -c \"import json; print('TLEDGER', ' '.join(r['id'] + ':' + r['result'] + ':' + r.get('mode','') for r in map(json.loads, open('$X/pushhome2/test-ledger.jsonl'))))\"
  echo \"TPROD \$(ls $X/pushhome2/ledger.jsonl 2>/dev/null | wc -l)\"
")
echo "$res" | sed 's/^/    /'
chk "$(g T1)" "DONE 50000000 rc=0" "T1 tcp: two files pushed"
cmp -s $D/$NAME $X/recvbase4/files/srv/2026/06/16/$NAME && cmp -s $D/$NAME2 $X/recvbase4/files/srv/2026/06/16/$NAME2 \
  && ok "T1 tcp: received files identical" || bad "T1 tcp: received files differ"
chk "$(g T2)" "DONE 0 rc=0" "T2 tcp: rerun skips ids already ok"
ms=$(g T3 | sed 's/.*ms=//'); [ "$(g T3 | cut -d' ' -f1)" = "rc=1" ] && [ "$ms" -lt 10000 ] && ok "T3 tcp: EXISTS -> stop before any port, ${ms} ms" || bad "T3 tcp: EXISTS: $(g T3)"
ms=$(g T4 | sed 's/.*ms=//'); [ "$(g T4 | cut -d' ' -f1-3)" = "DONE 20000000 rc=0" ] && [ "$ms" -ge 1800 ] && ok "T4 tcp: RATE_MBPS=10: 20 MB in ${ms} ms" || bad "T4 tcp rate: $(g T4)"
chk "$(g T5)" "DONE 20000000 rc=0" "T5 PUSH_TEST_DAY=1970/01/02 pushes"
[ -f $X/recvbase6/files/srv/1970/01/02/$NAME2 ] && ok "T5 file landed under 1970/01/02" || bad "T5 file not under 1970/01/02"
chk "$(g T6)" "PUSH_TEST_DAY must look like 1970/MM/DD (got '2026/01/01') rc=64" "T6 test day outside 1970/ refused"
chk "$(g TLEDGER)" "t1:ok:tcp t2:ok:tcp t3:fail:tcp t4:ok:tcp t5:ok:tcp" "T7 PUSH_LEDGER used, mode recorded"
chk "$(g TPROD)" "0" "T7 production ledger path untouched"

echo "== receiver tput gates (direct)"
cat > $X/tclient.py << 'EOF'
# tclient.py <token-mode good|bad-then-good|none> <bytes to send> <total size> --- reads LISTEN from the receiver's stdout
import socket, subprocess, sys, os, time
mode, nsend, size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
env = dict(os.environ)
p = subprocess.Popen(['python3', env['RECV']], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, env=env)
first = p.stdout.readline().decode().split()
if first[:1] == ['LISTEN']:
    ip, port, tok = first[1], int(first[2]), bytes.fromhex(first[3])
    if mode == 'bad-then-good':
        with socket.create_connection((ip, port)) as s:
            s.sendall(os.urandom(16)); time.sleep(0.3)
    if mode != 'none':
        s = socket.create_connection((ip, port), timeout=10)
        try:
            s.sendall(tok)
            left = nsend
            while left > 0:
                k = min(left, 1 << 20); s.sendall(b'\0' * k); left -= k
            s.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        rest = p.stdout.read().decode().strip(); s.close()
    else:
        rest = p.stdout.read().decode().strip()
    print(rest.split()[0] if rest else '?', 'rc=%d' % p.wait())
else:
    print(' '.join(first), 'rc=%d' % p.wait())
EOF
B7=$X/recvbase7; mkdir -p $B7/files $B7/state
tc() { RECV_BASE=$B7 RECV=$X/ubv-recv.py SSH_ORIGINAL_COMMAND="$1" SSH_CONNECTION="$2" RECV_ACCEPT_TIMEOUT=3 python3 $X/tclient.py $3 $4 $5; }
chk "$(tc "tput srv 2026/07/01/$NAME 1000000" "127.0.0.1 1 127.0.0.1 22" bad-then-good 1000000 1000000)" "OK rc=0" "R9 wrong token rejected, right token then accepted"
chk "$(python3 -c "import json; print(' '.join(json.loads(l)['result'] for l in open('$B7/state/recv.log')))")" "conn-reject ok" "R9 recv.log: conn-reject then ok"
t0=$(date +%s%N); out=$(tc "tput srv 2026/07/02/$NAME 1000000" "127.0.0.2 1 127.0.0.1 22" good 1000000 1000000); ms=$(( ($(date +%s%N) - t0) / 1000000 ))
chk "$out" "NOCONN rc=6" "R10 connection from another IP than the ssh client -> NOCONN (${ms} ms)"
[ ! -e $B7/files/srv/2026/07/02/$NAME ] && ok "R10 nothing written" || bad "R10 file written"
chk "$(tc "tput srv 2026/07/03/$NAME 1000000" "127.0.0.1 1 127.0.0.1 22" good 400000 1000000)" "SIZE rc=4" "R11 sender gone mid-file -> SIZE"
chk "$(ls $B7/files/srv/2026/07/03 2>/dev/null | wc -l)" "0" "R11 no file or .part left behind"
chk "$(tc "tput srv 2026/07/04/$NAME 1000000" "" good 1000000 1000000)" "REJECT rc=2" "R12 tput without SSH_CONNECTION -> REJECT"
G2=134217728
chk "$(tc "tput srv 2026/07/05/$NAME $G2" "127.0.0.1 1 127.0.0.1 22" good $G2 $G2)" "OK rc=0" "R13 128 MiB over tput"
cached=$(python3 - "$B7/files/srv/2026/07/05/$NAME" << 'EOF'
import ctypes, mmap, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY); size = os.fstat(fd).st_size; ps = mmap.PAGESIZE
libc = ctypes.CDLL(None, use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
addr = libc.mmap(None, size, mmap.PROT_READ, mmap.MAP_SHARED, fd, 0)
vec = (ctypes.c_ubyte * ((size + ps - 1) // ps))()
libc.mincore(ctypes.c_void_p(addr), ctypes.c_size_t(size), vec)
print(sum(v & 1 for v in vec) * ps)
EOF
)
[ -n "$cached" ] && [ "$cached" -lt $((G2 / 8)) ] && ok "R13 page cache after tput: $cached B (dropped)" || bad "R13 page cache after tput: '$cached'"

echo "== fresh base, source read error"
B14=$X/recvbase14; mkdir -p $B14
out=$(printf 'hello' | RECV_BASE=$B14 SSH_ORIGINAL_COMMAND="put srv 2026/06/18/$NAME 5" python3 $X/ubv-recv.py 2>&1)
[ "$out" = "OK 5 $(printf 'hello' | sha256sum | cut -c1-64)" ] && [ -s $B14/state/recv.log ] && ok "R14 base without state/: OK, state/recv.log created" || bad "R14: '$out', log: $(ls $B14/state 2>&1)"
out=$(cd $X && PUSH_DEST=x@host.invalid timeout 20 python3 -c "
import importlib.util
s = importlib.util.spec_from_file_location('p', 'ubv-push.py'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
n, digest, err = m.stream('/proc/self/mem', lambda b: None)    # reading offset 0 of /proc/self/mem fails with EIO
print(n, err)" 2>&1); rc=$?
[ $rc = 0 ] && [[ $out == "0 read error: "* ]] && ok "P9 source read error -> the file fails ('${out#0 }'), no hang" || bad "P9 rc=$rc: $out"

echo "== receiver: a --base that does not exist"
out=$(printf 'hello' | RECV_BASE=$X/nosuch SSH_ORIGINAL_COMMAND="put srv 2026/06/18/$NAME 5" python3 $X/ubv-recv.py 2> $X/r15.err; echo "rc=$?")
[ "$(echo $out)" = "REJECT rc=2" ] && [ ! -e $X/nosuch ] && grep -q "does not exist" $X/r15.err \
  && ok "R15 missing base: REJECT rc=2, nothing created" || bad "R15: '$out' $(cat $X/r15.err) created=$(test -e $X/nosuch && echo yes || echo no)"

echo "== copy runner: verify cleanup stops only the sha256sum whose argument IS the batch's sha file"
# three real sha256sum processes blocked on FIFOs: the batch's file and two near-misses a substring / regex match takes
V=$X/wd; mkdir -p $V $X/import; vp=()
NL=$'\n'   # the fourth name has a newline inside: b1.sha256<newline>backup (one argument, not two)
for f in b1.sha256 b1.sha256.backup b1Xsha256 "b1.sha256${NL}backup"; do mkfifo "$V/$f"; sha256sum -c --quiet "$V/$f" > /dev/null 2>&1 & vp+=($!); done
printf 'NAME_PREFIX=test-transfer\nIMPORT_DIR=%s/import\nSOURCE_SSH=source.invalid\nTARGET_SSH=target.invalid\nTARGET_STAGING=/volume/test/import-staging\nSOURCE_WORKDIR=/var/lib/test-push\nTARGET_WORKDIR=%s\n' "$X" "$V" > $X/site.env
sleep 0.5
out=$(env -i PATH=/usr/bin:/bin HOME=$X IMPORT_SITE=$X/site.env timeout 30 python3 -c "
import importlib.util, subprocess
s = importlib.util.spec_from_file_location('cq', '$TOOL/copyq.py'); cq = importlib.util.module_from_spec(s); s.loader.exec_module(cq)
hosts = []
def here(host, cmd, timeout=120, input=None):    # the 'target' is this host: run copyq's remote snippet locally
    hosts.append(host); r = subprocess.run(['bash', '-c', cmd], input=input, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr
cq.ssh = here
p = subprocess.Popen(['sleep', '30'], start_new_session=True)   # stands in for verify-staged's own process group
cq.Runner.kill_verify(None, p, 'b1')
print(' '.join(hosts), 'group-stopped' if p.wait(timeout=10) == -15 else 'group-left')" 2>&1); rc=$?
sleep 0.3
alive() { kill -0 "$1" 2> /dev/null && echo alive || echo gone; }
st="$(alive ${vp[0]}) $(alive ${vp[1]}) $(alive ${vp[2]}) $(alive ${vp[3]})"
[ $rc = 0 ] && [ "$out" = "target.invalid group-stopped" ] && [ "$st" = "gone alive alive alive" ] \
  && ok "V1 process group stopped; b1.sha256 stopped; b1.sha256.backup, b1Xsha256 and b1.sha256<newline>backup untouched" || bad "V1 rc=$rc out='$out' states: $st"
kill ${vp[@]} 2> /dev/null; wait ${vp[@]} 2> /dev/null

echo "RESULT pass=$pass fail=$fail"
[ $fail -eq 0 ]
