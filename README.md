# ww-pipeline

General daemon for the two-agent Codex pipelines (worker + orchestrator).
One canonical copy serves every pipeline repo; per-project state lives in
each repo's `logs/pipeline/`.

## Layout

- `bin/pipeline.sh <repo-root>` — the daemon. One cycle: guard check →
  orchestrator `codex exec` session (only on `ACTION NEEDED`) → worker
  session in a fresh detached worktree (only when a plan on origin/main has
  an unchecked `- [ ]`) → loop on progress, else sleep 30 min. An
  unrecognized guard verdict stands down the whole cycle, worker included.
  A second instance against the same repo refuses to start (exit 75).
  After 3 consecutive phase failures (`WW_PIPELINE_FAIL_LIMIT`) the daemon
  auto-creates `PAUSE` and notifies, instead of retrying forever. Sessions
  run `-s danger-full-access` (they must commit and push). Session
  transcripts land in `<repo>/logs/pipeline/sessions/` clamped to 15-line
  output blocks, pruned to the newest 40; day logs are pruned after 14 days.
- `bin/statusbar.30s.sh` — SwiftBar plugin; reads `projects.conf`, one
  menu bar glyph per project (🟢 working / ⏱ phase running >120 min,
  presumed hung / 🌙 sleeping / ⏸ paused / 🔴 dead-or-stalled /
  ⚪ never run) with a dropdown section each (Pause / Run-now, Model
  picker, resume commands, latest log).
- `models.conf` — the models offered in each project's Model submenu, one
  `<engine>:<model-id> [label]` per line. `codex` entries run `codex exec`,
  `claude` entries run `claude -p`.
- `bin/set-model.sh <repo-root> <engine:model-id>` — writes the selection
  the daemon reads. Refuses ids absent from `models.conf`, since the value
  decides which binary gets executed.
- `launchd/com.dracon.<project>.pipeline.plist` — one LaunchAgent per
  project (`KeepAlive`; restarts on crash).
- `tests/test-pipeline.sh` — daemon contract tests against fixture repos
  with stub guards. Guard *behavior* tests live in each project repo.
- `worktrees/` (gitignored) — per-project worker worktrees, removed when
  clean after each phase.

## A repo qualifies when it has

- `tools/orchestrator-guard.sh` printing `NOTHING TO DO` / `ACTION NEEDED`
  (optionally honoring a `NO VALUABLE WORK AVAILABLE` hold in the latest
  ORCHESTRATOR-NOTES.md entry),
- `tools/worker-preflight.sh` / `tools/worker-lock.sh` (the worker lease),
- `docs/superpowers/plans/*.md` with `- [ ]` task boxes as the queue,
- `logs/` gitignored,
- the shared `worker-run` / `orchestrator-run` skills, installed for every
  engine you intend to select (`~/.codex/skills`, symlinked into
  `~/.claude/skills`).

## Add a project

Run `bin/add-project.sh <repo-root> [bar-label]`. It verifies the repo
qualifies (guard, lease scripts, plans dir, notes file, `logs/` gitignored),
generates the plist into `launchd/`, and registers the project in
`projects.conf` (the menu bar picks it up within 30 s as ⚪). Then two
manual steps, in this order:

1. Pause/disable the project's Codex app automations — the daemon must
   never run alongside them (the worker lease serializes collisions, but
   every collision wastes a session).
2. Copy the generated plist to `~/Library/LaunchAgents/` and
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<plist>`.

`projects.conf` format: one `<repo-root> [bar-label]` per line; the label
appears next to the project's glyph in the menu bar (default: first two
letters of the repo name). The file is untracked (it holds local paths) —
see `projects.conf.example`; `add-project.sh` creates it as needed.

## Operate

- Pause/resume + run-now: menu bar dropdown (flag files
  `logs/pipeline/PAUSE` / `POKE` in the repo).
- Model: menu bar dropdown → Model (flag file `logs/pipeline/MODEL`). The
  daemon re-reads it at the start of every phase, so a switch needs no
  restart and never disturbs a phase already running — it lands on the next
  one. "Reset to codex default" deletes the flag, restoring `codex exec` on
  whatever `~/.codex/config.toml` sets. The choice is per project and covers
  both phases; both engines run unsandboxed (`-s danger-full-access` for
  codex, `--permission-mode bypassPermissions` for claude) because the
  sessions must commit and push. Switching engines only works because
  `orchestrator-run` / `worker-run` are shared skills installed for both
  CLIs (`~/.codex/skills`, symlinked into `~/.claude/skills`).
- Stop/rollback: Pause first, wait for ⏸/🌙, then
  `launchctl bootout gui/$(id -u)/com.dracon.<project>.pipeline` —
  a mid-phase kill murders a live session and can hold the worker
  lease for up to 59 minutes.
- After editing `bin/pipeline.sh`, restart each daemon — `/bin/sh` never
  rereads its own script, so a daemon started before the edit keeps running
  the old code indefinitely and silently ignores anything the change added.
  Pause, wait for ⏸/🌙, then `kill <pid>`; `KeepAlive` relaunches it against
  the new file within seconds. (Flag files like `PAUSE`/`POKE`/`MODEL` are
  read at run time and never need this — only code changes do.)
- Dry run: `WW_PIPELINE_DRY_RUN=1 sh bin/pipeline.sh <repo-root>` — one
  cycle's decisions, no sessions, state isolated to `status-dry.json`.
- Full transcripts: `codex resume <session id>` (ids in the dropdown,
  day log, and capture headers).
