#!/bin/bash
set -euo pipefail

# CCSwitcher Local Dev Build Script
#
# Builds CCSwitcher.app for local installation with PINNED signing identity.
# Refuses ad-hoc signing (CODE_SIGN_IDENTITY="-") because:
#   1. Ad-hoc-signed apps have no stable code-signing identity, so the macOS
#      keychain prompts on every cross-app read of `Claude Code-credentials`.
#   2. "Always Allow" cannot persist trust for an ad-hoc binary across rebuilds.
#   3. The user clicks Allow, the prompt times out, the keychain write partially
#      fails, and Claude Code is left with a stale/half-written credential → 401.
#
# This script enforces:
#   - DEVELOPMENT_TEAM        = 6QF32QTRVD   (Long's personal Apple Dev team)
#   - CODE_SIGN_STYLE         = Automatic
#   - CODE_SIGN_IDENTITY     != "-"           (no ad-hoc)
#   - PRODUCT_BUNDLE_IDENTIFIER = me.xueshi.ccswitcher  (keep ACL stable)
#
# Usage:
#   ./scripts/build.sh                 # release config, default install path
#   ./scripts/build.sh debug           # debug config
#   ./scripts/build.sh release install # rebuild + install over /Applications/CCSwitcher.app

CONFIGURATION="${1:-release}"
INSTALL_ACTION="${2:-}"
EXPECTED_TEAM="6QF32QTRVD"
EXPECTED_BUNDLE_ID="me.xueshi.ccswitcher"
INSTALL_PATH="/Applications/CCSwitcher.app"

die() { echo "ERROR: $1" >&2; exit 1; }
say() { echo "==> $1"; }

# --- Preflight ---

[ -f "project.yml" ] || die "Must be run from the project root (project.yml not found)"

command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode command-line tools"

# Refuse ad-hoc signing if it was passed via env (catch DeepSeek-style mistakes)
if [ "${CODE_SIGN_IDENTITY:-}" = "-" ]; then
    die "CODE_SIGN_IDENTITY=\"-\" (ad-hoc) is REFUSED. This breaks keychain ACL trust with Claude Code-credentials. See memory/feedback_native_macos_builds.md."
fi

# Verify the expected dev team is installed and has a valid cert.
# `security find-identity` doesn't print OU=<TeamID>, so we extract every
# Apple Development cert and grep its subject for the team identifier.
say "Verifying signing identity..."
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" || true)
if [ -z "$IDENTITIES" ]; then
    die "No Apple Development identities found in the keychain. Open Xcode → Settings → Accounts and download manual profiles."
fi
CERT_TEAMS=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | awk '/-----BEGIN CERTIFICATE-----/{flag=1; cert=""} flag{cert=cert $0 "\n"} /-----END CERTIFICATE-----/{flag=0; print cert; cert=""}' \
    | while IFS= read -r line; do
        if [ "$line" = "-----BEGIN CERTIFICATE-----" ]; then
            buf="$line"
        elif [ "$line" = "-----END CERTIFICATE-----" ]; then
            buf="$buf"$'\n'"$line"
            echo "$buf" | openssl x509 -noout -subject 2>/dev/null
            buf=""
        else
            buf="$buf"$'\n'"$line"
        fi
    done | grep -oE "OU=[A-Z0-9]{10}" | sed 's/OU=//' | sort -u)

# Fallback: enumerate certs by SHA-1 from find-identity
if [ -z "$CERT_TEAMS" ]; then
    CERT_TEAMS=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Apple Development/{print $2}' \
        | while read -r sha; do
            security find-certificate -c "$sha" -p 2>/dev/null \
                | openssl x509 -noout -subject 2>/dev/null \
                | grep -oE "OU=[A-Z0-9]{10}" | sed 's/OU=//'
        done | sort -u)
fi
echo "Apple Dev teams in keychain: ${CERT_TEAMS:-(none detected — falling back to runtime team check)}"
if [ -n "$CERT_TEAMS" ]; then
    echo "$CERT_TEAMS" | grep -qx "$EXPECTED_TEAM" \
        || die "Expected team $EXPECTED_TEAM not present in installed certs. Got: $CERT_TEAMS"
