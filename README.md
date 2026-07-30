# ww-pipeline

General daemon for the two-agent Codex pipelines (worker + orchestrator).
One canonical copy serves every pipeline repo; per-project state lives in
each repo's `logs/pipeline/`. Origin: the Worldwright unified-pipeline spec
(`docs/superpowers/specs/2026-07-29-unified-pipeline-wrapper-design.md`).

## Layout

- `bin/pipeline.sh <repo-root>` — the daemon. One cycle: guard check →
  orchestrator `codex exec` session (only on `ACTION NEEDED`; stands down on
  anything else) → worker session in a fresh detached worktree (only when
  the earliest plan on origin/main has an unchecked `- [ ]`) → loop on
  progress, else sleep 30 min. Sessions run `-s danger-full-access`
  (they must commit and push). Session transcripts land in
  `<repo>/logs/pipeline/sessions/` clamped to 15-line output blocks,
  pruned to the newest 40.
- `bin/statusbar.30s.sh` — SwiftBar plugin; reads `projects.conf`, one
  menu bar glyph per project (🟢 working / 🌙 sleeping / ⏸ paused /
  🔴 dead-or-stalled / ⚪ never run) with a dropdown section each
  (Pause / Run-now, `codex resume` commands, today's log).
- `launchd/com.dracon.<project>.pipeline.plist` — one LaunchAgent per
  project (`KeepAlive`; restarts on crash).
- `tests/test-pipeline.sh` — daemon contract tests against fixture repos
  with stub guards. Guard *behavior* tests live in each project repo.
- `worktrees/` (gitignored) — per-project worker worktrees, removed when
  clean after each phase.

## A repo qualifies when it has

- `tools/orchestrator-guard.sh` printing `NOTHING TO DO` / `ACTION NEEDED`
  (optionally honoring a `NO VALUABLE WORK AVAILABLE` hold in the latest
  ORCHESTRATOR-NOTES.md entry — port from worldwright's guard),
- `tools/worker-preflight.sh` / `tools/worker-lock.sh` (the worker lease),
- `docs/superpowers/plans/*.md` with `- [ ]` task boxes as the queue,
- `logs/` gitignored,
- the shared `worker-run` / `orchestrator-run` Codex skills.

## Add a project

1. Pause/disable the project's Codex app automations — the daemon must
   never run alongside them (the worker lease serializes collisions, but
   every collision wastes a session).
2. Add the repo root to `projects.conf`.
3. Copy its plist from `launchd/` to `~/Library/LaunchAgents/` and
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<plist>`.

## Operate

- Pause/resume + run-now: menu bar dropdown (flag files
  `logs/pipeline/PAUSE` / `POKE` in the repo).
- Stop/rollback: Pause first, wait for ⏸/🌙, then
  `launchctl bootout gui/$(id -u)/com.dracon.<project>.pipeline` —
  a mid-phase kill murders a live codex session and can hold the worker
  lease for up to 59 minutes.
- Dry run: `WW_PIPELINE_DRY_RUN=1 sh bin/pipeline.sh <repo-root>` — one
  cycle's decisions, no sessions, state isolated to `status-dry.json`.
- Full transcripts: `codex resume <session id>` (ids in the dropdown,
  day log, and capture headers).
