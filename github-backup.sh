#!/usr/bin/env bash
# github-backup.sh
# Fetches/clones all repositories owned by the authenticated GitHub user into a local mirror directory.
# Usage:
#   GITHUB_TOKEN=... github-backup.sh <GITHUB_USERNAME> <TARGET_DIR> [include_forks]
#   GITHUB_TOKEN_FILE=/path/to/token.txt github-backup.sh <GITHUB_USERNAME> <TARGET_DIR> [include_forks]
#
# PAT requirements:
#   Fine-grained personal access token, access to all repositories,
#   permissions: read-only for contents and metadata
#
# Parameters:
#   GITHUB_USERNAME - GitHub username for the token owner; used as a safety check when selecting owned repositories
#   TARGET_DIR      - Local directory to store bare mirrors (<TARGET_DIR>/<repo>.git)
#   include_forks   - Optional: "true" to include forked repos; defaults to "false" (exclude forks)
#
# Requires: curl, jq, git, base64
# Notes:
# - We avoid printing the token and do not persist it in git remote URLs.
# - This script is suitable as a resticprofile "run before" hook.

set -euo pipefail

usage() {
  echo "Usage: GITHUB_TOKEN=... $0 <GITHUB_USERNAME> <TARGET_DIR> [include_forks]" >&2
  echo "   or: GITHUB_TOKEN_FILE=/path/to/token.txt $0 <GITHUB_USERNAME> <TARGET_DIR> [include_forks]" >&2
  echo "  Set exactly one of GITHUB_TOKEN or GITHUB_TOKEN_FILE." >&2
  echo "  GITHUB_USERNAME must be the username that owns the token." >&2
  echo "  include_forks: optional, default 'false'. Set to 'true' to include forked repos." >&2
  exit 1
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
fi

if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_TOKEN_FILE:-}" ]]; then
  echo "Error: set only one of GITHUB_TOKEN or GITHUB_TOKEN_FILE." >&2
  exit 1
fi

if [[ -n "${GITHUB_TOKEN_FILE:-}" ]]; then
  if [[ ! -r "${GITHUB_TOKEN_FILE}" ]]; then
    echo "Error: GITHUB_TOKEN_FILE '${GITHUB_TOKEN_FILE}' is not readable." >&2
    exit 1
  fi

  IFS= read -r TOKEN < "${GITHUB_TOKEN_FILE}"
else
  TOKEN="${GITHUB_TOKEN:-}"
fi

if [[ -z "${TOKEN:-}" ]]; then
  echo "Error: set GITHUB_TOKEN or GITHUB_TOKEN_FILE before running this script." >&2
  usage
fi

USERNAME="$1"
TARGET_DIR="$2"
INCLUDE_FORKS="${3:-false}"

# Normalize INCLUDE_FORKS to 'true' or 'false'
case "${INCLUDE_FORKS,,}" in
  true|1|yes|y) INCLUDE_FORKS="true" ;;
  false|0|no|n|"") INCLUDE_FORKS="false" ;;
  *)
    echo "Warning: unrecognized include_forks value '${INCLUDE_FORKS}'. Defaulting to 'false'." >&2
    INCLUDE_FORKS="false"
    ;;
esac

# Dependencies check
for cmd in curl jq git base64; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd is required but not installed" >&2
    exit 2
  fi
done

echo "Starting GitHub mirror sync for user '${USERNAME}' into '${TARGET_DIR}' (include forks: ${INCLUDE_FORKS})..."

# Prepare target directory
mkdir -p "$TARGET_DIR"

# Prevent git from prompting for credentials
export GIT_TERMINAL_PROMPT=0

GIT_AUTH_HEADER="Authorization: Basic $(printf '%s' "x-access-token:${TOKEN}" | base64 | tr -d '\n')"

# Run git with an Authorization header supplied via ephemeral config.
github_git() {
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
  GIT_CONFIG_VALUE_0="${GIT_AUTH_HEADER}" \
    git "$@"
}

# Helper: fetch GitHub API JSON with the configured token.
github_api_get() {
  local path="$1"

  curl -sS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com${path}"
}

