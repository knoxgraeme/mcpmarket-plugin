---
description: Manually sync MCPmarket skills from your workspace
user_invocable: true
---

Run the MCPmarket sync script to pull the latest baseline skills from the server.

Use the Bash tool to run the sync script bundled with this skill:

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/sync/sync.sh"
```

If that path doesn't resolve in the current shell, locate `sync.sh` in this skill's folder by other means (e.g. `find`) and run it.

Report the output to the user.
