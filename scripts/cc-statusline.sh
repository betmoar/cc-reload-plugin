#!/usr/bin/env bash
#
# Composed statusline: cc-proxy quota gauges  +  cc-reload context segment.
#
# Wire this as the single statusLine command in ~/.claude/settings.json:
#   "statusLine": { "type": "command",
#     "command": "bash /ABS/PATH/cc-reload-plugin/scripts/cc-statusline.sh" }
#
# Claude Code allows exactly one statusLine, so to show both plugins something
# has to COMPOSE them. This reads the session JSON from stdin once, hands the
# same bytes to each renderer, and joins their non-empty output with " | ".
# Either renderer missing/empty is fine — the bar degrades to whatever is left.
#
# cc-proxy is located via $PROXY_PATH (set by cc-proxy's own setup), so this
# auto-follows cc-proxy version bumps without editing settings.json. cc-reload's
# segment lives next to this file.
#
# Self-relocation: when this copy lives in the versioned plugin cache
# (.../cc-reload/<ver>/scripts), re-exec the composer from the NEWEST installed
# cc-reload version. That makes a version-pinned settings.json path
# (".../cc-reload/0.1.5/scripts/cc-statusline.sh") keep tracking new installs
# without ever editing settings.json again. A checkout OUTSIDE the cache (your
# dev tree) is left alone — you chose that path deliberately, so we never
# redirect away from it.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$HERE" in
  */.claude/plugins/cache/*/cc-reload/*/scripts)
    CACHE_ROOT="${HERE%/cc-reload/*}"   # .../<owner> dir holding cc-reload/<ver>
    NEWEST="$(ls -d "$CACHE_ROOT"/cc-reload/*/scripts/cc-statusline.sh 2>/dev/null | sort -V | tail -1)"
    # Only hand off to a DIFFERENT, readable file — never re-exec ourselves (loop).
    if [ -n "$NEWEST" ] && [ "$NEWEST" != "$HERE/cc-statusline.sh" ] && [ -f "$NEWEST" ]; then
      exec bash "$NEWEST"
    fi
    ;;
esac

IN="$(cat)"

# --- cc-proxy segment (quota / credits / proxy-liveness) ---------------------
# Derive the proxy dir from PROXY_PATH (.../cc-proxy/<ver>/bin/cc-proxy.js ->
# .../cc-proxy/<ver>); fall back to the newest cached version if unset.
PROXY_OUT=""
PROXY_SL=""
if [ -n "${PROXY_PATH:-}" ]; then
  cand="$(dirname "$(dirname "$PROXY_PATH")")/scripts/statusline.js"
  [ -f "$cand" ] && PROXY_SL="$cand"
fi
if [ -z "$PROXY_SL" ]; then
  cand="$(ls -d "$HOME"/.claude/plugins/cache/*/cc-proxy/*/scripts/statusline.js 2>/dev/null | sort -V | tail -1)"
  [ -n "$cand" ] && [ -f "$cand" ] && PROXY_SL="$cand"
fi
if [ -n "$PROXY_SL" ] && command -v node >/dev/null 2>&1; then
  PROXY_OUT="$(printf '%s' "$IN" | node "$PROXY_SL" 2>/dev/null)"
fi

# --- cc-reload segment (context occupancy vs budget) -------------------------
RELOAD_OUT="$(printf '%s' "$IN" | bash "$HERE/statusline.sh" 2>/dev/null)"

# --- join non-empty parts with " | " -----------------------------------------
OUT=""
for part in "$PROXY_OUT" "$RELOAD_OUT"; do
  [ -n "$part" ] || continue
  if [ -z "$OUT" ]; then OUT="$part"; else OUT="$OUT | $part"; fi
done
printf '%s' "$OUT"
