#!/usr/bin/env bash
# MCPmarket baseline skill sync (agent-neutral).
# Run by an agent's SessionStart hook (via the agent's hook-shim).
#
# Reads only:
#   MCPMARKET_PLUGIN_ROOT  (required) plugin install dir
#   MCPMARKET_TOKEN        bearer token; falls back to .mcp.json
#   MCPMARKET_TOOLKIT_URL  toolkit MCP URL; falls back to .mcp.json
#   MCPMARKET_API_URL      API base URL override (allowlisted)
#   MCPMARKET_SKILLS_DIR   skills dir; default $PLUGIN_ROOT/skills

set -euo pipefail

MCPMARKET_SYNC_VERSION="0.4.0"
USER_AGENT="mcpmarket-sync/${MCPMARKET_SYNC_VERSION}"

# Split literal so the build-time substitution can't rewrite the
# comparison along with the assignment.
MCPMARKET_CLIENT="__MCPMARKET_CLIENT__"
if [ "$MCPMARKET_CLIENT" = "__MCPMARKET""_CLIENT__" ]; then
  MCPMARKET_CLIENT=""
fi

PLUGIN_ROOT="${MCPMARKET_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
fi

if ! command -v node &>/dev/null; then
  echo "MCPmarket sync: node not installed — skipping sync" >&2
  exit 0
fi

if [ -n "$PLUGIN_ROOT" ] && [ -f "$PLUGIN_ROOT/.mcp.json" ]; then
  MCP_CONFIG="$PLUGIN_ROOT/.mcp.json"
  # Read the single MCP server entry — each plugin's .mcp.json holds
  # exactly one server, keyed by the per-toolkit plugin name
  # (`mcpmarket-<slug>`). Reading the only key under `mcpServers`
  # avoids threading the slug into this script. Codex uses
  # `http_headers`; Claude uses `headers`. Try both. Use \x1F (Unit
  # Separator, non-whitespace) so an empty leading field is preserved
  # — tab would be stripped as IFS whitespace.
  MCP_FIELDS=$(MCP_CONFIG_PATH="$MCP_CONFIG" node -e '
    try {
      const cfg = JSON.parse(require("fs").readFileSync(process.env.MCP_CONFIG_PATH, "utf8"));
      const servers = (cfg && cfg.mcpServers) || {};
      const keys = Object.keys(servers);
      const s = keys.length === 1 ? servers[keys[0]] : {};
      const url = s.url || "";
      const auth = (s.http_headers && s.http_headers.Authorization) || (s.headers && s.headers.Authorization) || "";
      process.stdout.write(url + "\x1F" + auth);
    } catch { process.stdout.write("\x1F"); }
  ')
  IFS=$'\x1F' read -r MCP_URL MCP_AUTH <<<"$MCP_FIELDS"
  TOOLKIT_URL="${MCPMARKET_TOOLKIT_URL:-$MCP_URL}"
  API_TOKEN="${MCPMARKET_TOKEN:-${MCP_AUTH#Bearer }}"

  if [ -z "$TOOLKIT_URL" ] || [ -z "$API_TOKEN" ]; then
    echo "MCPmarket sync: .mcp.json present but credentials unreadable — skipping sync" >&2
    exit 0
  fi
else
  TOOLKIT_URL="${MCPMARKET_TOOLKIT_URL:-}"
  API_TOKEN="${MCPMARKET_TOKEN:-}"
fi

API_BASE_URL="${MCPMARKET_API_URL:-https://app.mcpmarket.com}"

# Allowlist the API base URL by parsed host. `case` glob `*` matches
# `/`, so a pattern like `https://*.mcpmarket.com/*` also matches
# `https://attacker.com/foo.mcpmarket.com/bar` — splitting on `://`
# and `/` removes that bypass.
API_SCHEME=""
API_HOST=""
case "$API_BASE_URL" in
  https://*) API_SCHEME=https; API_HOST="${API_BASE_URL#https://}"; API_HOST="${API_HOST%%/*}" ;;
  http://*)  API_SCHEME=http;  API_HOST="${API_BASE_URL#http://}";  API_HOST="${API_HOST%%/*}" ;;
esac
# Reject userinfo (@) and multi-colon hosts — `localhost:8080@evil.com`
# would otherwise satisfy `localhost:*`.
case "$API_HOST" in
  *[!a-zA-Z0-9.:-]*) API_HOST="" ;;
  *:*:*)             API_HOST="" ;;
esac
API_ALLOWED=false
if [ "$API_SCHEME" = "https" ]; then
  case "$API_HOST" in
    app.mcpmarket.com|*.mcpmarket.com) API_ALLOWED=true ;;
  esac
elif [ "$API_SCHEME" = "http" ]; then
  case "$API_HOST" in
    localhost|localhost:*|127.0.0.1|127.0.0.1:*) API_ALLOWED=true ;;
  esac
fi
if [ "$API_ALLOWED" != "true" ]; then
  echo "MCPmarket sync: api_url '$API_BASE_URL' not in allowlist — skipping sync" >&2
  exit 0
fi

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

# Fire-and-forget telemetry. Inlined JSON is safe only because reason
# is a hardcoded literal, slugs are regex-validated, and http_code
# comes from curl's writer.
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

# `${arr[@]+"${arr[@]}"}` is the empty-array-safe expansion under
# `set -u` (bash 4.2 on macOS errors on bare `${arr[@]}` for empties).
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

