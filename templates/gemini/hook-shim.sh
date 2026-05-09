#!/usr/bin/env bash
set -euo pipefail
# Map Gemini CLI's contract to the agent-neutral MCPMARKET_* contract.
#
# Gemini does NOT set an env var like GEMINI_EXTENSION_ROOT for hook
# processes. Instead, the manifest uses ${extensionPath} string
# substitution at hydration time — it's gone by the time bash runs.
# The hooks.json command passes the resolved extension path as $1, and
# we also fall back to deriving it from this script's own location so
# direct invocation (e.g. from a /sync skill) still works.
#
# MCPMARKET_TOKEN, MCPMARKET_TOOLKIT_URL, and MCPMARKET_API_URL are
# already in the environment thanks to Gemini's `settings` array — they
# pass through unchanged.

if [ "$#" -ge 1 ] && [ -n "$1" ]; then
  PLUGIN_ROOT="$1"
else
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  PLUGIN_ROOT="$SCRIPT_DIR"
fi

export MCPMARKET_PLUGIN_ROOT="$PLUGIN_ROOT"
exec bash "${MCPMARKET_PLUGIN_ROOT}/shared/sync.sh"
