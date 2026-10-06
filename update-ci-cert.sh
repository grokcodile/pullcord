#!/bin/bash
# Puts the Developer ID certificate build.sh signs with into the two GitHub
# secrets release.yml imports it from (MACOS_CERT_P12_BASE64 and
# MACOS_CERT_PASSWORD), then runs the release workflow once from main as a dry
# run, to prove CI can sign with it. Run it after renewing the certificate.
#
#   ./update-ci-cert.sh Certificates.p12   # a .p12 exported from Keychain Access;
#                                          # asks for its password
#   ./update-ci-cert.sh                    # export straight from your keychain;
#                                          # macOS asks you to allow it
#
# Either way, exactly one identity goes to GitHub, chosen by SHA-1 hash, along
# with its intermediate certificate so the runner can validate the chain. That
# matters because the certificates here share one name: an export of "the"
# Developer ID can carry the retired one too, and `security export` can only
# take every identity at once. So a few lines of Swift pick the one by hash.
#
# What goes to GitHub is re-wrapped under a random password, never shown; your
# own .p12 password stays on this machine.
set -euo pipefail

# Resolved before the cd below, so a path relative to wherever this was run
# from still works.
SRC="${1:-}"
if [ -n "$SRC" ]; then
    if [ ! -f "$SRC" ]; then
        echo "No such file: ${SRC}" >&2
        exit 1
    fi
    SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
fi

cd "$(dirname "$0")"

REPO="grokcodile/pullcord"

HASH="${SIGN_IDENTITY:-$(sed -n 's/^DEFAULT_SIGN_IDENTITY="\([0-9A-Fa-f]\{40\}\)"$/\1/p' build.sh)}"
HASH="$(printf '%s' "$HASH" | tr 'a-f' 'A-F')"
if [ "${#HASH}" -ne 40 ] || ! printf '%s' "$HASH" | grep -Eq '^[0-9A-F]{40}$'; then
    echo "No certificate hash: set SIGN_IDENTITY, or DEFAULT_SIGN_IDENTITY in build.sh." >&2
    exit 1
fi
# CI checks the .p12 against its own copy of the hash, so a mismatch here would
# only surface as a failed release.
if ! grep -qi "SIGN_CERT_SHA1: ${HASH}" .github/workflows/release.yml; then
    echo "release.yml's SIGN_CERT_SHA1 isn't ${HASH} — update it to match first." >&2
    exit 1
