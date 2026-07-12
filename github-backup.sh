#!/usr/bin/env bash
# github-backup.sh
# Fetches/clones all repositories owned by a GitHub user into a local mirror directory.
# Usage:
#   github-backup.sh <GITHUB_TOKEN> <GITHUB_USERNAME> <TARGET_DIR> [include_forks]
#
# Parameters:
#   GITHUB_TOKEN   - Personal access token (fine-graine, access to all repos, permissions: read-only for contents and metadata)
#   GITHUB_USERNAME- GitHub username whose repos to mirror (should match the token's owner to include private repos)
#   TARGET_DIR     - Local directory to store bare mirrors (<TARGET_DIR>/<repo>.git)
#   include_forks  - Optional: "true" to include forked repos; defaults to "false" (exclude forks)
#
# Requires: curl, jq, git
# Notes:
# - We avoid printing the token and remove credentials from remotes after each operation.
# - This script is suitable as a resticprofile "run before" hook.

set -euo pipefail

usage() {
  echo "Usage: $0 <GITHUB_TOKEN> <GITHUB_USERNAME> <TARGET_DIR> [include_forks]" >&2
  echo "  include_forks: optional, default 'false'. Set to 'true' to include forked repos." >&2
  exit 1
}

if [[ $# -lt 3 || $# -gt 4 ]]; then
  usage
fi

TOKEN="$1"
USERNAME="$2"
TARGET_DIR="$3"
INCLUDE_FORKS="${4:-false}"

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
for cmd in curl jq git; do
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

# Helper: fetch a page of repos the authenticated user owns (includes private if token has access)
fetch_owned_repos_page() {
  local page="$1"
  curl -sS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user/repos?per_page=100&affiliation=owner&visibility=all&page=${page}"
}

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
  auth_url="https://x-access-token:${TOKEN}@github.com/${USERNAME}/${name}.git"
  public_url="https://github.com/${USERNAME}/${name}.git"

  if [[ -d "$repo_dir" ]]; then
    echo "[UPDATE] ${name} ..."
    git -C "$repo_dir" remote set-url origin "$auth_url" >/dev/null 2>&1 || true
    if ! git -C "$repo_dir" fetch --all --prune --tags >/dev/null 2>&1; then
      echo "  -> Failed to update ${name}" >&2
      ((fail_count++))
      continue
    fi
    echo "  -> Updated ${name}"
  else
    echo "[CLONE] ${name} ..."
    if ! git clone --mirror "$auth_url" "$repo_dir" >/dev/null 2>&1; then
      echo "  -> Failed to clone ${name}" >&2
      ((fail_count++))
      continue
    fi
    echo "  -> Cloned ${name}"
  fi

  # Remove credentials from remote to avoid storing tokens on disk
  git -C "$repo_dir" remote set-url origin "$public_url" >/dev/null 2>&1 || true
done

if [[ $fail_count -gt 0 ]]; then
  echo "Completed with $fail_count failures." >&2
  exit 5
fi

echo "All repositories processed successfully."
