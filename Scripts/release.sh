#!/bin/zsh
# Prepare one independent local product. Nothing is published to GitHub.
# Defaults to Mobile Capture for compatibility with the capture prototype's build command.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE=release
PRODUCT=capture
NOTARIZE=1
USB_CANDIDATE=0
for argument in "$@"; do
  case "$argument" in
    --development) MODE=development; NOTARIZE=0 ;;
    --skip-notarize) NOTARIZE=0 ;;
    --oh-my-android) PRODUCT=android ;;
    --mobile-capture) PRODUCT=capture ;;
    --experimental-iphone-usb) USB_CANDIDATE=1 ;;
    *) print -u2 "Usage: Scripts/release.sh [--development | --skip-notarize] [--mobile-capture | --oh-my-android] [--experimental-iphone-usb]"; exit 2 ;;
  esac
done
if (( USB_CANDIDATE )) && [[ "$MODE" != development || "$PRODUCT" != capture ]]; then
  print -u2 "The experimental iPhone USB candidate is available only for a Mobile Capture development build."
  exit 2
fi
IDENTITY=-
BUILD_OPTIONS=()
if [[ "$PRODUCT" == capture ]]; then
  SCHEME=MobileCapture
  BUNDLE="Mobile Capture.app"
  ARTIFACT=MobileCapture
  DEFAULT_NOTARY_PROFILE=mobile-capture
  ENTITLEMENTS=Sources/MobileCaptureApp/MobileCapture.entitlements
  CAPTURE_DEPENDENCY_CACHE=${CAPTURE_DEPENDENCY_CACHE:-$HOME/Library/Caches/MobileCapture/Dependencies}
  [[ -d "$CAPTURE_DEPENDENCY_CACHE" ]] || { print -u2 "Prepare the pinned dependency cache first. See docs/CAPTURE-DISTRIBUTION.md."; exit 1; }
else
  SCHEME=OhMyAndroid
  BUNDLE="Oh My Android.app"
  ARTIFACT=OhMyAndroid
  DEFAULT_NOTARY_PROFILE=oh-my-android
  ENTITLEMENTS=Sources/App/OhMyAndroid.entitlements
fi
if [[ "$MODE" == release ]]; then
  if [[ "$PRODUCT" == capture ]]; then
    CAPTURE_BUNDLE_IDENTIFIER=${CAPTURE_BUNDLE_IDENTIFIER:?Set your owner-controlled capture bundle ID for release; local.mobilecapture.development is for development only}
  fi
  if [[ -n "${CAPTURE_BUNDLE_IDENTIFIER:-}" ]]; then
    [[ "$CAPTURE_BUNDLE_IDENTIFIER" != local.* && "$CAPTURE_BUNDLE_IDENTIFIER" == *.* && "$CAPTURE_BUNDLE_IDENTIFIER" != *[^A-Za-z0-9.-]* ]] || { print -u2 "Choose an owner-controlled reverse-DNS capture bundle identifier, not the provisional local identity."; exit 1; }
    BUILD_OPTIONS+=("MOBILE_CAPTURE_BUNDLE_IDENTIFIER=$CAPTURE_BUNDLE_IDENTIFIER")
  fi
  TEAM_ID=${TEAM_ID:?Set TEAM_ID to your own Apple Developer team ID, or use --development}
  IDENTITY=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v team="($TEAM_ID)" '/Developer ID Application/ && index($0, team) { print $2; exit }')
  [[ -n "$IDENTITY" ]] || { print -u2 "No Developer ID Application identity for the selected team. iOS certificates cannot sign this Mac release."; exit 1; }
