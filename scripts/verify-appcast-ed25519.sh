#!/usr/bin/env bash
# Verify a Sparkle / WinSparkle appcast Ed25519 signature against a public key.
#
# Usage: scripts/verify-appcast-ed25519.sh <appcast.xml> <base64-public-key>
#
# The installer named by the appcast enclosure must sit next to the appcast.
set -euo pipefail

appcast="${1:?usage: $0 <appcast.xml> <base64-public-key>}"
key_b64="${2:?usage: $0 <appcast.xml> <base64-public-key>}"
[[ -f "$appcast" ]] || { echo "error: appcast not found: $appcast" >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/langlang-appcast-verify.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

sig_b64="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$appcast" | head -1)"
url="$(sed -n 's/.*url="\([^"]*\)".*/\1/p' "$appcast" | head -1)"
[[ -n "$sig_b64" && -n "$url" ]] ||
  { echo "error: appcast is missing the enclosure URL or edSignature" >&2; exit 1; }

binary="$(dirname "$appcast")/${url##*/}"
[[ -f "$binary" ]] ||
  { echo "error: enclosure not found next to appcast: ${url##*/}" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) b64d='base64 -D' ;;
  *) b64d='base64 -d' ;;
esac

printf '%s' "$sig_b64" | $b64d >"$tmp/sig.bin"
printf '%s' "$key_b64" | $b64d >"$tmp/pub.raw"
[[ "$(wc -c <"$tmp/pub.raw" | tr -d ' ')" == "32" ]] ||
  { echo "error: Ed25519 public key must decode to 32 bytes" >&2; exit 1; }

# Ed25519 SubjectPublicKeyInfo header followed by the raw public key.
{
  printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'
  cat "$tmp/pub.raw"
} >"$tmp/pub.der"

# Ed25519 one-shot verification needs OpenSSL 3.x (-rawin). 1.1.1 cannot
# verify Ed25519 through pkeyutl; set OPENSSL to an openssl3 binary there.
openssl_bin="${OPENSSL:-openssl}"
case "$("$openssl_bin" version)" in
  "OpenSSL 3."*) ;;
  *)
    echo "error: OpenSSL 3 is required for Ed25519 verification (set OPENSSL=/path/to/openssl3)" >&2
    exit 2
    ;;
esac

"$openssl_bin" pkeyutl -verify -pubin -keyform DER -inkey "$tmp/pub.der" \
  -rawin -in "$binary" -sigfile "$tmp/sig.bin" >/dev/null
echo "ok: appcast signature matches ${url##*/}"
