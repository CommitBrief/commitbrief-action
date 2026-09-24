#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# install.sh — install the commitbrief CLI for the composite action.
#
# Called by action.yml's "Install commitbrief" step. Implements ADR-0044:
#
#   1. Resolve the `version` input (CB_VERSION):
#        vX.Y.Z / X.Y.Z (prerelease suffix allowed)  -> release path
#        latest  -> newest stable tag from the releases API -> release path
#        anything else (branch, commit SHA)            -> source fallback
#   2. Map RUNNER_OS / RUNNER_ARCH to the goreleaser archive name. A platform
#      with no release asset takes the source fallback, with a warning.
#   3. Download the archive and checksums.txt from the GitHub release.
#   4. Verify the archive's SHA-256 against checksums.txt. A missing entry or
#      a mismatch is a hard failure; there is NO fallback on verification
#      failure, because a source build would turn a bad download into a
#      silent success.
#   5. Extract only the binary into $RUNNER_TEMP/commitbrief-bin and add
#      that directory to $GITHUB_PATH.
#
# Source fallback: the script does not build anything itself. It writes
# `method=source` and `ref=<ref>` to $GITHUB_OUTPUT; action.yml then runs
# actions/setup-go + `go install` only when method == source.
#
# Trust model (ADR-0044 §3): checksums.txt is unsigned and is served from the
# same release as the archive. The check proves integrity (no truncated or
# corrupted download), not provenance: whoever can publish release assets can
# publish a matching checksums.txt. Transport security comes from TLS.
#
# Environment:
#   CB_VERSION              required; the action's `version` input
#   GITHUB_TOKEN            optional; authenticates the `latest` lookup, and
#                           is only sent when GITHUB_SERVER_URL is github.com
#   GITHUB_SERVER_URL       set by the runner; anything other than
#                           https://github.com (GitHub Enterprise Server)
#                           makes the `latest` lookup anonymous, so a GHES
#                           token never reaches api.github.com
#   RUNNER_OS, RUNNER_ARCH  set by the runner
#   RUNNER_TEMP, GITHUB_PATH required; set by the runner
#   GITHUB_OUTPUT           optional; receives method= and ref=

set -euo pipefail

readonly REPO="CommitBrief/commitbrief"
readonly API_LATEST="https://api.github.com/repos/${REPO}/releases/latest"
readonly DOWNLOAD_BASE="https://github.com/${REPO}/releases/download"
readonly RELEASE_RE='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
readonly STABLE_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
readonly SOURCE_REF_RE='^[0-9A-Za-z][0-9A-Za-z._/-]*$'
readonly SHA256_RE='^[0-9a-f]{64}$'
# Every request, and every redirect it follows, is HTTPS with TLS >= 1.2.
CURL_OPTS=(-fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --retry-delay 2)
readonly CURL_OPTS

# Workflow commands are read from stderr as well as stdout. stderr keeps the
# message visible when fail runs inside a $(...) capture.
fail() {
  echo "::error::commitbrief install: $*" >&2
  exit 1
}

set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

# source_fallback <ref> <reason> — hand off to action.yml's setup-go +
# go install steps. Only ever reached for refs or platforms that have no
# release asset, never after a download or verification failure.
source_fallback() {
  local ref=$1 reason=$2
  [[ "$ref" =~ $SOURCE_REF_RE ]] || fail "version '$ref' is neither a release tag, 'latest', nor a valid git ref"
  echo "::warning::commitbrief install: ${reason}. Building '${ref}' from source with go install: this is slower and is not verified against release checksums."
  set_output method source
  set_output ref "$ref"
  exit 0
}

# fetch <url> <dest> — HTTPS only, fails on any non-2xx response.
fetch() {
  curl "${CURL_OPTS[@]}" -o "$2" "$1"
}

# latest_token — the token to send to api.github.com, or nothing. On GitHub
# Enterprise Server the job token belongs to the GHES instance: sending it to
# github.com would leak a credential to another service and fail with 401.
latest_token() {
  local server=${GITHUB_SERVER_URL:-https://github.com}
  if [ "${server%/}" = "https://github.com" ]; then
    printf '%s' "${GITHUB_TOKEN:-}"
  fi
}

resolve_latest() {
  local json tag token
  token=$(latest_token)
  if [ -n "$token" ]; then
    # Header via --config on stdin keeps the token out of the process list.
    json=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
      curl "${CURL_OPTS[@]}" --config - \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "$API_LATEST") || fail "could not resolve 'latest' from $API_LATEST"
  else
    json=$(curl "${CURL_OPTS[@]}" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "$API_LATEST") || fail "could not resolve 'latest' from $API_LATEST (unauthenticated; the API rate limit may apply)"
  fi
  # The API may answer pretty-printed or minified; match the key anywhere.
  tag=$(printf '%s\n' "$json" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 |
    sed -E 's/.*"([^"]*)"$/\1/') || true
  [[ "$tag" =~ $STABLE_RE ]] || fail "the releases API returned an unexpected tag_name '${tag}' for 'latest'"
  printf '%s\n' "$tag"
}

