#!/usr/bin/env bash
# install/render.sh <out_dir> [--tool-dir DIR] [--home DIR] [--summary-time HH:MM] [--observe-time HH:MM]
#                             [--top-user USER]
# Renders this site's systemd units, the copyq-top wrapper and (with --top-user) its sudoers drop-in from the templates
# in systemd/ and install/ into <out_dir>, using the site configuration (IMPORT_SITE). Installs nothing: review the
# files, then install them as README "Install" describes.
#   --tool-dir      the tool directory the units run (default: this checkout's tool/)
#   --home          HOME for the units (ssh keys and config of the user they run as; default: $HOME)
#   --summary-time  daily summary (default 09:15), --observe-time  observation check (default 09:05)
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd); TOOL=$REPO/tool; . "$TOOL/lib-site.sh"
need IMPORT_DIR
out=${1:?usage: render.sh <out_dir> [options]}; shift
tool_dir=$TOOL; home=$HOME; summary=09:15; observe=09:05; top_user=
while [ $# -gt 0 ]; do
  case $1 in
    --tool-dir) tool_dir=$2 ;; --home) home=$2 ;; --summary-time) summary=$2 ;; --observe-time) observe=$2 ;;
    --top-user) top_user=$2 ;; *) echo "unknown option $1"; exit 64 ;;
  esac; shift 2
done
for t in "$summary" "$observe"; do [[ $t =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "bad time '$t' (HH:MM)"; exit 64; }; done
[[ $tool_dir == /* && $tool_dir != *[!A-Za-z0-9/._@+-]* ]] || { echo "bad --tool-dir"; exit 64; }
[[ $home == /* && $home != *[!A-Za-z0-9/._@+-]* ]] || { echo "bad --home"; exit 64; }
[ -z "$top_user" ] || [[ $top_user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "bad --top-user"; exit 64; }
site_file=$(readlink -f "$SITE_FILE")
[[ $site_file == /* && $site_file != *[!A-Za-z0-9/._@+-]* ]] || { echo "bad site file path '$site_file'"; exit 64; }
# the sudoers drop-in lets that user run the wrapper as root without a password: what it executes (the tool path as
# written and the whole tool tree, symlinks followed hop by hop) and what root then reads and shows (the site file;
# IMPORT_DIR: <slug>.list, copyq/ state + runner.log; the camera id map, or the directory it would be created in) must
# be root-only (install/rootcheck.py: owner, mode, access + default ACLs)
top_user_ok() {
  local -a a=(tree "$tool_dir" path "$site_file" path "$IMPORT_DIR")
  [ -e "$IMPORT_DIR/copyq" ] && a+=(tree "$IMPORT_DIR/copyq")
  if [ -n "${IDMAP:-}" ]; then a+=(path "$(dirname "$IDMAP")"); [ -e "$IDMAP" ] && a+=(path "$IDMAP"); fi
  python3 -I "$REPO/install/rootcheck.py" "${a[@]}"
}
if [ -n "$top_user" ]; then
  top_user_ok || { echo "REFUSED: --top-user needs root-only paths for everything the wrapper runs or reads as root"; exit 1; }
fi
mkdir -p -m 700 "$out"
render() {   # template -> output file
  sed -e "s#@TOOL_DIR@#$tool_dir#g" -e "s#@SITE_FILE@#$site_file#g" -e "s#@HOME@#$home#g" \
      -e "s#@NAME_PREFIX@#$NAME_PREFIX#g" -e "s#@IMPORT_DIR@#$IMPORT_DIR#g" -e "s#@SOURCE_NAME@#$SOURCE_NAME#g" \
      -e "s#@TARGET_NAME@#$TARGET_NAME#g" -e "s#@SUMMARY_TIME@#$summary#g" -e "s#@OBSERVE_TIME@#$observe#g" \
      -e "s#@TOP_USER@#$top_user#g" "$1" > "$2"
  ! grep -q '@[A-Z_]*@' "$2" || { echo "unrendered placeholder in $2"; exit 1; }
  echo "rendered $2"
}
for u in copy.service copy-summary.service copy-summary.timer observe.service observe.timer; do
  render "$REPO/systemd/$u.in" "$out/$NAME_PREFIX-$u"
done
render "$REPO/install/copyq-top.sh.in" "$out/copyq-top"; chmod 755 "$out/copyq-top"
if [ -n "$top_user" ]; then render "$REPO/install/copyq-top.sudoers.in" "$out/copyq-top.sudoers"; chmod 440 "$out/copyq-top.sudoers"; fi
