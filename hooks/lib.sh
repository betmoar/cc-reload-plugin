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

# Resolve a model id to its context window in tokens. The "[1m]" suffix and the
# 1M-context tiers (e.g. Sonnet 5) select the 1M window; otherwise 200K. This is
# a heuristic over model-id strings — `context_window` in .reload/config always
# wins (set it for your main model so a new/unrecognized id can't misconfigure
# the budget). Most 200K ids now belong to subagents; the budget targets the
# main session's window.
model_window() {
  case "$1" in
    *"[1m]"*)   printf '1000000' ;;
    *sonnet-5*) printf '1000000' ;;   # Sonnet 5 ships with a 1M window
    *opus-4*)   printf '200000'  ;;
    *)          printf '200000'  ;;
  esac
}
