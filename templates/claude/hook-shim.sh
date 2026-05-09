#!/usr/bin/env bash
set -euo pipefail
# Map Claude Code env vars to the agent-neutral contract
export MCPMARKET_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:?}"
export MCPMARKET_TOKEN="${CLAUDE_PLUGIN_OPTION_api_token:-}"
export MCPMARKET_TOOLKIT_URL="${CLAUDE_PLUGIN_OPTION_toolkit_url:-}"
export MCPMARKET_API_URL="${CLAUDE_PLUGIN_OPTION_api_url:-}"
exec bash "${MCPMARKET_PLUGIN_ROOT}/shared/sync.sh" "$@"
