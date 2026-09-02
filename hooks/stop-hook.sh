#!/usr/bin/env bash
#
# cc-reload Stop hook — PRIMARY path: proactive reset before context rot.
#
# Goal: keep manual sessions well under the auto-compact threshold (stay ~45% of
# the window, lower per task). When occupancy crosses context_budget_pct, the
# behavior is set by context_budget_mode:
#
#   notify (DEFAULT)  -> emit a one-line systemMessage nudging the user to run
#       /snapshot + /clear (or adjust /reload-budget). No block, no forced model
#       turn, zero model tokens. Escalation-laddered via .reload/notified: first
#       crossing notifies, then again only when occupancy grows ≥10 points;
#       dropping back under budget resets the ladder.
#
#   snapshot          -> the two-pass automated snapshot (accepts the legacy
#                        value `checkpoint` as an alias):
#   pass 1 (over budget)         -> block + re-inject "write .reload/session.md, then STOP"
#   pass 2 (.reload/summarizing) -> digest written -> arm a reload + yield for /clear
#       Pass 1 is additionally gated on the arm: once .reload/pending exists (pass 2
#       done, or a manual /snapshot), further over-budget Stops get the laddered
#       reminder instead of another forced snapshot turn — re-blocking every turn
#       until the user /clears was the invasive failure mode this gate removes.
#
# Occupancy signal: the LAST assistant turn's input tokens (input + cache_read +
# cache_creation) ≈ the full context sent that turn, INCLUDING system prompt and
# tools. That usage object lives in the transcript JSONL. It is NOT an officially
# documented schema, so this is best-effort: if it's missing we fall back to a
# byte/4 estimate (which over-counts → triggers earlier → safer for "never
# auto-compact"). Window size comes from .reload/model (stamped by SessionStart).
#
source "$(dirname "$0")/lib.sh"
repete_active && exit 0

HOOK_INPUT="$(cat)"

# This session's id, for arm ownership (spec §4.2.3). Stop's payload carries
# session_id; the transcript filename IS the session id (verified), so its
# basename is an equivalent fallback if the field is ever absent. Parsed HERE,
# before pass 2, because pass 2 must not depend on the transcript being readable.
SESSION_ID="$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)"
if [ -z "$SESSION_ID" ]; then
  _tp="$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)"
  [ -n "$_tp" ] && SESSION_ID="$(basename "$_tp" .jsonl)"
fi

# pass 2: a snapshot turn just ran (the summarizing marker is set).
# Complete the cycle here — arm the reload and yield — BEFORE any budget or
# transcript gating. Pass 1 already committed us to a reset, so this must not
# depend on the budget still being enabled or the transcript still being
# readable: disabling the budget (context_budget_pct: 0) or an unreadable
# transcript mid-snapshot must never strand the marker or leave the reload
# un-armed. This is the one path that truly always completes.
if [ -f "$SUMMARIZING" ]; then
  ensure_reload_dir
  # Freshness check BEFORE consuming the marker: the digest is "fresh" only if
  # it was (re)written after pass 1 set the marker. A snapshot turn that never
  # touched session.md must not be reported as "digest saved" — but an existing
  # stale digest is still armed (same floor PreCompact provides), just honestly.
  FRESH=""
  [ -f "$DIGEST" ] && [ "$DIGEST" -nt "$SUMMARIZING" ] && FRESH=1
  rm -f "$SUMMARIZING"
  if [ -f "$DIGEST" ]; then
    # Stamp the arm's owner when we have one. When we do NOT, fall back to the
    # literal `touch` rather than writing an empty file: an empty arm must keep
    # meaning exactly what it means today (a pre-0.3 / un-owned arm), or the
    # unknown-id case silently becomes the new default and the ownership tests
    # would be asserting the fallback rather than the feature.
    if [ -n "$SESSION_ID" ]; then
      printf '%s' "$SESSION_ID" > "$PENDING" 2>/dev/null || touch "$PENDING" 2>/dev/null
    else
      touch "$PENDING" 2>/dev/null
    fi
    # Verify the arm the way SessionStart reads it (-f). `printf >` fails and
    # `touch` "succeeds" on a directory; claiming "reload armed" over an arm
    # that can never rehydrate is the silent-wrong shape (audit 2026-09-02 F05).
    if [ ! -f "$PENDING" ]; then
      jq -n --arg m "⚠️ cc-reload: could not write the arm marker (.reload/pending is not a writable regular file) — reload NOT armed. Remove whatever is at .reload/pending, then run /snapshot before you /clear." \
        '{systemMessage:$m}'
      exit 0
    fi
    if [ -n "$FRESH" ]; then
      jq -n --arg m "🧹 cc-reload: session digest saved to .reload/session.md and reload armed. Run /clear (or /compact) — it rehydrates automatically (you'll see a '🔄 restored' line; run /reload for the full sitrep)." \
        '{systemMessage:$m}'
    else
      jq -n --arg m "⚠️ cc-reload: the snapshot turn did NOT refresh .reload/session.md — armed the existing (possibly stale) digest as a floor. Run /snapshot to write a fresh one before you /clear." \
        '{systemMessage:$m}'
    fi
  else
    # The snapshot turn ended with no digest on disk (never written, or deleted
    # mid-snapshot). Don't arm an empty reload — SessionStart would just un-arm
    # it on the next start — and say so plainly so the user can recover.
    jq -n --arg m "⚠️ cc-reload: no .reload/session.md found — reload NOT armed. Run /snapshot to capture this session before you /clear." \
      '{systemMessage:$m}'
  fi
  exit 0
