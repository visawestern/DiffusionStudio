#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Diffusion Studio"
BUNDLE="build/${APP_NAME}.app"
TARGET_ARCH="$(uname -m)"
DEPLOY_TARGET="14.0"
VERSION="1.0"
BUILD_NUMBER="1"
BUNDLE_ID="local.diffusionstudio.app"
ICON="build/AppIcon.icns"

rm -rf "build/${APP_NAME}.app"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"

echo "==> Компиляция (${TARGET_ARCH}, macOS ${DEPLOY_TARGET}+)"

swiftc \
  -O \
  -swift-version 5 \
  -target "${TARGET_ARCH}-apple-macosx${DEPLOY_TARGET}" \
  -o "${BUNDLE}/Contents/MacOS/DiffusionStudio" \
  Sources/Settings.swift \
  Sources/Progress.swift \
  Sources/EngineServer.swift \
  Sources/Runner.swift \
  Sources/Presets.swift \
  Sources/SettingsSheet.swift \
  Sources/RootView.swift \
  Sources/App.swift

if [[ ! -f "${ICON}" ]]; then
  echo "==> Генерация иконки"
  mkdir -p build
  swift Tools/make_icon.swift "${ICON}"
fi
cp "${ICON}" "${BUNDLE}/Contents/Resources/AppIcon.icns"

cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>DiffusionStudio</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>${DEPLOY_TARGET}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>MIT License. Локальная генерация изображений через stable-diffusion.cpp.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

echo "==> Подпись (ad-hoc)"

codesign --force --sign - --timestamp=none "${BUNDLE}" 2>/dev/null \
  || echo "   codesign пропущен"

echo
echo "Готово: $(cd "$(dirname "$BUNDLE")" && pwd)/${APP_NAME}.app"
echo "Запуск:  open \"build/${APP_NAME}.app\""