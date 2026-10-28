#!/usr/bin/env bash
# install/test-render.sh --- offline tests of render.sh's --top-user guard. The sudoers drop-in lets that user run the
# copyq-top wrapper as root, so everything the wrapper executes must be root-only: the tool path as given (every
# component, symlinks included), everything under the tool directory, and the site file. Builds a sandbox under /run
# (root-owned parents; /tmp is world-writable and therefore refused itself) with a copy of tool/ and a throw-away site
# configuration whose hosts are *.invalid. Needs root, an unprivileged account (nobody) and, for the ACL cases,
# setfacl on a filesystem with ACLs. Touches nothing outside the sandbox and renders into it; installs nothing.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
[ "$(id -u)" = 0 ] || { echo "needs root (it creates root-owned and nobody-owned files)"; exit 64; }
NB=$(id -u nobody) || { echo "needs an account named nobody"; exit 64; }
S=$(mktemp -d -p /run test-render.XXXXXX); trap 'rm -rf "$S"' EXIT
pass=0; fail=0; skip=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
skp() { echo "  SKIP $*"; skip=$((skip+1)); }
has() { grep -qF -- "$1" "$S/out"; }
mkdir -p "$S/opt" "$S/import"; cp -a "$REPO/tool" "$S/opt/tool"; chown -R root:root "$S/opt/tool"; chmod -R go-w "$S/opt/tool"
printf 'NAME_PREFIX=footage-heist\nIMPORT_DIR=%s/import\nSOURCE_SSH=source.invalid\nTARGET_SSH=target.invalid\nTARGET_STAGING=/volume/test/import-staging\nTARGET_WORKDIR=/var/lib/footage-heist\nSOURCE_WORKDIR=/var/lib/footage-heist\n' "$S" > "$S/site.env"
chmod 600 "$S/site.env"
mkdir "$S/home-u"; chown "$NB" "$S/home-u"                  # a directory an unprivileged user owns
# r <render.sh args...>: rc echoed, output in $S/out, rendered files in $S/r. SITE overrides the site file, BENV sets
# BASH_ENV (fakes, R9)
r() {
  rm -rf "$S/r"
  env -i "PATH=$PATH" "HOME=/root" "IMPORT_SITE=${SITE:-$S/site.env}" ${BENV:+"BASH_ENV=$BENV"} \
    bash "$REPO/install/render.sh" "$S/r" "$@" > "$S/out" 2>&1
  echo $?
}
refused() { [ "$1" = 1 ] && has "REFUSED" && [ ! -e "$S/r/copyq-top.sudoers" ]; }
acl() { setfacl "$@" 2>/dev/null; }

# preconditions: the sandbox chain itself is root-only, and the copied tool tree is clean
p=$S; clean=1; while :; do [ "$(stat -c %u "$p")" = 0 ] && [ $(( 0$(stat -c %a "$p") & 022 )) = 0 ] || clean=0; [ "$p" = / ] && break; p=$(dirname "$p"); done
[ "$clean" = 1 ] && [ -z "$(find "$S/opt/tool" ! -type l \( ! -user root -o -perm /022 \) -print -quit)" ] \
  && ok "sandbox $S: root-only parents, clean tool copy" || { bad "sandbox not root-only --- every case below would refuse"; echo "RESULT pass=$pass fail=$fail skip=$skip"; exit 1; }

echo "R1 a root-only tool directory renders the wrapper (path as given) and the drop-in"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
[ "$rc" = 0 ] && grep -qF "exec python3 -E -s $S/opt/tool/copyq-top.py " "$S/r/copyq-top" && grep -q '^nobody ALL=(root) NOPASSWD: /usr/local/bin/copyq-top ""' "$S/r/copyq-top.sudoers" \
  && ok "rc 0, wrapper + drop-in" || bad "rc=$rc $(cat "$S/out")"

echo "R2 a symlink in a root-only directory is fine, and the wrapper keeps the symlink path"
ln -s "$S/opt/tool" "$S/link-tool"
rc=$(r --tool-dir "$S/link-tool" --top-user nobody)
[ "$rc" = 0 ] && grep -qF "exec python3 -E -s $S/link-tool/copyq-top.py " "$S/r/copyq-top" && ok "rc 0, wrapper runs $S/link-tool" || bad "rc=$rc $(cat "$S/out")"

