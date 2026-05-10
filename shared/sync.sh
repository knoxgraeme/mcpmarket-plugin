#!/usr/bin/env bash
# MCPmarket baseline skill sync (agent-neutral).
# Run by an agent's SessionStart hook (via the agent's hook-shim) to
# fetch baseline skills for the configured toolkit.
#
# Reads only:
#   MCPMARKET_PLUGIN_ROOT  (required) plugin install dir
#   MCPMARKET_TOKEN        bearer token; falls back to .mcp.json
#   MCPMARKET_TOOLKIT_URL  toolkit MCP URL; falls back to .mcp.json
#   MCPMARKET_API_URL      API base URL override (allowlisted)
#   MCPMARKET_SKILLS_DIR   skills dir; default $PLUGIN_ROOT/skills

set -euo pipefail

MCPMARKET_SYNC_VERSION="0.2.0"
USER_AGENT="mcpmarket-sync/${MCPMARKET_SYNC_VERSION}"

# Split-literal guard: do NOT collapse to a bare placeholder. The split
# prevents the build-time substitution from rewriting this comparison
# along with the assignment above, so unbaked (curl-pipe) installs still
# detect the placeholder and zero the value.
MCPMARKET_CLIENT="__MCPMARKET_CLIENT__"
if [ "$MCPMARKET_CLIENT" = "__MCPMARKET""_CLIENT__" ]; then
  MCPMARKET_CLIENT=""
fi

# Fall back to deriving plugin root from this script's location so
# direct invocation (e.g. via /sync) works without env vars.
PLUGIN_ROOT="${MCPMARKET_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
fi

if ! command -v jq &>/dev/null; then
  echo "MCPmarket sync: jq not installed — skipping sync" >&2
  exit 0
fi

if [ -n "$PLUGIN_ROOT" ] && [ -f "$PLUGIN_ROOT/.mcp.json" ]; then
  MCP_CONFIG="$PLUGIN_ROOT/.mcp.json"
  TOOLKIT_URL="${MCPMARKET_TOOLKIT_URL:-$(jq -r '.mcpServers.mcpmarket.url // empty' "$MCP_CONFIG")}"
  # Codex uses `http_headers`; Claude uses `headers`. Try both.
  BEARER=$(jq -r '.mcpServers.mcpmarket.http_headers.Authorization // .mcpServers.mcpmarket.headers.Authorization // empty' "$MCP_CONFIG")
  API_TOKEN="${MCPMARKET_TOKEN:-${BEARER#Bearer }}"

  if [ -z "$TOOLKIT_URL" ] || [ -z "$API_TOKEN" ]; then
    echo "MCPmarket sync: .mcp.json present but credentials unreadable — skipping sync" >&2
    exit 0
  fi
else
  TOOLKIT_URL="${MCPMARKET_TOOLKIT_URL:-}"
  API_TOKEN="${MCPMARKET_TOKEN:-}"
fi

API_BASE_URL="${MCPMARKET_API_URL:-https://app.mcpmarket.com}"

# Allowlist API base URL — prevents token exfiltration if a user is
# tricked into pointing MCPMARKET_API_URL at an attacker host.
case "$API_BASE_URL" in
  https://app.mcpmarket.com|https://app.mcpmarket.com/*) ;;
  https://*.mcpmarket.com|https://*.mcpmarket.com/*) ;;
  http://localhost:*|http://127.0.0.1:*) ;;
  *)
    echo "MCPmarket sync: api_url '$API_BASE_URL' not in allowlist — skipping sync" >&2
    exit 0
    ;;
esac

if [ -z "$TOOLKIT_URL" ] || [ -z "$API_TOKEN" ] || [ -z "$PLUGIN_ROOT" ]; then
  echo "MCPmarket sync: missing configuration — skipping sync" >&2
  exit 0
fi

# Toolkit URL format: https://gateway.example.com/{orgSlug}/toolkits/{toolkitSlug}/mcp
URL_PATH=$(echo "$TOOLKIT_URL" | sed -E 's|https?://[^/]*/||; s|/mcp$||')
ORG_SLUG=$(echo "$URL_PATH" | cut -d'/' -f1)
TOOLKIT_SLUG=$(echo "$URL_PATH" | cut -d'/' -f3)

