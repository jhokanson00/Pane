#!/usr/bin/env bash
# Builds a release of Pane: a universal app in a .dmg, notarized, plus the signed
# appcast.xml that Sparkle reads for updates.
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
# origin/main. Without a Developer ID certificate it makes a test .dmg only: nothing is
# signed for updates.
#
# Every copy of Pane accepts only updates and feeds signed with the EdDSA key whose
# public half is scripts/sparkle-public-key.txt (and SUPublicEDKey). Changing that key
# needs a new SUFeedURL too: a feed carries one signature, so one key's users would be
# cut off from updates.
#
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
PINNED_KEY="$(cat scripts/sparkle-public-key.txt)"
PROFILE="${PANE_NOTARY_PROFILE:-pane-notary}"
PLIST=Resources/Info.plist
NOTES="docs/releases/$VERSION.md"
OUT=build/release
DMG="$OUT/Pane-$VERSION.dmg"
BUILT_FROM="$OUT/built-from"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

fail() { echo "$*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

TMP="$(mktemp -d)"
MOUNT="$TMP/mount"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rm -rf "$TMP"' EXIT

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

# A signature checked with the pinned key alone, as every copy of Pane checks it.
verify() {
  swift scripts/verify-signature.swift "$PINNED_KEY" "$@" >/dev/null ||
    fail "$1 isn't signed with the key in scripts/sparkle-public-key.txt."
}

# The entitlements of $1 as "name=value" pairs, or nothing.
entitlements() {
  codesign -d --entitlements - --xml "$1" 2>/dev/null > "$TMP/entitlements.plist" || true
  [ -s "$TMP/entitlements.plist" ] || return 0
  plutil -p "$TMP/entitlements.plist" | sed -n 's/^ *"\(.*\)" => \(.*\)$/\1=\2/p' | sort | tr '\n' ' '
}

# What every copy of Pane that ships must be: Pane's team and the hardened runtime
# throughout, camera and microphone its only entitlements (Sparkle's helpers none),
# libraries only from inside the app and macOS, notarized, and set to take updates only
# from this repo's feed, signed with the pinned key.
check_app() {
  local app="$1" sparkle="$1/Contents/Frameworks/Sparkle.framework/Versions/B" part details
  codesign --verify --deep --strict "$app" || fail "$app: its signature doesn't verify."
  for part in "$app" "$sparkle/Sparkle" "$sparkle/Autoupdate" "$sparkle/Updater.app"; do
    details="$(codesign -dv --verbose=2 "$part" 2>&1)"
    grep -qx "TeamIdentifier=$TEAM_ID" <<<"$details" || fail "$part isn't signed by team $TEAM_ID."
    grep -q 'flags=0x[0-9a-f]*(.*runtime' <<<"$details" || fail "$part lacks the hardened runtime."
  done
  [ "$(entitlements "$app")" = "com.apple.security.device.audio-input=true com.apple.security.device.camera=true " ] ||
    fail "$app: entitlements aren't exactly camera and microphone: $(entitlements "$app")"
  for part in "$sparkle/Autoupdate" "$sparkle/Updater.app"; do
    [ -z "$(entitlements "$part")" ] || fail "$part has entitlements."
  done
  [ "$(otool -l "$app/Contents/MacOS/Pane" | awk '$1 == "path" { print $2 }' | sort -u | tr '\n' ' ')" = \
    "/usr/lib/swift @executable_path/../Frameworks " ] || fail "$app looks for libraries outside the app and macOS."
  local info="$app/Contents/Info.plist"
  [ "$(plist "$info" SUPublicEDKey)" = "$PINNED_KEY" ] || fail "$app: SUPublicEDKey isn't the pinned key."
  [ "$(plist "$info" SUFeedURL)" = "$FEED" ] || fail "$app: SUFeedURL isn't $FEED."
  # Both or neither: a signed feed without checking updates before opening them stops
  # the updater from starting at all.
  [ "$(plist "$info" SURequireSignedFeed)" = true ] && [ "$(plist "$info" SUVerifyUpdateBeforeExtraction)" = true ] ||
    fail "$app: SURequireSignedFeed and SUVerifyUpdateBeforeExtraction must both be on."
  xcrun stapler validate -q "$app" || fail "$app isn't notarized and stapled."
  spctl --assess --type execute "$app" || fail "Gatekeeper rejects $app."
}

# Everything that's about to go out, checked as users will get it: the feed's XML and
# signature, the .dmg's notarization and signature, and the app inside it.
verify_release() {
  xmllint --noout "$OUT/appcast.xml" || fail "$OUT/appcast.xml isn't well-formed XML."
  verify "$OUT/appcast.xml"
  verify "$DMG" "$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$OUT/appcast.xml")"
  local build
  build="$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$OUT/appcast.xml")"
  xcrun stapler validate -q "$DMG" || fail "$DMG isn't notarized and stapled."
  spctl --assess --type open --context context:primary-signature "$DMG" || fail "Gatekeeper rejects $DMG."
  mkdir -p "$MOUNT"
  hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG"
  check_app "$MOUNT/Pane.app"
  [ "$(plist "$MOUNT/Pane.app/Contents/Info.plist" CFBundleShortVersionString)" = "$VERSION" ] &&
    [ "$(plist "$MOUNT/Pane.app/Contents/Info.plist" CFBundleVersion)" = "$build" ] ||
    fail "The app in $DMG isn't version $VERSION, build $build, as the feed says."
  hdiutil detach -quiet "$MOUNT"
}

