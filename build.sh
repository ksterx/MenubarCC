#!/bin/bash
set -euo pipefail

VERSION="${1:-2.0.0}"
IDENTITY="Developer ID Application: Kosuke Ishikawa (44UPBHBKJV)"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Building MenubarCC v${VERSION}"

# Compile Swift sources
echo "==> Compiling..."
swiftc -O -whole-module-optimization \
    -framework Cocoa \
    -framework ServiceManagement \
    -framework UserNotifications \
    -target arm64-apple-macos13.0 \
    -o "${REPO_DIR}/MenubarCC-swift" \
    "${REPO_DIR}"/Sources/*.swift

# Create .app bundle
echo "==> Creating app bundle..."
rm -rf "${REPO_DIR}/dist/MenubarCC.app"
mkdir -p "${REPO_DIR}/dist/MenubarCC.app/Contents/"{MacOS,Resources}

cp "${REPO_DIR}/MenubarCC-swift" "${REPO_DIR}/dist/MenubarCC.app/Contents/MacOS/MenubarCC"
cp "${REPO_DIR}/menubarcc-icon.png" "${REPO_DIR}/dist/MenubarCC.app/Contents/Resources/"
cp "${REPO_DIR}/menubarcc_hook.py" "${REPO_DIR}/dist/MenubarCC.app/Contents/Resources/"
cp "${REPO_DIR}/MenubarCC.icns" "${REPO_DIR}/dist/MenubarCC.app/Contents/Resources/"

cat > "${REPO_DIR}/dist/MenubarCC.app/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MenubarCC</string>
    <key>CFBundleDisplayName</key>
    <string>MenubarCC</string>
    <key>CFBundleIdentifier</key>
    <string>com.ksterx.clawd</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>MenubarCC</string>
    <key>CFBundleIconFile</key>
    <string>MenubarCC.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Sign
echo "==> Signing..."
codesign --force --options runtime --timestamp \
    --sign "${IDENTITY}" \
    "${REPO_DIR}/dist/MenubarCC.app/Contents/MacOS/MenubarCC"
codesign --force --options runtime --timestamp \
    --sign "${IDENTITY}" \
    "${REPO_DIR}/dist/MenubarCC.app"

echo "==> Verifying..."
codesign -vv "${REPO_DIR}/dist/MenubarCC.app"

echo "==> Done: dist/MenubarCC.app (v${VERSION})"
