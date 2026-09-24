#!/bin/bash
# The update feed for this fork's builds, which ship through the Homebrew tap
# mekh/homebrew-tap instead of the upstream releases.
#
#   Support/fork-appcast.sh <Imark-x.y.z.dmg>
#
# Run it once the tap has the release `imark-v<version>` with that disk image
# attached. The feed points at the asset, and a feed that points at nothing is
# an update window that fails, so the asset is downloaded first and has to be
# the same bytes as the image given here.
#
# The image and the feed are signed with the EdDSA key kept in the login
# keychain under the `mekh-imark` account; only its public half is in
# Support/Imark-Info.plist. The feed is written to appcasts/imark.xml in the
# tap's clone, and committing and pushing that file is what publishes the
# update: the app reads it from raw.githubusercontent.com, which is its
# SUFeedURL.
#
# Nothing here touches the upstream feed or key. Those are migsilva89/imark's,
# and Support/appcast.sh is theirs.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

ACCOUNT="mekh-imark"
TAP_REPO="mekh/homebrew-tap"
TAP="${IMARK_TAP_DIR:-$HOME/Projects/mech/homebrew-tap}"
FEED="$TAP/appcasts/imark.xml"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Imark-Info.plist)"
DMG="${1:-}"
NAME="Imark-$VERSION.dmg"
TAG="imark-v$VERSION"
ASSET="https://github.com/$TAP_REPO/releases/download/$TAG/$NAME"

TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
GENERATE="$TOOLS/generate_appcast"
KEYS="$TOOLS/generate_keys"

die() { echo "error: $*" >&2; exit 1; }

[ -n "$DMG" ] || die "usage: Support/fork-appcast.sh <$NAME>"
[ -f "$DMG" ] || die "no disk image at $DMG"
[ "$(basename "$DMG")" = "$NAME" ] \
	|| die "$(basename "$DMG") is not $NAME — the version in Support/Imark-Info.plist is $VERSION"
[ -x "$GENERATE" ] || die "Sparkle's release tools are missing — run swift package resolve"
[ -d "$TAP/.git" ] || die "no clone of $TAP_REPO at $TAP (set IMARK_TAP_DIR)"

EXPECTED="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Support/Imark-Info.plist)"
ACTUAL="$("$KEYS" --account "$ACCOUNT" -p)" \
	|| die "no Sparkle key under the $ACCOUNT account in the keychain"
[ "$ACTUAL" = "$EXPECTED" ] || die "the Sparkle key in the keychain does not match the app"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# What installed copies will actually download, compared with what is about to
# be signed. A signature over different bytes is an update every copy rejects.
curl -fsSL -o "$STAGE/published.dmg" "$ASSET" \
	|| die "$ASSET is not there yet — publish the release first"
[ "$(shasum -a 256 < "$STAGE/published.dmg")" = "$(shasum -a 256 < "$DMG")" ] \
	|| die "the image published as $TAG is not $DMG"
rm "$STAGE/published.dmg"

mkdir "$STAGE/archives"
ditto "$DMG" "$STAGE/archives/$NAME"
"$GENERATE" \
	--account "$ACCOUNT" \
	--download-url-prefix "https://github.com/$TAP_REPO/releases/download/$TAG/" \
	--full-release-notes-url "https://github.com/$TAP_REPO/releases/tag/$TAG" \
	--link "https://github.com/mekh/imark" \
	--maximum-versions 1 \
	--maximum-deltas 0 \
	-o "$STAGE/appcast.xml" \
	"$STAGE/archives"

xmllint --noout "$STAGE/appcast.xml"
grep -q 'sparkle:edSignature=' "$STAGE/appcast.xml" || die "the update in the feed is not signed"
grep -q '<!-- sparkle-signatures:' "$STAGE/appcast.xml" || die "the feed itself is not signed"
grep -qF "url=\"$ASSET\"" "$STAGE/appcast.xml" || die "the feed does not point at $ASSET"

mkdir -p "$(dirname "$FEED")"
cp "$STAGE/appcast.xml" "$FEED"

echo "update feed → $FEED"
echo
echo "to publish it:"
echo "  git -C \"$TAP\" add appcasts/imark.xml"
echo "  git -C \"$TAP\" commit -m \"imark $VERSION feed\""
echo "  git -C \"$TAP\" push origin main"
