#!/usr/bin/env bash
# Install the LangLang feed puller on an nginx host.
#
# Usage:
#   sudo deploy/install-feed-puller.sh \
#     --macos-dir /srv/optimatist.ai/langlang/macos \
#     --windows-dir /srv/optimatist.ai/langlang/windows
#
# Idempotent: creates the service user and directories, writes
# /etc/langlang-feed.env when absent, installs the systemd units, and enables
# the 10-minute timer. Existing feed files are left in place.
set -euo pipefail

REPO_URL="${LANGLANG_RELEASES_URL:-https://github.com/OptimatistAI/langlang-releases.git}"
REPO_DIR="${LANGLANG_RELEASES_DIR:-/opt/langlang-releases}"
STATE_DIR="${LANGLANG_FEED_STATE_DIR:-/var/lib/langlang-feed}"
SERVICE_USER="${LANGLANG_FEED_USER:-langlang-feed}"
NGINX_GROUP="${LANGLANG_NGINX_GROUP:-www-data}"
NGINX_USER="${LANGLANG_NGINX_USER:-www-data}"
MACOS_DIR=""
WINDOWS_DIR=""

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  echo "error: $*" >&2
  exit 2
}

while (($#)); do
  case "$1" in
    --macos-dir)
      [[ $# -ge 2 ]] || fail "--macos-dir needs a value"
      MACOS_DIR="$2"
      shift
      ;;
    --windows-dir)
      [[ $# -ge 2 ]] || fail "--windows-dir needs a value"
      WINDOWS_DIR="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

[[ "$(id -u)" == "0" ]] || fail "run this as root (sudo)"
[[ -n "$MACOS_DIR" && -n "$WINDOWS_DIR" ]] ||
  fail "both --macos-dir and --windows-dir are required"
[[ "$MACOS_DIR" == /* && "$WINDOWS_DIR" == /* ]] ||
  fail "feed directories must be absolute paths"

for cmd in git curl jq openssl systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required"
done
case "$(openssl version)" in
  "OpenSSL 3."*) ;;
  *) fail "OpenSSL 3 is required for Ed25519 verification (found: $(openssl version))" ;;
esac
getent group "$NGINX_GROUP" >/dev/null || fail "nginx group '$NGINX_GROUP' does not exist"

if [[ -d "$REPO_DIR/.git" ]]; then
  echo "==> Update $REPO_DIR"
  git -C "$REPO_DIR" pull --ff-only
elif [[ -e "$REPO_DIR" ]]; then
  fail "$REPO_DIR exists but is not a git checkout"
else
  echo "==> Clone $REPO_URL"
  git clone --depth 1 "$REPO_URL" "$REPO_DIR"
fi

if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  echo "==> Create $SERVICE_USER"
  useradd --system --home "$STATE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi

echo "==> Create directories"
for dir in "$STATE_DIR" "$MACOS_DIR" "$WINDOWS_DIR"; do
  install -d -o "$SERVICE_USER" -g "$NGINX_GROUP" -m 2755 "$dir"
done

if [[ -f /etc/langlang-feed.env ]]; then
  echo "==> Keep existing /etc/langlang-feed.env"
  keys_path="$(sed -n 's/^LANGLANG_PUBLIC_KEYS_FILE=//p' /etc/langlang-feed.env | tail -1)"
  if [[ -n "$keys_path" && ! -f "$keys_path" ]]; then
    echo "warning: /etc/langlang-feed.env points to missing keys file: $keys_path"
    echo "         set LANGLANG_PUBLIC_KEYS_FILE=$REPO_DIR/config/public-keys.env"
  fi
else
  echo "==> Write /etc/langlang-feed.env"
  cat >/etc/langlang-feed.env <<EOF
LANGLANG_RELEASES_REPO=OptimatistAI/langlang-releases
LANGLANG_FEED_STATE_DIR=$STATE_DIR
LANGLANG_MACOS_FEED_DIR=$MACOS_DIR
LANGLANG_WINDOWS_FEED_DIR=$WINDOWS_DIR
LANGLANG_PUBLIC_KEYS_FILE=$REPO_DIR/config/public-keys.env
EOF
  chmod 0644 /etc/langlang-feed.env
fi

echo "==> Install systemd units"
sed -e "s|/opt/langlang-releases|$REPO_DIR|g" \
  -e "s|Group=www-data|Group=$NGINX_GROUP|" \
  "$REPO_DIR/deploy/systemd/langlang-feed-puller.service" \
  >/etc/systemd/system/langlang-feed-puller.service
install -m 0644 "$REPO_DIR/deploy/systemd/langlang-feed-puller.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now langlang-feed-puller.timer

echo "==> Check nginx readability"
for dir in "$MACOS_DIR" "$WINDOWS_DIR"; do
  if id -u "$NGINX_USER" >/dev/null 2>&1 &&
    runuser -u "$NGINX_USER" -- test -r "$dir" 2>/dev/null &&
    runuser -u "$NGINX_USER" -- test -x "$dir" 2>/dev/null; then
    echo "ok: $NGINX_USER can traverse and read $dir"
  else
    echo "warning: cannot confirm $NGINX_USER traversal of $dir; check parent directory permissions"
  fi
done

cat <<EOF

Installed. Next:

  sudo -u $SERVICE_USER $REPO_DIR/scripts/feed-puller.sh --dry-run --platform all
  sudo systemctl start langlang-feed-puller.service
  journalctl -u langlang-feed-puller.service -f

After the first publish, verify:

  curl -fsSL https://optimatist.ai/langlang/macos/appcast.xml
  curl -fsSL https://optimatist.ai/langlang/windows/appcast.xml

The puller writes files as $SERVICE_USER:$NGINX_GROUP with mode 0644, so
nginx can serve them. If nginx returns 403, check AppArmor/SELinux and that
the webroot's parent directories are traversable by $NGINX_GROUP.
EOF
