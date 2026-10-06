#!/bin/bash
# Builds Pullcord.app into ./build. Used by both install.sh and CI.
#
# Code-signing: SIGN_IDENTITY picks the identity and must be a certificate's SHA-1
# hash (40 hex digits). It defaults to the Developer ID Application cert for team
# 8UP5SFXY56 (G2 Sub-CA, expires 2031-09-16). Sign by hash, never by name: the
# keychain can hold several identities with the identical name — the older cert
# Apple is retiring was there too — so a name is ambiguous (codesign refuses to
# choose, and the old `grep | head -1` quietly took the first, older one). An
# identity you set explicitly that isn't usable is an error, even if it's the same
# hash as the default; only the *default* missing (a machine that never had this
# cert) falls back to ad-hoc.
#
# The fallback matters for more than distribution. macOS keys Accessibility and
# Screen Recording to the app's designated requirement — with a Developer ID
# that's the stable "identifier + team OU", but an ad-hoc signature has no cert,
# so it reduces to the binary's cdhash. That changes on *every* build, so each
# rebuild looks like a brand-new app and has to be granted both again.
set -e

cd "$(dirname "$0")"

APP_NAME="Pullcord"
BUILD_DIR="./build/${APP_NAME}.app"
# Mirrored by the pinned hash in .github/workflows/release.yml.
DEFAULT_SIGN_IDENTITY="DEA1A3749B06CF3619F72152EFC35A48E380C4E4"
# Remember whether the caller chose the identity (empty counts as unset): one that
# was chosen and can't be used must fail rather than fall back to ad-hoc — CI
# exports exactly the default hash, so comparing against the default can't tell.
SIGN_IDENTITY_EXPLICIT="${SIGN_IDENTITY:+1}"
SIGN_IDENTITY="${SIGN_IDENTITY:-$DEFAULT_SIGN_IDENTITY}"
if ! printf '%s' "$SIGN_IDENTITY" | grep -Eq '^[0-9A-Fa-f]{40}$'; then
    echo "error: SIGN_IDENTITY must be a certificate SHA-1 hash (40 hex digits), not a name." >&2
    exit 1
fi
# `find-identity -v` lists only *valid* identities, so a cert that is expired,
# untrusted or missing its private key is absent here too — "not found" below
# means "not usable", not necessarily "not installed".
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qiE "^ *[0-9]+\) ${SIGN_IDENTITY} "; then
    if [ -n "$SIGN_IDENTITY_EXPLICIT" ]; then
        echo "error: SIGN_IDENTITY=${SIGN_IDENTITY} is not among the valid code-signing identities" >&2
        echo "       (missing, expired, untrusted, or no private key)." >&2
        exit 1
    fi
    SIGN_IDENTITY=""
fi
BUILD_ABS="$PWD/${BUILD_DIR#./}"

echo "Building ${APP_NAME}..."

rm -rf ./build
mkdir -p "${BUILD_DIR}/Contents/MacOS"
mkdir -p "${BUILD_DIR}/Contents/Resources"

# Info.plist's LSMinimumSystemVersion is the one place the supported macOS is set:
# the deployment target is read from it here, and release.yml writes the same
# value into the Homebrew cask's `depends_on macos`. Releases are Apple Silicon
# only (Apple Intelligence is too), so the architecture is pinned rather than
# taken from whatever Mac builds.
MIN_MACOS="$(plutil -extract LSMinimumSystemVersion raw Info.plist)"
# -Osize rather than -O: this app spends its life idle waiting on a hotkey, and
# the work that isn't idle (OCR, the on-device model, speech) happens inside
# system frameworks rather than here — so the size is worth more than the last
# few percent of throughput. Measured on this source: 536KB at -O, 491KB here.
swiftc -Osize main.swift \
    -target "arm64-apple-macos${MIN_MACOS}" \
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

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with: ${SIGN_IDENTITY}"
    # --options runtime is the hardened runtime, which notarization requires.
    # --timestamp gets a trusted timestamp, so the signature outlives the cert.
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "${BUILD_DIR}"
    codesign --verify --strict --verbose=1 "${BUILD_DIR}"
    # Prove who signed it. `codesign -dvv` can't: the old and new certs share a
    # name and team and it prints no hash, so a signature from the wrong one reads
    # identically. The signing certificate's own fingerprint is unambiguous.
    CERT_DIR="$(mktemp -d)"
    ( cd "$CERT_DIR" && codesign -d --extract-certificates "$BUILD_ABS" 2>/dev/null )
    SIGNED_BY="$(openssl x509 -inform DER -in "$CERT_DIR/codesign0" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
    rm -rf "${CERT_DIR:?}"
    if [ "$(printf '%s' "$SIGNED_BY" | tr a-f A-F)" != "$(printf '%s' "$SIGN_IDENTITY" | tr a-f A-F)" ]; then
        echo "error: signed by certificate ${SIGNED_BY}, expected ${SIGN_IDENTITY}." >&2
        exit 1
    fi
    echo "Signed by certificate ${SIGNED_BY}"
else
    echo "Signing identity ${DEFAULT_SIGN_IDENTITY} not among the valid identities — signing ad-hoc."
    echo "  (macOS will forget this app's permissions on every rebuild.)"
    # No --deep: Apple deprecated it for signing, and there is nothing nested
    # in this bundle to descend into anyway.
    codesign --force --sign - "${BUILD_DIR}"
fi

echo "Built ${BUILD_DIR}"
