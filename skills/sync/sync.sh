#!/usr/bin/env bash
# MCPmarket baseline skill sync
# Called by SessionStart hook — fetches baseline skills from the web app API
# and writes them to the plugin's skills/ directory for auto-loading.
#
# Reads credentials from:
#   1. CLAUDE_PLUGIN_OPTION_* env vars (CLI plugin install with userConfig)
#   2. .mcp.json in plugin root (downloaded zip with baked-in credentials)

set -euo pipefail

# CLAUDE_PLUGIN_ROOT is set by Claude Code when running plugin hooks, but
# not when the script is invoked through the Bash tool from the /sync
# skill. Fall back to deriving the plugin root from this script's own
# location (skills/sync/sync.sh → ../..) so /sync works the same as the
# SessionStart hook.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  PLUGIN_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
fi

# Check for jq early — needed for .mcp.json fallback and API response parsing
if ! command -v jq &>/dev/null; then
  echo "MCPmarket sync: jq not installed — skipping sync" >&2
  exit 0
fi

# Read from .mcp.json if env vars aren't set (baked-in credentials from download)
if [ -n "$PLUGIN_ROOT" ] && [ -f "$PLUGIN_ROOT/.mcp.json" ]; then
  MCP_CONFIG="$PLUGIN_ROOT/.mcp.json"
  TOOLKIT_URL="${CLAUDE_PLUGIN_OPTION_toolkit_url:-$(jq -r '.mcpServers.mcpmarket.url // empty' "$MCP_CONFIG")}"
  BEARER=$(jq -r '.mcpServers.mcpmarket.headers.Authorization // empty' "$MCP_CONFIG")
  API_TOKEN="${CLAUDE_PLUGIN_OPTION_api_token:-${BEARER#Bearer }}"

  # .mcp.json was present but the credentials couldn't be extracted
  # (wrong shape, jq returned empty, file hand-edited). Log it as a
  # distinct failure so debugging doesn't have to guess between "never
  # configured" and "configured but unreadable".
  if [ -z "$TOOLKIT_URL" ] || [ -z "$API_TOKEN" ]; then
    echo "MCPmarket sync: .mcp.json present but credentials unreadable — skipping sync" >&2
    exit 0
  fi
else
  TOOLKIT_URL="${CLAUDE_PLUGIN_OPTION_toolkit_url:-}"
  API_TOKEN="${CLAUDE_PLUGIN_OPTION_api_token:-}"
fi

API_BASE_URL="${CLAUDE_PLUGIN_OPTION_api_url:-https://app.mcpmarket.com}"

# Validate api_url before using it as the base for Authorization-bearing
# requests. Without this, a user socially-engineered into setting
# CLAUDE_PLUGIN_OPTION_api_url=https://attacker.com would exfiltrate
# their API token on the next sync. Allowlist covers production, any
# mcpmarket.com subdomain (staging/preview), and localhost for dev.
case "$API_BASE_URL" in
  https://app.mcpmarket.com|https://app.mcpmarket.com/*) ;;
  https://*.mcpmarket.com|https://*.mcpmarket.com/*) ;;
  http://localhost:*|http://127.0.0.1:*) ;;
  *)
    echo "MCPmarket sync: api_url '$API_BASE_URL' not in allowlist — skipping sync" >&2
    exit 0
    ;;
esac

# Validate required values
if [ -z "$TOOLKIT_URL" ] || [ -z "$API_TOKEN" ] || [ -z "$PLUGIN_ROOT" ]; then
  echo "MCPmarket sync: missing configuration — skipping sync" >&2
  exit 0
fi

# Parse org slug and toolkit slug from MCP URL
# Format: https://gateway.example.com/{orgSlug}/toolkits/{toolkitSlug}/mcp
URL_PATH=$(echo "$TOOLKIT_URL" | sed -E 's|https?://[^/]*/||; s|/mcp$||')
ORG_SLUG=$(echo "$URL_PATH" | cut -d'/' -f1)
TOOLKIT_SLUG=$(echo "$URL_PATH" | cut -d'/' -f3)