echo "R3 a symlink in a user-owned directory refuses, though its target is root-only (the user can re-point it later)"
ln -s "$S/opt/tool" "$S/home-u/tool"
rc=$(r --tool-dir "$S/home-u/tool" --top-user nobody)
refused "$rc" && has "$S/home-u is not owned by root" && ok "refused, names $S/home-u" || bad "rc=$rc $(cat "$S/out")"

echo "R4 anything under the tool directory that someone else can write refuses"
mkdir -p "$S/opt/tool/__pycache__"; chown "$NB" "$S/opt/tool/__pycache__"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
refused "$rc" && has "__pycache__ is not owned by root" && ok "__pycache__ owned by another user" || bad "rc=$rc $(cat "$S/out")"
chown root "$S/opt/tool/__pycache__"
chmod g+w "$S/opt/tool/siteconf.py"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
refused "$rc" && has "siteconf.py is writable by group or others" && ok "a group-writable module" || bad "rc=$rc $(cat "$S/out")"
chmod g-w "$S/opt/tool/siteconf.py"
mkdir "$S/opt/tool/sub"; touch "$S/opt/tool/sub/x"; chmod o+w "$S/opt/tool/sub/x"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
refused "$rc" && has "sub/x is writable by group or others" && ok "a world-writable file in a subdirectory" || bad "rc=$rc $(cat "$S/out")"
rm -rf "$S/opt/tool/sub"

echo "R5 a symlink inside the tool directory must lead to a root-only target"
touch "$S/home-u/evil.py"; chown "$NB" "$S/home-u/evil.py"; ln -s "$S/home-u/evil.py" "$S/opt/tool/extra.py"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
refused "$rc" && has "is not owned by root" && ok "link to a user-owned file refused" || bad "rc=$rc $(cat "$S/out")"
rm "$S/opt/tool/extra.py"; ln -s "$S/opt/tool/siteconf.py" "$S/opt/tool/alias.py"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
[ "$rc" = 0 ] && ok "link to a root-only file accepted" || bad "rc=$rc $(cat "$S/out")"
rm "$S/opt/tool/alias.py"

echo "R6 write ACLs refuse: a named user on a module (also with a masked-off entry), a default entry, a named user on a parent"
if acl -m "u:nobody:rw" "$S/opt/tool/gen.py"; then
  rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)      # the ACL mask shows as group bits: the mode check sees it
  refused "$rc" && has "gen.py" && ok "u:nobody:rw on gen.py" || bad "rc=$rc $(cat "$S/out")"
  acl -m "m::r" "$S/opt/tool/gen.py"                       # mode back to no group write: only the ACL check can see it
  [ $(( 0$(stat -c %a "$S/opt/tool/gen.py") & 022 )) = 0 ] || bad "mask did not clear the group write bit (test setup)"
  rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
  refused "$rc" && has "gen.py: an ACL entry grants write access" && ok "masked-off u:nobody:rw entry (a later chmod g+w would make it effective)" || bad "rc=$rc $(cat "$S/out")"
  acl -b "$S/opt/tool/gen.py"
  acl -d -m "u:nobody:rwx" "$S/opt/tool"
  rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
  refused "$rc" && has "a default ACL entry grants write access" && ok "default:user:nobody:rwx on the tool directory (future files would be writable)" || bad "rc=$rc $(cat "$S/out")"
  acl -k "$S/opt/tool"
  acl -m "u:nobody:rwx" "$S/opt"
  rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
  refused "$rc" && has "$S/opt" && ok "u:nobody:rwx on a parent" || bad "rc=$rc $(cat "$S/out")"
  acl -b "$S/opt"
  rc=$(r --tool-dir "$S/opt/tool" --top-user nobody); [ "$rc" = 0 ] && ok "ACLs removed: rc 0 again" || bad "cleanup: rc=$rc $(cat "$S/out")"
else
  skp "setfacl does not work on $S (no ACL support)"
fi

echo "R7 the site file: group-writable, or in a user-owned directory, refuses"
chmod g+w "$S/site.env"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
refused "$rc" && has "site.env is writable by group or others" && ok "group-writable site file" || bad "rc=$rc $(cat "$S/out")"
chmod g-w "$S/site.env"
cp -p "$S/site.env" "$S/home-u/site.env"
rc=$(SITE=$S/home-u/site.env r --tool-dir "$S/opt/tool" --top-user nobody)
refused "$rc" && has "$S/home-u is not owned by root" && ok "site file in a user-owned directory" || bad "rc=$rc $(cat "$S/out")"

