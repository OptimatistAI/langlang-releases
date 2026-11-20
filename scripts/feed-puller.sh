#!/usr/bin/env bash
# Pull the newest LangLang desktop release from the public releases repo and
# publish its installer + appcast into the nginx feed directories.
#
# Usage:
#   scripts/feed-puller.sh [--dry-run] [--force] [--platform macos|windows|all]
#
# Configuration (environment or deploy/langlang-feed.env):
#   LANGLANG_RELEASES_REPO     default OptimatistAI/langlang-releases
#   LANGLANG_FEED_STATE_DIR    default /var/lib/langlang-feed
#   LANGLANG_MACOS_FEED_DIR    e.g. /srv/optimatist.ai/langlang/macos
#   LANGLANG_WINDOWS_FEED_DIR  e.g. /srv/optimatist.ai/langlang/windows
#   LANGLANG_PUBLIC_KEYS_FILE  default <repo>/config/public-keys.env
#   GITHUB_TOKEN               optional; raises GitHub API rate limits
#   OPENSSL                    openssl3 binary if `openssl` is 1.1.1
set -euo pipefail

REPO="${LANGLANG_RELEASES_REPO:-OptimatistAI/langlang-releases}"
API="${GITHUB_API_URL:-https://api.github.com}"
STATE_DIR="${LANGLANG_FEED_STATE_DIR:-/var/lib/langlang-feed}"
MACOS_FEED_DIR="${LANGLANG_MACOS_FEED_DIR:-}"
WINDOWS_FEED_DIR="${LANGLANG_WINDOWS_FEED_DIR:-}"
TOKEN="${GITHUB_TOKEN:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="${LANGLANG_PUBLIC_KEYS_FILE:-$script_dir/../config/public-keys.env}"

DRY_RUN=0
FORCE=0
PLATFORM=all
WORK_DIRS=()
LOCK_DIR=""

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail() { log "error: $*"; exit 2; }

cleanup() {
  if ((${#WORK_DIRS[@]})); then
    rm -rf "${WORK_DIRS[@]}"
  fi
  if [[ -n "$LOCK_DIR" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --platform)
      [[ $# -ge 2 ]] || fail "--platform needs a value"
      PLATFORM="$2"
      shift
      ;;
    -h | --help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

case "$PLATFORM" in
  macos | windows | all) ;;
  *) fail "unknown platform: $PLATFORM" ;;
esac

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
[[ -f "$KEYS_FILE" ]] || fail "public keys file not found: $KEYS_FILE"

mkdir -p "$STATE_DIR"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$STATE_DIR/.lock"
  flock -n 9 || fail "another feed pull is already running"
else
  LOCK_DIR="$STATE_DIR/.lock.d"
  mkdir "$LOCK_DIR" 2>/dev/null || fail "another feed pull is already running"
fi

auth=()
if [[ -n "$TOKEN" ]]; then
  auth=(-H "Authorization: Bearer $TOKEN")
fi

releases_json="$STATE_DIR/releases.json"
curl -fsSL ${auth[@]+"${auth[@]}"} -H 'Accept: application/vnd.github+json' \
  "$API/repos/$REPO/releases?per_page=50" -o "$releases_json"

publish_platform() {
  local platform="$1"
  local prefix="$2"
  local feed_dir="$3"

  if [[ -z "$feed_dir" ]]; then
    log "skip $platform: feed directory is not configured"
    return 0
  fi
  [[ -d "$feed_dir" ]] || fail "$platform feed directory not found: $feed_dir"
  [[ -w "$feed_dir" ]] || fail "$platform feed directory is not writable: $feed_dir"

  local last_tag=""
  if [[ -f "$STATE_DIR/$platform.last_tag" ]]; then
    last_tag="$(cat "$STATE_DIR/$platform.last_tag")"
  fi

  local tag
  tag="$(jq -r --arg p "$prefix" '
    [ .[] | select((.draft // false) == false) | select(.tag_name | startswith($p)) ]
    | sort_by(try (.tag_name | split("+") | last | tonumber) catch 0)
    | last | .tag_name // empty
  ' "$releases_json")"
  [[ -n "$tag" ]] || { log "no published $platform release in $REPO"; return 0; }

  if [[ "$tag" == "$last_tag" && "$FORCE" != "1" ]]; then
    log "$platform already current: $tag"
    return 0
  fi
  log "$platform: ${last_tag:-none} -> $tag"

  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/langlang-feed-$platform.XXXXXX")"
  WORK_DIRS+=("$work")

  local name url
  while IFS=$'\t' read -r name url; do
    [[ -n "$name" && -n "$url" ]] || continue
    curl -fsSL ${auth[@]+"${auth[@]}"} -o "$work/$name" "$url"
  done < <(jq -r --arg t "$tag" '
    .[] | select(.tag_name == $t) | .assets[] | [.name, .browser_download_url] | @tsv
  ' "$releases_json")
  [[ -n "$(ls -A "$work")" ]] || fail "$tag has no downloadable assets"

  bash "$script_dir/verify-release-assets.sh" "$work" "$platform" "$KEYS_FILE"

  local binaries=()
  case "$platform" in
    macos)
      shopt -s nullglob
      binaries=("$work"/*.dmg)
      ;;
    windows)
      shopt -s nullglob
      binaries=("$work"/*.exe)
      ;;
  esac
  ((${#binaries[@]} == 1)) || fail "expected one installer for $tag, found ${#binaries[@]}"
  local binary="${binaries[0]}"
  local binary_name
  binary_name="$(basename "$binary")"

  if ((DRY_RUN)); then
    log "dry-run: would publish $binary_name + appcast.xml to $feed_dir"
    return 0
  fi

  if [[ -f "$feed_dir/appcast.xml" ]]; then
    cp -p "$feed_dir/appcast.xml" "$STATE_DIR/$platform.appcast.previous"
  fi

  # Binary first, appcast last: clients never see an appcast for a missing file.
  install -m 0644 "$binary" "$feed_dir/.$binary_name.tmp"
  mv -f "$feed_dir/.$binary_name.tmp" "$feed_dir/$binary_name"
  install -m 0644 "$work/appcast.xml" "$feed_dir/.appcast.xml.tmp"
  mv -f "$feed_dir/.appcast.xml.tmp" "$feed_dir/appcast.xml"

  printf '%s\n' "$tag" >"$STATE_DIR/$platform.last_tag"
  log "published $platform $tag to $feed_dir"
}

if [[ "$PLATFORM" == "all" || "$PLATFORM" == "macos" ]]; then
  publish_platform macos "macos-v" "$MACOS_FEED_DIR"
fi
if [[ "$PLATFORM" == "all" || "$PLATFORM" == "windows" ]]; then
  publish_platform windows "windows-v" "$WINDOWS_FEED_DIR"
fi
