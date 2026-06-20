#!/usr/bin/env bash
# scout-action runtime entrypoint.
#
# Reads SCOUT_* env vars (set by action.yml), gathers files matching the
# globs, posts to scout's /analyse/items endpoint, decides pass/fail
# against the strictness thresholds, and posts a PR comment.
#
# Dependencies on GitHub-hosted runners: bash, jq, curl, gh — all
# pre-installed.

set -uo pipefail
shopt -s globstar nullglob

# --- logging helpers (define first; everything else uses them) -----------

log()  { printf '::notice::%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
err()  { printf '::error::%s\n' "$*"; }
die()  { err "$*"; exit 1; }

write_output() {
  local k="$1" v="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$k" "$v" >> "$GITHUB_OUTPUT"
  fi
}

# --- PR comment helpers (defined before any call site) -------------------

post_pr_comment() {
  local body_file="$1"
  if [[ "${COMMENT_ON_PR:-true}" != "true" ]]; then return 0; fi
  if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" && "${GITHUB_EVENT_NAME:-}" != "pull_request_target" ]]; then
    log "not a pull_request event (event=${GITHUB_EVENT_NAME:-unknown}); skipping comment"
    return 0
  fi
  local pr_number=""
  if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "$GITHUB_EVENT_PATH" ]]; then
    pr_number=$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)
  fi
  if [[ -z "$pr_number" ]]; then
    warn "could not resolve PR number; skipping comment"
    return 0
  fi
  if [[ -z "${GH_TOKEN:-}" ]]; then
    warn "github-token empty; skipping comment"
    return 0
  fi
  export GH_TOKEN
  # update mode: find prior comment by magic marker, edit in place.
  if [[ "${COMMENT_MODE:-update}" == "update" ]]; then
    local existing_id=""
    existing_id=$(gh api "repos/$GITHUB_REPOSITORY/issues/$pr_number/comments" \
      --jq '.[] | select(.body | startswith("<!-- scout-action -->")) | .id' 2>/dev/null \
      | head -n1 || true)
    if [[ -n "$existing_id" ]]; then
      if gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$existing_id" \
           -f body="$(cat "$body_file")" > /dev/null 2>&1; then
        log "updated scout-action comment $existing_id"
        return 0
      fi
      warn "PATCH on comment $existing_id failed; falling back to new comment"
    fi
  fi
  if gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$pr_number/comments" \
       -f body="$(cat "$body_file")" > /dev/null 2>&1; then
    log "posted scout-action comment on PR #$pr_number"
  else
    warn "comment post failed (non-fatal)"
  fi
}

render_findings_block() {
  local sev="$1" emoji="$2" findings_path="$3"
  local count
  count=$(jq --arg s "$sev" '[.[] | select(.severity == $s)] | length' "$findings_path")
  if (( count == 0 )); then return 0; fi
  printf '\n### %s%s (%d)\n\n' "$emoji" "${sev^}" "$count"
  if [[ "$sev" == "high" ]]; then
    jq -r --arg s "$sev" \
      '.[] | select(.severity == $s) | "- **\(.title)** (\(.category)) — \(.rationale)"' \
      "$findings_path"
  else
    printf '<details><summary>%d %s finding(s)</summary>\n\n' "$count" "$sev"
    jq -r --arg s "$sev" \
      '.[] | select(.severity == $s) | "- **\(.title)** (\(.category)) — \(.rationale)"' \
      "$findings_path"
    printf '\n</details>\n'
  fi
}

# --- inputs --------------------------------------------------------------

: "${SCOUT_API_KEY:?api-key input is required}"
ENDPOINT="${SCOUT_ENDPOINT:-https://scout-api.downloadserver.co.uk}"
SYSTEM_NAME="${SCOUT_SYSTEM_NAME:-}"
if [[ -z "$SYSTEM_NAME" ]]; then
  SYSTEM_NAME="${GITHUB_REPOSITORY##*/}"
fi
MODEL_GUID="${SCOUT_MODEL_GUID:-}"
TEMPERATURE="${SCOUT_TEMPERATURE:-}"

MAX_INPUT_BYTES="${SCOUT_MAX_INPUT_BYTES:-1000000}"
MAX_FILE_BYTES="${SCOUT_MAX_FILE_BYTES:-200000}"

STRICTNESS="${SCOUT_STRICTNESS:-report-only}"
MAX_HIGH="${SCOUT_MAX_HIGH:-}"
MAX_MEDIUM="${SCOUT_MAX_MEDIUM:-}"
MAX_LOW="${SCOUT_MAX_LOW:-}"
FAIL_ON_UPSTREAM_ERROR="${SCOUT_FAIL_ON_UPSTREAM_ERROR:-false}"

COMMENT_ON_PR="${SCOUT_COMMENT_ON_PR:-true}"
COMMENT_MODE="${SCOUT_COMMENT_MODE:-update}"
GH_TOKEN="${SCOUT_GITHUB_TOKEN:-}"

