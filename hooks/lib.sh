#!/usr/bin/env bash
# shellcheck disable=SC2034  # path constants below are consumed by the sourcing hook scripts
#
# cc-reload shared hook guards. Sourced by every hook script.
#
# Two invariants enforced here for ALL hooks:
#   1. Fail open if jq is missing — we cannot parse hook input safely, so do
#      nothing rather than misbehave. (Sourced `exit 0` exits the caller too.)
#   2. Stand down if a cc-repete loop owns this session — cc-repete owns the
#      context budget / handoff / rehydrate cycle while a loop is active, and
#      cc-reload must never fight it.
#
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RELOAD_DIR="$PROJECT_DIR/.reload"
DIGEST="$RELOAD_DIR/session.md"
PENDING="$RELOAD_DIR/pending"          # arming marker: rehydrate on next SessionStart
SUMMARIZING="$RELOAD_DIR/summarizing"  # transient: budget snapshot turn in progress
CONFIG="$RELOAD_DIR/config"
MODELFILE="$RELOAD_DIR/model"          # model id + resolved window, stamped by SessionStart

command -v jq >/dev/null 2>&1 || exit 0

# Create .reload/ and drop a self-ignoring .gitignore the first time, so a plugin
# user's project never accidentally commits per-session runtime state. A lone "*"
# ignores every file in the dir — including the .gitignore itself — so nothing
# under .reload/ is ever tracked, regardless of the project's own gitignore.
ensure_reload_dir() {
  mkdir -p "$RELOAD_DIR"
  [ -f "$RELOAD_DIR/.gitignore" ] || printf '*\n' > "$RELOAD_DIR/.gitignore"
}

# True when a cc-repete loop is active in this project -> cc-reload stands down.
repete_active() {
  local f="$PROJECT_DIR/.repete/loop.local.md"
  [ -f "$f" ] && grep -qE '^active:[[:space:]]*true[[:space:]]*$' "$f"
}

# Read a "key: value" line from a file (absent -> empty). Strips only the
# surrounding whitespace and a single layer of surrounding quotes, so a string
# value keeps any internal spaces.
kv() {
  [ -f "$2" ] || return 0
  grep -E "^$1:" "$2" | head -1 \
    | sed -E "s/^$1:[[:space:]]*//; s/[[:space:]]+\$//; s/^\"(.*)\"\$/\1/"
}
cfg() { kv "$1" "$CONFIG"; }

# Resolve a model id to its context window in tokens. Current-generation
# main-session models — Opus 4.6/4.7/4.8, Sonnet 4.6, the 5-series (Fable/Mythos/
# Sonnet 5/Opus 5), and any "[1m]" id — ship a 1M window at standard pricing.
# Haiku is a genuine 200K tier, as were the OLDER non-"[1m]" Opus/Sonnet (4.0/4.1/
# 4.5 and Sonnet 4.0/4.5, which offered 1M only behind the "[1m]" beta). Any
# unrecognized id assumes a large 1M window (optimistic — better to checkpoint a
# small session late than nag a large one early). This is a heuristic over
# model-id strings — `context_window` in .reload/config always wins (set it for
# your main model so a new/unrecognized id can't misconfigure the budget). Most
# 200K ids now belong to subagents; the budget targets the main session's window.
model_window() {
  case "$1" in
    *"[1m]"*)                          printf '1000000' ;;   # explicit 1M beta suffix
    *opus-4-6*|*opus-4-7*|*opus-4-8*)  printf '1000000' ;;   # current Opus: 1M at standard pricing
    *sonnet-4-6*)                      printf '1000000' ;;   # Sonnet 4.6: 1M
    *fable-5*|*mythos-5*|*sonnet-5*|*opus-5*) printf '1000000' ;;   # 5-series tiers: 1M
    *opus-4-0*|*opus-4-1*|*opus-4-5*)  printf '200000'  ;;   # older non-[1m] Opus: genuine 200K
    *sonnet-4-0*|*sonnet-4-5*)         printf '200000'  ;;   # older non-[1m] Sonnet: genuine 200K
    *haiku*)                           printf '200000'  ;;   # Haiku tiers: 200K
    *)                                 printf '1000000' ;;   # unrecognized id -> assume large (see stop-hook floor)
  esac
}
