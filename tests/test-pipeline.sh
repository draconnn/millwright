#!/bin/sh
# Contract tests for bin/pipeline.sh against fixture repos with stub guards.
# Guard *behavior* (queue-hold marker etc.) is tested in each project repo;
# here the guard is a stub and only the daemon's contract is under test.
set -eu

infra_root=$(cd "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/pipeline-infra-test.$$

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

git_commit() {
  git -C "$1" add .
  git -C "$1" -c user.name="Pipeline Test" -c user.email="pipeline-test@example.invalid" commit -m "$2" >/dev/null
}

# make_fixture <name> <guard-verdict-line> <plan-content>
make_fixture() {
  mkdir -p "$tmp/$1"
  git init --bare "$tmp/$1/origin.git" >/dev/null
  git clone "$tmp/$1/origin.git" "$tmp/$1/primary" >/dev/null 2>&1
  f="$tmp/$1/primary"
  mkdir -p "$f/tools" "$f/docs/superpowers/plans"
  printf '#!/bin/sh\necho "%s"\n' "$2" > "$f/tools/orchestrator-guard.sh"
  chmod +x "$f/tools/orchestrator-guard.sh"
  printf '%s\n' "$3" > "$f/docs/superpowers/plans/2026-07-30-plan.md"
  git_commit "$f" "fixture state"
  git -C "$f" branch -M main
  git -C "$f" push origin main >/dev/null 2>&1
}

done_plan="# Batch done
- [x] finished task"

open_plan="# Batch next
- [ ] unchecked task"

daemon() { # run the central daemon against fixture $1 with env pre-set
  sh "$infra_root/bin/pipeline.sh" "$1"
}

test_requires_repo_root() {
  set +e
  out=$(sh "$infra_root/bin/pipeline.sh" "$tmp/definitely-missing" 2>&1)
  rc=$?
  set -e
  [ "$rc" = 64 ] || { echo "expected exit 64 for bad root, got $rc: $out" >&2; exit 1; }
}

test_dry_run_idle_cycle() {
  make_fixture dryidle "NOTHING TO DO: stub hold. End the orchestrator run now." "$done_plan"
  f="$tmp/dryidle/primary"
  out=$(WW_PIPELINE_DRY_RUN=1 daemon "$f")
  case $out in
    *"DRY RUN ["*) echo "idle fixture must launch no phases, got: $out" >&2; exit 1 ;;
  esac
  grep -q 'cycle: idle' "$f"/logs/pipeline/*.log || {
    echo "expected idle cycle in daemon log" >&2; exit 1
  }
}

test_dry_run_active_cycle() {
  make_fixture dryactive "ACTION NEEDED (worker lease: none): - 1 commit(s) stub" "$open_plan"
  f="$tmp/dryactive/primary"
  out=$(WW_PIPELINE_DRY_RUN=1 daemon "$f")
  case $out in
    *"DRY RUN [orchestrator]"*) ;;
    *) echo "expected orchestrator dry-run phase, got: $out" >&2; exit 1 ;;
  esac
  case $out in
    *"DRY RUN [worker]"*) ;;
    *) echo "expected worker dry-run phase, got: $out" >&2; exit 1 ;;
  esac
  state=$(jq -r .state "$f/logs/pipeline/status-dry.json")
  [ "$state" = "stopped" ] || {
    echo "expected final state stopped, got: $state" >&2; exit 1
  }
  if [ -f "$f/logs/pipeline/status.json" ]; then
    echo "dry run must not write the live status.json" >&2; exit 1
  fi
}

test_fails_closed_on_garbled_guard() {
  # Open plan on purpose: a garbled guard must stand down the WHOLE cycle,
  # worker included — a done_plan fixture would mask a worker that still runs.
  make_fixture garbled "fatal: something went wrong entirely" "$open_plan"
  f="$tmp/garbled/primary"
  out=$(WW_PIPELINE_DRY_RUN=1 daemon "$f")
  case $out in
    *"DRY RUN ["*) echo "garbled guard must stand down, got: $out" >&2; exit 1 ;;
  esac
  grep -q 'guard output unrecognized' "$f"/logs/pipeline/*.log || {
    echo "expected stand-down warning in daemon log" >&2; exit 1
  }
}

test_single_instance_lock() {
  make_fixture lock "NOTHING TO DO: stub hold. End the orchestrator run now." "$done_plan"
  f="$tmp/lock/primary"
  ( cd "$f" && WW_PIPELINE_CODEX=/usr/bin/true WW_PIPELINE_NOTIFY=0 \
      WW_PIPELINE_IDLE_SLEEP_MIN=1 sh "$infra_root/bin/pipeline.sh" "$f" ) &
  pid=$(wait_for_daemon_pid "$f/logs/pipeline/status.json") || {
    echo "daemon never wrote a pid to status.json" >&2; exit 1
  }
  set +e
  out=$(WW_PIPELINE_NOTIFY=0 sh "$infra_root/bin/pipeline.sh" "$f" 2>&1)
  rc=$?
  set -e
  [ "$rc" = 75 ] || {
    echo "expected exit 75 from second instance, got $rc: $out" >&2
    kill_and_verify_gone "$pid"; exit 1
  }
  p2=$(jq -r '.pid' "$f/logs/pipeline/status.json")
  [ "$p2" = "$pid" ] || {
    echo "second instance clobbered status.json (pid $p2, expected $pid)" >&2
    kill_and_verify_gone "$pid"; exit 1
  }
  kill_and_verify_gone "$pid"
}

test_failure_breaker_auto_pauses() {
  make_fixture breaker "ACTION NEEDED (worker lease: none): - 1 commit(s) stub" "$open_plan"
  f="$tmp/breaker/primary"
  ( cd "$f" && WW_PIPELINE_CODEX=/usr/bin/false WW_PIPELINE_NOTIFY=0 \
      WW_PIPELINE_FAIL_LIMIT=2 WW_PIPELINE_IDLE_SLEEP_MIN=1 \
      sh "$infra_root/bin/pipeline.sh" "$f" ) &
  pid=$(wait_for_daemon_pid "$f/logs/pipeline/status.json") || {
    echo "daemon never wrote a pid to status.json" >&2; exit 1
  }
  n=0
  while ! grep -q 'circuit breaker' "$f"/logs/pipeline/*.log 2>/dev/null; do
    sleep 1; n=$(( n + 1 ))
    [ "$n" -lt 30 ] || {
      echo "breaker never tripped after repeated phase failures" >&2
      kill_and_verify_gone "$pid"; exit 1
    }
  done
  [ -f "$f/logs/pipeline/PAUSE" ] || {
    echo "breaker tripped but did not create the PAUSE flag" >&2
    kill_and_verify_gone "$pid"; exit 1
  }
  kill_and_verify_gone "$pid"
}

wait_for_daemon_pid() { # $1 = status.json path
  n=0
  while [ "$n" -lt 30 ]; do
    if [ -f "$1" ]; then
      p=$(jq -r '.pid // 0' "$1" 2>/dev/null || echo 0)
      [ "$p" -gt 0 ] 2>/dev/null && { echo "$p"; return 0; }
    fi
    sleep 1; n=$(( n + 1 ))
  done
  return 1
}

kill_and_verify_gone() { # $1 = pid  (TERM lands after the current sleep tick)
  kill "$1" 2>/dev/null || true
  n=0
  while [ "$n" -lt 12 ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 1; n=$(( n + 1 ))
  done
  echo "daemon pid $1 survived kill" >&2
  kill -9 "$1" 2>/dev/null || true
  return 1
}

test_poke_cuts_idle_sleep() {
  make_fixture poke "NOTHING TO DO: stub hold. End the orchestrator run now." "$done_plan"
  f="$tmp/poke/primary"
  ( cd "$f" && WW_PIPELINE_CODEX=/usr/bin/true WW_PIPELINE_NOTIFY=0 \
      WW_PIPELINE_IDLE_SLEEP_MIN=1 sh "$infra_root/bin/pipeline.sh" "$f" ) &
  pid=$(wait_for_daemon_pid "$f/logs/pipeline/status.json") || {
    echo "daemon never wrote a pid to status.json" >&2; exit 1
  }
  n=0
  while ! grep -q 'cycle: idle' "$f"/logs/pipeline/*.log 2>/dev/null; do
    sleep 1; n=$(( n + 1 ))
    [ "$n" -lt 20 ] || { echo "daemon never reached idle" >&2; kill_and_verify_gone "$pid"; exit 1; }
  done
  touch "$f/logs/pipeline/POKE"
  n=0
  while ! grep -q 'idle sleep cut short by POKE' "$f"/logs/pipeline/*.log 2>/dev/null; do
    sleep 1; n=$(( n + 1 ))
    [ "$n" -lt 15 ] || { echo "POKE never cut the sleep" >&2; kill_and_verify_gone "$pid"; exit 1; }
  done
  kill_and_verify_gone "$pid"
}

set_model() { # <fixture root> <engine:id> — bypasses set-model.sh validation
  mkdir -p "$1/logs/pipeline"
  printf '%s\n' "$2" > "$1/logs/pipeline/MODEL"
}

test_set_model_validates_against_models_conf() {
  make_fixture setmodel "NOTHING TO DO: stub hold. End the orchestrator run now." "$done_plan"
  f="$tmp/setmodel/primary"
  set +e
  out=$(WW_PIPELINE_HOME="$infra_root" sh "$infra_root/bin/set-model.sh" \
          "$f" "claude:not-a-real-model" 2>&1)
  rc=$?
  set -e
  [ "$rc" = 65 ] || {
    echo "expected exit 65 for an unlisted model, got $rc: $out" >&2; exit 1
  }
  if [ -f "$f/logs/pipeline/MODEL" ]; then
    echo "a rejected model must not be written to the flag file" >&2; exit 1
  fi
  WW_PIPELINE_HOME="$infra_root" sh "$infra_root/bin/set-model.sh" \
    "$f" "claude:claude-opus-5" >/dev/null
  got=$(cat "$f/logs/pipeline/MODEL")
  [ "$got" = "claude:claude-opus-5" ] || {
    echo "expected MODEL flag 'claude:claude-opus-5', got '$got'" >&2; exit 1
  }
}

test_model_flag_switches_engine_in_dry_run() {
  make_fixture claudedry "ACTION NEEDED (worker lease: none): - 1 commit(s) stub" "$open_plan"
  f="$tmp/claudedry/primary"
  set_model "$f" "claude:claude-opus-5"
  out=$(WW_PIPELINE_DRY_RUN=1 daemon "$f")
  case $out in
    *"DRY RUN [orchestrator]: claude claude-opus-5"*) ;;
    *) echo "expected claude engine in the orchestrator dry run, got: $out" >&2; exit 1 ;;
  esac
  case $out in
    *"DRY RUN [worker]: claude claude-opus-5"*) ;;
    *) echo "expected claude engine in the worker dry run, got: $out" >&2; exit 1 ;;
  esac
}

test_unrecognized_model_falls_back_to_codex() {
  make_fixture badmodel "ACTION NEEDED (worker lease: none): - 1 commit(s) stub" "$open_plan"
  f="$tmp/badmodel/primary"
  set_model "$f" "gibberish-with-no-engine"
  out=$(WW_PIPELINE_DRY_RUN=1 daemon "$f")
  case $out in
    *"DRY RUN [orchestrator]: codex default"*) ;;
    *) echo "expected fallback to the codex default, got: $out" >&2; exit 1 ;;
  esac
  grep -q 'unrecognized MODEL' "$f"/logs/pipeline/*.log || {
    echo "expected an unrecognized-MODEL warning in the daemon log" >&2; exit 1
  }
}

test_claude_engine_is_actually_executed() {
  # The codex stub succeeds and the claude stub fails, so the breaker can only
  # trip if the MODEL flag really routed the phase to claude. Were dispatch
  # broken and codex still running, every phase would succeed and this test
  # would time out instead of passing.
  make_fixture claudeexec "ACTION NEEDED (worker lease: none): - 1 commit(s) stub" "$open_plan"
  f="$tmp/claudeexec/primary"
  set_model "$f" "claude:claude-opus-5"
  ( cd "$f" && WW_PIPELINE_CODEX=/usr/bin/true WW_PIPELINE_CLAUDE=/usr/bin/false \
      WW_PIPELINE_NOTIFY=0 WW_PIPELINE_FAIL_LIMIT=2 WW_PIPELINE_IDLE_SLEEP_MIN=1 \
      sh "$infra_root/bin/pipeline.sh" "$f" ) &
  pid=$(wait_for_daemon_pid "$f/logs/pipeline/status.json") || {
    echo "daemon never wrote a pid to status.json" >&2; exit 1
  }
  n=0
  while ! grep -q 'circuit breaker' "$f"/logs/pipeline/*.log 2>/dev/null; do
    sleep 1; n=$(( n + 1 ))
    [ "$n" -lt 30 ] || {
      echo "claude engine never ran — breaker did not trip" >&2
      kill_and_verify_gone "$pid"; exit 1
    }
  done
  grep -q 'start \[claude claude-opus-5\]' "$f"/logs/pipeline/*.log || {
    echo "phase log did not record the claude engine" >&2
    kill_and_verify_gone "$pid"; exit 1
  }
  kill_and_verify_gone "$pid"
}

test_model_switch_applies_without_restart() {
  # The whole point of the flag file: a live daemon must pick up a new model at
  # the next phase. Both stubs succeed so the loop keeps cycling; done_plan
  # keeps the worker (and its worktree) out of it, leaving orchestrator phases
  # as the observable. Asserting the same pid logged both engines is what rules
  # out "it only reads MODEL at startup".
  make_fixture hotswap "ACTION NEEDED (worker lease: none): - 1 commit(s) stub" "$done_plan"
  f="$tmp/hotswap/primary"
  set_model "$f" "codex:gpt-5.5"
  ( cd "$f" && WW_PIPELINE_CODEX=/usr/bin/true WW_PIPELINE_CLAUDE=/usr/bin/true \
      WW_PIPELINE_NOTIFY=0 WW_PIPELINE_IDLE_SLEEP_MIN=1 \
      sh "$infra_root/bin/pipeline.sh" "$f" ) &
  pid=$(wait_for_daemon_pid "$f/logs/pipeline/status.json") || {
    echo "daemon never wrote a pid to status.json" >&2; exit 1
  }
  n=0
  while ! grep -q 'start \[codex gpt-5.5\]' "$f"/logs/pipeline/*.log 2>/dev/null; do
    sleep 1; n=$(( n + 1 ))
    [ "$n" -lt 20 ] || {
      echo "daemon never ran a phase on the initial model" >&2
      kill_and_verify_gone "$pid"; exit 1
    }
  done
  # Swap the model under the running daemon — no signal, no restart.
  set_model "$f" "claude:claude-opus-5"
  touch "$f/logs/pipeline/POKE"
  n=0
  while ! grep -q 'start \[claude claude-opus-5\]' "$f"/logs/pipeline/*.log 2>/dev/null; do
    sleep 1; n=$(( n + 1 ))
    [ "$n" -lt 25 ] || {
      echo "live daemon did not pick up the new model without a restart" >&2
      kill_and_verify_gone "$pid"; exit 1
    }
  done
  still=$(jq -r '.pid' "$f/logs/pipeline/status.json")
  [ "$still" = "$pid" ] || {
    echo "daemon restarted mid-test (pid $still, expected $pid) — proves nothing" >&2
    kill_and_verify_gone "$pid"; exit 1
  }
  kill_and_verify_gone "$pid"
}

test_requires_repo_root
test_dry_run_idle_cycle
test_dry_run_active_cycle
test_fails_closed_on_garbled_guard
test_single_instance_lock
test_failure_breaker_auto_pauses
test_poke_cuts_idle_sleep
test_set_model_validates_against_models_conf
test_model_flag_switches_engine_in_dry_run
test_unrecognized_model_falls_back_to_codex
test_claude_engine_is_actually_executed
test_model_switch_applies_without_restart
echo "pipeline infra tests ok"
