#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/.build/ButterflyAppIcon.iconset"
SOURCE="$ROOT/assets/icon_1024.png"

cd "$ROOT"
swift scripts/make_icon.swift
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ROOT/assets/AppIcon.icns"
sips -z 256 256 "$SOURCE" --out "$ROOT/assets/icon-preview.png" >/dev/null
echo "OK → assets/AppIcon.icns"