echo "R8 a tool directory under /tmp refuses (world-writable parent)"
X=$(mktemp -d /tmp/test-render.XXXXXX); cp -a "$S/opt/tool" "$X/tool"
rc=$(r --tool-dir "$X/tool" --top-user nobody)
refused "$rc" && has "/tmp is writable by group or others" && ok "refused, names /tmp" || bad "rc=$rc $(cat "$S/out")"
rm -rf "$X"

echo "R9 the checker fails closed when it cannot read an ACL (patched getxattr); a filesystem without ACLs is fine"
for e in EACCES EIO ENOTSUP; do
  out=$(python3 -I -c "
import errno, importlib.util, os, sys
s = importlib.util.spec_from_file_location('rc', '$REPO/install/rootcheck.py'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
def boom(p, name, follow_symlinks=True): raise OSError(errno.$e, os.strerror(errno.$e))
m.os.getxattr = boom
sys.exit(m.main(['tree', '$S/opt/tool']))" 2>&1); rc=$?
  case $e in
    ENOTSUP) [ $rc = 0 ] && ok "ENOTSUP (no ACLs on this filesystem): accepted" || bad "ENOTSUP: rc=$rc $out" ;;
    *) [ $rc = 1 ] && [[ $out == *"cannot read its ACL"* ]] && ok "$e reading an ACL: refused" || bad "$e: rc=$rc $out" ;;
  esac
done

echo "R10 without --top-user nothing is checked and no drop-in is written (the units run as whoever installs them)"
rc=$(r --tool-dir "$S/home-u/tool")
[ "$rc" = 0 ] && [ -e "$S/r/copyq-top" ] && [ ! -e "$S/r/copyq-top.sudoers" ] && ok "rc 0, wrapper only" || bad "rc=$rc $(cat "$S/out")"

echo "R11 what root reads and shows must be root-only too: IMPORT_DIR, its copyq/ dir, the camera id map (or its directory)"
chown "$NB" "$S/import"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
refused "$rc" && has "$S/import is not owned by root" && ok "IMPORT_DIR owned by another user" || bad "rc=$rc $(cat "$S/out")"
chown root "$S/import"; mkdir "$S/import/copyq"; chmod 777 "$S/import/copyq"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
refused "$rc" && has "$S/import/copyq is writable by group or others" && ok "a world-writable copyq/ dir" || bad "rc=$rc $(cat "$S/out")"
chmod 700 "$S/import/copyq"
cp -p "$S/site.env" "$S/site-idmap.env"; echo "IDMAP=$S/home-u/idmap.tsv" >> "$S/site-idmap.env"
rc=$(SITE=$S/site-idmap.env r --tool-dir "$S/opt/tool" --top-user nobody)
refused "$rc" && has "$S/home-u is not owned by root" && ok "IDMAP (not created yet) in a user-owned directory" || bad "rc=$rc $(cat "$S/out")"
sed -i "s#^IDMAP=.*#IDMAP=$S/import/idmap.tsv#" "$S/site-idmap.env"; touch "$S/import/idmap.tsv"
rc=$(SITE=$S/site-idmap.env r --tool-dir "$S/opt/tool" --top-user nobody)
[ "$rc" = 0 ] && ok "IDMAP inside the root-only IMPORT_DIR: rc 0" || bad "rc=$rc $(cat "$S/out")"

echo "R12 the wrapper pins PATH before its first command (as root even id comes from PATH), runs python3 -E -s"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
w=$S/r/copyq-top
first=$(grep -vE '^[[:space:]]*(#|$)' "$w" | head -1)
[ "$rc" = 0 ] && [ "${first%%;*}" = 'PATH=/usr/sbin:/usr/bin:/sbin:/bin' ] \
  && grep -qxF "IMPORT_SITE=$S/site.env exec python3 -E -s $S/opt/tool/copyq-top.py \"\$@\"" "$w" \
  && sh -n "$w" && ok "PATH is the first command, python3 -E -s, sh -n clean" || bad "rc=$rc first='$first' $(cat "$w")"

