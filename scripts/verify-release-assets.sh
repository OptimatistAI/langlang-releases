#!/usr/bin/env bash
# Verify one platform's release asset directory.
#
# Usage: scripts/verify-release-assets.sh <dir> <macos|windows> [public-keys.env]
#
# The directory must contain the installer, appcast.xml, and SHA256SUMS.
set -euo pipefail

dir="${1:?usage: $0 <dir> <macos|windows> [public-keys.env]}"
platform="${2:?usage: $0 <dir> <macos|windows> [public-keys.env]}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
keys_file="${3:-$script_dir/../config/public-keys.env}"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -d "$dir" ]] || fail "asset directory not found: $dir"
[[ -f "$keys_file" ]] || fail "public keys file not found: $keys_file"
cd "$dir"
[[ -f SHA256SUMS ]] || fail "SHA256SUMS is missing"
[[ -f appcast.xml ]] || fail "appcast.xml is missing"

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c SHA256SUMS
else
  shasum -a 256 -c SHA256SUMS
fi

case "$platform" in
  macos) pattern='*.dmg' ;;
  windows) pattern='*.exe' ;;
  *) fail "unknown platform: $platform" ;;
esac
shopt -s nullglob
binaries=($pattern)
((${#binaries[@]} == 1)) ||
  fail "expected one $pattern asset, found ${#binaries[@]}"

# shellcheck disable=SC1090
source "$keys_file"
case "$platform" in
  macos) key="${MACOS_SPARKLE_PUBLIC_KEY:-}" ;;
  windows) key="${WINDOWS_WINSPARKLE_PUBLIC_KEY:-}" ;;
esac
[[ -n "$key" ]] || fail "no public key configured for $platform"

"$script_dir/verify-appcast-ed25519.sh" "$dir/appcast.xml" "$key"
echo "ok: $platform assets verified ($dir)"
