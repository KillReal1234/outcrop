#!/bin/bash
#
# Outcrop release script.
#
# Usage:   scripts/release_outcrop.sh <version> [--dry-run]
# Example: OUTCROP_TEAM_ID=<team id> scripts/release_outcrop.sh 0.1.1
#          OUTCROP_TEAM_ID=<team id> scripts/release_outcrop.sh 0.1.1 --dry-run
#
# A real run:
#   1. checks that the working tree is clean and the branch is `fork`;
#   2. sets MARKETING_VERSION to <version> and CURRENT_PROJECT_VERSION to the current build + 1;
#   3. archives a Release build signed with the local Apple Development identity (no notarization);
#   4. zips Outcrop.app with ditto, checks the code signature of the unpacked copy, and signs the zip
#      with the Sparkle key stored under `--account outcrop`;
#   5. adds an item for the new build to appcast.xml;
#   6. commits the version bump and appcast.xml;
#   7. prints the publish commands. It never runs them: publishing is a separate, manual step.
#
# --dry-run does steps 2-5 into ../.derived/release-dry-run/ (a copy of appcast.xml is written there),
# leaves the working tree untouched and does not commit. The clean-tree and branch checks only warn.
#
# Requirements:
#   - OUTCROP_TEAM_ID: the team ID of the Apple Development certificate (not stored in the repository);
#   - the Sparkle tools resolved by Xcode in ../.derived/SourcePackages/artifacts/sparkle/Sparkle/bin;
#   - the Outcrop update signing key in the login keychain under the account `outcrop`.

set -euo pipefail

usage() {
    echo "Usage: scripts/release_outcrop.sh <version> [--dry-run]" >&2
    exit 1
}

fail() {
    echo "error: $*" >&2
    exit 1
}

VERSION=""
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*) usage ;;
        *)
            [ -z "$VERSION" ] || usage
            VERSION="$arg"
            ;;
    esac
