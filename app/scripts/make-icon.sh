#!/usr/bin/env bash
# make-icon.sh OUT.icns — renders the icon and packs it into an .icns.
set -euo pipefail
OUT="$1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swift "$(dirname "$0")/make-icon.swift" "$TMP/icon.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT"
