#!/usr/bin/env bash
# Usage: scripts/set-icon.sh my-icon.png  → resized to 1024x1024, alpha removed
set -euo pipefail
src="${1:?usage: set-icon.sh icon.png}"
dst="$(dirname "$0")/../ios/JapuszkoInjector/Assets.xcassets/AppIcon.appiconset/icon.png"
magick "$src" -resize 1024x1024^ -gravity center -extent 1024x1024 -background black -alpha remove -alpha off "$dst"
echo "icon set → $dst"