# Resolve strictness preset into per-severity caps. Per-severity inputs
# always win if set (so `block-on-any-high` + `max-high: 3` => 3 highs OK).
preset_high="" ; preset_medium="" ; preset_low=""
case "$STRICTNESS" in
  report-only)          : ;; # all unlimited
  block-on-any-high)    preset_high=0 ;;
  block-on-high-medium) preset_high=0 ; preset_medium=0 ;;
  strict)               preset_high=0 ; preset_medium=0 ; preset_low=0 ;;
  custom)               : ;; # rely entirely on per-severity inputs
  *) die "unknown strictness '$STRICTNESS' (one of: report-only, block-on-any-high, block-on-high-medium, strict, custom)" ;;
esac
MAX_HIGH="${MAX_HIGH:-$preset_high}"
MAX_MEDIUM="${MAX_MEDIUM:-$preset_medium}"
MAX_LOW="${MAX_LOW:-$preset_low}"

for varname in MAX_HIGH MAX_MEDIUM MAX_LOW; do
  v="${!varname}"
  if [[ -n "$v" ]] && ! [[ "$v" =~ ^[0-9]+$ ]]; then
    die "$varname='$v' must be a non-negative integer"
  fi
done

log "endpoint=$ENDPOINT system-name=$SYSTEM_NAME strictness=$STRICTNESS caps=H:${MAX_HIGH:-∞}/M:${MAX_MEDIUM:-∞}/L:${MAX_LOW:-∞}"

# --- gather items --------------------------------------------------------

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ITEMS_FILE="$WORK_DIR/items.jsonl"
: > "$ITEMS_FILE"

bytes_used=0
files_seen=0
files_truncated=0
files_dropped=0