fi

# --- pass 1: detect when occupancy crosses the budget ---

# Loop guard: stop_hook_active means this turn is ALREADY a continuation forced
# by a Stop hook. Reaching here with it set means the pass-1/pass-2 marker
# handshake broke (marker unwritable or deleted mid-cycle) — blocking again
# would re-prompt the snapshot forever. Stand down; the budget re-triggers
# cleanly on the next ordinary Stop.
STOP_ACTIVE="$(printf '%s' "$HOOK_INPUT" | jq -r '.stop_hook_active // false')"
[ "$STOP_ACTIVE" = "true" ] && exit 0

# Budget as a % of the window (default 45). 0 disables the proactive path.
PCT="$(cfg context_budget_pct)"; [[ "$PCT" =~ ^[0-9]+$ ]] || PCT=45
[ "$PCT" -gt 0 ] || exit 0

TRANSCRIPT="$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // ""')"
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

# Best-effort: the last MAIN-THREAD assistant turn's total input tokens + model
# id from the transcript. Model ids never contain spaces, so "tokens<space>model"
# splits unambiguously.
#
# The scan program is defined ONCE and used by both reads below (audit
# 2026-09-02 F01/F02/F03 — the three defects were one `jq -rs` slurp):
#   * per-line `fromjson? | objects` — a truncated/partial line, or a row whose
#     `message` is not an object, is SKIPPED; the old slurp aborted the whole
#     parse on one such line and silently fell back to the byte/4 estimate
#     (3MB of transcript read as "~75%" where usage was 10%).
#   * `.isSidechain != true` — subagent rows are not the main thread. Older
#     Claude Code versions append them to the main transcript (cc-repete measured
#     "500 trailing sidechain lines"); current ones write subagents/*.jsonl. A
#     subagent's small usage under-reported occupancy (no nudge while the main
#     thread was over budget) AND its model restamped .reload/model — a haiku
#     subagent stamped 200K, which on a [1m]-alias session permanently stripped
#     the invariant-5 shield. `!= true` keeps rows where the field is absent/null.
#   * one "tokens model" line per matching row; the caller keeps the LAST.
TURN_SCAN_JQ='fromjson? | objects
  | select((.message|type)=="object" and .message.role=="assistant" and .isSidechain != true)
  | ((((.message.usage // {})
        | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)))
       | tostring)
     + " " + (.message.model // ""))'

# Read a tail WINDOW first, the whole file only if the window holds no
# main-thread assistant row. The transcript is tens of MB near budget and this
# runs on every Stop: the slurp measured 2.2s / 275MB RSS on 57MB (over the ~1s
# budget), a full-file stream 0.85s, the window 0.03s. A tail window is a
# SUFFIX, so any main-thread row it contains is necessarily the file's last one
# — the answer is identical to a full read. 2000 lines covers the documented
# 500-sidechain-line hazard 4x; when even that is exceeded the fallback keeps
# the answer correct at the old cost. jq reads tail's stdin on the window path
# (never the path, never a slurp flag — the test pins that by invocation).
WINDOW_LINES=2000
LAST_TURN="$(tail -n "$WINDOW_LINES" "$TRANSCRIPT" 2>/dev/null | jq -rR "$TURN_SCAN_JQ" 2>/dev/null | tail -n 1)"
if [ -z "$LAST_TURN" ]; then
  LAST_TURN="$(jq -rR "$TURN_SCAN_JQ" "$TRANSCRIPT" 2>/dev/null | tail -n 1)"
fi
USED="${LAST_TURN%% *}"
LIVE_MODEL="${LAST_TURN#* }"
[ "$LIVE_MODEL" = "$LAST_TURN" ] && LIVE_MODEL=""   # no space at all -> no model field
if ! [[ "$USED" =~ ^[0-9]+$ ]] || [ "$USED" -le 0 ]; then
  USED=$(( $(wc -c < "$TRANSCRIPT" 2>/dev/null || echo 0) / 4 ))   # fallback estimate
fi

# Refresh model stamp from the transcript so mid-session /model switches are
# detected. The last assistant turn carries the model id that actually ran —
# if it differs from the stamped value, rewrite both model and window so this
# and all future turns compute occupancy against the right window.
#
# EXCEPT: the transcript id is LOSSY w.r.t. the "[1m]" alias. A session
# configured as e.g. `claude-sonnet-4-5[1m]` (or the alias form `sonnet[1m]`)
# runs with a 1M window, but message.model carries only the bare API id
# (`claude-sonnet-4-5-…`), which model_window() maps to the 200K base — so a
# naive restamp would downgrade the window 5x and nag from ~9% real occupancy.
# If the stamped model is a "[1m]" form of the SAME model (its base name
# appears in the live id), keep the stamp; a genuine /model switch to a
# different family still restamps because the base no longer matches.
#
# The base match is BOUNDARY-ANCHORED, for the reason invariant 6 anchors
# model_window(): claude-sonnet-4-5 is a literal prefix of a future
# claude-sonnet-4-50, and a bare *"$BASE"* would shield that genuinely
# different model — pinning a stale [1m] stamp and its window forever, the
# mirror image of the F05 downgrade this shield exists to prevent. A model id
# segment ends at the id's end or at a "-", so both forms the stamp can take
# are covered: a full id (claude-sonnet-4-5, a PREFIX of the live id) and an
# alias (sonnet, which appears MID-id in claude-sonnet-4-5-…). Hence the
# leading *"$BASE" rather than an exact prefix match.
if [ -n "$LIVE_MODEL" ]; then
  STAMPED_MODEL="$(kv model "$MODELFILE")"
  if [ "$LIVE_MODEL" != "$STAMPED_MODEL" ]; then
    RESTAMP=1
    case "$STAMPED_MODEL" in
      *"[1m]"*)
        BASE="${STAMPED_MODEL%%\[*}"   # claude-sonnet-4-5[1m] -> claude-sonnet-4-5; sonnet[1m] -> sonnet
        if [ -n "$BASE" ]; then
          case "$LIVE_MODEL" in *"$BASE"|*"$BASE"-*) RESTAMP="" ;; esac
        fi
        ;;
    esac
    if [ -n "$RESTAMP" ]; then
      ensure_reload_dir
      printf 'model: %s\nwindow: %s\n' "$LIVE_MODEL" "$(model_window "$LIVE_MODEL")" > "$MODELFILE"
    fi
  fi
