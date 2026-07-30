#!/bin/sh
# pipeline.sh — general two-agent pipeline daemon (canonical copy:
# ~/.ww-pipeline/bin/pipeline.sh). Chains fresh `codex exec` sessions
# (orchestrator -> worker) in a loop while origin/main advances; sleeps
# IDLE_SLEEP_MIN minutes after a cycle that moved nothing. Designed to run
# under launchd with KeepAlive; safe to run manually.
#
# Usage: pipeline.sh <repo-root>
# The repo must follow the shared pipeline conventions: a
# tools/orchestrator-guard.sh printing NOTHING TO DO / ACTION NEEDED,
# docs/superpowers/plans/*.md with "- [ ]" task boxes, and the shared
# worker-run / orchestrator-run Codex skills.
#
# Controls (all under <repo>/logs/pipeline/):
#   PAUSE  — pause between phases (menu bar toggles this)
#   POKE   — cut the current idle sleep short
#   WW_PIPELINE_DRY_RUN=1 — one cycle, print decisions, no codex sessions
# Origin spec: worldwright docs/superpowers/specs/2026-07-29-unified-pipeline-wrapper-design.md

set -u

ROOT=${1:-${WW_PIPELINE_ROOT:-}}
if [ -z "$ROOT" ] || { [ ! -d "$ROOT/.git" ] && [ ! -f "$ROOT/.git" ]; }; then
  echo "pipeline.sh: first argument must be a git repo root (got: '${ROOT:-}')" >&2
  exit 64
fi
ROOT=$(cd "$ROOT" && pwd)
PROJECT=$(basename "$ROOT")
PIPE_DIR="$ROOT/logs/pipeline"
STATUS="$PIPE_DIR/status.json"
HEARTBEAT="$PIPE_DIR/heartbeat"
PAUSE_FLAG="$PIPE_DIR/PAUSE"
POKE_FLAG="$PIPE_DIR/POKE"
IDLE_SLEEP_MIN=${WW_PIPELINE_IDLE_SLEEP_MIN:-30}
DRY_RUN=${WW_PIPELINE_DRY_RUN:-0}
CODEX=${WW_PIPELINE_CODEX:-codex}
WORKTREES="$HOME/.ww-pipeline/worktrees/$PROJECT"

# Dry runs must never clobber the live daemon's status surface (a dry run
# during a live phase once painted the menu bar dead) — isolate their state.
if [ "$DRY_RUN" = 1 ]; then
  STATUS="$PIPE_DIR/status-dry.json"
  HEARTBEAT="$PIPE_DIR/heartbeat-dry"
fi

notify() {
  [ "${WW_PIPELINE_NOTIFY:-1}" = 1 ] || return 0
  command -v osascript >/dev/null 2>&1 && osascript \
    -e "display notification \"$1\" with title \"$PROJECT pipeline\"" \
    2>/dev/null
}

command -v jq >/dev/null 2>&1 || {
  echo "ww-pipeline: jq is required" >&2
  notify "pipeline cannot start — jq is required"
  exit 78
}

mkdir -p "$PIPE_DIR"

# File is named by UTC date (the tests depend on that); line timestamps are
# LOCAL wall-clock time for readability — the operator reads this file.
logfile() { printf '%s' "$PIPE_DIR/$(date -u +%Y%m%d).log"; }
log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" >> "$(logfile)"; }
log_sep() { printf '\n' >> "$(logfile)"; }

# Condense the guard's multi-line report to one line: verdict + reasons.
guard_summary() {
  printf '%s\n' "$1" | awk '
    NR==1 { printf "%s", $0; next }
    /^- /  { printf "  %s", $0 }
  '
}

PHASE_STARTED=""
SLEEP_UNTIL=""
LAST_CYCLE=""
LAST_EXIT=""
LAST_PHASE=""
QUEUE=""
LAST_WORKER_SESSION=""
LAST_ORCH_SESSION=""

write_status() { # $1 = state
  jq -n \
    --arg state "$1" \
    --arg phase_started_at "$PHASE_STARTED" \
    --arg sleep_until "$SLEEP_UNTIL" \
    --arg pid "$$" \
    --arg last_cycle "$LAST_CYCLE" \
    --arg last_exit "$LAST_EXIT" \
    --arg last_phase "$LAST_PHASE" \
    --arg queue "$QUEUE" \
    --arg worker "$LAST_WORKER_SESSION" \
    --arg orchestrator "$LAST_ORCH_SESSION" \
    '{state:$state, phase_started_at:$phase_started_at,
      sleep_until:$sleep_until, pid:($pid|tonumber),
      last_cycle:$last_cycle, last_exit:$last_exit, last_phase:$last_phase,
      queue:$queue,
      last_sessions:{worker:$worker, orchestrator:$orchestrator}}' \
    > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
}