done
[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3, got '$VERSION'"

[ -n "${OUTCROP_TEAM_ID:-}" ] || fail "OUTCROP_TEAM_ID is not set. Export the team ID of your Apple Development certificate, for example: OUTCROP_TEAM_ID=<team id> scripts/release_outcrop.sh $VERSION"

# Run from the repository root.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DERIVED="$REPO_ROOT/../.derived"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
SPARKLE_ACCOUNT="outcrop"
PBXPROJ="Clarc.xcodeproj/project.pbxproj"
APPCAST="appcast.xml"
TAG="v$VERSION"
ZIP_NAME="Outcrop-$VERSION.zip"
DOWNLOAD_URL="https://github.com/KillReal1234/outcrop/releases/download/$TAG/$ZIP_NAME"

if [ "$DRY_RUN" = 1 ]; then
    OUT_DIR="$DERIVED/release-dry-run"
else
    OUT_DIR="$DERIVED/release/$TAG"
fi

[ -x "$SPARKLE_BIN/sign_update" ] || fail "sign_update not found in $SPARKLE_BIN. Build the app once so Xcode resolves the Sparkle package."

# --- 1. Working tree and branch ---------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
DIRTY="$(git status --porcelain)"
if [ "$DRY_RUN" = 1 ]; then
    [ "$BRANCH" = "fork" ] || echo "warning: on branch '$BRANCH', a real release must run on 'fork'"
    [ -z "$DIRTY" ] || echo "warning: the working tree has uncommitted changes, a real release needs a clean tree"
else
    [ "$BRANCH" = "fork" ] || fail "releases are made from the 'fork' branch, current branch is '$BRANCH'"
    [ -z "$DIRTY" ] || fail "the working tree is not clean; commit or stash your changes first"
fi

# --- 2. Version and build number --------------------------------------------
CURRENT_BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([0-9]+);.*/\1/')"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || fail "could not read CURRENT_PROJECT_VERSION from $PBXPROJ"
NEW_BUILD=$((CURRENT_BUILD + 1))

APPCAST_MAX="$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>' "$APPCAST" | grep -oE '[0-9]+' | sort -rn | head -1 || true)"
if [ -n "$APPCAST_MAX" ] && [ "$APPCAST_MAX" -ge "$NEW_BUILD" ]; then
    fail "appcast.xml already has build $APPCAST_MAX, which is not lower than the new build $NEW_BUILD"
fi
if grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST"; then
    fail "appcast.xml already has version $VERSION"
fi

echo "Outcrop $TAG, build $NEW_BUILD (current build $CURRENT_BUILD)"
[ "$DRY_RUN" = 1 ] && echo "Dry run: output goes to $OUT_DIR, the working tree is not changed"

if [ "$DRY_RUN" = 0 ]; then
    sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PBXPROJ"
    sed -i '' -E "s/MARKETING_VERSION = [0-9][0-9.]*;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
fi

# Start from an empty output folder.
rm -rf "${OUT_DIR:?}"
mkdir -p "$OUT_DIR"

# --- 3. Release archive ------------------------------------------------------
ARCHIVE="$OUT_DIR/Outcrop.xcarchive"
BUILD_LOG="$OUT_DIR/xcodebuild.log"
echo "Archiving (log: $BUILD_LOG)..."
# The version is passed on the command line as well, so a dry run gets it without editing the project.
if ! xcodebuild archive \
    -project Clarc.xcodeproj \
    -scheme Clarc \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$OUTCROP_TEAM_ID" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$NEW_BUILD" \
    > "$BUILD_LOG" 2>&1; then
    grep -E 'error:' "$BUILD_LOG" | head -20 >&2 || true
    fail "xcodebuild archive failed, see $BUILD_LOG"
fi

APP="$ARCHIVE/Products/Applications/Outcrop.app"
[ -d "$APP" ] || fail "Outcrop.app not found in the archive"

BUILT_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
BUILT_BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
[ "$BUILT_VERSION" = "$VERSION" ] && [ "$BUILT_BUILD" = "$NEW_BUILD" ] \
    || fail "the archived app reports $BUILT_VERSION ($BUILT_BUILD), expected $VERSION ($NEW_BUILD)"

# --- 4. Zip and Sparkle signature -------------------------------------------
# --norsrc --noextattr --noqtn: keep extended attributes out of the zip, otherwise
# plain unzip creates ._* files that break the code seal of Sparkle.framework.
ZIP="$OUT_DIR/$ZIP_NAME"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$ZIP"
ZIP_LENGTH="$(stat -f%z "$ZIP")"

# Verify the code signature of the app as users get it: unpacked from the zip.
# This runs in a temporary folder because folders synced by a file provider (such as
# iCloud Drive) add Finder attributes that a strict check rejects.
CHECK_DIR="$(mktemp -d -t outcrop-release-check)"
ditto -x -k "$ZIP" "$CHECK_DIR"
if ! codesign --verify --deep --strict "$CHECK_DIR/Outcrop.app"; then
    rm -rf "${CHECK_DIR:?}"
    fail "the code signature of Outcrop.app unpacked from $ZIP_NAME does not verify"
fi
rm -rf "${CHECK_DIR:?}"

echo "Signing $ZIP_NAME with the Sparkle key (account: $SPARKLE_ACCOUNT)..."
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" -p "$ZIP")"
[ -n "$SIGNATURE" ] || fail "sign_update returned no signature"
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$ZIP" "$SIGNATURE" \
    || fail "the Sparkle signature of $ZIP_NAME does not verify"

# --- 5. Appcast item ---------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
    TARGET_APPCAST="$OUT_DIR/appcast.xml"
    cp "$APPCAST" "$TARGET_APPCAST"
else
    TARGET_APPCAST="$APPCAST"
fi

PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
ITEM_FILE="$OUT_DIR/appcast-item.xml"
cat > "$ITEM_FILE" <<EOF
    <item>
      <title>Outcrop $TAG</title>
      <sparkle:version>$NEW_BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure
        url="$DOWNLOAD_URL"
        length="$ZIP_LENGTH"
        type="application/octet-stream"
        sparkle:edSignature="$SIGNATURE" />
    </item>
EOF

# Insert the item right before </channel>.
python3 - "$ITEM_FILE" "$TARGET_APPCAST" <<'PYEOF'
import sys
item_path, appcast_path = sys.argv[1], sys.argv[2]
item = open(item_path, encoding="utf-8").read()
content = open(appcast_path, encoding="utf-8").read()
marker = "  </channel>"
if content.count(marker) != 1:
    sys.exit("error: expected exactly one '  </channel>' line in " + appcast_path)
content = content.replace(marker, item + marker)
open(appcast_path, "w", encoding="utf-8").write(content)
PYEOF
rm -f "$ITEM_FILE"

if command -v xmllint > /dev/null; then
    xmllint --noout "$TARGET_APPCAST" || fail "$TARGET_APPCAST is not well-formed XML"
fi

if [ "$DRY_RUN" = 1 ]; then
    echo ""
    echo "Dry run finished:"
    echo "  $ZIP ($ZIP_LENGTH bytes)"
    echo "  $TARGET_APPCAST"
    exit 0
fi

# --- 6. Commit ---------------------------------------------------------------
git add "$PBXPROJ" "$APPCAST"
git commit -m "chore(release): $TAG (build $NEW_BUILD)"

# --- 7. Publish commands (printed only, never run here) ----------------------
cat <<EOF

Release $TAG (build $NEW_BUILD) is committed locally. Nothing has been published.
Archive: $ZIP

To publish, run these commands yourself:

  git push origin fork
  git tag $TAG
  git push origin $TAG
  gh release create $TAG "$ZIP" --title "Outcrop $TAG" --notes "Outcrop $TAG (build $NEW_BUILD)"

EOF
