#!/usr/bin/env bash

set -euo pipefail
set -x

API="https://api.github.com/repos/telegramdesktop/tdesktop/releases/latest"

# GitHub-hosted runners usually have these, but the workflow also installs them.
# Use Bearer token if provided to avoid rate limits.
HDR=(
  -H "Accept:application/vnd.github+json"
  -H "User-Agent:telegram-appimage"
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  HDR+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
fi

curl -fsSL "${HDR[@]}" "$API" > /tmp/telegram.json

TARBALL_URL="$(
  jq -r '.assets[].browser_download_url | select(test("tsetup\\..*\\.tar\\.xz$"))' /tmp/telegram.json | head -n 1
)"
if [[ -z "$TARBALL_URL" || "$TARBALL_URL" == "null" ]]; then
  echo "ERROR: failed to find Linux tarball (tsetup.*.tar.xz) in latest release assets" >&2
  echo "Hint: check API response in /tmp/telegram.json, or set GITHUB_TOKEN to avoid rate limits." >&2
  exit 1
fi

VERSION="$(jq -r '.tag_name' /tmp/telegram.json)"
if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
  echo "ERROR: failed to read tag_name from GitHub API response" >&2
  exit 1
fi

echo "TELEGRAM_VERSION=$VERSION" >> "${GITHUB_ENV:?GITHUB_ENV not set (this script expects to run in GitHub Actions)}"

rm -rf Telegram AppDir dist package.tar.xz

wget -q "$TARBALL_URL" -O package.tar.xz

tar -xf package.tar.xz
rm -f package.tar.xz

# The tarball contains a Telegram/ directory with the binary + libs.
# Use it as AppDir root.
mv Telegram AppDir
rm -f AppDir/Updater || true

cp -f telegram.png AppDir/
cp -f telegram.desktop AppDir/

cat > AppDir/AppRun <<'APP_RUN'
#!/bin/sh
CURRENTDIR="$(dirname "$(readlink -f "$0")")"
export DESKTOPINTEGRATION=0
exec "${CURRENTDIR}/Telegram" "$@"
APP_RUN

chmod +x AppDir/AppRun AppDir/Telegram

ARCH="${ARCH:-x86_64}"
APPIMAGETOOL="appimagetool-${ARCH}.AppImage"

wget -q "https://github.com/AppImage/AppImageKit/releases/download/continuous/${APPIMAGETOOL}" -O "${APPIMAGETOOL}"
chmod +x "${APPIMAGETOOL}"

# Avoid relying on FUSE when running AppImage tools.
export APPIMAGE_EXTRACT_AND_RUN=1

UPINFO=""
if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
  UPINFO="gh-releases-zsync|$(echo "$GITHUB_REPOSITORY" | tr '/' '|')|continuous|Telegram*.AppImage.zsync"
fi

mkdir -p dist

if [[ -n "$UPINFO" ]]; then
  ARCH="$ARCH" "./${APPIMAGETOOL}" --comp gzip AppDir -n -u "$UPINFO"
else
  ARCH="$ARCH" "./${APPIMAGETOOL}" --comp gzip AppDir -n
fi

# Move outputs into dist/
shopt -s nullglob
# Only move Telegram outputs. Avoid a broad "*.AppImage*" glob here:
# - It overlaps with Telegram*.AppImage* and can create duplicates
# - It would also match appimagetool-*.AppImage itself
OUT=(Telegram*.AppImage*)
if (( ${#OUT[@]} == 0 )); then
  echo "ERROR: appimagetool produced no .AppImage outputs" >&2
  exit 1
fi

# Be robust against accidental duplicate matches (e.g. if someone adds a broader glob later).
declare -A _moved=()
for f in "${OUT[@]}"; do
  [[ "$f" == Telegram*.AppImage* ]] || continue
  [[ -e "$f" ]] || continue
  if [[ -n "${_moved[$f]+x}" ]]; then
    continue
  fi
  _moved[$f]=1
  mv -- "$f" dist/
done