on_exit() {
  code=$?
  PHASE_STARTED=""
  SLEEP_UNTIL=""
  LAST_EXIT="code $code at $(date -u +%FT%TZ)"
  write_status stopped
  log "daemon stop pid=$$ code=$code"
  [ "$code" -ne 0 ] && notify "pipeline stopped (exit $code) — launchd restarts it"
}
trap on_exit EXIT
trap 'exit 129' INT TERM HUP

run_phase() { # $1 = phase name; remaining args passed to `codex exec`
  phase=$1; shift
  # The prompt is the last codex argument; flags are constant noise in a log.
  for _a in "$@"; do prompt=$_a; done
  PHASE_STARTED=$(date -u +%FT%TZ)
  phase_epoch=$(date +%s)
  write_status "$phase"
  log "$phase: start — \"$prompt\""
  if [ "$DRY_RUN" = 1 ]; then
    log "$phase: DRY RUN — prompt: \"$prompt\""
    echo "DRY RUN [$phase]: codex exec $*"
    PHASE_STARTED=""
    return 0
  fi
  touch "$HEARTBEAT"
  ( while kill -0 $$ 2>/dev/null; do touch "$HEARTBEAT"; sleep 60; done ) &
  hb=$!
  # Full session transcripts go to individual capture files, never the day
  # log — appending them once grew a day log to 7.5MB and froze editors.
  mkdir -p "$PIPE_DIR/sessions"
  out="$PIPE_DIR/sessions/$(date -u +%Y%m%dT%H%M%SZ)-$phase.out"
  "$CODEX" exec -o "$out.last" "$@" > "$out.raw" 2>&1
  rc=$?
  kill "$hb" 2>/dev/null
  wait "$hb" 2>/dev/null || true
  # Keep captures readable: the transcript quotes every command's full
  # output (AGENTS.md dumps, file reads, test logs) — clamp each output
  # block to its first 15 lines. The full conversation stays available
  # via `codex resume <session id>`.
  awk '
    function flush() { if (inout && skipped > 0)
      printf "  ... (+%d lines truncated)\n", skipped }
    /^(exec|codex|thinking|user|tokens used)$/ {
      flush(); inout=0; skipped=0; print; next }
    /^ (succeeded|failed|exited|aborted)/ { inout=1; n=0; skipped=0; print; next }
    inout { n++; if (n <= 15) print; else skipped++; next }
    { print }
    END { flush() }
  ' "$out.raw" > "$out" && rm -f "$out.raw" || mv "$out.raw" "$out"
  if [ "$rc" -ne 0 ]; then
    { printf -- '--- %s session tail (rc=%s) ---\n' "$phase" "$rc"
      tail -40 "$out"; } >> "$(logfile)"
  fi
  sid=$(grep -m1 -iE 'session[ _]?id' "$out" \
        | grep -oE '[0-9a-f]{8}-[0-9a-f-]{27,}' | head -1 || true)
  case $phase in
    worker) LAST_WORKER_SESSION="${sid:-unknown} @ $PHASE_STARTED" ;;
    orchestrator) LAST_ORCH_SESSION="${sid:-unknown} @ $PHASE_STARTED" ;;
  esac
  PHASE_STARTED=""
  LAST_PHASE="$phase rc=$rc at $(date -u +%FT%TZ)"
  dur=$(( $(date +%s) - phase_epoch ))
  dur_h=$(( dur / 60 ))m$(( dur % 60 ))s
  if [ "$rc" -eq 0 ]; then
    log "$phase: done in $dur_h  session ${sid:-unknown}  capture sessions/$(basename "$out")"
  else
    log "$phase: FAILED rc=$rc after $dur_h  session ${sid:-unknown}  capture sessions/$(basename "$out")"
  fi
  # The model's closing message, indented under the done/FAILED line.
  if [ -s "$out.last" ]; then
    head -40 "$out.last" | sed 's/^/          | /' >> "$(logfile)"
  fi
  rm -f "$out.last"
  # keep only the newest 40 capture files
  ls -t "$PIPE_DIR/sessions" 2>/dev/null | tail -n +41 | while read -r f; do
    rm -f "$PIPE_DIR/sessions/$f"
  done
  return "$rc"
}

worker_has_work() {
  git -C "$ROOT" ls-tree -r --name-only origin/main docs/superpowers/plans/ \
    | grep '\.md$' | sort | while read -r p; do
        if git -C "$ROOT" show "origin/main:$p" 2>/dev/null \
            | grep -q '^[[:space:]]*- \[ \]'; then
          echo "$p"
          break
        fi
      done | grep -q .
}

