#!/bin/sh
# set-model.sh <repo-root> <engine:model-id>
#
# Writes the per-project model selection that bin/pipeline.sh reads at the start
# of every phase (<repo>/logs/pipeline/MODEL). Invoked by the menu bar's Model
# submenu in bin/statusbar.30s.sh; safe to run by hand.
#
# The value picks which CLI the daemon executes, so it is validated against
# the checkout's models.conf and never taken on trust.

set -u

INFRA=${WW_PIPELINE_HOME:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
MODELS_CONF="$INFRA/models.conf"

[ $# -eq 2 ] || {
  echo "usage: set-model.sh <repo-root> <engine:model-id>" >&2
  exit 64
}
root=$1
sel=$2

if [ ! -d "$root/.git" ] && [ ! -f "$root/.git" ]; then
  echo "set-model.sh: first argument must be a git repo root (got: '$root')" >&2
  exit 64
fi
root=$(cd "$root" && pwd)

[ -f "$MODELS_CONF" ] || {
  echo "set-model.sh: missing model list $MODELS_CONF" >&2
  exit 66
}

known=$(awk -v want="$sel" '
  /^[[:space:]]*(#|$)/ { next }
  $1 == want { print "yes"; exit }
' "$MODELS_CONF")
[ "$known" = "yes" ] || {
  echo "set-model.sh: '$sel' is not listed in $MODELS_CONF" >&2
  exit 65
}

pipe="$root/logs/pipeline"
mkdir -p "$pipe" || exit 73
printf '%s\n' "$sel" > "$pipe/MODEL.tmp" && mv "$pipe/MODEL.tmp" "$pipe/MODEL" || {
  echo "set-model.sh: could not write $pipe/MODEL" >&2
  exit 73
}

# The switch lands on the next phase; a phase already running finishes on the
# engine it started with.
echo "$(basename "$root"): model set to $sel (takes effect on the next phase)"
