# Status line segment

`scripts/statusline.sh` turns Claude Code's own statusline data into a budget-aware gauge:

```
ctx[1M] 7%·45
   │    │   └ this project's reload budget (% of window), from .reload/config (45 default)
   │    └──── current occupancy (input + cache), coloured GREEN / YELLOW / RED relative to the budget
   └───────── context window: 1M / 200k
```

It is read-only: it never runs the hooks or reads the transcript. Claude Code (≥ 2.1.132) hands the
statusline `context_window.used_percentage` and `context_window_size` on stdin, and the segment
renders those. The window tag is resolved like the Stop hook, not trusted from the payload: a valid
`context_window` override in `.reload/config` wins, then this session's line in `.reload/model`
(so a 1M proxy model does not render as the harness's conservative 200k), then the payload.

It prints nothing early in a session or right after `/compact` (no signal yet), so the slot stays
clean. With the budget disabled (`context_budget_pct: 0`) it drops the `·N` suffix and colours on
absolute thresholds (60% yellow, 85% red).

## Native setup

Point `statusLine` at the script with an **absolute** path (the command runs outside plugin
context, so `${CLAUDE_PLUGIN_ROOT}` is unavailable):

```json
"statusLine": {
  "type": "command",
  "command": "bash /ABS/PATH/TO/cc-reload/scripts/statusline.sh"
}
```

## With a composer

Claude Code allows one `statusLine`. To show this segment beside others you need a composer in that
slot. cc-reload ships the manifest a composer can discover, `.claude-plugin/statusline.json`:

```json
{ "name": "cc-reload", "render": "scripts/statusline.sh", "order": 20 }
```

A composer fans the session JSON to every renderer and joins the non-empty output, so an empty or
errored segment drops out with no dangling separator.
