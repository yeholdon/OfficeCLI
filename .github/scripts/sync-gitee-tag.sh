#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_GITHUB_REPOSITORY="iOfficeAI/OfficeCLI"
readonly DEFAULT_GITEE_OWNER="yeholdon"
readonly DEFAULT_GITEE_REPOSITORY="OfficeCLI"

github_repository="${SOURCE_GITHUB_REPOSITORY:-$DEFAULT_GITHUB_REPOSITORY}"
gitee_owner="${GITEE_OWNER:-$DEFAULT_GITEE_OWNER}"
gitee_repository="${GITEE_REPO:-$DEFAULT_GITEE_REPOSITORY}"
gitee_username="${GITEE_USERNAME:-$gitee_owner}"
requested_tag="${1:-}"

die() {
  echo "error: $*" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die "required command not found: git"
[[ -n "${GITEE_TOKEN:-}" ]] || die "GITEE_TOKEN is required"
[[ "$github_repository" == */* ]] ||
  die "SOURCE_GITHUB_REPOSITORY must have the form owner/repository"
[[ "$requested_tag" =~ ^v[0-9A-Za-z][0-9A-Za-z._-]*$ ]] ||
  die "refusing unexpected release tag: $requested_tag"

source_url="https://github.com/$github_repository.git"
gitee_url="https://gitee.com/$gitee_owner/$gitee_repository.git"
tag_ref="refs/tags/$requested_tag"

echo "Fetching source tag $requested_tag from $github_repository..."
git fetch --no-tags "$source_url" "$tag_ref:$tag_ref"
source_tag_sha="$(git rev-parse "$tag_ref")"

gitee_tag_sha="$(git ls-remote --refs "$gitee_url" "$tag_ref" | awk 'NR == 1 { print $1 }')"
if [[ -n "$gitee_tag_sha" ]]; then
  [[ "$gitee_tag_sha" == "$source_tag_sha" ]] ||
    die "Gitee tag $requested_tag exists at a different Git object"
  echo "Gitee tag $requested_tag is already synchronized."
  exit 0
fi

credential_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/officecli-gitee-git.XXXXXX")"
readonly credential_dir
trap 'rm -rf -- "$credential_dir"' EXIT

askpass="$credential_dir/askpass.sh"
cat >"$askpass" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' "${GITEE_USERNAME:?}" ;;
  *Password*) printf '%s\n' "${GITEE_TOKEN:?}" ;;
  *) exit 1 ;;
esac
EOF
chmod 700 "$askpass"

echo "Pushing source tag $requested_tag to Gitee..."
GIT_ASKPASS="$askpass" \
GIT_TERMINAL_PROMPT=0 \
GITEE_USERNAME="$gitee_username" \
git -c credential.helper= push "$gitee_url" "$tag_ref:$tag_ref"

gitee_tag_sha="$(git ls-remote --refs "$gitee_url" "$tag_ref" | awk 'NR == 1 { print $1 }')"
[[ "$gitee_tag_sha" == "$source_tag_sha" ]] ||
  die "Gitee tag verification failed for $requested_tag"

echo "Gitee tag $requested_tag is synchronized."
