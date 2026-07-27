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

# Best-effort: last assistant turn's total input tokens + model id from the
# transcript, in ONE jq pass — the transcript is tens of MB near budget, and
# this hook runs on every Stop, so it must not be slurped twice. Model ids
# never contain spaces, so "tokens<space>model" splits unambiguously.
LAST_TURN="$(jq -rs '
    [ .[] | select(.message.role=="assistant") ] | last
    | (((.message.usage // {})
        | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)))
       | tostring)
      + " " + (.message.model // "")
  ' "$TRANSCRIPT" 2>/dev/null)"
USED="${LAST_TURN%% *}"
LIVE_MODEL="${LAST_TURN#* }"
if ! [[ "$USED" =~ ^[0-9]+$ ]] || [ "$USED" -le 0 ]; then
  USED=$(( $(wc -c < "$TRANSCRIPT" 2>/dev/null || echo 0) / 4 ))   # fallback estimate
fi

# Refresh model stamp from the transcript so mid-session /model switches are
# detected. The last assistant turn carries the model id that actually ran —
# if it differs from the stamped value, rewrite both model and window so this
# and all future turns compute occupancy against the right window.
if [ -n "$LIVE_MODEL" ]; then
  STAMPED_MODEL="$(kv model "$MODELFILE")"
  if [ "$LIVE_MODEL" != "$STAMPED_MODEL" ]; then
    ensure_reload_dir
    printf 'model: %s\nwindow: %s\n' "$LIVE_MODEL" "$(model_window "$LIVE_MODEL")" > "$MODELFILE"
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

if [ "$MODE" = "snapshot" ] && [ ! -f "$PENDING" ]; then
  # pass 1: block + re-inject a focused snapshot brief (NOT a continuation of work).
  # If the marker cannot be written (read-only dir, .reload is a file, disk full),
  # do NOT block: pass 2 keys off that marker, so blocking without it would make
  # every future Stop re-enter pass 1 — an endless snapshot prompt.
  ensure_reload_dir
  touch "$SUMMARIZING" 2>/dev/null || exit 0
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