if [ -z "$ORG_SLUG" ] || [ -z "$TOOLKIT_SLUG" ]; then
  echo "MCPmarket sync: could not parse toolkit URL — skipping sync" >&2
  exit 0
fi

if ! echo "$ORG_SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
  echo "MCPmarket sync: invalid org slug '$ORG_SLUG' — skipping sync" >&2
  exit 0
fi
if ! echo "$TOOLKIT_SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
  echo "MCPmarket sync: invalid toolkit slug '$TOOLKIT_SLUG' — skipping sync" >&2
  exit 0
fi

SYNC_URL="${API_BASE_URL}/api/v1/plugin/baseline?org=${ORG_SLUG}&toolkit=${TOOLKIT_SLUG}"
FAILURE_URL="${API_BASE_URL}/api/v1/plugin/sync-failure"

# Fire-and-forget failure telemetry. Best-effort; cannot fail the hook.
# Inlined JSON is safe only because reason is a hardcoded literal,
# slugs are regex-validated, and http_code comes from curl's writer.
report_failure() {
  local reason="$1"
  local http_code="${2:-}"
  local payload
  if [ -n "$http_code" ]; then
    payload=$(printf '{"reason":"%s","orgSlug":"%s","toolkitSlug":"%s","httpCode":%s}' \
      "$reason" "$ORG_SLUG" "$TOOLKIT_SLUG" "$http_code")
  else
    payload=$(printf '{"reason":"%s","orgSlug":"%s","toolkitSlug":"%s"}' \
      "$reason" "$ORG_SLUG" "$TOOLKIT_SLUG")
  fi
  curl -sS --max-time 3 -X POST \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    ${CLIENT_HEADER_ARGS[@]+"${CLIENT_HEADER_ARGS[@]}"} \
    -d "$payload" \
    "$FAILURE_URL" >/dev/null 2>&1 || true
}

SKILLS_DIR="${MCPMARKET_SKILLS_DIR:-$PLUGIN_ROOT/skills}"
mkdir -p "$SKILLS_DIR"

TMPFILE=$(mktemp)
CURL_ERR=$(mktemp)
trap 'rm -f "$TMPFILE" "$CURL_ERR"' EXIT

# `${arr[@]+"${arr[@]}"}` — empty-array-safe expansion under `set -u`
# (bash 4.2 on macOS errors on bare `${arr[@]}` for empty arrays).
CLIENT_HEADER_ARGS=()
if [ -n "$MCPMARKET_CLIENT" ]; then
  CLIENT_HEADER_ARGS=(-H "X-MCPmarket-Client: $MCPMARKET_CLIENT")
fi

HTTP_CODE=$(curl -sS -o "$TMPFILE" -w '%{http_code}' --max-time 15 \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Accept: application/json" \
  -H "User-Agent: $USER_AGENT" \
  ${CLIENT_HEADER_ARGS[@]+"${CLIENT_HEADER_ARGS[@]}"} \
  "$SYNC_URL" 2>"$CURL_ERR") || {
  ERR=$(tr -d '\n' < "$CURL_ERR" | head -c 200)
  echo "MCPmarket sync: network error — using cached skills (${ERR:-no detail})" >&2
  report_failure "network_error"
  exit 0
}

if [ "$HTTP_CODE" != "200" ]; then
  echo "MCPmarket sync: API returned HTTP $HTTP_CODE — using cached skills" >&2
  report_failure "http_error" "$HTTP_CODE"
  exit 0
fi

RESPONSE=$(cat "$TMPFILE")

if ! echo "$RESPONSE" | jq -e '.data.skills' >/dev/null 2>&1; then
  echo "MCPmarket sync: invalid response — using cached skills" >&2
  report_failure "invalid_response"
  exit 0
fi

SKILL_COUNT=$(echo "$RESPONSE" | jq '.data.skills | length')

if [ "$SKILL_COUNT" -eq 0 ]; then
  echo "MCPmarket sync: no baseline skills configured"
  exit 0
fi

# Never overwrite skills that ship with the plugin — server is not
# authoritative over them.
BUNDLED_SKILLS="sync"

SYNCED_SLUGS=()