echo "R13 a link chain through a user-owned directory refuses, although the link and the target are root-owned"
mkdir -p "$S/opt2"; ln -s "$S/home-u/link" "$S/opt2/tool-link"; ln -s "$S/opt/tool" "$S/home-u/link"
rc=$(r --tool-dir "$S/opt2/tool-link" --top-user nobody)
refused "$rc" && has "$S/home-u is not owned by root" && ok "root link -> user dir link -> root target: refused" || bad "rc=$rc $(cat "$S/out")"
rm "$S/home-u/link"; mkdir -p "$S/opt3"; ln -s "$S/opt/tool" "$S/opt3/hop2"; ln -s "$S/opt3/hop2" "$S/opt2/hop1"
rc=$(r --tool-dir "$S/opt2/hop1" --top-user nobody)
[ "$rc" = 0 ] && grep -qF "exec python3 -E -s $S/opt2/hop1/copyq-top.py " "$S/r/copyq-top" && ok "two root-only hops: accepted, wrapper keeps the path as given" || bad "rc=$rc $(cat "$S/out")"

echo "R14 a linked directory inside the tool tree is walked too"
mkdir -p "$S/cache"; touch "$S/cache/copyq.cpython-312.pyc"; chown "$NB" "$S/cache/copyq.cpython-312.pyc"
mv "$S/opt/tool/__pycache__" "$S/pyc.keep"; ln -s "$S/cache" "$S/opt/tool/__pycache__"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
refused "$rc" && has "$S/cache/copyq.cpython-312.pyc is not owned by root" && ok "__pycache__ -> root dir with a user-owned .pyc: refused" || bad "rc=$rc $(cat "$S/out")"
chown root "$S/cache/copyq.cpython-312.pyc"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
[ "$rc" = 0 ] && ok "the same link with root-only contents: accepted" || bad "rc=$rc $(cat "$S/out")"
rm "$S/opt/tool/__pycache__"; mv "$S/pyc.keep" "$S/opt/tool/__pycache__"

echo "R17 a symlinked module: the directory its target is in is walked too (Python loads a script's siblings and __pycache__ from its real directory)"
mkdir -p "$S/rel"; cp -a "$S/opt/tool/copyq-top.py" "$S/opt/tool/copyq.py" "$S/rel/"; chown -R root:root "$S/rel"; chmod -R go-w "$S/rel"
touch "$S/rel/siteconf.py"; chown "$NB" "$S/rel/siteconf.py"
mv "$S/opt/tool/copyq-top.py" "$S/top.keep"; ln -s "$S/rel/copyq-top.py" "$S/opt/tool/copyq-top.py"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
refused "$rc" && has "$S/rel/siteconf.py is not owned by root" && ok "copyq-top.py -> a root-only file next to a user-owned siteconf.py: refused" || bad "rc=$rc $(cat "$S/out")"
chown root "$S/rel/siteconf.py"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
[ "$rc" = 0 ] && ok "the same link with a root-only target directory: accepted" || bad "rc=$rc $(cat "$S/out")"
rm "$S/opt/tool/copyq-top.py"; mv "$S/top.keep" "$S/opt/tool/copyq-top.py"

echo "R15 default ACLs of the owning group / others that grant write refuse (later files would be writable)"
if acl -d -m "g::rwx" "$S/opt/tool"; then
  rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
  refused "$rc" && has "$S/opt/tool: a default ACL entry grants write access" && ok "default:group::rwx" || bad "rc=$rc $(cat "$S/out")"
  acl -k "$S/opt/tool"; acl -d -m "u::rwx,g::r-x,o::rwx" "$S/opt/tool"
  rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
  refused "$rc" && has "a default ACL entry grants write access" && ok "default:other::rwx" || bad "rc=$rc $(cat "$S/out")"
  acl -k "$S/opt/tool"
else
  skp "setfacl does not work on $S (no ACL support)"
fi

echo "R16 a symlink loop inside the tool tree refuses (bounded hops, no hang)"
ln -s "$S/opt/tool/loop-b" "$S/opt/tool/loop-a"; ln -s "$S/opt/tool/loop-a" "$S/opt/tool/loop-b"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody)
refused "$rc" && has "symlinks (a loop?)" && ok "loop: refused" || bad "rc=$rc $(cat "$S/out")"
rm "$S/opt/tool/loop-a" "$S/opt/tool/loop-b"
rc=$(r --tool-dir "$S/opt/tool" --top-user nobody); [ "$rc" = 0 ] && ok "cleanup: rc 0 again" || bad "cleanup: rc=$rc $(cat "$S/out")"

echo "RESULT pass=$pass fail=$fail skip=$skip"
[ "$fail" = 0 ]