publish() {
  verify_release
  echo "==> Tagging v$VERSION and pushing main"
  git tag -a "v$VERSION" -m "Pane $VERSION"
  git push origin main "refs/tags/v$VERSION"

  # A draft first: publish only once GitHub holds exactly what was built, so the feed
  # every copy of Pane reads never points at a missing or different file. (With
  # Immutable Releases on, a published file can't be replaced, only superseded.)
  echo "==> Uploading a draft release v$VERSION"
  gh release create "v$VERSION" "$DMG" "$OUT/appcast.xml" --repo "$REPO" \
    --verify-tag --draft --title "Pane $VERSION" --notes-file "$OUT/notes.md"
  gh release download "v$VERSION" --repo "$REPO" --dir "$TMP/uploaded"
  cmp "$DMG" "$TMP/uploaded/Pane-$VERSION.dmg"
  cmp "$OUT/appcast.xml" "$TMP/uploaded/appcast.xml"

  echo "==> Publishing v$VERSION"
  gh release edit "v$VERSION" --repo "$REPO" --draft=false --latest
  # Pane checks in the background and says nothing if the feed is wrong, so look.
  curl -fsSL "$FEED" | cmp -s - "$OUT/appcast.xml" ||
    echo "!! $FEED doesn't serve this appcast.xml yet. Check it again in a minute."
  echo "Published: https://github.com/$REPO/releases/tag/v$VERSION"
}

# A notarized build of this very commit is already in build/release: publish that.
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

# The key the app carries, the key in the keychain and the pinned key must all be one.
[ "$(plist "$PLIST" SUPublicEDKey)" = "$PINNED_KEY" ] ||
  fail "SUPublicEDKey in $PLIST isn't scripts/sparkle-public-key.txt. Changing it needs a new SUFeedURL."

# Version: the build number must be above the live one or Sparkle never offers it.
# Rerunning for the same version keeps the build number it already has.
LIVE_BUILD="$(curl -fsSL "$FEED" | sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' | head -1)" ||
  [ "$PUBLISH" = 0 ] || fail "Couldn't read the live appcast at $FEED."
LIVE_BUILD="${LIVE_BUILD:-0}"
BUILD="$(plist "$PLIST" CFBundleVersion)"
if [ "$(plist "$PLIST" CFBundleShortVersionString)" != "$VERSION" ] || [ "$BUILD" -le "$LIVE_BUILD" ]; then
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
SIGNED_BY="$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p')"
NOTARIZE=0
if [ -n "$SIGNED_BY" ]; then
  NOTARIZE=1
  [ "$("$SPARKLE_BIN/generate_keys" --account Pane -p)" = "$PINNED_KEY" ] ||
    fail "The EdDSA key in the keychain (account Pane) isn't scripts/sparkle-public-key.txt."
elif [ "$PUBLISH" = 1 ]; then
  fail "No Developer ID Application certificate in the keychain; only notarized builds are published."
else
  echo
  echo "!! No Developer ID certificate: making a TEST .dmg (not notarized, not signed for updates)."
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
  check_app "$APP"
fi

echo "==> Making $DMG"
STAGE="$TMP/stage"
mkdir "$STAGE"
cp -R "$APP" "$STAGE/Pane.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Pane $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

# Only release builds are signed for updates; a test build stops here.
if [ "$NOTARIZE" = 0 ]; then
  echo
  echo "Test build: $DMG"
  exit 0
fi

codesign --force --timestamp --sign "$SIGNED_BY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# Sparkle: the update is the .dmg itself, signed with the EdDSA key in the keychain
# (made by generate_keys --account Pane).
echo "==> Writing appcast.xml"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account Pane "$DMG")"

WHATS_NEW="$(cat "$NOTES" 2>/dev/null || echo "Pane $VERSION.")"
MIN_OS="$(plist "$PLIST" LSMinimumSystemVersion)"
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
# sign_update signs XML it can't parse without complaint, so check it first.
xmllint --noout "$OUT/appcast.xml" || fail "$OUT/appcast.xml isn't well-formed XML."
"$SPARKLE_BIN/sign_update" --account Pane "$OUT/appcast.xml" >/dev/null

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

verify_release

echo
echo "Built:"
ls -lh "$OUT"

# Publishable: from a commit with nothing left uncommitted.
if [ "$CLEAN" = 1 ]; then
  echo "$VERSION $(git rev-parse HEAD)" > "$BUILT_FROM"
fi

if [ "$PUBLISH" = 1 ]; then
  publish
elif [ "$CLEAN" = 1 ]; then
  echo
  echo "Not published. To publish this build: scripts/release.sh $VERSION --publish"
else
  echo
  echo "Not published, and not publishable: built from uncommitted changes."
fi
