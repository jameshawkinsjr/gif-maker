# Shared settings for the build scripts. Sourced, not executed.
#
# Environment:
#   CODESIGN_IDENTITY   Signing identity to use. Defaults to the first
#                       "Developer ID Application" certificate in your keychain,
#                       then the first "Apple Development" one, or ad-hoc ("-")
#                       if there is neither.
#   BUNDLE_ID           Bundle identifier (default: app.gifmaker.GifMaker).
#   VERSION             Version string (default: 1.0.0).

APP_NAME="GIF Maker"
BUNDLE_ID="${BUNDLE_ID:-app.gifmaker.GifMaker}"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR="build"

# Prints the code-signing identity to use; "-" means ad-hoc.
signing_identity() {
    if [ -n "${CODESIGN_IDENTITY:-}" ]; then
        echo "$CODESIGN_IDENTITY"
        return
    fi
    local identities identity
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    identity="$(echo "$identities" | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
    if [ -z "$identity" ]; then
        identity="$(echo "$identities" | awk -F'"' '/Apple Development/ { print $2; exit }')"
    fi
    echo "${identity:--}"
}

# True when the identity is a Developer ID certificate, i.e. one Gatekeeper
# trusts for apps distributed outside the App Store.
is_developer_id() {
    case "$1" in
        "Developer ID Application"*) return 0 ;;
        *) return 1 ;;
    esac
}