fi
DERIVED="build/${ARTIFACT}Distribution/$MODE"
BUILD="$DERIVED/Build/Products/Release"
mkdir -p "$DERIVED"
xcodegen generate > "$DERIVED/generate.log" 2>&1
if ! xcodebuild -project OhMyAndroid.xcodeproj -scheme "$SCHEME" -configuration Release \
    -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
    "${BUILD_OPTIONS[@]}" build > "$DERIVED/build.log" 2>&1; then
  /usr/bin/tail -30 "$DERIVED/build.log" >&2
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$BUILD/$BUNDLE/Contents/Info.plist")
STAMP=$(/bin/date -u +%Y%m%d-%H%M%S)
DESTINATION="dist/$ARTIFACT-$VERSION-arm64-$MODE-$STAMP"
[[ ! -e "$DESTINATION" ]] || { print -u2 "Artifact destination already exists: $DESTINATION"; exit 1; }
mkdir -p "$DESTINATION"
/usr/bin/ditto "$BUILD/$BUNDLE" "$DESTINATION/$BUNDLE"
APP="$PWD/$DESTINATION/$BUNDLE"
/usr/bin/ditto LICENSE "$APP/Contents/Resources/PROJECT-LICENSE.txt"
if [[ "$PRODUCT" == capture ]]; then
  if [[ "$MODE" == release ]]; then
    /usr/libexec/PlistBuddy -c 'Set :MobileCaptureDevelopmentIdentity false' "$APP/Contents/Info.plist"
  fi
  swift Scripts/bundle-capture-dependencies.swift install --app "$APP" \
    --cache-root "$CAPTURE_DEPENDENCY_CACHE" --sign "$IDENTITY"
  if (( USB_CANDIDATE )); then
    python3 -B Scripts/bundle-iphone-usb-candidate.py install --app "$APP" \
      --lock Dependencies/Capture/iphone-usb-arm64.candidate.lock.json --sign "$IDENTITY"
  fi
fi
SIGN=(/usr/bin/codesign --force --sign "$IDENTITY")
if [[ "$MODE" == release ]]; then SIGN+=(--options runtime --timestamp)
else SIGN+=(--options 0 --timestamp=none)
fi
if [[ "$PRODUCT" == android ]]; then
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  "${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
  "${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
  "${SIGN[@]}" "$SPARKLE/Autoupdate"
  "${SIGN[@]}" "$SPARKLE/Updater.app"
  "${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
  HELPERS=(ohmyandroid-mcp)
else
  HELPERS=(mobile-capture-host mobile-capture-proxy)
fi
for helper in "${HELPERS[@]}"; do "${SIGN[@]}" "$APP/Contents/MacOS/$helper"; done
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
python3 -B Scripts/check-capture-product.py --product "$PRODUCT" --app "$APP"
if [[ "$PRODUCT" == capture ]]; then
  swift Scripts/bundle-capture-dependencies.swift smoke --app "$APP" --cache-root "$CAPTURE_DEPENDENCY_CACHE"
  if (( USB_CANDIDATE )); then
    python3 -B Scripts/bundle-iphone-usb-candidate.py smoke --app "$APP"
  fi
else
  Scripts/test-mcp.py "$APP/Contents/MacOS/ohmyandroid-mcp"
fi
ZIP="$ARTIFACT-$VERSION-arm64-$MODE.zip"
(cd "$DESTINATION" && /usr/bin/ditto -c -k --keepParent "$BUNDLE" "$ZIP")
if (( NOTARIZE )); then
  xcrun notarytool submit "$DESTINATION/$ZIP" --keychain-profile "${NOTARY_PROFILE:-$DEFAULT_NOTARY_PROFILE}" --wait
  xcrun stapler staple "$APP"
  /bin/rm "$DESTINATION/$ZIP"
  (cd "$DESTINATION" && /usr/bin/ditto -c -k --keepParent "$BUNDLE" "$ZIP")
  /usr/sbin/spctl -a -vv "$APP"
fi
(cd "$DESTINATION" && /usr/bin/shasum -a 256 "$ZIP" > SHA256SUMS)
print "Prepared: $DESTINATION/$ZIP"
if [[ "$MODE" == development ]]; then
  print "Development artifact: ad-hoc signed, Apple Silicon, not notarized. No Gatekeeper settings were changed."
elif (( ! NOTARIZE )); then
  print "Developer ID signed; notarization was explicitly skipped."
fi
print "Updates remain disabled pending independent release configuration. No upload or publication was performed."