# Single node pass emits TSV records the bash loop below consumes:
#   S<TAB><slug><TAB><version><TAB><base64-content>
#   F<TAB><slug><TAB><path><TAB><base64-content>
# Rejects \t/\n/\x00 in string fields so a server can't forge extra
# records by smuggling \n into a slug or path.
RECORDS=$(node -e '
  const UNSAFE = /[\t\n\x00]/;
  let raw;
  try { raw = require("fs").readFileSync(0, "utf8"); } catch { process.exit(1); }
  let r;
  try { r = JSON.parse(raw); } catch { process.exit(1); }
  const skills = r && r.data && r.data.skills;
  if (!Array.isArray(skills)) process.exit(1);
  const out = [];
  for (const s of skills) {
    if (!s || typeof s.slug !== "string" || UNSAFE.test(s.slug)) continue;
    const version = s.version || "";
    if (UNSAFE.test(version)) continue;
    const c = Buffer.from(s.content || "", "utf8").toString("base64");
    out.push(["S", s.slug, version, c].join("\t"));
    if (Array.isArray(s.files)) {
      for (const f of s.files) {
        if (!f || typeof f.path !== "string" || UNSAFE.test(f.path)) continue;
        const fc = Buffer.from(f.content || "", "utf8").toString("base64");
        out.push(["F", s.slug, f.path, fc].join("\t"));
      }
    }
  }
  process.stdout.write(out.join("\n"));
' < "$TMPFILE") || {
  echo "MCPmarket sync: invalid response — using cached skills" >&2
  report_failure "invalid_response"
  exit 0
}

# `printf '%s\n'` restores the trailing newline that `$()` strips.
SKILLS_TSV=$(printf '%s\n' "$RECORDS" | awk -F'\t' '$1=="S" { print $2"\t"$3"\t"$4 }')
SKILL_COUNT=$(printf '%s\n' "$SKILLS_TSV" | awk 'NF { c++ } END { print c+0 }')

if [ "$SKILL_COUNT" -eq 0 ]; then
  echo "MCPmarket sync: no baseline skills configured"
  exit 0
fi

# Never overwrite skills that ship with the plugin.
BUNDLED_SKILLS="sync"

SYNCED_SLUGS=()

while IFS=$'\t' read -r SLUG VERSION CONTENT_B64; do
  if [ -z "$SLUG" ] || [ "$SLUG" = "null" ]; then
    continue
  fi

  # Required: a server-returned `..` would otherwise pivot SKILL_DIR to
  # $PLUGIN_ROOT and overwrite the agent's startup hook.
  if ! echo "$SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
    echo "MCPmarket sync: skipping skill with invalid slug '$SLUG'" >&2
    continue
  fi

  case " $BUNDLED_SKILLS " in
    *" $SLUG "*) continue ;;
  esac

  SYNCED_SLUGS+=("$SLUG")
  SKILL_DIR="$SKILLS_DIR/$SLUG"
  mkdir -p "$SKILL_DIR"

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

  if [ -n "$CONTENT_B64" ]; then
    TMP_SKILL="$(mktemp "$SKILL_DIR/SKILL.md.XXXX")"
    printf '%s\n' "$(echo "$CONTENT_B64" | base64 -d)" > "$TMP_SKILL"
    mv "$TMP_SKILL" "$SKILL_DIR/SKILL.md"
  fi

  FILES_TSV=$(printf '%s\n' "$RECORDS" | awk -F'\t' -v slug="$SLUG" '$1=="F" && $2==slug { print $3"\t"$4 }')
  if [ -n "$FILES_TSV" ]; then
    while IFS=$'\t' read -r FILE_PATH FILE_CONTENT_B64; do
      if [ -z "$FILE_PATH" ] || [ "$FILE_PATH" = "null" ]; then
        continue
      fi

      # Segment-level path-traversal guard; `case` globs miss bare `..`
      # and `foo/..`.
      _PATH_OK=true
      case "$FILE_PATH" in /*) _PATH_OK=false ;; esac
      if [ "$_PATH_OK" = "true" ]; then
        IFS='/' read -ra _SEGS <<<"$FILE_PATH"
        for _SEG in "${_SEGS[@]}"; do
          if [ "$_SEG" = ".." ] || [ "$_SEG" = "." ] || [ -z "$_SEG" ]; then
            _PATH_OK=false
            break
          fi
        done
      fi
      if [ "$_PATH_OK" != "true" ]; then continue; fi

      FILE_DIR=$(dirname "$SKILL_DIR/$FILE_PATH")
      mkdir -p "$FILE_DIR"
      TMP_FILE="$(mktemp "$SKILL_DIR/$FILE_PATH.XXXX")"
      printf '%s\n' "$(echo "$FILE_CONTENT_B64" | base64 -d)" > "$TMP_FILE"
      mv "$TMP_FILE" "$SKILL_DIR/$FILE_PATH"
    done <<EOF
$FILES_TSV
EOF
  fi

  rm -f "$SKILL_DIR/.version"
done <<EOF
$SKILLS_TSV
EOF

# Cleanup: only delete subdirs whose SKILL.md carries the
# `mcpmarket-version:` stamp the sync writes, so hand-placed skills
# survive even if MCPMARKET_SKILLS_DIR is misconfigured.
if [ -d "$SKILLS_DIR" ] && [ "$SKILLS_DIR" != "/" ]; then
  for EXISTING in "$SKILLS_DIR"/*/; do
    [ -d "$EXISTING" ] || continue
    EXISTING_SLUG=$(basename "$EXISTING")
    case " $BUNDLED_SKILLS " in
      *" $EXISTING_SLUG "*) continue ;;
    esac

    [ -f "$EXISTING/SKILL.md" ] || continue
    HAS_STAMP=$(awk '
      /^---[[:space:]]*$/ { if (in_fm) exit; in_fm=1; next }
      in_fm && /^[[:space:]]+mcpmarket-version:/ { print "1"; exit }
    ' "$EXISTING/SKILL.md")
    [ -n "$HAS_STAMP" ] || continue

    FOUND=false
    # Length check required: `"${empty[@]:-}"` expands to one empty word.
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
