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
  make_fixture garbled "fatal: something went wrong entirely" "$done_plan"
  f="$tmp/garbled/primary"
  out=$(WW_PIPELINE_DRY_RUN=1 daemon "$f")
  case $out in
    *"DRY RUN ["*) echo "garbled guard must stand down, got: $out" >&2; exit 1 ;;
  esac
  grep -q 'guard output unrecognized' "$f"/logs/pipeline/*.log || {
    echo "expected stand-down warning in daemon log" >&2; exit 1
  }
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

test_requires_repo_root
test_dry_run_idle_cycle
test_dry_run_active_cycle
test_fails_closed_on_garbled_guard
test_poke_cuts_idle_sleep
echo "pipeline infra tests ok"