sha256_of() {
  local sum
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum "$1" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 "$1" | awk '{print $1}')
  else
    fail "neither sha256sum nor shasum is available to verify the download"
  fi
  printf '%s\n' "$sum" | tr 'A-F' 'a-f'
}

# expected_sum <checksums-file> <asset> — mirrors ParseChecksums in
# commitbrief/internal/upgrade/asset.go: "<sha256>  <name>" lines, a leading
# '*' (binary mode) is not part of the name, the last matching line wins.
expected_sum() {
  awk -v asset="$2" '
    NF == 2 { name = $2; sub(/^\*/, "", name); if (name == asset) sum = $1 }
    END { print sum }
  ' "$1" | tr 'A-F' 'a-f'
}

# ---------------------------------------------------------------- 1. version

version=${CB_VERSION:-}
[ -n "$version" ] || fail "the version input is empty"

if [ "$version" = "latest" ]; then
  tag=$(resolve_latest)
  echo "Resolved version 'latest' to ${tag}."
elif [[ "$version" =~ $RELEASE_RE ]]; then
  tag="v${version#v}"
else
  source_fallback "$version" "'${version}' is not a release tag"
fi

# --------------------------------------------------------------- 2. platform

os=""
arch=""
case "${RUNNER_OS:-}" in
  Linux) os=linux ;;
  macOS) os=darwin ;;
  Windows) os=windows ;;
esac
case "${RUNNER_ARCH:-}" in
  X64) arch=x86_64 ;;
  ARM64) arch=arm64 ;;
esac
if [ -z "$os" ] || [ -z "$arch" ]; then
  source_fallback "$tag" "no release asset for RUNNER_OS='${RUNNER_OS:-}' RUNNER_ARCH='${RUNNER_ARCH:-}'"
fi

[ -n "${RUNNER_TEMP:-}" ] || fail "RUNNER_TEMP is not set"
[ -n "${GITHUB_PATH:-}" ] || fail "GITHUB_PATH is not set"

# Same template as .goreleaser.yaml archives.name_template and
# internal/upgrade/asset.go AssetName: no leading "v", amd64 -> x86_64,
# Windows archives are .zip, everything else .tar.gz.
if [ "$os" = "windows" ]; then
  asset="commitbrief_${tag#v}_${os}_${arch}.zip"
  binary="commitbrief.exe"
else
  asset="commitbrief_${tag#v}_${os}_${arch}.tar.gz"
  binary="commitbrief"
fi

temp_root=$RUNNER_TEMP
if command -v cygpath >/dev/null 2>&1; then
  temp_root=$(cygpath -u "$RUNNER_TEMP")
fi
work=$(mktemp -d "${temp_root}/commitbrief-dl.XXXXXX")
trap 'rm -rf "$work"' EXIT

# --------------------------------------------------------------- 3. download

echo "Downloading ${asset} (${tag})."
fetch "${DOWNLOAD_BASE}/${tag}/${asset}" "${work}/${asset}" ||
  fail "could not download ${asset} from release ${tag}. The tag may not exist or may have no asset for this platform; pin a newer release tag, or a branch or commit SHA to build from source."

fetch "${DOWNLOAD_BASE}/${tag}/checksums.txt" "${work}/checksums.txt" ||
  fail "could not download checksums.txt from release ${tag}; refusing to install an unverified binary."

# ----------------------------------------------------------------- 4. verify

want=$(expected_sum "${work}/checksums.txt" "$asset")
[[ "$want" =~ $SHA256_RE ]] || fail "checksums.txt of ${tag} has no valid SHA-256 entry for ${asset}; refusing to install."
got=$(sha256_of "${work}/${asset}")
if [ "$got" != "$want" ]; then
  fail "checksum mismatch for ${asset}: expected ${want}, got ${got}. Refusing to install."
fi

# ---------------------------------------------------------------- 5. install

bin_dir="${temp_root}/commitbrief-bin"
rm -rf "$bin_dir"
mkdir -p "$bin_dir"

if [ "$os" = "windows" ]; then
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "${work}/${asset}" "$binary" -d "$bin_dir"
  elif command -v 7z >/dev/null 2>&1; then
    # 7z is a native Windows binary: MSYS does not rewrite a path glued to
    # the -o flag, so hand it a Windows path.
    out_dir=$bin_dir
    if command -v cygpath >/dev/null 2>&1; then out_dir=$(cygpath -w "$bin_dir"); fi
    7z e -y -o"$out_dir" "${work}/${asset}" "$binary" >/dev/null
  else
    fail "neither unzip nor 7z is available to extract ${asset}"
  fi
else
  tar -xzf "${work}/${asset}" -C "$bin_dir" "$binary"
  chmod +x "${bin_dir}/${binary}"
fi
[ -f "${bin_dir}/${binary}" ] || fail "${asset} did not contain ${binary}"

path_entry=$bin_dir
if command -v cygpath >/dev/null 2>&1; then
  path_entry=$(cygpath -w "$bin_dir")
fi
printf '%s\n' "$path_entry" >>"$GITHUB_PATH"

set_output method prebuilt
set_output ref "$tag"

echo "Installed commitbrief ${tag} (prebuilt, sha256 verified) into ${path_entry}."
"${bin_dir}/${binary}" --version
