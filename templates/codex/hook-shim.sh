#!/usr/bin/env bash
# Maps Codex CLI env vars onto the agent-neutral MCPMARKET_* contract,
# then runs shared/sync.sh.
set -euo pipefail
# PLUGIN_ROOT is canonical; CLAUDE_PLUGIN_ROOT is a legacy alias.
export MCPMARKET_PLUGIN_ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:?PLUGIN_ROOT not set}}"
export MCPMARKET_TOKEN="${MCPMARKET_TOKEN:-}"
export MCPMARKET_TOOLKIT_URL="${MCPMARKET_TOOLKIT_URL:-}"
export MCPMARKET_API_URL="${MCPMARKET_API_URL:-}"
exec bash "${MCPMARKET_PLUGIN_ROOT}/shared/sync.sh" "$@"
