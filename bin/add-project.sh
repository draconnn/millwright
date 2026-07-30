#!/bin/sh
# add-project.sh <repo-root> [bar-label] — stage a repo for the pipeline
# daemon: verify the shared conventions, generate its LaunchAgent plist,
# and register it in projects.conf. Prints the two manual steps that remain
# (pausing the repo's Codex app automations is deliberately manual).
set -eu

infra=$(cd "$(dirname "$0")/.." && pwd)
root=${1:-}
label=${2:-}

if [ -z "$root" ] || [ ! -d "$root" ]; then
  echo "usage: add-project.sh <repo-root> [bar-label]" >&2
  exit 64
fi
root=$(cd "$root" && pwd)
project=$(basename "$root")
[ -n "$label" ] || label=$(printf '%s' "$project" | cut -c1-2)

fail=0
check() { # <path> <what>
  if [ ! -e "$root/$1" ]; then
    echo "MISSING: $1 ($2)" >&2
    fail=1
  fi
}
check .git "must be a git repo"
check tools/orchestrator-guard.sh "guard printing NOTHING TO DO / ACTION NEEDED"
check tools/worker-preflight.sh "worker lease acquisition"
check tools/worker-lock.sh "worker lease helper"
check docs/superpowers/plans "plan queue directory"
check ORCHESTRATOR-NOTES.md "orchestrator notes file"
if ! grep -qE '^logs/?$' "$root/.gitignore" 2>/dev/null; then
  echo "MISSING: .gitignore entry for logs/ (daemon state must stay untracked)" >&2
  fail=1
fi
[ "$fail" = 0 ] || { echo "not staged — fix the items above first." >&2; exit 1; }

plist="$infra/launchd/com.dracon.$project.pipeline.plist"
sed -e "s|/Users/dracon/projects/worldwright|$root|g" \
    -e "s|com.dracon.worldwright.pipeline|com.dracon.$project.pipeline|g" \
  "$infra/launchd/com.dracon.worldwright.pipeline.plist" > "$plist"
plutil -lint "$plist" >/dev/null

if ! grep -q "^$root " "$infra/projects.conf" 2>/dev/null \
   && ! grep -q "^$root\$" "$infra/projects.conf" 2>/dev/null; then
  printf '%s %s\n' "$root" "$label" >> "$infra/projects.conf"
fi

echo "staged: $project (label '$label')"
echo "  plist: $plist"
echo "  registered in $infra/projects.conf (menu bar shows it within 30s)"
echo ""
echo "The daemon must never run alongside the project's Codex app automations."
printf "Have you paused/disabled them for %s? [y/N] " "$project"
read -r answer
case $answer in
  y|Y|yes|YES)
    cp "$plist" ~/Library/LaunchAgents/
    launchctl bootstrap "gui/$(id -u)" \
      ~/Library/LaunchAgents/"com.dracon.$project.pipeline.plist"
    echo "daemon loaded — the menu bar glyph should go 🟢 or 🌙 within 30s."
    ;;
  *)
    echo "Not loading. When the automations are paused, run:"
    echo "  cp \"$plist\" ~/Library/LaunchAgents/ && launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.dracon.$project.pipeline.plist"
    ;;
esac