# Ensure a mirror remote URL is the public repository URL and verify the change stuck.
ensure_public_remote() {
  local repo_dir="$1"
  local public_url="$2"
  local current_url

  git -C "$repo_dir" remote set-url origin "$public_url" >/dev/null 2>&1 || return 1
  current_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"
  [[ "$current_url" == "$public_url" ]]
}

# Helper: fetch a page of repos the authenticated user owns (includes private if token has access)
fetch_owned_repos_page() {
  local page="$1"
  github_api_get "/user/repos?per_page=100&affiliation=owner&visibility=all&page=${page}"
}

# Validate that the supplied username matches the authenticated token owner.
validate_token_owner() {
  local user_resp
  local auth_login

  user_resp="$(github_api_get "/user")"

  auth_login="$(echo "$user_resp" | jq -r 'if type == "object" and .login then .login else empty end')"
  if [[ -z "$auth_login" ]]; then
    echo "Error: Unable to determine the authenticated GitHub user. Raw message follows:" >&2
    echo "$user_resp" >&2
    exit 3
  fi

  if [[ "${auth_login,,}" != "${USERNAME,,}" ]]; then
    echo "Error: GITHUB_USERNAME '${USERNAME}' does not match the authenticated token owner '${auth_login}'." >&2
    exit 4
  fi

  USERNAME="$auth_login"
}

validate_token_owner

# Collect repositories owned by the specified username
declare -a REPOS=()
page=1
while :; do
  resp="$(fetch_owned_repos_page "$page")"

  # Validate response
  if ! echo "$resp" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "Error: Unexpected response from GitHub API. Raw message follows:" >&2
    echo "$resp" >&2
    exit 3
  fi

  count="$(echo "$resp" | jq 'length')"
  if [[ "$count" -eq 0 ]]; then
    break
  fi

  # Filter by owner and optionally exclude forks
  if [[ "$INCLUDE_FORKS" == "true" ]]; then
    mapfile -t batch < <(echo "$resp" | jq -r --arg user "$USERNAME" '.[] | select(.owner.login == $user) | .name')
  else
    mapfile -t batch < <(echo "$resp" | jq -r --arg user "$USERNAME" '.[] | select(.owner.login == $user and .fork != true) | .name')
  fi

  if [[ "${#batch[@]}" -gt 0 ]]; then
    REPOS+=("${batch[@]}")
  fi

  ((page++))
done

echo "Discovered ${#REPOS[@]} repositories owned by '${USERNAME}' (forks ${INCLUDE_FORKS})."

# Clone or update each repository as a mirror
fail_count=0
for name in "${REPOS[@]}"; do
  repo_dir="${TARGET_DIR}/${name}.git"
  public_url="https://github.com/${USERNAME}/${name}.git"

  if [[ -d "$repo_dir" ]]; then
    echo "[UPDATE] ${name} ..."
    if ! ensure_public_remote "$repo_dir" "$public_url"; then
      echo "  -> Failed to restore public origin URL for ${name}" >&2
      ((fail_count += 1))
      continue
    fi

    if ! github_git -C "$repo_dir" fetch --prune --tags origin >/dev/null 2>&1; then
      echo "  -> Failed to update ${name}" >&2
      ((fail_count += 1))
      continue
    fi
    echo "  -> Updated ${name}"
  else
    echo "[CLONE] ${name} ..."
    if ! github_git clone --mirror "$public_url" "$repo_dir" >/dev/null 2>&1; then
      echo "  -> Failed to clone ${name}" >&2
      ((fail_count += 1))
      continue
    fi

    if ! ensure_public_remote "$repo_dir" "$public_url"; then
      echo "  -> Clone completed but failed to verify public origin URL for ${name}" >&2
      ((fail_count += 1))
      continue
    fi

    echo "  -> Cloned ${name}"
  fi
done

if [[ $fail_count -gt 0 ]]; then
  echo "Completed with $fail_count failures." >&2
  exit 5
fi

echo "All repositories processed successfully."
