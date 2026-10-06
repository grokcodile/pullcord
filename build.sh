#!/bin/bash
# Builds Pullcord.app into ./build, signed with the Developer ID certificate named
# by SIGN_IDENTITY (a SHA-1 hash; see below) when it is in the keychain. That
# matters for more than distribution: macOS ties Accessibility and Screen
# Recording to the signing identity, so an ad-hoc build — which gets a new
# identity every time — has to be re-granted after every rebuild. A stable
# Developer ID signature means the permissions are granted once and stay.
set -e

cd "$(dirname "$0")"

APP_NAME="Pullcord"
BUILD_DIR="./build/${APP_NAME}.app"

# The certificate to sign with, as its SHA-1 hash and never its name. A keychain
# can hold several certificates with the identical "Developer ID Application:
# Name (TEAM)" label — a renewal leaves the old one behind, and one certificate
# can sit in two keychains — and codesign resolves a name to whichever it finds
# first without saying which. That is how an app ends up signed by a certificate
# Apple is retiring. A hash names exactly one.
# List yours with: security find-identity -v -p codesigning
DEFAULT_SIGN_IDENTITY="DEA1A3749B06CF3619F72152EFC35A48E380C4E4"
# The certificate that one replaced. It has the same name and team, so nothing
# but the hash tells them apart, and a SIGN_IDENTITY left in a shell profile
# would otherwise pass every check below and ship a build signed by it.
RETIRED_SIGN_IDENTITY="BFF6F3CC3EAF28FD1F7793C0E377E6893A305004"
EXPLICIT_IDENTITY="${SIGN_IDENTITY:+1}"
SIGN_IDENTITY="$(printf '%s' "${SIGN_IDENTITY:-$DEFAULT_SIGN_IDENTITY}" | tr 'a-f' 'A-F')"

# The length test is separate because grep is line-oriented: a value with a
# newline in it would pass the pattern as long as one line were 40 hex digits.
if [ "${#SIGN_IDENTITY}" -ne 40 ] || ! printf '%s' "$SIGN_IDENTITY" | grep -Eq '^[0-9A-F]{40}$'; then
    echo "SIGN_IDENTITY must be a certificate SHA-1 hash (40 hex characters), not a name." >&2
    echo "  A name can match several certificates and codesign won't say which it used." >&2
    echo "  List them with: security find-identity -v -p codesigning" >&2
    exit 1
fi

if [ "$SIGN_IDENTITY" = "$RETIRED_SIGN_IDENTITY" ]; then
    echo "SIGN_IDENTITY ${SIGN_IDENTITY} is the retired Developer ID certificate; refusing to sign with it." >&2
    echo "  Unset SIGN_IDENTITY to use ${DEFAULT_SIGN_IDENTITY}." >&2
    exit 1
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    HAVE_IDENTITY=1
elif [ -n "$EXPLICIT_IDENTITY" ]; then
    # Asked for rather than defaulted to: silently signing with something else
    # (or ad-hoc) would hand back a build that isn't the one that was asked for.
    echo "SIGN_IDENTITY ${SIGN_IDENTITY} is not a valid signing identity in any keychain." >&2
    exit 1
else
    HAVE_IDENTITY=
fi

echo "Building ${APP_NAME}..."

rm -rf ./build
mkdir -p "${BUILD_DIR}/Contents/MacOS"
mkdir -p "${BUILD_DIR}/Contents/Resources"

# Spotlight's four-panel UI is macOS 26+, so unlike Key54 there is no reason
# to target anything older.
# -Osize rather than -O: this app spends its life idle waiting on a hotkey, and
# the work that isn't idle (OCR, the on-device model, speech) happens inside
# system frameworks rather than here — so the size is worth more than the last
# few percent of throughput. Measured on this source: 536KB at -O, 491KB here.
swiftc -Osize main.swift \
    -target "$(uname -m)-apple-macos26.0" \
    -framework Cocoa \
    -framework Carbon \
    -framework ServiceManagement \
    -framework Vision \
    -framework IOKit \
    -framework FoundationModels \
    -o "${BUILD_DIR}/Contents/MacOS/${APP_NAME}"

# Local symbols are a third of the binary and nothing reads them at runtime —
# Swift reflection uses its own metadata sections, not the symbol table. Measured:
# 491KB down to 296KB. Has to happen before codesign, or it breaks the signature.
# (-x keeps global symbols; a full strip can break Swift binaries.)
strip -x "${BUILD_DIR}/Contents/MacOS/${APP_NAME}"

cp Info.plist "${BUILD_DIR}/Contents/Info.plist"
cp icon/AppIcon.icns "${BUILD_DIR}/Contents/Resources/AppIcon.icns"

if [ -n "$HAVE_IDENTITY" ]; then
    echo "Signing with certificate ${SIGN_IDENTITY}"
    # --options runtime is the hardened runtime, which notarization requires.
    # --timestamp gets a trusted timestamp, so the signature outlives the cert.
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "${BUILD_DIR}"
    codesign --verify --strict --verbose=1 "${BUILD_DIR}"

    # Read the leaf certificate back out of the signature and compare, rather
    # than trusting that --sign did what the hash said: this is what proves the
    # retired certificate didn't sign it.
    # On either failure the bundle is deleted, since it is exactly the artifact
    # this check exists to reject and ./build is where the next step looks.
    CERT_DIR="$(mktemp -d)"
    trap 'rm -rf "$CERT_DIR"' EXIT
    if ! codesign -d --extract-certificates="${CERT_DIR}/cert" "${BUILD_DIR}" >/dev/null 2>&1; then
        echo "Could not read the signing certificate back out of ${BUILD_DIR}." >&2
        rm -rf "${BUILD_DIR}"
        exit 1
    fi
    SIGNED_BY="$(shasum -a 1 < "${CERT_DIR}/cert0" | awk '{print toupper($1)}')"
    if [ "$SIGNED_BY" != "$SIGN_IDENTITY" ]; then
        echo "Signed by certificate ${SIGNED_BY}, expected ${SIGN_IDENTITY}." >&2
        rm -rf "${BUILD_DIR}"
        exit 1
    fi
    echo "Verified: signed by ${SIGNED_BY}"
else
    echo "No valid signing identity with hash ${SIGN_IDENTITY} — signing ad-hoc."
    echo "  (It isn't in the keychain, or its chain isn't trusted, or it has expired. To sign"
    echo "  with your own Developer ID: SIGN_IDENTITY=<hash from find-identity> bash build.sh)"
    echo "  macOS will forget this app's permissions on every rebuild."
    codesign --force --sign - "${BUILD_DIR}"
fi

echo "Built ${BUILD_DIR}"
