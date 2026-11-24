#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
bin=$(swift build -c release --show-bin-path)
destination="${1:-$HOME/Applications}/Task Desk.app"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
app="$stage/Task Desk.app"
mkdir -p "$app/Contents/"{MacOS,Helpers,Resources}
install -m755 "$bin/TaskDesk" "$app/Contents/MacOS/TaskDesk"
install -m755 "$bin/taskctl" "$app/Contents/Helpers/taskctl"
sips -s format png -Z 620 Branding/movedot-wordmark.svg --out "$app/Contents/Resources/Wordmark.png" >/dev/null
sips -s format png -z 1024 1024 Branding/movedot-icon.svg --out "$stage/icon.png" >/dev/null
icons="$stage/AppIcon.iconset"
mkdir "$icons"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$stage/icon.png" --out "$icons/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$stage/icon.png" --out "$icons/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icons" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Task Desk</string>
<key>CFBundleDisplayName</key><string>Task Desk</string>
<key>CFBundleIdentifier</key><string>com.movedot.taskdesk</string>
<key>CFBundleExecutable</key><string>TaskDesk</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>com.movedot.taskdesk</string>
<key>CFBundleURLSchemes</key><array><string>taskdesk</string></array>
</dict></array>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.19</string>
<key>CFBundleVersion</key><string>20</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Helpers/taskctl"
codesign --force --sign - "$app"
mkdir -p "$(dirname "$destination")"
ditto "$app" "$destination"
codesign --verify --strict "$destination"
echo "Installed $destination"
