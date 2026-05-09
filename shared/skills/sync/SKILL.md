---
description: Manually sync MCPmarket skills from your workspace
user_invocable: true
---

Run the MCPmarket sync script to pull the latest baseline skills from the server.

Use the Bash tool to run the sync script bundled with this plugin:

```
bash "${MCPMARKET_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT}}}/shared/sync.sh"
```

If none of those variables are set in the current shell, locate `sync.sh` under the plugin's `shared/` folder by other means (e.g. `find`) and run it. Note: Gemini CLI does not set any plugin-root env var on hook processes — when running under Gemini, always fall back to `find` rather than relying on `$1` or an env var.

Report the output to the user.
