#!/usr/bin/env bash
#
# cc-reload Stop hook — PRIMARY path: proactive reset before context rot.
#
# Goal: keep manual sessions well under the auto-compact threshold (stay ~45% of
# the window, lower per task). When occupancy crosses context_budget_pct, do a
# two-step checkpoint so you /clear long before auto-compaction would ever fire:
#   pass 1 (over budget)         -> block + re-inject "write .reload/session.md, then STOP"
#   pass 2 (.reload/summarizing) -> digest written -> arm a reload + yield for /clear
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

# pass 2: a checkpoint snapshot turn just ran (the summarizing marker is set).
# Complete the cycle here — arm the reload and yield — BEFORE any budget or
# transcript gating. Pass 1 already committed us to a reset, so this must not
# depend on the budget still being enabled or the transcript still being
# readable: disabling the budget (context_budget_pct: 0) or an unreadable
# transcript mid-checkpoint must never strand the marker or leave the reload
# un-armed. This is the one path that truly always completes.
if [ -f "$SUMMARIZING" ]; then
  ensure_reload_dir
  rm -f "$SUMMARIZING"
  if [ -f "$DIGEST" ]; then
    touch "$PENDING"
    jq -n --arg m "🧹 cc-reload: session digest saved to .reload/session.md and reload armed. Run /clear (or /compact) — it rehydrates automatically (you'll see a '🔄 restored' line; run /reload for the full sitrep)." \
      '{systemMessage:$m}'
  else
    # The checkpoint turn ended with no digest on disk (never written, or deleted
    # mid-checkpoint). Don't arm an empty reload — SessionStart would just un-arm
    # it on the next start — and say so plainly so the user can recover.
    jq -n --arg m "⚠️ cc-reload: no .reload/session.md found — reload NOT armed. Run /checkpoint to capture this session before you /clear." \
      '{systemMessage:$m}'
  fi
  exit 0
fi

# --- pass 1: detect when occupancy crosses the budget ---

# Budget as a % of the window (default 45). 0 disables the proactive path.
PCT="$(cfg context_budget_pct)"; [[ "$PCT" =~ ^[0-9]+$ ]] || PCT=45
[ "$PCT" -gt 0 ] || exit 0

TRANSCRIPT="$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // ""')"
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

# Window: config override wins (set it for your main model), else the value
# SessionStart stamped from the live model, else assume a large 1M window. The
# floor is deliberately optimistic: when the window is entirely unknown (no
# override, no stamp yet) a 1M session must not be nagged early, so we prefer a
# late checkpoint over a false-early one. The >200K-used self-heal below still
# rescues a stale *low* stamp.
WINDOW="$(cfg context_window)"; [[ "$WINDOW" =~ ^[0-9]+$ ]] || WINDOW="$(kv window "$MODELFILE")"
[[ "$WINDOW" =~ ^[0-9]+$ ]] || WINDOW=1000000

# Best-effort: last assistant turn's total input tokens from the transcript.
USED="$(jq -rs '
    [ .[] | select(.message.role=="assistant") ] | last
    | (.message.usage // {})
    | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
  ' "$TRANSCRIPT" 2>/dev/null)"
if ! [[ "$USED" =~ ^[0-9]+$ ]] || [ "$USED" -le 0 ]; then
  USED=$(( $(wc -c < "$TRANSCRIPT" 2>/dev/null || echo 0) / 4 ))   # fallback estimate
fi

# Auto-correct upward from observed usage (unless the window is pinned in config):
# a session that has already processed >200K tokens cannot be on a 200K window, so
# a stale/unrecognized 200K guess for a large-context model self-heals here. This
# is the safe direction — it only ever *raises* the window (lowers occupancy), so
# it can't cause a premature reset; it just stops one.
if [ -z "$(cfg context_window)" ] && [ "$USED" -gt 200000 ] && [ "$WINDOW" -lt 1000000 ]; then
  WINDOW=1000000
fi

OCCUPANCY=$(( USED * 100 / WINDOW ))
[ "$OCCUPANCY" -ge "$PCT" ] || exit 0

# pass 1: block + re-inject a focused snapshot brief (NOT a continuation of work).
ensure_reload_dir
touch "$SUMMARIZING"
REINJECT='--- cc-reload context checkpoint: write a session digest, then STOP ---
Context is ~'"$OCCUPANCY"'% of the window (budget '"$PCT"'%). Reset before rot sets in. Capture the working thread so the next session resumes losslessly.

Write .reload/session.md (overwrite it), tight — under ~30 lines — with frontmatter and four sections:
  ---
  session_id: "<this session id, if known; else omit>"
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
