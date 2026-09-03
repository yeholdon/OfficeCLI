#!/usr/bin/env bash

set -Eeuo pipefail

readonly GITEE_API_BASE="https://gitee.com/api/v5"
readonly DEFAULT_GITHUB_REPOSITORY="iOfficeAI/OfficeCLI"
readonly DEFAULT_GITEE_OWNER="yeholdon"
readonly DEFAULT_GITEE_REPOSITORY="OfficeCLI"
readonly DEFAULT_MAX_ASSET_BYTES=$((50 * 1024 * 1024))

github_repository="${SOURCE_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-$DEFAULT_GITHUB_REPOSITORY}}"
gitee_owner="${GITEE_OWNER:-$DEFAULT_GITEE_OWNER}"
gitee_repository="${GITEE_REPO:-$DEFAULT_GITEE_REPOSITORY}"
max_asset_bytes="${GITEE_MAX_ASSET_BYTES:-$DEFAULT_MAX_ASSET_BYTES}"
dry_run="${GITEE_DRY_RUN:-false}"
requested_tag="${1:-latest}"

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_command curl
require_command jq

[[ "$dry_run" == "true" || "$dry_run" == "false" ]] ||
  die "GITEE_DRY_RUN must be true or false"
if [[ "$dry_run" != "true" ]]; then
  [[ -n "${GITEE_TOKEN:-}" ]] || die "GITEE_TOKEN is required"
fi
[[ "$github_repository" == */* ]] ||
  die "SOURCE_GITHUB_REPOSITORY must have the form owner/repository"
[[ "$max_asset_bytes" =~ ^[0-9]+$ ]] || die "GITEE_MAX_ASSET_BYTES must be an integer"

work_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
work_dir="$(mktemp -d "$work_root/officecli-gitee-release.XXXXXX")"
readonly work_dir
trap 'rm -rf -- "$work_dir"' EXIT

assets_dir="$work_dir/assets"
release_json="$work_dir/github-release.json"
release_body="$work_dir/release-body.md"
gitee_response="$work_dir/gitee-response.json"
download_list="$work_dir/download-assets.txt"
mkdir -p "$assets_dir"
: >"$download_list"

github_api_get() {
  local path="$1"
  local -a headers=(
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2022-11-28'
    --header 'User-Agent: OfficeCLI-Gitee-release-mirror'
  )
  if [[ -n "${GH_TOKEN:-}" ]]; then
    headers+=(--header "Authorization: Bearer $GH_TOKEN")
  fi

  curl --fail --silent --show-error --location \
    --connect-timeout 30 --max-time 120 \
    --retry 3 --retry-all-errors \
    "${headers[@]}" \
    "https://api.github.com/$path"
}

if [[ -z "$requested_tag" || "$requested_tag" == "latest" ]]; then
  requested_tag="$(github_api_get "repos/$github_repository/releases/latest" | jq -er .tag_name)"
fi

[[ "$requested_tag" =~ ^v[0-9A-Za-z][0-9A-Za-z._-]*$ ]] ||
  die "refusing unexpected release tag: $requested_tag"

echo "Reading GitHub release $requested_tag from $github_repository..."
github_api_get "repos/$github_repository/releases/tags/$requested_tag" >"$release_json"

if [[ "$(jq -r '.draft' "$release_json")" == "true" ]]; then
  die "GitHub release $requested_tag is still a draft"
fi

release_name="$(jq -r '.name // .tag_name' "$release_json")"
prerelease="$(jq -r '.prerelease' "$release_json")"
target_commitish="$(jq -r '.target_commitish // "main"' "$release_json")"
[[ "$target_commitish" =~ ^[0-9A-Za-z][0-9A-Za-z._/-]*$ && "$target_commitish" != *..* ]] ||
  die "refusing unexpected target_commitish: $target_commitish"
jq -r '.body // ""' "$release_json" >"$release_body"

expected_asset_count="$(jq '.assets | length' "$release_json")"
(( expected_asset_count > 0 )) || die "GitHub release $requested_tag has no uploaded assets"
jq -e 'any(.assets[]; .name == "SHA256SUMS")' "$release_json" >/dev/null ||
  die "GitHub release $requested_tag does not contain SHA256SUMS"

# Reject unsupported files before creating a Gitee release. GitHub's asset size
# metadata lets a too-large release fail without first downloading its binaries.
while IFS=$'\t' read -r asset_name asset_size; do
  [[ -n "$asset_name" && "$asset_name" != */* && "$asset_name" != "." && "$asset_name" != ".." ]] ||
    die "refusing unexpected GitHub asset name: $asset_name"
  if (( asset_size > max_asset_bytes )); then
    die "$asset_name is $asset_size bytes; Gitee mirror limit is $max_asset_bytes bytes"
  fi
