#!/usr/bin/env bash
# Skillfish baseline skill sync
# Called by SessionStart hook — fetches baseline skills from the web app API
# and writes them to the plugin's skills/ directory for auto-loading.
#
# Env vars (set by Claude Code plugin system):
#   CLAUDE_PLUGIN_OPTION_toolkit_url  — MCP endpoint URL (e.g. https://gateway.mcpmarket.com/org/toolkits/slug/mcp)
#   CLAUDE_PLUGIN_OPTION_api_token    — API token (sk_user_...)
#   CLAUDE_PLUGIN_ROOT                — Plugin root directory

set -euo pipefail

API_BASE_URL="${CLAUDE_PLUGIN_OPTION_api_url:-https://app.mcpmarket.com}"
TOOLKIT_URL="${CLAUDE_PLUGIN_OPTION_toolkit_url:-}"
API_TOKEN="${CLAUDE_PLUGIN_OPTION_api_token:-}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"

# Validate required env vars
if [ -z "$TOOLKIT_URL" ] || [ -z "$API_TOKEN" ] || [ -z "$PLUGIN_ROOT" ]; then
  echo "Skillfish sync: missing configuration — skipping sync" >&2
  exit 0
fi

# Check for jq
if ! command -v jq &>/dev/null; then
  echo "Skillfish sync: jq not installed — skipping sync" >&2
  exit 0
fi

# Parse org slug and toolkit slug from MCP URL
# Format: https://gateway.example.com/{orgSlug}/toolkits/{toolkitSlug}/mcp
URL_PATH=$(echo "$TOOLKIT_URL" | sed -E 's|https?://[^/]*/||; s|/mcp$||')
ORG_SLUG=$(echo "$URL_PATH" | cut -d'/' -f1)
TOOLKIT_SLUG=$(echo "$URL_PATH" | cut -d'/' -f3)

if [ -z "$ORG_SLUG" ] || [ -z "$TOOLKIT_SLUG" ]; then
  echo "Skillfish sync: could not parse toolkit URL — skipping sync" >&2
  exit 0
fi

# Validate parsed slugs look reasonable (alphanumeric + hyphens)
if ! echo "$ORG_SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
  echo "Skillfish sync: invalid org slug '$ORG_SLUG' — skipping sync" >&2
  exit 0
fi
if ! echo "$TOOLKIT_SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
  echo "Skillfish sync: invalid toolkit slug '$TOOLKIT_SLUG' — skipping sync" >&2
  exit 0
fi

SYNC_URL="${API_BASE_URL}/api/v1/plugin/baseline?org=${ORG_SLUG}&toolkit=${TOOLKIT_SLUG}"

SKILLS_DIR="$PLUGIN_ROOT/skills"
mkdir -p "$SKILLS_DIR"

# Fetch baseline skills from API
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

HTTP_CODE=$(curl -sS -o "$TMPFILE" -w '%{http_code}' --max-time 15 \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Accept: application/json" \
  "$SYNC_URL" 2>/dev/null) || {
  echo "Skillfish sync: network error — using cached skills" >&2
  exit 0
}

if [ "$HTTP_CODE" != "200" ]; then
  echo "Skillfish sync: API returned HTTP $HTTP_CODE — using cached skills" >&2
  exit 0
fi

RESPONSE=$(cat "$TMPFILE")

# Validate response
if ! echo "$RESPONSE" | jq -e '.data.skills' >/dev/null 2>&1; then
  echo "Skillfish sync: invalid response — using cached skills" >&2
  exit 0
fi

SKILL_COUNT=$(echo "$RESPONSE" | jq '.data.skills | length')

if [ "$SKILL_COUNT" -eq 0 ]; then
  echo "Skillfish sync: no baseline skills configured"
  exit 0
fi

# Track synced slugs for cleanup
SYNCED_SLUGS=()

for i in $(seq 0 $((SKILL_COUNT - 1))); do
  SKILL=$(echo "$RESPONSE" | jq -r ".data.skills[$i]")
  SLUG=$(echo "$SKILL" | jq -r '.slug')
  VERSION=$(echo "$SKILL" | jq -r '.version')

  if [ -z "$SLUG" ] || [ "$SLUG" = "null" ]; then
    continue
  fi

  SYNCED_SLUGS+=("$SLUG")
  SKILL_DIR="$SKILLS_DIR/$SLUG"
  mkdir -p "$SKILL_DIR"

  # Check if already up-to-date
  VERSION_FILE="$SKILL_DIR/.version"
  if [ -f "$VERSION_FILE" ] && [ "$(cat "$VERSION_FILE")" = "$VERSION" ]; then
    continue
  fi

  # Write entry point (SKILL.md)
  CONTENT=$(echo "$SKILL" | jq -r '.content')
  if [ -n "$CONTENT" ] && [ "$CONTENT" != "null" ]; then
    printf '%s\n' "$CONTENT" > "$SKILL_DIR/SKILL.md"
  fi

  # Write resource files
  FILE_COUNT=$(echo "$SKILL" | jq '.files | length')
  for j in $(seq 0 $((FILE_COUNT - 1))); do
    FILE_PATH=$(echo "$SKILL" | jq -r ".files[$j].path")
    FILE_CONTENT=$(echo "$SKILL" | jq -r ".files[$j].content")

    if [ -z "$FILE_PATH" ] || [ "$FILE_PATH" = "null" ]; then
      continue
    fi

    # Prevent path traversal
    case "$FILE_PATH" in
      ../*|*/../*|/*) continue ;;
    esac

    FILE_DIR=$(dirname "$SKILL_DIR/$FILE_PATH")
    mkdir -p "$FILE_DIR"
    printf '%s\n' "$FILE_CONTENT" > "$SKILL_DIR/$FILE_PATH"
  done

  echo "$VERSION" > "$VERSION_FILE"
done

# Remove skills no longer marked as baseline
if [ -d "$SKILLS_DIR" ] && [ "$SKILLS_DIR" != "/" ]; then
  for EXISTING in "$SKILLS_DIR"/*/; do
    [ -d "$EXISTING" ] || continue
    EXISTING_SLUG=$(basename "$EXISTING")
    FOUND=false
    for S in "${SYNCED_SLUGS[@]:-}"; do
      if [ "$S" = "$EXISTING_SLUG" ]; then
        FOUND=true
        break
      fi
    done
    if [ "$FOUND" = "false" ]; then
      rm -rf "$EXISTING"
    fi
  done
fi

echo "Skillfish sync: $SKILL_COUNT baseline skill(s) synced"
