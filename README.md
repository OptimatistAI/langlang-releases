<p align="center">
  <img src="docs/assets/logo.png" width="128" alt="LangLang">
</p>

# LangLang releases

Public release artifacts and publishing tooling for LangLang desktop builds.

This repository hosts **installers and update feeds**, not application source.
The app source lives in the private `OptimatistAI/langlang` repository.

GitHub attaches auto-generated source archives (`Source code (zip/tar.gz)`) to
every release. Here they contain only this repository's tooling — release
scripts, public keys, and systemd units — never the application source.

## Release layout

| Platform | Tag | Assets |
|----------|-----|--------|
| macOS | `macos-v<marketing>+<build>` | notarized `.dmg`, `appcast.xml`, `SHA256SUMS` |
| Windows | `windows-v<marketing>+<build>` | NSIS `.exe`, portable `.zip`, `appcast.xml`, `SHA256SUMS` |

Future Android/OHOS artifacts use the same pattern (`android-v…`, `ohos-v…`).
iOS is distributed through TestFlight/App Store and is not published here.

Each appcast is signed with the Ed25519 key compiled into the app; the matching
public keys are in [`config/public-keys.env`](config/public-keys.env).

## Verify a release manually

```bash
scripts/verify-release-assets.sh <asset-dir> macos
scripts/verify-release-assets.sh <asset-dir> windows
```

The verifier checks `SHA256SUMS`, requires exactly one installer, and verifies
the appcast Ed25519 signature against the baked-in public key. Ed25519
verification needs OpenSSL 3; on a host where `openssl` is 1.1.1, set
`OPENSSL=/path/to/openssl3`.

## Run the feed puller on the update server

The puller polls the newest published release for each platform, verifies it,
and copies the installer + appcast into the nginx feed directory. The binary is
published first and `appcast.xml` last, so clients never see a feed pointing at
a missing file.

```bash
# Test without touching the live feed.
scripts/feed-puller.sh --dry-run --platform all

# Publish once.
scripts/feed-puller.sh --platform all
```

Configuration is read from the environment; see
[`deploy/langlang-feed.env.example`](deploy/langlang-feed.env.example).

### systemd installation

```bash
sudo git clone https://github.com/OptimatistAI/langlang-releases.git /opt/langlang-releases
sudo useradd --system --home /var/lib/langlang-feed --shell /usr/sbin/nologin langlang-feed
sudo install -d -o langlang-feed -g www-data -m 2755 \
  /var/lib/langlang-feed \
  /srv/optimatist.ai/langlang/macos \
  /srv/optimatist.ai/langlang/windows
sudo install -m 0640 /opt/langlang-releases/deploy/langlang-feed.env.example /etc/langlang-feed.env
# Edit /etc/langlang-feed.env for the real webroot and keys path.
sudo install -m 0644 /opt/langlang-releases/deploy/systemd/langlang-feed-puller.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now langlang-feed-puller.timer
sudo systemctl start langlang-feed-puller.service
journalctl -u langlang-feed-puller.service -f
```

The service user needs write access to the two feed directories and read access
to `config/public-keys.env`. Updates to the puller itself are deliberate: pull
the repository and re-run the service; it is not self-updating.

## Rollback

The previous appcast is kept under `LANGLANG_FEED_STATE_DIR` as
`<platform>.appcast.previous`. Restore it to stop offering the new version;
older installers remain in the feed directory.

## Security notes

- Only public installers and update metadata live here; signing private keys
  never enter this repository.
- The verifier treats release assets as untrusted input and never executes them.
- The puller works without a GitHub token because the repository is public; an
  optional `GITHUB_TOKEN` only raises API rate limits.
