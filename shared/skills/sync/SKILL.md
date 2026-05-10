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

Report the output to the user.