done < <(jq -r '.assets[] | [.name, .size] | @tsv' "$release_json")

gitee_request() {
  local method="$1"
  local path="$2"
  local output="$3"
  shift 3

  curl --silent --show-error --location \
    --connect-timeout 30 --max-time 900 \
    --request "$method" \
    --header "Authorization: Bearer $GITEE_TOKEN" \
    --output "$output" \
    --write-out '%{http_code}' \
    "$@" \
    "$GITEE_API_BASE$path"
}

attachments_path=""

refresh_attachments() {
  local status
  status="$(gitee_request GET "$attachments_path?per_page=100&page=1" "$gitee_response")"
  [[ "$status" == "200" ]] || {
    jq -r '.message // .' "$gitee_response" >&2 || true
    die "could not list Gitee release attachments (HTTP $status)"
  }
}

attachment_exists() {
  local asset_name="$1"
  jq -e --arg name "$asset_name" 'any(.[]; (.name // .filename) == $name)' \
    "$gitee_response" >/dev/null
}

gitee_release_exists=false
gitee_release_id=""

if [[ "$dry_run" == "true" ]]; then
  jq -r '.assets[].name' "$release_json" >"$download_list"
else
  release_path="/repos/$gitee_owner/$gitee_repository/releases/tags/$requested_tag"
  status="$(gitee_request GET "$release_path" "$gitee_response")"

  case "$status" in
    200)
      # Gitee returns HTTP 200 with a JSON null body when the tag exists but
      # no Release has been created for it yet.
      if jq -e 'type == "object" and .id != null' "$gitee_response" >/dev/null; then
        gitee_release_exists=true
        gitee_release_id="$(jq -er '.id' "$gitee_response")"
        attachments_path="/repos/$gitee_owner/$gitee_repository/releases/$gitee_release_id/attach_files"
        refresh_attachments
      else
        jq -n '[]' >"$gitee_response"
      fi
      ;;
    404)
      jq -n '[]' >"$gitee_response"
      ;;
    *)
      jq -r '.message // .' "$gitee_response" >&2 || true
      die "could not query Gitee release (HTTP $status)"
      ;;
  esac

  while IFS= read -r asset_name; do
    if ! attachment_exists "$asset_name"; then
      printf '%s\n' "$asset_name" >>"$download_list"
    fi
  done < <(jq -r '.assets[].name' "$release_json")

  missing_asset_count="$(wc -l <"$download_list" | tr -d ' ')"
  if (( missing_asset_count == 0 )); then
    echo "Gitee release is already complete:"
    echo "https://gitee.com/$gitee_owner/$gitee_repository/releases/tag/$requested_tag"
    exit 0
  fi

  echo "$missing_asset_count Gitee attachment(s) need synchronization."
  if ! grep -Fqx -- SHA256SUMS "$download_list"; then
    # Always fetch the manifest so every downloaded binary is verified, even
    # when SHA256SUMS itself already exists on Gitee.
    printf '%s\n' SHA256SUMS >>"$download_list"
  fi
fi

download_asset() {
  local asset_name="$1"
  local asset_url
  asset_url="$(jq -er --arg name "$asset_name" \
    '.assets[] | select(.name == $name) | .browser_download_url' "$release_json")"

  echo "Downloading: $asset_name"
  curl --fail --silent --show-error --location \
    --connect-timeout 30 --max-time 900 \
    --retry 3 --retry-all-errors \
    --header 'User-Agent: OfficeCLI-Gitee-release-mirror' \
    --output "$assets_dir/$asset_name" \
    "$asset_url"
}

echo "Downloading and verifying required release assets..."
while IFS= read -r asset_name; do
  download_asset "$asset_name"