fi
WORK="$(mktemp -d)"
SCRATCH_KC="${WORK}/scratch.keychain-db"
CHECK_KC="${WORK}/check.keychain-db"
cleanup() {
    security delete-keychain "$SCRATCH_KC" 2>/dev/null || true
    security delete-keychain "$CHECK_KC" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

cat > "${WORK}/export.swift" <<'SWIFT'
// export-identity <sha1> <out.p12> [<in.p12>]
//
// Writes the identity whose certificate has that SHA-1 to <out.p12> under
// P12_PASSPHRASE.
//
// Without <in.p12> it searches the user's keychains and writes the identity
// alone. With <in.p12> (password IN_PASSPHRASE), that file is imported into
// EXPORT_KEYCHAIN, a scratch keychain, the identity is picked out of whatever
// else the file holds, and the intermediates its chain needs are added, so the
// runner can validate it without having them installed.
import CryptoKit
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func passphraseParams(_ passphrase: CFString) -> SecItemImportExportKeyParameters {
    var params = SecItemImportExportKeyParameters()
    params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    params.passphrase = Unmanaged.passUnretained(passphrase as AnyObject)
    return params
}

func sha1(_ cert: SecCertificate) -> String {
    Insecure.SHA1.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02X", $0) }.joined()
}

let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
guard args.count == 3 || args.count == 4, let outPass = env["P12_PASSPHRASE"], !outPass.isEmpty else {
    fail("usage: P12_PASSPHRASE=... export-identity <sha1> <out.p12> [<in.p12>]")
}
let want = args[1].uppercased()

var keychain: SecKeychain?
if let path = env["EXPORT_KEYCHAIN"] {
    guard SecKeychainOpen(path, &keychain) == errSecSuccess, keychain != nil else { fail("Can't open \(path).") }
}

if args.count == 4 {
    guard let keychain else { fail("Importing a .p12 needs EXPORT_KEYCHAIN (a scratch keychain).") }
    guard let input = FileManager.default.contents(atPath: args[3]) else { fail("Can't read \(args[3]).") }
    let inPass = (env["IN_PASSPHRASE"] ?? "") as CFString
    var params = passphraseParams(inPass)
    var format = SecExternalFormat.formatPKCS12
    var type = SecExternalItemType.itemTypeAggregate
    let imported = withExtendedLifetime(inPass) {
        SecItemImport(input as CFData, nil, &format, &type, [], &params, keychain, nil)
    }
    if imported == errSecPkcs12VerifyFailure || imported == errSecPassphraseRequired || imported == errSecAuthFailed {
        fail("Wrong password for \(args[3]).")
    }
    guard imported == errSecSuccess else {
        fail("Couldn't open \(args[3]): \(SecCopyErrorMessageString(imported, nil) as String? ?? String(imported)).")
    }
}

var query: [String: Any] = [
    kSecClass as String: kSecClassIdentity,
    kSecMatchLimit as String: kSecMatchLimitAll,
    kSecReturnRef as String: true,
]
if let keychain { query[kSecMatchSearchList as String] = [keychain] }

var found: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &found)
let identities = status == errSecSuccess ? (found as? [SecIdentity] ?? []) : []
var available: [String] = []
var match: (identity: SecIdentity, cert: SecCertificate)?
for identity in identities {
    var cert: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { continue }
    let hash = sha1(cert)
    available.append(hash)
    if hash == want { match = (identity, cert); break }
}
guard let match else {
    fail("No identity with certificate SHA-1 \(want). Found: \(available.isEmpty ? "none" : available.joined(separator: ", ")).")
}

func certificates(in keychain: SecKeychain) -> [SecCertificate] {
    var found: CFTypeRef?
    let query: [String: Any] = [
        kSecClass as String: kSecClassCertificate,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true,
        kSecMatchSearchList as String: [keychain],
    ]
    guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess else { return [] }
    return found as? [SecCertificate] ?? []
}

