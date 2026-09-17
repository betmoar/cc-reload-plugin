# cc-reload

**Session continuity across context resets for Claude Code.** Before you `/clear`, `/compact`, or
auto-compaction fires, cc-reload snapshots the session's working thread to `.reload/session.md`.
After the reset it puts that thread straight back into the fresh context. An ordinary session
never loses its place.

> Status: **v0.5.0.** Companion to [cc-repete](https://github.com/betmoar/cc-repete-plugin): cc-repete
> owns continuity *inside a mission loop*, cc-reload covers *ordinary sessions* and stands down
> whenever a cc-repete loop is active.

## Install

```
claude plugin marketplace add betmoar/cc-reload-plugin
claude plugin install cc-reload@cc-reload-plugin
```

Needs `bash` and `jq`. `git` and `curl` are optional (repo facts in the digest, cc-proxy windows).

## Sixty seconds

1. Work as usual. A status line tells you when context passes the budget (45% of the window
   by default): `🔔 cc-reload · context ~47% — time to reset: /snapshot then /clear`.
2. Run `/snapshot`. The digest is written and a reload is **armed**.
3. Run `/clear`. The next session starts with a banner (`🔄 cc-reload (clear) — <intent> | → <next step>`)
   and the digest already in its context. Carry on from the next concrete step.

`/compact` and auto-compaction take the same route automatically: a `PreCompact` hook arms the
reload and guarantees *a* digest exists (a thin mechanical one if you never wrote one).

## Commands

| Command | What it does |
| --- | --- |
| `/snapshot [note]` | Write `.reload/session.md` (read-first, carries open questions forward) and arm a reload |
| `/snapshot --check` | Audit the digest: a fresh subagent reads it *alone* and says what it would do next. Writes nothing |
| `/reload` | Rehydrate by hand: five-line sitrep from the digest, plus the last journal entries |
| `/reload-budget <pct\|off\|notify\|snapshot>` | Set the trigger threshold or the escalation mode for this project |

## How it works

Four hooks, one directory of state (`.reload/`, self-ignored by git), no daemon, no network on the
per-turn path.

| Hook | Role |
| --- | --- |
| `Stop` | Measures context occupancy from the transcript every turn. Over budget: nudge (`notify`, default) or force a digest-writing turn (`snapshot` mode) |
| `PreCompact` | Backstop: arms the reload before any compaction, writes a fallback digest if none exists |
| `SessionStart` | Rehydrates when a reload is armed for *this* session's lineage. Reports staleness (commits since, days old) |
| `PreToolUse` | Guards the digest slot: side-files another live session's digest before it is overwritten |

The digest is ~30 lines: `mission` (the original ask, never rewritten), `intent`, and four
sections: *Done this stretch / In flight / Next concrete step / Open questions & risks*. Every
snapshot replaces the last, so it is written read-first.

Details, with the measurement caveats: [`docs/how-it-works.md`](docs/how-it-works.md).

## Two sessions in one directory

Since 0.5.0 two live Claude Code sessions can share a working directory without taking each
other's reload:

- A session only consumes an arm set by **its own process** (a `/clear` keeps the process),
  a pid-less arm, or an **orphan** whose process has exited (the quit-and-restart case).
- An arm set by **another live session is left in place**, with a one-line notice. The new
  session starts fresh; `/reload` pulls the other digest in on purpose.
- When both sessions snapshot, the digest slot is side-filed rather than lost, and each
  session's `/clear` gets **its own** thread back.
- `.reload/journal` records every snapshot, arm, side-file and rehydrate with time, session id
  and process id, so "who snapshotted, and when?" has an answer.

Limits and the exact rules: [`docs/concurrent-sessions.md`](docs/concurrent-sessions.md).

## Configuration

`.reload/config` (per project, all optional; `/reload-budget` writes it for you):

```
context_budget_pct: 45       # act at this % of the window. 0 = off. Default 45.
context_budget_mode: notify  # notify (default: nudge, never blocks) | snapshot (automated digest turn)
context_window: 1000000      # AUTHORITATIVE window override in tokens. Set this for your main model.
```

| Key | Default | Meaning |
| --- | --- | --- |
| `context_budget_pct` | `45` | Trigger threshold as % of the window. `0`/`off` disables the proactive path. Lower it for reasoning-heavy work (`/reload-budget 30`) |
| `context_budget_mode` | `notify` | `notify`: one laddered status line, zero model tokens. `snapshot`: a forced digest turn, then a request to `/clear` (`checkpoint` still accepted) |
| `context_window` | auto | Pins the window in tokens and wins over detection. Set it once for your main model |
| `context_owner_window` | `14400` | Seconds within which another session's digest counts as live and is side-filed before an overwrite. `0`/`off` disables |

Trailing `# comments` are allowed on any line.

## Status line

`scripts/statusline.sh` renders `ctx[1M] 7%·45` (window, occupancy coloured against the budget,
budget) from Claude Code's own statusline data. Read-only, never touches the transcript. Setup
and the composer manifest: [`docs/statusline.md`](docs/statusline.md).

## Known limitations

- **Occupancy is best-effort.** The transcript's per-turn `usage` field is undocumented; if it
  disappears the hook falls back to a byte estimate that errs early.
- **`CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` are undocumented** Claude Code variables (measured
  on 2.1.274). Without them the plugin degrades to a single shared arm and un-owned digests,
  exactly the pre-0.5 behaviour.
- **The digest guard covers `Write`/`Edit`.** A digest written through a Bash heredoc bypasses it.
- **Hook output is capped at 10,000 characters** by Claude Code. A larger digest is injected
  anyway, and the banner warns that Claude may have received a preview; `/reload` reads the file.
- **`summarizing`, `notified` and the legacy `model:` pair** remain shared between sessions in one
  directory. Their collisions are cosmetic (an extra nudge, a deferred snapshot turn).

## Layout

```
hooks/        hooks.json + lib.sh + the four hook scripts
scripts/      arm-reload.sh, claim-digest.sh, context-block.sh, reload-config.sh, statusline.sh
commands/     /snapshot, /reload, /reload-budget
skills/       maintaining-session-continuity (judgment for using the plugin)
templates/    session.md — the digest's source of truth
tests/        run-all.sh is THE gate (what CI runs); one suite per hook/script + e2e + concurrent
docs/         how-it-works, concurrent-sessions, statusline
CLAUDE.md     maintainer handoff: invariants, couplings, playbooks
```

MIT — see [`LICENSE`](LICENSE).
