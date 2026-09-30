#!/bin/sh
# Akkari CLI installer. Everything runs inside main() so a truncated download executes nothing.
# Usage: curl -fsSL https://raw.githubusercontent.com/tekara-inc/akkari-cli-releases/main/install.sh | sh
# Environment: AKKARI_INSTALL_VERSION (default latest), AKKARI_CONFIG_DIR (parent of the akkari home),
#              AKKARI_RELEASES_BASE_URL (default GitHub releases), AKKARI_NO_MODIFY_PATH (skip shell rc edits).
set -eu

main() {
  base="${AKKARI_RELEASES_BASE_URL:-https://github.com/tekara-inc/akkari-cli-releases/releases}"
  base="${base%/}"
  if [ -n "${AKKARI_CONFIG_DIR:-}" ]; then home="$AKKARI_CONFIG_DIR/akkari"; else home="$HOME/.config/akkari"; fi
  platform="$(detect_platform)"
  work="$(mktemp -d "${TMPDIR:-/tmp}/akkari-install.XXXXXX")"
  trap 'rm -rf "$work"' EXIT INT TERM

  if [ -n "${AKKARI_INSTALL_VERSION:-}" ]; then
    version="$AKKARI_INSTALL_VERSION"
  else
    fetch "$base/latest/download/manifest.json" "$work/manifest.json"
    version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$work/manifest.json" | head -n 1)"
    [ -n "$version" ] || fail "could not determine the latest version"
  fi
  release="$base/download/v$version"
  name="akkari-$version-$platform"
  say "Installing akkari $version for $platform"
  fetch "$release/SHA256SUMS" "$work/SHA256SUMS"
  fetch "$release/$name.tar.gz" "$work/$name.tar.gz"
  expected="$(grep " $name.tar.gz\$" "$work/SHA256SUMS" | awk '{print $1}' | head -n 1)"
  [ -n "$expected" ] || fail "SHA256SUMS has no entry for $name.tar.gz"
  actual="$(sha256_of "$work/$name.tar.gz")"
  [ "$actual" = "$expected" ] || fail "checksum mismatch for $name.tar.gz"

  versions="$home/cli/versions"
  mkdir -p "$versions"
  chmod 700 "$home" "$home/cli" 2>/dev/null || true
  rm -rf "$versions/$version.partial"
  mkdir "$versions/$version.partial"
  tar -xzf "$work/$name.tar.gz" -C "$versions/$version.partial" --strip-components 1
  [ -x "$versions/$version.partial/akkari" ] || chmod 755 "$versions/$version.partial/akkari"
  rm -rf "$versions/$version"
  mv "$versions/$version.partial" "$versions/$version"

  stop_legacy_tracker "$home/cli/current/akkari"
  # -n replaces an existing symlink instead of descending into the directory it points at.
  ln -sfn "versions/$version" "$home/cli/current"
  write_receipt "$home" "$version" "$platform" "$actual"

  mkdir -p "$HOME/.local/bin"
  ln -sfn "$home/cli/current/akkari" "$HOME/.local/bin/akkari"
  warn_shadow "$home/cli/current/akkari"
  "$home/cli/current/akkari" update --verify-install >/dev/null 2>&1 || fail "the installed release failed signature verification; remove $home/cli and retry"
  ensure_path
  say ""
  say "akkari $version installed to $home/cli/current/akkari"
  say "Next:"
  say "  akkari auth login"
  say "  akkari setup --apply"
}

detect_platform() {
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in
    Darwin) os=darwin
      if [ "$arch" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then arch=arm64; fi ;;
    Linux) os=linux
      if ldd --version 2>&1 | grep -qi musl; then fail "musl-based Linux is not supported in this release"; fi ;;
    *) fail "unsupported operating system: $os" ;;
  esac
  case "$arch" in
    x86_64|amd64) arch=x64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) fail "unsupported architecture: $arch" ;;
  esac
  printf '%s-%s\n' "$os" "$arch"
}

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o "$2" "$1" || fail "download failed: $1"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1" || fail "download failed: $1"
  else fail "curl or wget is required"; fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else fail "sha256sum or shasum is required"; fi
}

# A tracker started by an older install outside versions/ keeps serving until stopped; stop it before the swap.
stop_legacy_tracker() {
  existing="$(command -v akkari 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "$1" ] && [ "$existing" != "$HOME/.local/bin/akkari" ]; then
    say "Stopping the tracker from the previous installation at $existing"
    "$existing" tracker stop --json >/dev/null 2>&1 || true
    say "After installing, run: akkari setup --apply   (rewrites host hooks to the new location)"
  fi
}

# After linking, another akkari earlier on PATH would keep running the old version.
warn_shadow() {
  resolved="$(command -v akkari 2>/dev/null || true)"
  [ -n "$resolved" ] || return 0
  [ "$resolved" = "$HOME/.local/bin/akkari" ] && return 0
  [ "$resolved" = "$1" ] && return 0
  say "Warning: another akkari is earlier on PATH at $resolved; remove it or put ~/.local/bin before it so akkari runs the new version."
}

write_receipt() {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$1/cli/install-receipt.json.tmp"
  printf '{\n  "schema": 1,\n  "version": "%s",\n  "installed_at": "%s",\n  "method": "install-script",\n  "source": "github:tekara-inc/akkari-cli-releases",\n  "platform": "%s",\n  "tarball_sha256": "%s"\n}\n' "$2" "$now" "$3" "$4" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$1/cli/install-receipt.json"
}

ensure_path() {
  case ":$PATH:" in *":$HOME/.local/bin:"*) return ;; esac
  line='export PATH="$HOME/.local/bin:$PATH"'
  if [ -z "${AKKARI_NO_MODIFY_PATH:-}" ]; then
    for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
      if [ -f "$rc" ] && ! grep -qF "$line" "$rc"; then printf '\n# Added by the Akkari CLI installer\n%s\n' "$line" >> "$rc"; fi
    done
    if [ -d "$HOME/.config/fish" ]; then mkdir -p "$HOME/.config/fish/conf.d"; printf 'fish_add_path -g "$HOME/.local/bin"\n' > "$HOME/.config/fish/conf.d/akkari.fish"; fi
  fi
  say "Add ~/.local/bin to your PATH (open a new shell afterwards):"
  say "  $line"
}

say() { printf '%s\n' "$1"; }
fail() { printf 'akkari install: %s\n' "$1" >&2; exit 1; }

main "$@"