# Single jq pass per skill; content base64-encoded so embedded newlines
# survive the read loop.
SKILLS_TSV=$(echo "$RESPONSE" | jq -r '
  .data.skills[]
  | [.slug, .version, (.content // "" | @base64)]
  | @tsv
')

while IFS=$'\t' read -r SLUG VERSION CONTENT_B64; do
  if [ -z "$SLUG" ] || [ "$SLUG" = "null" ]; then
    continue
  fi

  case " $BUNDLED_SKILLS " in
    *" $SLUG "*) continue ;;
  esac

  SYNCED_SLUGS+=("$SLUG")
  SKILL_DIR="$SKILLS_DIR/$SLUG"
  mkdir -p "$SKILL_DIR"

  # Read version stamp from SKILL.md frontmatter to skip up-to-date skills.
  LOCAL_VERSION=""
  if [ -f "$SKILL_DIR/SKILL.md" ]; then
    LOCAL_VERSION=$(awk '
      /^---[[:space:]]*$/ { if (in_fm) { exit } else { in_fm=1; next } }
      in_fm && /^[[:space:]]+mcpmarket-version:/ {
        sub(/^[[:space:]]+mcpmarket-version:[[:space:]]*/, "")
        gsub(/^["'\'']|["'\'']$/, "")
        print; exit
      }
    ' "$SKILL_DIR/SKILL.md")
  fi
  if [ -n "$LOCAL_VERSION" ] && [ "$LOCAL_VERSION" = "$VERSION" ]; then
    continue
  fi

  # Atomic write — partial writes can't leave a half-baked SKILL.md.
  if [ -n "$CONTENT_B64" ]; then
    TMP_SKILL="$(mktemp "$SKILL_DIR/SKILL.md.XXXX")"
    printf '%s\n' "$(echo "$CONTENT_B64" | base64 -d)" > "$TMP_SKILL"
    mv "$TMP_SKILL" "$SKILL_DIR/SKILL.md"
  fi

  FILES_TSV=$(echo "$RESPONSE" | jq -r --arg slug "$SLUG" '
    .data.skills[]
    | select(.slug == $slug)
    | .files[]?
    | [.path, (.content // "" | @base64)]
    | @tsv
  ')
  if [ -n "$FILES_TSV" ]; then
    while IFS=$'\t' read -r FILE_PATH FILE_CONTENT_B64; do
      if [ -z "$FILE_PATH" ] || [ "$FILE_PATH" = "null" ]; then
        continue
      fi

      # Path-traversal guard.
      case "$FILE_PATH" in
        ../*|*/../*|/*) continue ;;
      esac

      FILE_DIR=$(dirname "$SKILL_DIR/$FILE_PATH")
      mkdir -p "$FILE_DIR"
      TMP_FILE="$(mktemp "$SKILL_DIR/$FILE_PATH.XXXX")"
      printf '%s\n' "$(echo "$FILE_CONTENT_B64" | base64 -d)" > "$TMP_FILE"
      mv "$TMP_FILE" "$SKILL_DIR/$FILE_PATH"
    done <<EOF
$FILES_TSV
EOF
  fi

  # Drop legacy sidecar from older plugin versions.
  rm -f "$SKILL_DIR/.version"
done <<EOF
$SKILLS_TSV
EOF

# Remove skills no longer in the baseline (skip bundled).
if [ -d "$SKILLS_DIR" ] && [ "$SKILLS_DIR" != "/" ]; then
  for EXISTING in "$SKILLS_DIR"/*/; do
    [ -d "$EXISTING" ] || continue
    EXISTING_SLUG=$(basename "$EXISTING")
    case " $BUNDLED_SKILLS " in
      *" $EXISTING_SLUG "*) continue ;;
    esac
    FOUND=false
    # Length check required: bash expands "${empty[@]:-}" to one empty
    # word, which would match every real slug.
    if [ ${#SYNCED_SLUGS[@]} -gt 0 ]; then
      for S in "${SYNCED_SLUGS[@]}"; do
        if [ "$S" = "$EXISTING_SLUG" ]; then
          FOUND=true
          break
        fi
      done
    fi
    if [ "$FOUND" = "false" ]; then
      rm -rf "$EXISTING"
    fi
  done
fi

echo "MCPmarket sync: $SKILL_COUNT baseline skill(s) synced"