emit_item() {
  local kind="$1" path="$2"
  local size text truncated="false"
  size=$(stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null || echo 0)
  if (( size == 0 )); then
    return 0
  fi
  if (( bytes_used >= MAX_INPUT_BYTES )); then
    warn "max-input-bytes ($MAX_INPUT_BYTES) reached; dropping $path"
    files_dropped=$((files_dropped + 1))
    return 0
  fi
  local remaining=$(( MAX_INPUT_BYTES - bytes_used ))
  local cap=$MAX_FILE_BYTES
  if (( cap > remaining )); then cap=$remaining; fi
  if (( size > cap )); then
    text=$(head -c "$cap" "$path")
    text="${text}"$'\n\n... [truncated at '$cap' bytes]'
    truncated="true"
    files_truncated=$((files_truncated + 1))
  else
    text=$(cat "$path")
  fi
  bytes_used=$(( bytes_used + ${#text} ))
  files_seen=$((files_seen + 1))
  jq -n --arg type "$kind" --arg id "$path" --arg text "$text" --argjson trunc "$truncated" \
        '{type:$type, id:$id, text:$text, metadata:{path:$id, truncated:$trunc}}' \
        >> "$ITEMS_FILE"
}

gather() {
  local kind="$1" glob="$2"
  [[ -z "$glob" ]] && return 0
  # Word-splitting the glob so shell expansion fires; relies on `globstar`
  # + `nullglob` set at the top of the file.
  # shellcheck disable=SC2206
  local matches=( $glob )
  if (( ${#matches[@]} == 0 )); then
    warn "$kind glob matched no files: $glob"
    return 0
  fi
  local f
  for f in "${matches[@]}"; do
    [[ -f "$f" ]] || continue
    emit_item "$kind" "$f"
  done
}

gather requirement "${SCOUT_REQUIREMENTS_GLOB:-}"
gather nfr         "${SCOUT_NFRS_GLOB:-}"
gather test        "${SCOUT_TESTS_GLOB:-}"
gather doc         "${SCOUT_DOCS_GLOB:-}"

if (( files_seen == 0 )); then
  die "no files matched any of the requirements/nfrs/tests/docs globs — nothing to analyse"
fi
log "gathered $files_seen file(s); $files_truncated truncated; $files_dropped dropped over budget; bytes=$bytes_used"

# --- compose request body ------------------------------------------------

REQ_FILE="$WORK_DIR/request.json"
jq -s --arg sys "$SYSTEM_NAME" --arg model "$MODEL_GUID" --arg temp "$TEMPERATURE" '
  {systemName: $sys, items: .}
  | if ($model != "") then .model = $model else . end
  | if ($temp  != "") then .temperature = ($temp | tonumber) else . end
' "$ITEMS_FILE" > "$REQ_FILE"

# --- call scout ----------------------------------------------------------

RESP_FILE="$WORK_DIR/response.json"
HTTP_CODE=$(curl -sS -o "$RESP_FILE" -w '%{http_code}' \
  -X POST "$ENDPOINT/api/v1/analyse/items" \
  -H "Authorization: Bearer $SCOUT_API_KEY" \
  -H "Content-Type: application/json" \
  --data-binary "@$REQ_FILE" || echo "000")

log "scout responded HTTP $HTTP_CODE"

FINDINGS_PATH="$WORK_DIR/findings.json"

if [[ "$HTTP_CODE" != "200" ]]; then
  cp "$RESP_FILE" "$FINDINGS_PATH"
  write_output execution-id ""
  write_output findings-count 0
  write_output max-severity none
  write_output findings-json-path "$FINDINGS_PATH"
  detail=$(jq -r '.detail // .error // .' "$RESP_FILE" 2>/dev/null || cat "$RESP_FILE")
  if [[ "$FAIL_ON_UPSTREAM_ERROR" == "true" ]]; then
    die "scout call failed ($HTTP_CODE): $detail"
  fi
  warn "scout call failed ($HTTP_CODE) — passing because fail-on-upstream-error=false: $detail"
  if [[ "$COMMENT_ON_PR" == "true" ]]; then
    # shellcheck disable=SC2016  # backticks are literal markdown in printf formats, not command substitution
    {
      printf '<!-- scout-action -->\n'
      printf '## scout findings — upstream error\n\n'
      printf 'Scout returned HTTP `%s`. Step is passing because `fail-on-upstream-error: false`.\n\n' "$HTTP_CODE"
      printf '```\n%s\n```\n' "$detail"
    } > "$WORK_DIR/comment.md"
    post_pr_comment "$WORK_DIR/comment.md" || true
  fi
  exit 0
fi

# --- parse findings ------------------------------------------------------

jq '.findings // []' "$RESP_FILE" > "$FINDINGS_PATH"
EXEC_ID=$(jq -r '.executionId // empty' "$RESP_FILE")
MODEL=$(jq -r '.model // empty' "$RESP_FILE")

high_count=$(jq '[.[] | select(.severity == "high")]    | length' "$FINDINGS_PATH")
med_count=$( jq '[.[] | select(.severity == "medium")]  | length' "$FINDINGS_PATH")
low_count=$( jq '[.[] | select(.severity == "low")]     | length' "$FINDINGS_PATH")
total=$(jq 'length' "$FINDINGS_PATH")

max_sev="none"
if   (( high_count > 0 )); then max_sev="high"
elif (( med_count  > 0 )); then max_sev="medium"
elif (( low_count  > 0 )); then max_sev="low"
fi

log "findings: high=$high_count medium=$med_count low=$low_count (execution-id=$EXEC_ID model=$MODEL)"

write_output execution-id "$EXEC_ID"
write_output findings-count "$total"
write_output max-severity "$max_sev"
write_output findings-json-path "$FINDINGS_PATH"

# --- build PR comment body -----------------------------------------------

DEEP_LINK="https://scout.downloadserver.co.uk/#/history/${EXEC_ID}"
COMMENT_FILE="$WORK_DIR/comment.md"
# shellcheck disable=SC2016  # backticks are literal markdown in printf formats, not command substitution
{
  printf '<!-- scout-action -->\n'
  printf '## 🔍 scout findings (execution #%s)\n\n' "$EXEC_ID"
  printf '| Severity | Count |\n|---|---|\n'
  printf '| high   | %s%s |\n' "$high_count" "$([[ $high_count -gt 0 ]] && echo ' ⚠️')"
  printf '| medium | %s |\n' "$med_count"
  printf '| low    | %s |\n\n' "$low_count"
  printf 'Model: `%s` — strictness: `%s`\n' "$MODEL" "$STRICTNESS"
  render_findings_block high   '⚠️ ' "$FINDINGS_PATH"
  render_findings_block medium ''    "$FINDINGS_PATH"
  render_findings_block low    ''    "$FINDINGS_PATH"
  printf '\n[View full run in scout →](%s)\n' "$DEEP_LINK"
} > "$COMMENT_FILE"

post_pr_comment "$COMMENT_FILE" || warn "comment post failed (non-fatal)"

# --- enforce thresholds --------------------------------------------------

violations=()
if [[ -n "$MAX_HIGH"   ]] && (( high_count > MAX_HIGH   )); then violations+=( "high=$high_count > max-high=$MAX_HIGH" ); fi
if [[ -n "$MAX_MEDIUM" ]] && (( med_count  > MAX_MEDIUM )); then violations+=( "medium=$med_count > max-medium=$MAX_MEDIUM" ); fi
if [[ -n "$MAX_LOW"    ]] && (( low_count  > MAX_LOW    )); then violations+=( "low=$low_count > max-low=$MAX_LOW" ); fi

if (( ${#violations[@]} > 0 )); then
  err "scout gate failed: ${violations[*]}  →  $DEEP_LINK"
  exit 1
fi

log "scout gate passed (strictness=$STRICTNESS)  →  $DEEP_LINK"
exit 0
