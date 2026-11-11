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

# The .entitlements files contain $(APP_GROUP_IDENTIFIER). Xcode replaces it only when it signs,
# and this build does not sign, so replace it here.
app_group=$(xcodebuild -project CoverflexBudget.xcodeproj -scheme CoverflexBudget -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '$1 ~ /^ *APP_GROUP_IDENTIFIER$/ { print $2; exit }')
[[ -n "$app_group" ]] || { echo "Could not read APP_GROUP_IDENTIFIER" >&2; exit 1; }
mkdir -p build/entitlements
sign() { # <bundle> <entitlements file>
  local resolved="build/entitlements/$(basename "$2")"
  sed "s/\$(APP_GROUP_IDENTIFIER)/$app_group/g" "$2" > "$resolved"
  codesign --force --sign - --entitlements "$resolved" "$1"
}

# Sign the extension first: the app signature covers the extension.
sign "$widget" Widget/CoverflexBudgetWidget.entitlements
sign "$app" App/CoverflexBudget.entitlements

rm -rf build/ipa build/CoverflexBudget.ipa
mkdir -p build/ipa/Payload
cp -R "$app" build/ipa/Payload/
(cd build/ipa && zip -qry ../CoverflexBudget.ipa Payload)
rm -rf build/ipa

echo "Built build/CoverflexBudget.ipa"
