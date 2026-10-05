#!/usr/bin/env bash
# Builds a release of Pane: a universal app in a .dmg, notarized when a Developer ID
# certificate is installed, plus the signed appcast.xml that Sparkle reads for updates.
#
#   scripts/release.sh 1.1.0             # build into build/release/, publish nothing
#   scripts/release.sh 1.1.0 --publish   # also tag, push main and publish v1.1.0
#
# What's new goes in docs/releases/<version>.md (Markdown). It's shown in Pane's update
# window and on the GitHub release; --publish needs it.
#
# Sets the version in Resources/Info.plist, with a build number past the one that's
# live. From a clean tree that change is committed, and the build is publishable:
# --publish then reuses it if nothing has been committed since, or builds again.
# Publishing tags the commit that was built and needs a clean main that includes
# origin/main.
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
TEAM_ID="DHGK36B2V9"
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
PROFILE="${PANE_NOTARY_PROFILE:-pane-notary}"
PLIST=Resources/Info.plist
NOTES="docs/releases/$VERSION.md"
OUT=build/release
DMG="$OUT/Pane-$VERSION.dmg"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

fail() { echo "$*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Publishing tags exactly what was built, so start from a clean, current main.
if [ "$PUBLISH" = 1 ]; then
  [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "Publish from main."
  [ -z "$(git status --porcelain)" ] || fail "Commit or stash your changes first."
  git fetch --quiet origin main
  git merge-base --is-ancestor origin/main HEAD || fail "origin/main has commits main doesn't. Pull first."
  if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null ||
     git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null; then
    fail "v$VERSION is already tagged."
  fi
  [ -f "$NOTES" ] || fail "Write what's new in $NOTES first."
fi
if [ -f "$NOTES" ] && grep -q ']]>' "$NOTES"; then
  fail "$NOTES can't contain ]]>."
fi

publish() {
  echo "==> Tagging v$VERSION and pushing main"
  git tag -a "v$VERSION" -m "Pane $VERSION"
  git push origin main "refs/tags/v$VERSION"

  # A draft first: publish only once GitHub holds exactly what was built, so the feed
  # every copy of Pane reads never points at a missing or different file.
  echo "==> Uploading a draft release v$VERSION"
  gh release create "v$VERSION" "$DMG" "$OUT/appcast.xml" --repo "$REPO" \
    --verify-tag --draft --title "Pane $VERSION" --notes-file "$OUT/notes.md"
  gh release download "v$VERSION" --repo "$REPO" --dir "$TMP/uploaded"
  cmp "$DMG" "$TMP/uploaded/Pane-$VERSION.dmg"
  cmp "$OUT/appcast.xml" "$TMP/uploaded/appcast.xml"

  echo "==> Publishing v$VERSION"
  gh release edit "v$VERSION" --repo "$REPO" --draft=false --latest
  curl -fsSL "$FEED" | cmp -s - "$OUT/appcast.xml" ||
    echo "!! $FEED doesn't serve this appcast.xml yet. Check it again in a minute."
  echo "Published: https://github.com/$REPO/releases/tag/v$VERSION"
}

# A notarized build of this very commit is already in build/release: publish that.
BUILT_FROM="$OUT/built-from"
if [ "$PUBLISH" = 1 ] && [ -f "$DMG" ] && [ -f "$OUT/appcast.xml" ] && [ -f "$OUT/notes.md" ] &&
   [ "$(cat "$BUILT_FROM" 2>/dev/null)" = "$VERSION $(git rev-parse HEAD)" ]; then
  echo "==> Publishing the build of $(git rev-parse --short HEAD) in $OUT"
  publish
  exit 0
fi
CLEAN=0
if [ -z "$(git status --porcelain)" ]; then
  CLEAN=1
fi

# The update must be signed with the key whose public half every copy of Pane carries.
PUBLIC_KEY="$(plist SUPublicEDKey)"
[ "$("$SPARKLE_BIN/generate_keys" --account Pane -p)" = "$PUBLIC_KEY" ] ||
  fail "The EdDSA key in the keychain (account Pane) isn't SUPublicEDKey in $PLIST."

# Version: the build number must be above the live one or Sparkle never offers it.
# Rerunning for the same version keeps the build number it already has.
LIVE_BUILD="$(curl -fsSL "$FEED" | sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' | head -1)" ||
  [ "$PUBLISH" = 0 ] || fail "Couldn't read the live appcast at $FEED."
LIVE_BUILD="${LIVE_BUILD:-0}"
BUILD="$(plist CFBundleVersion)"
if [ "$(plist CFBundleShortVersionString)" != "$VERSION" ] || [ "$BUILD" -le "$LIVE_BUILD" ]; then
  BUILD=$(( (BUILD > LIVE_BUILD ? BUILD : LIVE_BUILD) + 1 ))
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
  if [ "$CLEAN" = 1 ]; then
    git commit --quiet -m "Pane $VERSION" -- "$PLIST"
  fi
fi
echo "==> Pane $VERSION (build $BUILD; live: $LIVE_BUILD)"

PANE_RELEASE=1 PANE_UNIVERSAL=1 ./scripts/build-app.sh release
APP=build/Pane.app

# Read the signature once: grep -q or awk's exit would cut codesign off mid-output,
# which pipefail counts as a failure.
SIGNATURE_INFO="$(codesign -dv --verbose=2 "$APP" 2>&1)"
SIGNED_BY="$(sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p' <<<"$SIGNATURE_INFO")"
NOTARIZE=0
if [ -n "$SIGNED_BY" ]; then
  NOTARIZE=1
  # The shipped app: Pane's team, nothing but camera and microphone entitlements,
  # every nested piece signed.
  grep -qx "TeamIdentifier=$TEAM_ID" <<<"$SIGNATURE_INFO" || fail "$APP isn't signed by team $TEAM_ID."
  ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
  if grep -q 'disable-library-validation\|allow-dyld\|allow-unsigned\|get-task-allow' <<<"$ENTITLEMENTS"; then
    fail "$APP has a development entitlement; build it with a Developer ID identity."
  fi
  codesign --verify --deep --strict "$APP"
elif [ "$PUBLISH" = 1 ]; then
  fail "No Developer ID Application certificate in the keychain; only notarized builds are published."
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
  spctl --assess --type execute -v "$APP"
fi

echo "==> Making $DMG"
STAGE="$TMP/stage"
mkdir "$STAGE"
cp -R "$APP" "$STAGE/Pane.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Pane $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

if [ "$NOTARIZE" = 1 ]; then
  codesign --force --timestamp --sign "$SIGNED_BY" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

# Sparkle: the update is the .dmg itself, signed with the EdDSA key in the keychain
# (made by generate_keys --account Pane; its public half is SUPublicEDKey in Info.plist).
echo "==> Writing appcast.xml"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account Pane "$DMG")"

# Check the .dmg's signature the way Pane will: against SUPublicEDKey.
cat > "$TMP/check.swift" <<'SWIFT'
import CryptoKit
import Foundation
let args = CommandLine.arguments
guard let keyData = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let file = try? Data(contentsOf: URL(fileURLWithPath: args[3])),
      key.isValidSignature(signature, for: file)
else { exit(1) }
SWIFT
ED_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGNATURE")"
swift "$TMP/check.swift" "$PUBLIC_KEY" "$ED_SIGNATURE" "$DMG" ||
  fail "The .dmg's EdDSA signature doesn't check out against SUPublicEDKey."

if [ -f "$NOTES" ]; then
  WHATS_NEW="$(cat "$NOTES")"
else
  WHATS_NEW="Test build of Pane $VERSION."
fi
MIN_OS="$(plist LSMinimumSystemVersion)"
# The notes are inline (not a link) so the feed's signature covers them.
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
      <description sparkle:format="markdown"><![CDATA[
$WHATS_NEW
]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Pane-$VERSION.dmg"
                 type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF

# Pane 1.1 and later only accept a feed signed with the same key (SURequireSignedFeed).
"$SPARKLE_BIN/sign_update" --account Pane "$OUT/appcast.xml" >/dev/null
"$SPARKLE_BIN/sign_update" --account Pane --verify "$OUT/appcast.xml"

# Release notes, edited on GitHub afterwards if needed.
{
  echo "$WHATS_NEW"
  echo
  echo "## Download"
  echo
  echo "Download **Pane-$VERSION.dmg** below, open it, and drag Pane to Applications."
  echo
  echo "Requires macOS $MIN_OS or later (captions need macOS 26). Runs on Apple silicon and Intel."
  echo
  echo "Signed with Developer ID (team $TEAM_ID) and notarized by Apple."
  echo "SHA-256 of Pane-$VERSION.dmg: \`$(shasum -a 256 "$DMG" | cut -d' ' -f1)\`"
} > "$OUT/notes.md"

echo
echo "Built:"
ls -lh "$OUT"

# Publishable: notarized, from a commit with nothing left uncommitted.
if [ "$NOTARIZE" = 1 ] && [ "$CLEAN" = 1 ]; then
  echo "$VERSION $(git rev-parse HEAD)" > "$BUILT_FROM"
fi

if [ "$PUBLISH" = 1 ]; then
  publish
elif [ -f "$BUILT_FROM" ]; then
  echo
  echo "Not published. To publish this build: scripts/release.sh $VERSION --publish"
else
  echo
  echo "Not published, and not publishable: built from uncommitted changes or not notarized."
fi
