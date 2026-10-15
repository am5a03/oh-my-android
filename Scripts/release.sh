#!/bin/zsh
# Prepare a local, self-contained capture artifact. Nothing is published to GitHub.
# Development: CAPTURE_DEPENDENCY_CACHE=/path/to/cache Scripts/release.sh --development
# Release: TEAM_ID=... CAPTURE_DEPENDENCY_CACHE=/path/to/cache Scripts/release.sh [--skip-notarize]
set -euo pipefail
cd "$(dirname "$0")/.."
MODE=release
NOTARIZE=1
for argument in "$@"; do
  case "$argument" in
    --development) MODE=development; NOTARIZE=0 ;;
    --skip-notarize) NOTARIZE=0 ;;
    *) print -u2 "Usage: Scripts/release.sh [--development | --skip-notarize]"; exit 2 ;;
  esac
done
CAPTURE_DEPENDENCY_CACHE=${CAPTURE_DEPENDENCY_CACHE:-$HOME/Library/Caches/MobileCapture/Dependencies}
[[ -d "$CAPTURE_DEPENDENCY_CACHE" ]] || { print -u2 "Prepare the pinned dependency cache first. See docs/CAPTURE-DISTRIBUTION.md."; exit 1; }
IDENTITY=-
if [[ "$MODE" == release ]]; then
  TEAM_ID=${TEAM_ID:?Set TEAM_ID to your own Apple Developer team ID, or use --development}
  IDENTITY=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v team="($TEAM_ID)" '/Developer ID Application/ && index($0, team) { print $2; exit }')
  [[ -n "$IDENTITY" ]] || { print -u2 "No Developer ID Application identity for the selected team. iOS development/distribution certificates cannot sign this Mac release."; exit 1; }
fi

DERIVED="build/CaptureDistribution/$MODE"
BUILD="$DERIVED/Build/Products/Release"
BUNDLE="Oh My Android.app"
mkdir -p "$DERIVED"
xcodegen generate > "$DERIVED/generate.log" 2>&1
if ! xcodebuild -project OhMyAndroid.xcodeproj -scheme OhMyAndroid -configuration Release \
    -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
    build > "$DERIVED/build.log" 2>&1; then
  /usr/bin/tail -30 "$DERIVED/build.log" >&2
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$BUILD/$BUNDLE/Contents/Info.plist")
STAMP=$(/bin/date -u +%Y%m%d-%H%M%S)
DESTINATION="dist/MobileCapture-$VERSION-arm64-$MODE-$STAMP"
[[ ! -e "$DESTINATION" ]] || { print -u2 "Artifact destination already exists: $DESTINATION"; exit 1; }
mkdir -p "$DESTINATION"
/usr/bin/ditto "$BUILD/$BUNDLE" "$DESTINATION/$BUNDLE"
APP="$PWD/$DESTINATION/$BUNDLE"
swift Scripts/bundle-capture-dependencies.swift install --app "$APP" \
  --cache-root "$CAPTURE_DEPENDENCY_CACHE" --sign "$IDENTITY"

SIGN=(/usr/bin/codesign --force --sign "$IDENTITY")
if [[ "$MODE" == release ]]; then SIGN+=(--options runtime --timestamp)
else SIGN+=(--options 0 --timestamp=none)
fi
# Sign inside out; dependency packaging already signed every engine code object with this identity.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
for helper in ohmyandroid-mcp mobile-capture-host mobile-capture-proxy; do
  "${SIGN[@]}" "$APP/Contents/MacOS/$helper"
done
"${SIGN[@]}" --entitlements Sources/App/OhMyAndroid.entitlements "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
swift Scripts/bundle-capture-dependencies.swift smoke --app "$APP" --cache-root "$CAPTURE_DEPENDENCY_CACHE"
Scripts/test-mcp.py "$APP/Contents/MacOS/ohmyandroid-mcp"

ZIP="MobileCapture-$VERSION-arm64-$MODE.zip"
(cd "$DESTINATION" && /usr/bin/ditto -c -k --keepParent "$BUNDLE" "$ZIP")
if (( NOTARIZE )); then
  xcrun notarytool submit "$DESTINATION/$ZIP" --keychain-profile "${NOTARY_PROFILE:-mobile-capture}" --wait
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
print "Updates are disabled until this fork configures its own feed and signing key. No upload or publication was performed."