fi
# If extraction failed, we'll catch the wrong team later in the post-build codesign check.

# Verify project.yml has the expected bundle ID + team
grep -q "PRODUCT_BUNDLE_IDENTIFIER.*$EXPECTED_BUNDLE_ID" project.yml || die "project.yml bundle ID drifted from $EXPECTED_BUNDLE_ID (would break Claude Code-credentials ACL trust)"

# Regenerate the .xcodeproj from project.yml so any project.yml drift is reflected
if command -v xcodegen >/dev/null; then
    say "Regenerating CCSwitcher.xcodeproj from project.yml..."
    xcodegen generate >/dev/null
else
    say "xcodegen not installed — skipping project regen (use existing .xcodeproj)"
fi

# --- Build ---

BUILD_DIR="build"
case "$CONFIGURATION" in
    debug)   CONFIG_TITLECASE="Debug" ;;
    release) CONFIG_TITLECASE="Release" ;;
    *) die "Unknown configuration: $CONFIGURATION (use debug or release)" ;;
esac

say "Building $CONFIG_TITLECASE into $BUILD_DIR/..."
rm -rf "$BUILD_DIR"
BUILD_LOG="$BUILD_DIR/xcodebuild.log"
mkdir -p "$BUILD_DIR"
set +e
xcodebuild \
    -project CCSwitcher.xcodeproj \
    -scheme CCSwitcher \
    -configuration "$CONFIG_TITLECASE" \
    -derivedDataPath "$BUILD_DIR" \
    DEVELOPMENT_TEAM="$EXPECTED_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates \
    build > "$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e
if [ $BUILD_STATUS -ne 0 ]; then
    echo "--- last 40 lines of xcodebuild log: ---"
    tail -40 "$BUILD_LOG"
    die "xcodebuild exited $BUILD_STATUS. Full log: $BUILD_LOG"
fi
grep -E "^(error|warning):" "$BUILD_LOG" | head -10 || true

BUILT_APP="$BUILD_DIR/Build/Products/$CONFIG_TITLECASE/CCSwitcher.app"
[ -d "$BUILT_APP" ] || die "Build produced no .app at $BUILT_APP — check $BUILD_LOG"

# --- Verify the built binary's signature is NOT ad-hoc ---

say "Verifying built signature..."
SIGINFO=$(codesign -dv "$BUILT_APP" 2>&1)
echo "$SIGINFO"

# Must have an Authority chain (not adhoc)
if echo "$SIGINFO" | grep -qi "Signature=adhoc"; then
    die "Built app is ad-hoc signed. Refusing to install — this would break keychain ACL trust."
fi
if ! echo "$SIGINFO" | grep -q "Authority=Apple Development"; then
    die "Built app is not signed by Apple Development. Authority chain:\n$SIGINFO"
fi
if ! echo "$SIGINFO" | grep -q "TeamIdentifier=$EXPECTED_TEAM"; then
    die "Built app has the wrong TeamIdentifier (expected $EXPECTED_TEAM). $SIGINFO"
fi

# Bundle ID must match
ACTUAL_BUNDLE_ID=$(defaults read "$BUILT_APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "")
[ "$ACTUAL_BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || die "Bundle ID drift: built '$ACTUAL_BUNDLE_ID', expected '$EXPECTED_BUNDLE_ID'"

say "Signature OK — TeamIdentifier=$EXPECTED_TEAM, BundleID=$EXPECTED_BUNDLE_ID, not ad-hoc"

# --- Install (optional) ---

if [ "$INSTALL_ACTION" = "install" ]; then
    say "Installing to $INSTALL_PATH..."
    # Kill running CCSwitcher before overwriting
    pkill -x CCSwitcher 2>/dev/null || true
    sleep 1
    rm -rf "$INSTALL_PATH"
    cp -R "$BUILT_APP" "$INSTALL_PATH"
    say "Installed. Verifying installed signature..."
    codesign -dv "$INSTALL_PATH" 2>&1 | head -5
    say "Done. Launch with: open '$INSTALL_PATH'"
else
    say "Build complete: $BUILT_APP"
    say "Install with: $0 $CONFIGURATION install"
fi