fi

# Window: a VALID positive context_window override wins (set it for your main
# model); else the value stamped from the live model; else assume a large 1M
# window. The floor is deliberately optimistic: an entirely-unknown window must
# not nag a 1M session early. Validate the override ONCE (CW): a non-positive or
# garbage value is treated as absent — so it can't divide by zero below, and (key
# for the self-heal) it isn't mistaken for a real pin.
CW="$(cfg context_window)"; { [[ "$CW" =~ ^[0-9]+$ ]] && [ "$CW" -gt 0 ]; } || CW=""
WINDOW="$CW"; [[ "$WINDOW" =~ ^[0-9]+$ ]] || WINDOW="$(kv window "$MODELFILE")"
{ [[ "$WINDOW" =~ ^[0-9]+$ ]] && [ "$WINDOW" -gt 0 ]; } || WINDOW=1000000

# Auto-correct upward from observed usage (unless a VALID window is pinned): a
# session that has already processed >200K tokens cannot be on a 200K window, so
# a stale/unrecognized 200K guess for a large-context model self-heals here. Keyed
# on the validated CW so an invalid override (e.g. 0) doesn't disable this.
if [ -z "$CW" ] && [ "$USED" -gt 200000 ] && [ "$WINDOW" -lt 1000000 ]; then
  WINDOW=1000000
