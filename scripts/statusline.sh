#!/usr/bin/env bash
#
# cc-reload statusline segment — context occupancy vs the reload budget.
#
# Emits ONE compact segment for Claude Code's statusline, e.g.  ctx[1M] 7%·45
#   [1M]   the model's context window size (1M / 200k), from stdin
#   7%     current occupancy (input + cache), pre-calculated by Claude Code
#   ·45    this project's reload budget (% of window) from .reload/config
#
# Data source: the statusLine command receives the live session JSON on stdin
# (Claude Code >= 2.1.132). We read context_window.{used_percentage,
# context_window_size} directly — the SAME input-only occupancy the Stop hook
# computes from the transcript — so this needs no hook to have run and never
# touches the transcript itself. Prints NOTHING (exit 0) when there is no
# context data yet (early session, or right after /compact until the next API
# call) or when jq is unavailable, so the slot stays clean and the composer can
# omit it without a dangling separator.
#
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0

IN="$(cat)"

# Pre-calculated context stats from the statusline stdin schema.
PCT="$(printf '%s' "$IN"  | jq -r '.context_window.used_percentage // empty' 2>/dev/null)"
SIZE="$(printf '%s' "$IN" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)"
PROJ="$(printf '%s' "$IN" | jq -r '.workspace.project_dir // .cwd // empty' 2>/dev/null)"

# No occupancy signal -> render nothing (stable, no flicker of a half-segment).
[ -n "$PCT" ] || exit 0
PCTI="${PCT%%.*}"; [[ "$PCTI" =~ ^[0-9]+$ ]] || exit 0

GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'

# Window-size tag: 1000000 -> 1M, 200000 -> 200k, else <n>k. Omitted if absent.
TAG=""
if [[ "$SIZE" =~ ^[0-9]+$ ]] && [ "$SIZE" -gt 0 ]; then
  if [ "$SIZE" -ge 1000000 ]; then
    if [ $(( SIZE % 1000000 )) -eq 0 ]; then TAG="$(( SIZE / 1000000 ))M"; else TAG="$(awk "BEGIN{printf \"%.1fM\", $SIZE/1000000}")"; fi
  else
    TAG="$(( SIZE / 1000 ))k"
  fi
fi

# Reload budget for this project (default 45; 0 = proactive path disabled).
BUDGET=45
if [ -n "$PROJ" ] && [ -f "$PROJ/.reload/config" ]; then
  b="$(grep -E '^context_budget_pct:' "$PROJ/.reload/config" 2>/dev/null | head -1 \
        | sed -E 's/^context_budget_pct:[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/')"
  [[ "$b" =~ ^[0-9]+$ ]] && BUDGET="$b"
fi

# Color: when a budget is set, grade RELATIVE to it (cc-reload's whole point is
# staying under budget); when disabled, fall back to absolute thresholds.
if [ "$BUDGET" -gt 0 ]; then
  YEL=$(( BUDGET * 2 / 3 ))
  if   [ "$PCTI" -ge "$BUDGET" ]; then C="$RED"
  elif [ "$PCTI" -ge "$YEL"    ]; then C="$YELLOW"
  else                                C="$GREEN"; fi
  SUFFIX="·${BUDGET}"
else
  if   [ "$PCTI" -ge 85 ]; then C="$RED"
  elif [ "$PCTI" -ge 60 ]; then C="$YELLOW"
  else                          C="$GREEN"; fi
  SUFFIX=""   # proactive path off -> no budget marker to compare against
fi

LABEL="ctx"; [ -n "$TAG" ] && LABEL="ctx[${TAG}]"
printf '%s %s%s%%%s%s' "$LABEL" "$C" "$PCTI" "$RESET" "$SUFFIX"
