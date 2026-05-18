---
description: Manually sync MCPmarket skills from your workspace
user_invocable: true
---

Run the MCPmarket sync script to pull the latest baseline skills from the server.

Use the Bash tool to run the sync script bundled with this plugin:

```
bash "${MCPMARKET_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT}}}/shared/sync.sh"
```

If none of those variables are set, locate `sync.sh` under the plugin's `shared/` folder (e.g. via `find`) and run it. Under Gemini CLI, always fall back to `find` — Gemini does not set a plugin-root env var.

## Interpreting the output

The script prints one of three lines on success and exits 0:

- `MCPmarket sync: N baseline skill(s) synced` — full sync ran; N is the count of skills written or updated this run (not the total in the toolkit).
- `MCPmarket sync: cached (Ns remaining)` — the script short-circuited because a successful sync ran within the last 5 minutes. Tell the user the cache is fresh and that no fetch happened. This is normal — agents and users should not interpret it as a failure.
- `MCPmarket sync: no baseline skills configured` — the toolkit has zero published skills.

On failure paths the script prints `MCPmarket sync: <reason> — ...` to stderr. Surface these to the user verbatim.

## Forcing a fresh sync

When the user explicitly asks to force a re-sync (e.g. they just published a new skill version and want it immediately), delete the cache sentinel before invoking the script:

```
rm -f "${MCPMARKET_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT}}}/.last-sync"
bash "${MCPMARKET_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT}}}/shared/sync.sh"
```

The sentinel file (`.last-sync` in the plugin root) is the only artifact the TTL cache reads — removing it forces the next invocation through the full fetch path. Do not force-sync proactively; only do it when the user has asked for it.

Report the output to the user.
