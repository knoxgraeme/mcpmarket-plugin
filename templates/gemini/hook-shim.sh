#!/usr/bin/env bash
# Maps Gemini CLI's contract onto the agent-neutral MCPMARKET_* contract,
# then runs shared/sync.sh.
#
# Gemini sets no plugin-root env var on hook processes — it passes the
# resolved path as $1 (via `${extensionPath}` in hooks.json). Fall back
# to deriving from this script's location for direct invocation.
# MCPMARKET_TOKEN / MCPMARKET_TOOLKIT_URL / MCPMARKET_API_URL come from
# Gemini's settings system and pass through unchanged.
set -euo pipefail

if [ "$#" -ge 1 ] && [ -n "$1" ]; then
  PLUGIN_ROOT="$1"
else
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  PLUGIN_ROOT="$SCRIPT_DIR"
fi

export MCPMARKET_PLUGIN_ROOT="$PLUGIN_ROOT"
exec bash "${MCPMARKET_PLUGIN_ROOT}/shared/sync.sh"
