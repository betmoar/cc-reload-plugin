#!/usr/bin/env bash
#
# reload-config.sh — safe get/set for .reload/config.
#
# Commands (and the models driving them) call this instead of hand-editing the
# file, so the guardrails live here: only known keys, validated values with
# actionable errors, unrelated keys preserved, .reload/ created with its
# self-ignoring .gitignore, write via temp file + mv so a failed write can't
# leave a half-written config.
#
# Usage:
#   reload-config.sh get <key>                       # prints value; '' if unset
#   reload-config.sh set context_budget_pct <0-95 | off>
#   reload-config.sh set context_window   <tokens >= 1000>
#
# Exit: 0 ok; 2 usage/validation error (message on stderr, config untouched).
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RELOAD_DIR="$PROJECT_DIR/.reload"
CONFIG="$RELOAD_DIR/config"

die(){ printf 'reload-config: %s\n' "$1" >&2; exit 2; }

MODE="${1:-}"; KEY="${2:-}"
case "$MODE" in get|set) ;; *) die "usage: reload-config.sh get|set <key> [value]" ;; esac
case "$KEY" in
  context_budget_pct|context_window) ;;
  *) die "unknown key '$KEY' (known keys: context_budget_pct, context_window)" ;;
esac

if [ "$MODE" = "get" ]; then
  [ -f "$CONFIG" ] || exit 0
  grep -E "^$KEY:" "$CONFIG" | head -1 \
    | sed -E "s/^$KEY:[[:space:]]*//; s/[[:space:]]+\$//; s/^\"(.*)\"\$/\1/"
  exit 0
fi

VAL="${3:-}"
case "$KEY" in
  context_budget_pct)
    [ "$VAL" = "off" ] && VAL=0
    { [[ "$VAL" =~ ^[0-9]+$ ]] && [ "$VAL" -le 95 ]; } \
      || die "context_budget_pct must be 0-95 or 'off' (got '$VAL'); 0 disables the proactive checkpoint"
    ;;
  context_window)
    { [[ "$VAL" =~ ^[0-9]+$ ]] && [ "$VAL" -ge 1000 ]; } \
      || die "context_window must be a token count >= 1000 (got '$VAL'), e.g. 1000000 for a 1M-window model"
    ;;
esac

mkdir -p "$RELOAD_DIR" 2>/dev/null || die "cannot create $RELOAD_DIR"
[ -f "$RELOAD_DIR/.gitignore" ] || printf '*\n' > "$RELOAD_DIR/.gitignore"

TMP="$CONFIG.tmp.$$"
{
  [ -f "$CONFIG" ] && grep -Ev "^$KEY:" "$CONFIG"
  printf '%s: %s\n' "$KEY" "$VAL"
} > "$TMP" 2>/dev/null && mv "$TMP" "$CONFIG" \
  || { rm -f "$TMP"; die "cannot write $CONFIG"; }
printf '%s: %s\n' "$KEY" "$VAL"
