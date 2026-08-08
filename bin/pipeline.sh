#!/bin/sh
# pipeline.sh — general two-agent pipeline daemon (canonical copy:
# ~/.ww-pipeline/bin/pipeline.sh). Chains fresh agent sessions
# (orchestrator -> worker) in a loop while origin/main advances; sleeps
# IDLE_SLEEP_MIN minutes after a cycle that moved nothing. Designed to run
# under launchd with KeepAlive; safe to run manually — a second instance
# against the same repo refuses to start (exit 75).
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
#   MODEL  — "<engine>:<model-id>" from ~/.ww-pipeline/models.conf, chosen in
#            the menu bar's Model submenu. Re-read at the start of every phase,
#            so switching needs no restart; absent = `codex exec` on the
#            ~/.codex/config.toml default.
#   WW_PIPELINE_DRY_RUN=1 — one cycle, print decisions, no agent sessions

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
CLAUDE=${WW_PIPELINE_CLAUDE:-claude}
WORKTREES="$HOME/.ww-pipeline/worktrees/$PROJECT"
MODEL_FLAG="$PIPE_DIR/MODEL"
ENGINE=codex
MODEL_ID=""

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

# Single-instance lock: if the status file names a live daemon, refuse to
# start. Runs before the EXIT trap is installed so this refusal can never
# paint "stopped" over the live daemon's status. Dry runs check their own
# isolated status file, so a dry run beside a live daemon still works.
if [ -f "$STATUS" ]; then
  other_pid=$(jq -r '.pid // 0' "$STATUS" 2>/dev/null || echo 0)
  other_state=$(jq -r '.state // ""' "$STATUS" 2>/dev/null || echo "")
  if [ "$other_state" != "stopped" ] && [ "$other_pid" -gt 0 ] 2>/dev/null \
      && kill -0 "$other_pid" 2>/dev/null; then
    echo "pipeline.sh: daemon already running for $ROOT (pid $other_pid, state $other_state) — refusing to start" >&2
    exit 75
  fi
fi

# Day logs are tiny but were never pruned; keep two weeks.
find "$PIPE_DIR" -maxdepth 1 -name '[0-9]*.log' -mtime +14 -delete 2>/dev/null

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
CONSEC_FAILS=0
FAIL_LIMIT=${WW_PIPELINE_FAIL_LIMIT:-3}

# A persistently failing phase (expired auth, broken skill) otherwise burns
# a codex session every cycle forever; auto-pause instead of retry-spamming.
failure_breaker() {
  [ "$CONSEC_FAILS" -ge "$FAIL_LIMIT" ] || return 0
  touch "$PAUSE_FLAG"
  CONSEC_FAILS=0
  log "circuit breaker: $FAIL_LIMIT consecutive phase failures — auto-paused (Resume in the menu bar or rm PAUSE)"
  notify "auto-paused after $FAIL_LIMIT consecutive phase failures"
}

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

# Resolve which CLI and model the next phase runs on. Read fresh every phase so
# a menu-bar switch lands without restarting the daemon (a restart would have to
# kill a live session). Anything unrecognized falls back to the historical
# behaviour rather than guessing an engine — the value picks a binary to exec.
read_model() {
  ENGINE=codex
  MODEL_ID=""
  [ -f "$MODEL_FLAG" ] || return 0
  sel=$(head -1 "$MODEL_FLAG" 2>/dev/null | tr -d '[:space:]')
  case $sel in
    claude:?*) ENGINE=claude; MODEL_ID=${sel#claude:} ;;
    codex:?*)  ENGINE=codex;  MODEL_ID=${sel#codex:} ;;
    ''|codex:|claude:) ;;
    *) log "warn: unrecognized MODEL '$sel' — using the codex default" ;;
  esac
}

