#!/usr/bin/env bash
# Builds a release of Pane: a universal app in a .dmg, notarized when a Developer ID
# certificate is installed, plus the appcast.xml that Sparkle reads for updates.
#
#   scripts/release.sh 1.0.0             # build into build/release/, publish nothing
#   scripts/release.sh 1.0.0 --publish   # also create the GitHub release v1.0.0
#
# Sets the version in Resources/Info.plist (and bumps the build number); commit that.
# Notarizing needs a stored notarytool profile, made once with:
#   xcrun notarytool store-credentials pane-notary --apple-id <id> --team-id <team>
# PANE_NOTARY_PROFILE picks a different profile name.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
PUBLISH=0
[ "${2:-}" = "--publish" ] && PUBLISH=1
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Usage: scripts/release.sh <version, e.g. 1.0.0> [--publish]" >&2
  exit 1
fi

REPO="jhokanson00/Pane"
PROFILE="${PANE_NOTARY_PROFILE:-pane-notary}"
PLIST=Resources/Info.plist
OUT=build/release
DMG="$OUT/Pane-$VERSION.dmg"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

# Version: the build number goes up by one each release.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
echo "==> Pane $VERSION (build $BUILD)"

PANE_UNIVERSAL=1 ./scripts/build-app.sh release
APP=build/Pane.app

NOTARIZE=0
if codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  NOTARIZE=1
elif [ "$PUBLISH" = 1 ]; then
  echo "No Developer ID Application certificate in the keychain; only notarized builds are published." >&2
  exit 1
else
  echo
  echo "!! No Developer ID certificate: making a TEST build (not notarized, not for publishing)."
  echo
fi

notarize() {
  echo "==> Notarizing $(basename "$1") (usually a few minutes)"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

rm -rf "$OUT"
mkdir -p "$OUT"

if [ "$NOTARIZE" = 1 ]; then
  ditto -c -k --keepParent "$APP" "$OUT/Pane.zip"
  notarize "$OUT/Pane.zip"
  xcrun stapler staple "$APP"
  rm "$OUT/Pane.zip"
fi

echo "==> Making $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Pane.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Pane $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

if [ "$NOTARIZE" = 1 ]; then
  IDENTITY="$(codesign -dv --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority=Developer ID Application/ { print $2; exit }')"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

# Sparkle: the update is the .dmg itself, signed with the EdDSA key in the keychain
# (made by generate_keys --account Pane; its public half is SUPublicEDKey in Info.plist).
echo "==> Writing appcast.xml"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account Pane "$DMG")"
MIN_OS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST")"
cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Pane</title>
    <item>
      <title>Pane $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Pane-$VERSION.dmg"
                 type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF

# Release notes, edited on GitHub afterwards if needed.
{
  echo "Download **Pane-$VERSION.dmg** below, open it, and drag Pane to Applications."
  echo
  echo "Requires macOS $MIN_OS or later (captions need macOS 26). Runs on Apple silicon and Intel."
} > "$OUT/notes.md"

echo
echo "Built:"
ls -lh "$OUT"

if [ "$PUBLISH" = 1 ]; then
  echo "==> Publishing GitHub release v$VERSION"
  gh release create "v$VERSION" "$DMG" "$OUT/appcast.xml" \
    --repo "$REPO" --title "Pane $VERSION" --notes-file "$OUT/notes.md"
else
  echo
  echo "Not published. Commit Resources/Info.plist, then rerun with --publish, or:"
  echo "  gh release create v$VERSION $DMG $OUT/appcast.xml --repo $REPO --title \"Pane $VERSION\" --notes-file $OUT/notes.md"
fi
