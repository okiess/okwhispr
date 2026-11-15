#!/bin/zsh
# Generates the app icon: renders AppIcon.png with make_icon.swift, builds a
# .iconset, and produces AppIcon.icns next to this script.
set -euo pipefail
here=${0:A:h}
png="$here/AppIcon.png"
iconset="$here/AppIcon.iconset"

swift "$here/make_icon.swift" "$png"

rm -rf "$iconset"
mkdir -p "$iconset"
# iconset size -> pixel size
declare -a specs=(
  "16x16:16" "16x16@2x:32" "32x32:32" "32x32@2x:64"
  "128x128:128" "128x128@2x:256" "256x256:256" "256x256@2x:512"
  "512x512:512" "512x512@2x:1024"
)
for entry in "${specs[@]}"; do
  name="${entry%%:*}"
  px="${entry##*:}"
  sips -z "$px" "$px" "$png" --out "$iconset/icon_${name}.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$here/AppIcon.icns"
echo "wrote $here/AppIcon.icns"