run_phase() { # $1 = phase, $2 = workdir, $3 = reasoning effort ("-" = none), $4 = prompt
  phase=$1; workdir=$2; effort=$3; prompt=$4
  read_model
  PHASE_STARTED=$(date -u +%FT%TZ)
  phase_epoch=$(date +%s)
  write_status "$phase"
  log "$phase: start [$ENGINE ${MODEL_ID:-default}] — \"$prompt\""
  if [ "$DRY_RUN" = 1 ]; then
    log "$phase: DRY RUN — prompt: \"$prompt\""
    echo "DRY RUN [$phase]: $ENGINE ${MODEL_ID:-default} in $workdir"
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
  claude_sid=""
  if [ "$ENGINE" = claude ]; then
    # `claude -p` has no -C: it takes the working directory from the process,
    # hence the subshell cd. We mint the session id ourselves so the menu bar
    # can offer an exact `claude --resume` instead of scraping the transcript.
    claude_sid=$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')
    set -- -p "$prompt" --permission-mode bypassPermissions --output-format text
    [ -n "$MODEL_ID" ] && set -- "$@" --model "$MODEL_ID"
    [ -n "$claude_sid" ] && set -- "$@" --session-id "$claude_sid"
    # Both CLIs take the same effort vocabulary (low|medium|high|xhigh|max), so
    # the orchestrator's "high" carries across engines instead of being dropped.
    [ "$effort" = "-" ] || set -- "$@" --effort "$effort"
    ( cd "$workdir" && exec "$CLAUDE" "$@" ) > "$out.raw" 2>&1
    rc=$?
    # -p prints only the closing message, so the capture already is the closer.
    cp "$out.raw" "$out.last" 2>/dev/null || true
  else
    set -- -C "$workdir" -s danger-full-access
    [ "$effort" = "-" ] || set -- "$@" -c "model_reasoning_effort=$effort"
    [ -n "$MODEL_ID" ] && set -- "$@" -c "model=$MODEL_ID"
    "$CODEX" exec -o "$out.last" "$@" "$prompt" > "$out.raw" 2>&1
    rc=$?
  fi
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
  if [ "$ENGINE" = claude ]; then
    sid=$claude_sid
  else
    sid=$(grep -m1 -iE 'session[ _]?id' "$out" \
          | grep -oE '[0-9a-f]{8}-[0-9a-f-]{27,}' | head -1 || true)
  fi
  # The engine is stored with the id so the menu bar knows whether to offer
  # `codex resume` or `claude --resume` for this session.
  case $phase in
    worker) LAST_WORKER_SESSION="$ENGINE:${sid:-unknown} @ $PHASE_STARTED" ;;
    orchestrator) LAST_ORCH_SESSION="$ENGINE:${sid:-unknown} @ $PHASE_STARTED" ;;
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
# Dirty worker worktrees are kept as evidence but previously accumulated in
# silence; name them at every start so they get inspected and removed.
if [ -d "$WORKTREES" ] && [ -n "$(ls "$WORKTREES" 2>/dev/null)" ]; then
  log "note: leftover worker worktree(s) kept dirty, inspect and remove: $(ls "$WORKTREES" | tr '\n' ' ')"
fi
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
  # The claude engine gets the equivalent via --permission-mode bypassPermissions.
  guard_ok=1
  case $guard_out in
    *"NOTHING TO DO"*) [ -n "$new_queue" ] || QUEUE="" ;;
    *"ACTION NEEDED"*)
      if run_phase orchestrator "$ROOT" high \
           "Use the orchestrator-run skill."; then
        CONSEC_FAILS=0
      else
        rc=$?
        CONSEC_FAILS=$(( CONSEC_FAILS + 1 ))
        log "warn: orchestrator phase rc!=0"
        notify "phase orchestrator failed (rc=$rc) — see logs/pipeline"
        failure_breaker
      fi ;;
    # A guard that prints neither verdict is broken or missing — stand down
    # the whole cycle, worker included; full-access sessions must not run on
    # an unverdicted repo.
    *) guard_ok=0
       log "warn: guard output unrecognized — standing down for this cycle" ;;
  esac

  pause_wait

  # The worker's preflight refuses a dirty checkout, and the primary carries
  # long-lived local modifications — so each worker phase gets a fresh
  # detached worktree of origin/main, matching the old Codex-app pattern.
  # The session pushes to origin itself; the worktree is removed when clean.
  if [ "$guard_ok" = 1 ] && worker_has_work; then
    # The deadline goes into the prompt text: a 2026-08-03 worker never ran
    # `date` and ground one task for 6+ hours past its 59-minute box.
    worker_prompt="Use the worker-run skill. Wall-clock deadline: $(date -v +59M '+%H:%M') local time — hard stop per the skill's time-box rules."
    if [ "$DRY_RUN" = 1 ]; then
      run_phase worker "$ROOT" - "$worker_prompt"
    else
      mkdir -p "$WORKTREES"
      wt="$WORKTREES/w$(date -u +%Y%m%d%H%M%S)"
      if git -C "$ROOT" worktree add --detach "$wt" origin/main >/dev/null 2>&1; then
        if run_phase worker "$wt" - "$worker_prompt"; then
          CONSEC_FAILS=0
        else
          rc=$?
          CONSEC_FAILS=$(( CONSEC_FAILS + 1 ))
          log "warn: worker phase rc!=0"
          notify "phase worker failed (rc=$rc) — see logs/pipeline"
          failure_breaker
        fi
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
