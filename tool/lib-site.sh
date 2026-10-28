# lib-site.sh --- sourced by the bash tools (after setting TOOL): loads the site configuration into shell variables
# through siteconf.py (one parser, one set of defaults and checks for every tool), and provides need().
_site=$(python3 "$TOOL/siteconf.py" shell) || exit 64
eval "$_site"; unset _site
# need KEY... --- abort unless every named site key is configured
need() {
  local k
  for k in "$@"; do
    [ -n "${!k:-}" ] || { echo "site configuration: $k is not set in $SITE_FILE" >&2; exit 64; }
  done
}
