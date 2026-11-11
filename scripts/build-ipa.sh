#!/usr/bin/env bash
# Builds build/CoverflexBudget.ipa for AltStore or SideStore.
#
# AltStore re-signs the app with your Apple ID. It reads the App Group entitlement from the
# binaries to create the App Group on your account, so the script ad hoc signs each bundle
# with its .entitlements file. Without the entitlement the widget cannot read the app's data.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet

xcodebuild build \
  -project CoverflexBudget.xcodeproj \
  -scheme CoverflexBudget \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -quiet

app="build/DerivedData/Build/Products/Release-iphoneos/CoverflexBudget.app"
widget="$app/PlugIns/CoverflexBudgetWidget.appex"

# Sign the extension first: the app signature covers the extension.
codesign --force --sign - --entitlements Widget/CoverflexBudgetWidget.entitlements "$widget"
codesign --force --sign - --entitlements App/CoverflexBudget.entitlements "$app"

rm -rf build/ipa build/CoverflexBudget.ipa
mkdir -p build/ipa/Payload
cp -R "$app" build/ipa/Payload/
(cd build/ipa && zip -qry ../CoverflexBudget.ipa Payload)
rm -rf build/ipa

echo "Built build/CoverflexBudget.ipa"