var items: [CFTypeRef] = [match.identity]
if args.count == 4, let keychain {
    // The chain is built from what this Mac trusts plus anything the file
    // brought with it. The root is left out: the runner must already trust it.
    var trust: SecTrust?
    let candidates = [match.cert] + certificates(in: keychain)
    if SecTrustCreateWithCertificates(candidates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
       let trust {
        _ = SecTrustEvaluateWithError(trust, nil)
        for cert in ((SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []).dropFirst() {
            let subject = SecCertificateCopyNormalizedSubjectSequence(cert) as Data?
            let issuer = SecCertificateCopyNormalizedIssuerSequence(cert) as Data?
            guard subject != issuer else { continue }
            // SecItemExport refuses a certificate that isn't in a keychain
            // ("No keychain is available"), and the system's intermediates
            // aren't. So copy each into the scratch keychain and export that
            // copy, read back by query: the ref SecItemAdd hands back is stale.
            let der = SecCertificateCopyData(cert) as Data
            guard let copy = SecCertificateCreateWithData(nil, der as CFData) else { continue }
            let added = SecItemAdd([kSecClass as String: kSecClassCertificate,
                                    kSecValueRef as String: copy,
                                    kSecUseKeychain as String: keychain] as CFDictionary, nil)
            guard added == errSecSuccess || added == errSecDuplicateItem,
                  let staged = certificates(in: keychain).first(where: { SecCertificateCopyData($0) as Data == der })
            else {
                fail("Couldn't stage intermediate \(SecCertificateCopySubjectSummary(cert) as String? ?? "?") (\(added)).")
            }
            items.append(staged)
        }
    }
}

let outPassCF = outPass as CFString
var outParams = passphraseParams(outPassCF)
var data: CFData?
let exported = withExtendedLifetime(outPassCF) {
    SecItemExport(items as CFArray, .formatPKCS12, [], &outParams, &data)
}
guard exported == errSecSuccess, let data else {
    fail("Export failed: \(SecCopyErrorMessageString(exported, nil) as String? ?? String(exported)).")
}
guard FileManager.default.createFile(atPath: args[2], contents: data as Data,
                                     attributes: [.posixPermissions: 0o600]) else {
    fail("Can't write \(args[2]).")
}
print("Exported \(want) with \(items.count - 1) intermediate certificate(s).")
SWIFT

if ! swiftc -O -o "${WORK}/export-identity" "${WORK}/export.swift" 2> "${WORK}/swiftc.log"; then
    cat "${WORK}/swiftc.log" >&2
    exit 1
fi

PASS="$(/usr/bin/openssl rand -base64 32 | tr -d '\n')"

if [ -n "$SRC" ]; then
    # P12_PASSWORD is for running this unattended; normally it asks.
    SRC_PASS="${P12_PASSWORD:-}"
    if [ -z "$SRC_PASS" ]; then
        if ! read -rsp "Password for $(basename "$SRC"): " SRC_PASS < /dev/tty; then
            echo "Can't ask for the password without a terminal; run this in one." >&2
            exit 1
        fi
        echo
    fi
else
    # Straight from the keychain: the identity alone first, then on through
    # the same path as a file would take, which adds the intermediates.
    echo "Exporting certificate ${HASH} — approve the keychain prompt with your login password."
    P12_PASSPHRASE="$PASS" "${WORK}/export-identity" "$HASH" "${WORK}/keychain.p12"
    SRC="${WORK}/keychain.p12"
    SRC_PASS="$PASS"
fi
security create-keychain -p "" "$SCRATCH_KC"
EXPORT_KEYCHAIN="$SCRATCH_KC" IN_PASSPHRASE="$SRC_PASS" P12_PASSPHRASE="$PASS" \
    "${WORK}/export-identity" "$HASH" "${WORK}/cert.p12" "$SRC"
unset SRC_PASS

# Check it the way release.yml will: import into an empty keychain and look for
# the hash among the identities that validate. Exactly one should.
security create-keychain -p "" "$CHECK_KC"
security import "${WORK}/cert.p12" -k "$CHECK_KC" -P "$PASS" >/dev/null
security find-identity -v -p codesigning "$CHECK_KC"
VALID="$(security find-identity -v -p codesigning "$CHECK_KC" | grep -c '^ *[0-9]*) ' || true)"
if [ "$VALID" != "1" ] || ! security find-identity -v -p codesigning "$CHECK_KC" | grep -q "$HASH"; then
    echo "The .p12 for CI doesn't hold exactly one valid identity ${HASH}; secrets left unchanged." >&2
    exit 1
fi

echo "Setting the ${REPO} secrets..."
base64 -i "${WORK}/cert.p12" | gh secret set MACOS_CERT_P12_BASE64 --repo "$REPO"
printf '%s' "$PASS" | gh secret set MACOS_CERT_PASSWORD --repo "$REPO"

# A run from main, not a tag: it imports the certificate, builds, signs and
# notarizes, and stops there — publishing and the tap are tag-only.
echo "Dry run of the release workflow from main (publishes nothing)..."
latest_dispatch() {
    gh run list --repo "$REPO" --workflow release.yml --event workflow_dispatch \
        --limit 1 --json databaseId --jq '.[0].databaseId // 0'
}
BEFORE="$(latest_dispatch)"
gh workflow run release.yml --repo "$REPO" --ref main
RUN="$BEFORE"
for _ in $(seq 30); do
    sleep 2
    RUN="$(latest_dispatch)"
    [ "$RUN" != "$BEFORE" ] && break
done
if [ "$RUN" = "$BEFORE" ]; then
    echo "The dry run didn't appear; check https://github.com/${REPO}/actions" >&2
    exit 1
fi
gh run watch "$RUN" --repo "$REPO" --exit-status
echo
echo "CI signs with ${HASH}. Pushing a v* tag now releases on its own."