fi

OCCUPANCY=$(( USED * 100 / WINDOW ))
if [ "$OCCUPANCY" -lt "$PCT" ]; then
  # Back under budget (bigger window detected, budget raised, or a reset): reset
  # the notify ladder so the NEXT crossing announces itself from scratch.
  rm -f "$NOTIFIED" 2>/dev/null
  exit 0
fi

# --- over budget: mode decides how hard to escalate ---
# `snapshot` is canonical; `checkpoint` is the pre-0.2.0 alias (a config written
# before the rename may still hold it). Anything else falls back to notify.
MODE="$(cfg context_budget_mode)"
case "$MODE" in snapshot|checkpoint) MODE="snapshot" ;; *) MODE="notify" ;; esac

# The arm gate is `-e`, not `-f`: ANY entry at .reload/pending suppresses a
# re-block (fail-open). A directory there can never hold an arm, but treating it
# as "not armed" re-entered pass 1 on every over-budget Stop (audit 2026-09-02
# F05); SessionStart's rehydrate gate stays `-f` — a non-file arm rehydrates
# nothing, and pass 2 / PreCompact say so when they cannot write one.
if [ "$MODE" = "snapshot" ] && [ ! -e "$PENDING" ]; then
  # pass 1: block + re-inject a focused snapshot brief (NOT a continuation of work).
  # If the marker cannot be written (read-only dir, .reload is a file, disk full),
  # do NOT block: pass 2 keys off that marker, so blocking without it would make
  # every future Stop re-enter pass 1 — an endless snapshot prompt.
  # The write is VERIFIED with -f, the test every reader uses: `touch` succeeds
  # on a directory, which -f then never matches and `rm -f` never removes, so
  # a stray `mkdir .reload/summarizing` blocked EVERY ordinary Stop (measured
  # 3/3; audit 2026-09-02 F05). Invariant 2: never block without the marker.
  ensure_reload_dir
  { touch "$SUMMARIZING" 2>/dev/null && [ -f "$SUMMARIZING" ]; } || exit 0
  REINJECT='--- cc-reload context snapshot: write a session digest, then STOP ---
Context is ~'"$OCCUPANCY"'% of the window (budget '"$PCT"'%). Reset before rot sets in. Capture the working thread so the next session resumes losslessly.

Write .reload/session.md (overwrite it), tight — under ~30 lines — with frontmatter and four sections:
  ---
  session_id: "<run: echo "$CLAUDE_CODE_SESSION_ID" — paste that value; if empty, use an empty string>"
  updated_at: "<ISO8601>"
  intent: "<one line: what this session is doing>"
  ---
  ## Done this stretch
  ## In flight
  ## Next concrete step
  ## Open questions & risks

Write durable artifacts to their normal homes too (commits, notes). Then STOP. Do NOT continue the work.'
  jq -n --arg r "$REINJECT" --arg m "🧹 cc-reload · context ~${OCCUPANCY}% — saving session digest before /clear" \
    '{decision:"block", reason:$r, systemMessage:$m}'
  exit 0
fi

# Notify path — notify mode, or snapshot mode with the reload already armed.
# systemMessage only: user-facing, zero model tokens, never blocks. Laddered so
# it fires on the first crossing and then only every ≥10 further points; if the
# ladder file can't be written we'd nag on every Stop, so fail open and silent
# instead (same philosophy as refusing to block without the marker).
LASTN="$(cat "$NOTIFIED" 2>/dev/null)"; [[ "$LASTN" =~ ^[0-9]+$ ]] || LASTN=""
if [ -n "$LASTN" ] && [ "$OCCUPANCY" -lt $(( LASTN + 10 )) ]; then
  exit 0
fi
ensure_reload_dir
printf '%s\n' "$OCCUPANCY" > "$NOTIFIED" 2>/dev/null || exit 0
if [ -f "$PENDING" ]; then
  MSG="🔔 cc-reload · context ~${OCCUPANCY}% (budget ${PCT}%) — reload armed. Run /clear to reset losslessly; run /snapshot first if you've done more work since the last digest."
else
  MSG="🔔 cc-reload · context ~${OCCUPANCY}% (budget ${PCT}%) — time to reset: /snapshot then /clear (auto-rehydrates), or /reload-budget <pct|off> to adjust."
fi
jq -n --arg m "$MSG" '{systemMessage:$m}'
exit 0
