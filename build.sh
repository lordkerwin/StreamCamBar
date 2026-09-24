#!/bin/zsh
# Builds StreamCamBar.app. `./build.sh install` also copies it to ~/Applications and launches it.
set -euo pipefail
cd "${0:A:h}"

APP=build/StreamCamBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -module-cache-path build/ModuleCache -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/StreamCamBar" Sources/StreamCamBar/*.swift \
  -framework IOKit -framework CoreMediaIO -framework ServiceManagement

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.seankerwin.StreamCamBar</string>
  <key>CFBundleName</key><string>StreamCamBar</string>
  <key>CFBundleExecutable</key><string>StreamCamBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x StreamCamBar || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/StreamCamBar.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/StreamCamBar.app
  echo "Installed to ~/Applications/StreamCamBar.app"
fi
