#!/bin/zsh
# Regenerate the macOS icon assets from the editable SVG. Requires ImageMagick.
set -eu
cd "$(dirname "$0")/.."

source_icon="docs/design/icons/playden-flat.svg"
asset_dir="App/Resources/Assets.xcassets/AppIcon.appiconset"

if ! command -v magick >/dev/null 2>&1; then
  print -u2 "ImageMagick is required to regenerate icons: brew install imagemagick"
  exit 1
fi

magick -background none "$source_icon" -resize 1024x1024 "$asset_dir/icon-1024.png"
for size in 16 32 64 128 256 512; do
  magick "$asset_dir/icon-1024.png" -filter Lanczos -resize "${size}x${size}" "$asset_dir/icon-${size}.png"
done