if [ -z "$ORG_SLUG" ] || [ -z "$TOOLKIT_SLUG" ]; then
  echo "MCPmarket sync: could not parse toolkit URL — skipping sync" >&2
  exit 0
fi

# Validate parsed slugs look reasonable (alphanumeric + hyphens)
if ! echo "$ORG_SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
  echo "MCPmarket sync: invalid org slug '$ORG_SLUG' — skipping sync" >&2
  exit 0
fi
if ! echo "$TOOLKIT_SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
  echo "MCPmarket sync: invalid toolkit slug '$TOOLKIT_SLUG' — skipping sync" >&2
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
  echo "MCPmarket sync: network error — using cached skills" >&2
  exit 0
}

if [ "$HTTP_CODE" != "200" ]; then
  echo "MCPmarket sync: API returned HTTP $HTTP_CODE — using cached skills" >&2
  exit 0
fi

RESPONSE=$(cat "$TMPFILE")

# Validate response
if ! echo "$RESPONSE" | jq -e '.data.skills' >/dev/null 2>&1; then
  echo "MCPmarket sync: invalid response — using cached skills" >&2
  exit 0
fi

SKILL_COUNT=$(echo "$RESPONSE" | jq '.data.skills | length')

if [ "$SKILL_COUNT" -eq 0 ]; then
  echo "MCPmarket sync: no baseline skills configured"
  exit 0
fi

# Skills that ship with the plugin itself — never overwritten by the
# baseline API and never deleted by the cleanup loop, regardless of
# what the server returns. This is a trust boundary: a compromised
# baseline endpoint returning {slug:"sync", content:"<attacker skill>"}
# would otherwise replace skills/sync/SKILL.md, and the next time the
# user ran /sync Claude would execute attacker-supplied instructions.
BUNDLED_SKILLS="sync"

# Track synced slugs for cleanup
SYNCED_SLUGS=()

for i in $(seq 0 $((SKILL_COUNT - 1))); do
  SKILL=$(echo "$RESPONSE" | jq -r ".data.skills[$i]")
  SLUG=$(echo "$SKILL" | jq -r '.slug')
  VERSION=$(echo "$SKILL" | jq -r '.version')

  if [ -z "$SLUG" ] || [ "$SLUG" = "null" ]; then
    continue
  fi

  # Refuse to write over any bundled skill, even if the server returns
  # one with the same slug. Mirrors the cleanup-loop guard below.
  case " $BUNDLED_SKILLS " in
    *" $SLUG "*) continue ;;
  esac

  SYNCED_SLUGS+=("$SLUG")
  SKILL_DIR="$SKILLS_DIR/$SLUG"
  mkdir -p "$SKILL_DIR"

  # Check if already up-to-date by reading the canonical version stamp
  # the server wrote into SKILL.md frontmatter at publish time
  # (`metadata.mcpmarket-version`).  Single source of truth — no separate
  # sidecar file means the version travels with the SKILL.md when
  # teammates copy or commit the folder elsewhere.
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

  # Write entry point (SKILL.md) — version stamp is already in the
  # content the API returned, no separate file write needed.
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

  # Opportunistic cleanup of pre-frontmatter sidecar files left over
  # from earlier plugin versions.  Idempotent.
  rm -f "$SKILL_DIR/.version"
done

# Remove skills no longer marked as baseline (skip bundled plugin skills,
# BUNDLED_SKILLS is hoisted above the write loop).
if [ -d "$SKILLS_DIR" ] && [ "$SKILLS_DIR" != "/" ]; then
  for EXISTING in "$SKILLS_DIR"/*/; do
    [ -d "$EXISTING" ] || continue
    EXISTING_SLUG=$(basename "$EXISTING")
    # Skip bundled skills that ship with the plugin
    case " $BUNDLED_SKILLS " in
      *" $EXISTING_SLUG "*) continue ;;
    esac
    FOUND=false
    # Guard: bash expands "${empty_array[@]:-}" to a single empty word,
    # so iterating without a length check would match "" against every
    # real slug and delete every non-bundled skill when the API returns
    # all-null-slug responses.
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
