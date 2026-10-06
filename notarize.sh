#!/bin/bash
# Builds, notarizes and staples Pullcord, then leaves a distributable disk
# image in ./dist. Notarization is what stops Gatekeeper showing the
# "unidentified developer" warning on someone else's Mac — the Developer ID
# signature alone isn't enough.
#
# This mirrors what .github/workflows/release.yml does on a tag; it exists for
# building a release by hand when CI isn't an option.
#
# One-time setup. Stores a credential in your keychain, so it has to be run by
# you rather than by a script:
#
#   xcrun notarytool store-credentials grokcodile \
#       --key ~/path/to/AuthKey_XXXXXXXXXX.p8 \
#       --key-id XXXXXXXXXX \
#       --issuer XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
#
# The profile is named for the team, not the app, because that is what the
# credential actually is — an App Store Connect key for 8UP5SFXY56. Naming it
# after an app is how the last one ended up called "liteswitch" and went stale
# on a rename; every app here shares this one profile instead.
#
# It's the same App Store Connect API key CI uses (the AC_API_* secrets), rather
# than an app-specific password, so local and CI authenticate as one identity
# and rotate together. Make one at App Store Connect → Users and Access →
# Integrations → App Store Connect API → *Team* Keys, with the Developer role.
# Personal keys are not eligible for the Notary API. The .p8 downloads once.
set -e

cd "$(dirname "$0")"

APP_NAME="Pullcord"
APP="./build/${APP_NAME}.app"
PROFILE="${NOTARY_PROFILE:-grokcodile}"
DIST="./dist"
ZIP="${DIST}/${APP_NAME}-submit.zip"
DMG="${DIST}/${APP_NAME}.dmg"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No notarytool credentials found for profile '${PROFILE}'."
    echo "Run this once with your App Store Connect team key, then try again:"
    echo
    echo "  xcrun notarytool store-credentials ${PROFILE} \\"
    echo "      --key ~/path/to/AuthKey_XXXXXXXXXX.p8 \\"
    echo "      --key-id XXXXXXXXXX \\"
    echo "      --issuer XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
    echo
    exit 1
fi

./build.sh

# Signing must be a real Developer ID, not ad-hoc, or notarization refuses it.
# (build.sh has already checked which certificate, by hash; this is the backstop
# for its ad-hoc fallback, which would otherwise get as far as Apple.)
if ! codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "TeamIdentifier=8UP5SFXY56"; then
    echo "Not signed with a Developer ID — nothing to notarize." >&2
    exit 1
fi

mkdir -p "$DIST"
rm -f "$ZIP"
# ditto, not zip: it preserves the bundle's symlinks and metadata. This archive
# is only a carrier for the notary service — the DMG is what ships.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting the app to Apple (this usually takes a minute or two)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
# Staple the ticket into the bundle so it validates offline. Has to happen
# before the DMG is built, so the image carries an already-stapled app.
xcrun stapler staple "$APP"
rm -f "$ZIP"

# A disk image with an Applications symlink, so opening it gives the
# drag-across window rather than a loose app in Downloads.
rm -rf "${DIST}/dmgroot" "$DMG"
mkdir -p "${DIST}/dmgroot"
cp -R "$APP" "${DIST}/dmgroot/"
ln -s /Applications "${DIST}/dmgroot/Applications"
# -fs HFS+ matches release.yml, and isn't cosmetic: without it hdiutil defaults
# to APFS, whose slack is compressed along with the content. Measured on this
# app: 1.24MB without the flag, 0.84MB with it.
hdiutil create -volname "${APP_NAME}" -srcfolder "${DIST}/dmgroot" \
    -ov -fs "HFS+" -format UDZO "$DMG"
rm -rf "${DIST}/dmgroot"

# The image is notarized in its own right: stapling the app stops Gatekeeper
# complaining about the app, stapling the image stops it complaining about the
# image someone just downloaded.
echo "Submitting the disk image..."
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo
echo "=== verification ==="
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier|Timestamp|Identifier)="
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
spctl --assess --type execute -vv "$APP"
shasum -a 256 "$DMG"
echo
echo "Notarized: ${DMG}"