idle_sleep() {
  SLEEP_UNTIL=$(date -u -v +"${IDLE_SLEEP_MIN}"M +%FT%TZ 2>/dev/null || echo "")
  write_status sleeping
  i=0
  while [ "$i" -lt $(( IDLE_SLEEP_MIN * 60 )) ]; do
    touch "$HEARTBEAT"
    if [ -f "$POKE_FLAG" ]; then
      rm -f "$POKE_FLAG"
      log "idle sleep cut short by POKE"
      break
    fi
    if [ -f "$PAUSE_FLAG" ]; then
      log "idle sleep cut short by PAUSE"
      break
    fi
    sleep 5
    i=$(( i + 5 ))
  done
  SLEEP_UNTIL=""
}

pause_wait() {
  if [ "$DRY_RUN" = 1 ]; then
    [ -f "$PAUSE_FLAG" ] && log "dry run: PAUSE flag present — ignoring"
    return 0
  fi
  while [ -f "$PAUSE_FLAG" ]; do
    write_status paused
    touch "$HEARTBEAT"
    sleep 5
  done
}

log_sep
log "daemon start pid=$$ dry_run=$DRY_RUN root=$ROOT"
write_status starting
touch "$HEARTBEAT"
while :; do
  touch "$HEARTBEAT"
  pause_wait

  git -C "$ROOT" fetch origin --quiet 2>/dev/null || log "warn: git fetch failed"
  head_before=$(git -C "$ROOT" rev-parse origin/main)

  # The guard resolves the repo from its cwd; under launchd cwd is "/",
  # so run it from the checkout root.
  guard_out=$( (cd "$ROOT" && sh tools/orchestrator-guard.sh) 2>&1 ) || true
  log_sep
  log "guard: $(guard_summary "$guard_out")"
  new_queue=$(printf '%s' "$guard_out" \
    | grep -oE '[0-9]+ plan\(s\) (queued with [0-9]+ unchecked task\(s\)|with unchecked tasks)' \
    | head -1)
  [ -n "$new_queue" ] && QUEUE=$new_queue

  # Sessions must commit and push; codex's workspace-write sandbox blocks
  # .git writes (verified 2026-07-29: "cannot create .git/index.lock"), so
  # phases run unsandboxed — the same trust the Codex app automations had.
  case $guard_out in
    *"NOTHING TO DO"*) : ;;
    *"ACTION NEEDED"*) run_phase orchestrator -C "$ROOT" \
         -s danger-full-access \
         -c model_reasoning_effort=high \
         "Use the orchestrator-run skill." \
         || { rc=$?; log "warn: orchestrator phase rc!=0"; \
              notify "phase orchestrator failed (rc=$rc) — see logs/pipeline"; } ;;
    *) log "warn: guard output unrecognized — standing down" ;;
  esac

  pause_wait

  # The worker's preflight refuses a dirty checkout, and the primary carries
  # long-lived local modifications — so each worker phase gets a fresh
  # detached worktree of origin/main, matching the old Codex-app pattern.
  # The session pushes to origin itself; the worktree is removed when clean.
  if worker_has_work; then
    if [ "$DRY_RUN" = 1 ]; then
      run_phase worker -C "$ROOT" -s danger-full-access \
        "Use the worker-run skill."
    else
      mkdir -p "$WORKTREES"
      wt="$WORKTREES/w$(date -u +%Y%m%d%H%M%S)"
      if git -C "$ROOT" worktree add --detach "$wt" origin/main >/dev/null 2>&1; then
        run_phase worker -C "$wt" -s danger-full-access \
          "Use the worker-run skill." \
          || { rc=$?; log "warn: worker phase rc!=0"; \
               notify "phase worker failed (rc=$rc) — see logs/pipeline"; }
        if [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
          git -C "$ROOT" worktree remove "$wt" >/dev/null 2>&1 \
            || log "warn: could not remove worker worktree $wt"
        else
          log "warn: worker worktree left dirty, keeping: $wt"
        fi
      else
        log "warn: worker worktree creation failed — skipping worker phase"
        notify "worker worktree creation failed — see logs/pipeline"
      fi
    fi
  fi

  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  head_after=$(git -C "$ROOT" rev-parse origin/main)
  if [ "$head_after" = "$head_before" ]; then
    LAST_CYCLE="idle at $(date -u +%FT%TZ) head=$head_after"
    log "cycle: idle — sleeping ${IDLE_SLEEP_MIN}m"
    if [ "$DRY_RUN" = 1 ]; then
      log "dry run: exiting after one cycle"
      exit 0
    fi
    idle_sleep
  else
    LAST_CYCLE="progressed at $(date -u +%FT%TZ) head=$head_after"
    log "cycle: progressed"
    if [ "$DRY_RUN" = 1 ]; then
      log "dry run: exiting after one cycle"
      exit 0
    fi
  fi
done
