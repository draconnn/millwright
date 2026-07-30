#!/bin/sh
# SwiftBar plugin for the two-agent pipeline daemons (canonical copy:
# ~/.ww-pipeline/bin/statusbar.30s.sh). Reads ~/.ww-pipeline/projects.conf
# (one "<repo-root> [bar-label]" per line, # comments allowed) and renders
# one "<glyph><label>" per project in the menu bar plus a dropdown section
# each. Install by symlinking into the SwiftBar plugins folder; ".30s" is
# the refresh interval.
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>

CONF="$HOME/.ww-pipeline/projects.conf"

# inspect <root> -> sets glyph/state/pid/... globals for one project
inspect() {
  root=$1
  pipe="$root/logs/pipeline"
  status="$pipe/status.json"
  glyph="⚪"; state="never run"; pid=0; alive=0; hb_age=999999
  phase_started=""; sleep_until=""; last_cycle="-"; queue=""
  wsess="-"; osess="-"; last_phase=""; last_exit=""
  [ -f "$status" ] || return 0
  state=$(jq -r '.state // "unknown"' "$status")
  pid=$(jq -r '.pid // 0' "$status")
  phase_started=$(jq -r '.phase_started_at // ""' "$status")
  sleep_until=$(jq -r '.sleep_until // ""' "$status")
  last_cycle=$(jq -r '.last_cycle // "-"' "$status")
  queue=$(jq -r '.queue // ""' "$status")
  wsess=$(jq -r '.last_sessions.worker // "-"' "$status")
  osess=$(jq -r '.last_sessions.orchestrator // "-"' "$status")
  last_phase=$(jq -r '.last_phase // ""' "$status")
  last_exit=$(jq -r '.last_exit // ""' "$status")
  [ "$pid" -gt 0 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null && alive=1
  [ -f "$pipe/heartbeat" ] && hb_age=$(( $(date +%s) - $(stat -f %m "$pipe/heartbeat") ))
  glyph="🔴"
  case $state in
    paused) glyph="⏸" ;;
    sleeping) [ "$alive" = 1 ] && [ "$hb_age" -lt 300 ] && glyph="🌙" ;;
    starting) [ "$alive" = 1 ] && glyph="🟢" ;;
    worker|orchestrator)
      [ "$alive" = 1 ] && [ "$hb_age" -lt 300 ] && glyph="🟢" ;;
    stopped) glyph="🔴" ;;
  esac
  [ "$alive" = 0 ] && [ "$state" != "stopped" ] && [ "$state" != "never run" ] && glyph="🔴"
}

# split_line <conf line> -> sets proj_root and proj_label
split_line() {
  proj_root=${1%% *}
  rest=${1#"$proj_root"}
  proj_label=$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')
  [ -n "$proj_label" ] || proj_label=$(basename "$proj_root" | cut -c1-2)
}

fmt_session() { # "id @ ts" -> "codex resume id  (ts)"; passthrough otherwise
  case $1 in
    "unknown @ "*|"-"|"") printf '%s' "$1" ;;
    *" @ "*) printf 'codex resume %s  (%s)' "${1%% @ *}" "${1##* @ }" ;;
    *) printf '%s' "$1" ;;
  esac
}

conf_lines=""
if [ -f "$CONF" ]; then
  conf_lines=$(grep -v '^[[:space:]]*#' "$CONF" | grep -v '^[[:space:]]*$')
fi
if [ -z "$conf_lines" ]; then
  echo "⚪ pipelines"
  echo "---"
  echo "no projects configured in $CONF"
  exit 0
fi

bar=""
while IFS= read -r line; do
  split_line "$line"
  inspect "$proj_root"
  bar="$bar$glyph$proj_label "
done <<EOF
$conf_lines
EOF
echo "${bar% }"
echo "---"

first=1
while IFS= read -r line; do
  split_line "$line"
  inspect "$proj_root"
  name=$(basename "$proj_root")
  [ "$first" = 1 ] || echo "---"
  first=0
  echo "$glyph $name"
  echo "state: $state (pid $pid, alive=$alive)"
  [ -n "$phase_started" ] && echo "phase since: $phase_started (heartbeat ${hb_age}s ago)"
  [ -n "$sleep_until" ] && echo "sleeping until: $sleep_until"
  echo "last cycle: $last_cycle"
  [ -n "$last_phase" ] && echo "last phase: $last_phase"
  [ -n "$last_exit" ] && echo "last exit: $last_exit"
  [ -n "$queue" ] && echo "queue: $queue"
  echo "worker: $(fmt_session "$wsess")"
  echo "orchestrator: $(fmt_session "$osess")"
  subj=$(git -C "$proj_root" log -1 --format=%s origin/main 2>/dev/null)
  [ -n "$subj" ] && echo "main: $subj"
  pipe="$proj_root/logs/pipeline"
  if [ -f "$pipe/PAUSE" ]; then
    echo "Resume | shell=/bin/rm param1=-f param2=$pipe/PAUSE terminal=false refresh=true"
  else
    echo "Pause after current phase | shell=/usr/bin/touch param1=$pipe/PAUSE terminal=false refresh=true"
  fi
  echo "Run now (cut idle sleep) | shell=/usr/bin/touch param1=$pipe/POKE terminal=false refresh=true"
  echo "Open today's log | shell=/usr/bin/open param1=$pipe/$(date -u +%Y%m%d).log terminal=false"
done <<EOF
$conf_lines
EOF