done <"$download_list"

[[ -f "$assets_dir/SHA256SUMS" ]] || die "release does not contain SHA256SUMS"

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

while IFS= read -r -d '' asset_path; do
  asset_name="$(basename "$asset_path")"
  [[ "$asset_name" == "SHA256SUMS" ]] && continue

  expected_hash="$(awk -v asset="$asset_name" '
    {
      name = $2
      sub(/^\*/, "", name)
      if (name == asset) { print $1; exit }
    }
  ' "$assets_dir/SHA256SUMS")"
  [[ -n "$expected_hash" ]] || die "SHA256SUMS does not contain $asset_name"

  actual_hash="$(sha256_file "$asset_path")"
  [[ "$actual_hash" == "$expected_hash" ]] || die "checksum mismatch for $asset_name"
  echo "$asset_name: OK"
done < <(find "$assets_dir" -maxdepth 1 -type f -print0)

if [[ "$dry_run" == "true" ]]; then
  echo "Dry run complete; no Gitee changes were made."
  exit 0
fi

if [[ "$gitee_release_exists" != "true" ]]; then
  echo "Creating Gitee release $requested_tag..."
  create_path="/repos/$gitee_owner/$gitee_repository/releases"
  create_response="$work_dir/gitee-create-response.json"
  create_status="$(gitee_request POST "$create_path" "$create_response" \
    --data-urlencode "tag_name=$requested_tag" \
    --data-urlencode "name=$release_name" \
    --data-urlencode "body@$release_body" \
    --data-urlencode "target_commitish=$target_commitish" \
    --data-urlencode "prerelease=$prerelease")"

  if [[ "$create_status" =~ ^2 ]]; then
    gitee_release_id="$(jq -er '.id' "$create_response")"
  else
    # A lost response may leave a successfully-created release behind. Read it
    # once before failing so a retry remains idempotent.
    status="$(gitee_request GET "$release_path" "$gitee_response")"
    if [[ "$status" == "200" ]] &&
      jq -e 'type == "object" and .id != null' "$gitee_response" >/dev/null; then
      gitee_release_id="$(jq -er '.id' "$gitee_response")"
    else
      create_error="$(jq -r '.message // .error // .' "$create_response" 2>/dev/null || true)"
      echo "::error title=Gitee release creation failed::HTTP $create_status: $create_error"
      die "Gitee release creation failed (HTTP $create_status)"
    fi
  fi

  attachments_path="/repos/$gitee_owner/$gitee_repository/releases/$gitee_release_id/attach_files"
fi

refresh_attachments

while IFS= read -r -d '' asset_path; do
  asset_name="$(basename "$asset_path")"

  if attachment_exists "$asset_name"; then
    echo "Already mirrored: $asset_name"
    continue
  fi

  echo "Uploading: $asset_name"
  uploaded=false
  for attempt in 1 2 3; do
    status="$(gitee_request POST "$attachments_path" "$work_dir/upload-response.json" \
      --form "file=@$asset_path;filename=$asset_name")"

    if [[ "$status" =~ ^2 ]]; then
      uploaded=true
      break
    fi

    # If the response was lost after Gitee stored the file, recognize it as a
    # success instead of uploading a duplicate on the next attempt.
    refresh_attachments
    if attachment_exists "$asset_name"; then
      uploaded=true
      break
    fi

    if (( attempt < 3 )); then
      sleep $((attempt * 2))
    fi
  done

  if [[ "$uploaded" != "true" ]]; then
    jq -r '.message // .' "$work_dir/upload-response.json" >&2 || true
    die "failed to upload $asset_name to Gitee (HTTP $status)"
  fi

  refresh_attachments
done < <(find "$assets_dir" -maxdepth 1 -type f -print0)

missing_assets=0
while IFS= read -r asset_name; do
  if ! attachment_exists "$asset_name"; then
    echo "Missing after upload: $asset_name" >&2
    missing_assets=$((missing_assets + 1))
  fi
done < <(jq -r '.assets[].name' "$release_json")

(( missing_assets == 0 )) || die "$missing_assets Gitee release attachments are missing"

echo "Gitee release mirror is complete:"
echo "https://gitee.com/$gitee_owner/$gitee_repository/releases/tag/$requested_tag"
