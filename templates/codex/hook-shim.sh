#!/usr/bin/env bash
set -euo pipefail
# Map Codex CLI env vars to the agent-neutral MCPMARKET_* contract.
#
# Codex (unlike Claude Code) has no install-time userConfig prompt, so
# there is no CODEX_PLUGIN_OPTION_* equivalent. Credentials are read
# from the plugin's `.mcp.json` (baked at install time by the curl-pipe
# script) by `shared/sync.sh`, with optional override via pre-set
# MCPMARKET_TOKEN / MCPMARKET_TOOLKIT_URL env vars.
#
# PLUGIN_ROOT is the canonical env var Codex sets for hook scripts (see
# codex-rs/hooks/src/engine/discovery.rs); CLAUDE_PLUGIN_ROOT exists as
# a legacy compatibility alias. We prefer PLUGIN_ROOT so the hook works
# when Codex eventually drops the alias.
export MCPMARKET_PLUGIN_ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:?PLUGIN_ROOT not set}}"
export MCPMARKET_TOKEN="${MCPMARKET_TOKEN:-}"
export MCPMARKET_TOOLKIT_URL="${MCPMARKET_TOOLKIT_URL:-}"
export MCPMARKET_API_URL="${MCPMARKET_API_URL:-}"
exec bash "${MCPMARKET_PLUGIN_ROOT}/shared/sync.sh" "$@"
