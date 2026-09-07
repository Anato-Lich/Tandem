#!/bin/bash
#
# make-dmg.sh — build, verify and package Tandem.app as a distributable .dmg.
#
# The release path, end to end:
#
#   1. work out the version (argument, else MARKETING_VERSION in
#      TandemApp/project.yml),
#   2. regenerate the Xcode project with xcodegen if project.yml is newer than
#      the .xcodeproj (the .xcodeproj is git-ignored, so on a fresh clone this
#      is what creates it),
#   3. xcodebuild -configuration Release into build/DerivedData (git-ignored),
#   4. verify the product: no /opt/ paths left in the main binary or in any
#      bundled dylib, a valid signature, the widget appex present, and — unless
#      --no-launch — that the app actually starts and survives five seconds,
#   5. stage Tandem.app + an /Applications symlink + the bundled third-party
#      licences + a "READ ME FIRST.txt" and roll it into a compressed UDZO
#      image at dist/Tandem-<version>.dmg, then hdiutil verify it,
#   6. print the path and its SHA-256.
#
# Steps 3-5 are idempotent: a second run rebuilds and replaces the .dmg rather
# than erroring or accumulating state (the staging folder is remade from
# scratch). The bytes differ run to run — HFS+ inside the image has timestamps.
#
# Usage:
#   tools/make-dmg.sh [version] [--strict] [--no-launch] [-h|--help]
#
#   version       Marketing version to stamp on the .dmg and volume name.
#                 Defaults to MARKETING_VERSION from TandemApp/project.yml.
#   --strict      Refuse to run if the git working tree is dirty. Use this for
#                 a real release; without it a dirty tree is only a warning, so
#                 the script stays usable mid-development.
#   --no-launch   Skip the five-second launch check (it puts an icon in the
#                 menu bar and talks to any attached device, so it is worth
#                 skipping while someone is using the machine).
#
# Requires: Xcode, xcodegen (brew install xcodegen), and the Homebrew kegs
# BatteryCore links against — tools/bundle-dylibs.sh copies those into the
# bundle as a post-build phase, so the resulting .app is self-contained.
#
# The app is signed ad hoc ("-"), not with a Developer ID and not notarised.
# See the "Release" section of TandemApp/README.md for what that means for
# whoever downloads the .dmg; READ ME FIRST.txt inside the image says the same
# thing to them directly.

set -euo pipefail

# ------------------------------------------------------------------- helpers
err()  { echo "error: make-dmg.sh: $*" >&2; exit 1; }
warn() { echo "warning: make-dmg.sh: $*" >&2; }
step() { echo; echo "==> $*"; }
note() { echo "    $*"; }

usage() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --------------------------------------------------------------------- paths
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$ROOT/TandemApp/project.yml"
XCODEPROJ="$ROOT/TandemApp/Tandem.xcodeproj"
DERIVED="$ROOT/build/DerivedData"
PRODUCT="$DERIVED/Build/Products/Release/Tandem.app"
STAGE="$ROOT/build/dmg-stage"
DIST="$ROOT/dist"

DEVELOPER_DIR_DEFAULT=/Applications/Xcode.app/Contents/Developer

# ------------------------------------------------------------------ argument
VERSION=""
STRICT=0
LAUNCH=1
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)  usage 0 ;;
        --strict)   STRICT=1 ;;
        --no-launch) LAUNCH=0 ;;
        -*)         echo "error: unknown option: $1" >&2; usage 2 ;;
        *)
            [ -z "$VERSION" ] || { echo "error: version given twice: $VERSION, $1" >&2; usage 2; }
            VERSION="$1" ;;
    esac
    shift
done

[ -f "$PROJECT_YML" ] || err "no $PROJECT_YML — run this from a Tandem checkout"

if [ -z "$VERSION" ]; then
    # The first MARKETING_VERSION in project.yml is the app target's; the
    # widget's copy below it is kept in step with it by hand.
    VERSION="$(awk -F'"' '/^ *MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_YML")"
    [ -n "$VERSION" ] || err "could not read MARKETING_VERSION from $PROJECT_YML"
    note "version $VERSION (from project.yml)"
else
    note "version $VERSION (from the command line)"
fi
case "$VERSION" in
    *[!0-9.]*|""|.*|*.) err "implausible version: '$VERSION'" ;;
esac

DMG="$DIST/Tandem-$VERSION.dmg"

# ------------------------------------------------------------- clean tree?
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    DIRTY="$(git -C "$ROOT" status --porcelain)"
    if [ -n "$DIRTY" ]; then
        if [ "$STRICT" -eq 1 ]; then
            echo "$DIRTY" >&2
            err "working tree is dirty and --strict was given; commit or stash first"
        fi
        warn "working tree is dirty (not --strict, continuing)"
    fi
else
    warn "not a git checkout; skipping the clean-tree check"
fi

# ----------------------------------------------------------------- xcodegen
step "Generating the Xcode project"
if [ ! -d "$XCODEPROJ" ] || [ "$PROJECT_YML" -nt "$XCODEPROJ/project.pbxproj" ]; then
    command -v xcodegen >/dev/null 2>&1 \
        || err "xcodegen not found (brew install xcodegen) and $XCODEPROJ is stale or missing"
    ( cd "$ROOT/TandemApp" && xcodegen generate ) || err "xcodegen generate failed"
else
    note "$XCODEPROJ is up to date with project.yml"
fi

# -------------------------------------------------------------------- build
step "Building Release"
: "${DEVELOPER_DIR:=$DEVELOPER_DIR_DEFAULT}"
export DEVELOPER_DIR
[ -d "$DEVELOPER_DIR" ] || err "DEVELOPER_DIR does not exist: $DEVELOPER_DIR"
note "DEVELOPER_DIR=$DEVELOPER_DIR"

BUILD_LOG="$ROOT/build/xcodebuild-release.log"
mkdir -p "$ROOT/build"
if ! xcodebuild \
        -project "$XCODEPROJ" \
        -scheme Tandem \
        -configuration Release \
        -derivedDataPath "$DERIVED" \
        build > "$BUILD_LOG" 2>&1; then
    echo "--- last 60 lines of $BUILD_LOG ---" >&2
    tail -60 "$BUILD_LOG" >&2
    err "xcodebuild failed; full log in $BUILD_LOG"
fi
grep -E '^(note: bundle-dylibs|.*warning: )' "$BUILD_LOG" | tail -5 || true
note "built (log: $BUILD_LOG)"
[ -d "$PRODUCT" ] || err "xcodebuild reported success but $PRODUCT is missing"

# ------------------------------------------------------------- verification
step "Verifying $PRODUCT"

MAIN_BIN="$PRODUCT/Contents/MacOS/Tandem"
[ -x "$MAIN_BIN" ] || err "no main binary at $MAIN_BIN"

# 1. Nothing may link anything under /opt (i.e. Homebrew): the whole point of
#    tools/bundle-dylibs.sh is that Contents/Frameworks is the only place dyld
#    has to look, so the .app runs on a Mac with no Homebrew at all.
check_no_opt() {
    local f="$1" bad
    bad="$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep '^/opt/' || true)"
    if [ -n "$bad" ]; then
        echo "    $f:" >&2
        echo "$bad" | sed 's/^/      /' >&2
        return 1
    fi
    return 0
}

opt_failures=0
check_no_opt "$MAIN_BIN" || opt_failures=1
dylib_count=0
if [ -d "$PRODUCT/Contents/Frameworks" ]; then
    while IFS= read -r -d '' dylib; do
        dylib_count=$((dylib_count + 1))
        check_no_opt "$dylib" || opt_failures=1
    done < <(find "$PRODUCT/Contents/Frameworks" -name '*.dylib' -print0)
fi
[ "$opt_failures" -eq 0 ] || err "the product still links libraries outside the bundle"
[ "$dylib_count" -gt 0 ] || err "Contents/Frameworks has no dylibs — did bundle-dylibs.sh run?"
note "otool: main binary + $dylib_count bundled dylibs, no /opt/ paths"
note "$(otool -L "$MAIN_BIN" | tail -n +2 | awk '{print $1}' | grep -c '@rpath/') @rpath references in the main binary"

# 2. Signature. Ad hoc, but it must still be internally consistent, and --deep
#    checks the nested appex and dylibs too.
codesign --verify --deep --strict --verbose=2 "$PRODUCT" 2>&1 | sed 's/^/    /' \
    || err "codesign --verify failed"
SIGNER="$(codesign -dv "$PRODUCT" 2>&1 | awk -F= '/^Signature=/ {print $2}')"
note "signature: ${SIGNER:-unknown} (ad-hoc builds report 'adhoc')"

# 3. The widget extension has to be inside the app, or the widget gallery has
#    nothing to show.
APPEX="$PRODUCT/Contents/PlugIns/TandemWidget.appex"
[ -d "$APPEX" ] || err "missing widget extension: $APPEX"
[ -x "$APPEX/Contents/MacOS/TandemWidget" ] || err "$APPEX has no executable"
note "appex: $(basename "$APPEX") present"

# 4. Licences must have been staged by bundle-dylibs.sh — the bundled dylibs
#    are LGPL/Apache and cannot ship without their texts.
LICENSES_SRC="$PRODUCT/Contents/Resources/Licenses"
[ -d "$LICENSES_SRC" ] || err "missing $LICENSES_SRC (bundle-dylibs.sh should have created it)"
note "licences: $(find "$LICENSES_SRC" -type f | wc -l | tr -d ' ') files"

# 5. Launch check: does it actually run?
if [ "$LAUNCH" -eq 1 ]; then
    step "Launch check (5 s)"
    # -g keeps it in the background, -n forces a new instance of *this* copy
    # rather than reactivating one the user already has running.
    open -g -n "$PRODUCT" || err "open failed"
    launched=0
    for _ in 1 2 3 4 5; do
        sleep 1
        if pgrep -f "$PRODUCT/Contents/MacOS/Tandem" >/dev/null 2>&1; then
            launched=1
        else
            [ "$launched" -eq 1 ] && err "the app started and then exited — see Console for a crash report"
        fi
    done
    [ "$launched" -eq 1 ] || err "the app never appeared in the process list after 'open'"
    osascript -e 'tell application id "dev.tandem.app" to quit' >/dev/null 2>&1 || true
    sleep 1
    pkill -f "$PRODUCT/Contents/MacOS/Tandem" >/dev/null 2>&1 || true
    note "launched and survived 5 s, then quit cleanly"
else
    note "launch check skipped (--no-launch)"
fi

# ------------------------------------------------------------------ staging
step "Staging the disk image"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# ditto, not cp -R: it preserves the extended attributes and the code
# signature of the bundle exactly.
ditto "$PRODUCT" "$STAGE/Tandem.app"
ln -s /Applications "$STAGE/Applications"
ditto "$LICENSES_SRC" "$STAGE/Licenses"

cat > "$STAGE/READ ME FIRST.txt" <<EOF
Tandem $VERSION
===============

To install: drag Tandem.app onto the Applications folder in this window.

This build is signed ad hoc and is NOT notarised by Apple.
------------------------------------------------------------------
Because it is not notarised, macOS Gatekeeper will refuse to open it on the
first try, with a message like "Tandem is damaged and can't be opened" or
"cannot be opened because Apple cannot check it for malicious software".
That message is about the missing notarisation, not about the app.

Two ways round it, after copying Tandem.app to /Applications:

  1. In Terminal:

         xattr -dr com.apple.quarantine /Applications/Tandem.app

     Then open the app normally. This removes the quarantine flag macOS
     attaches to anything downloaded from the internet.

  2. Or, without the Terminal: right-click (or Control-click) Tandem.app in
     the Finder, choose "Open", and confirm "Open" in the dialog that
     appears. On recent macOS versions you may instead have to open
     System Settings > Privacy & Security, scroll down, and click
     "Open Anyway" after the first blocked attempt.

You only have to do this once.

What it is
----------
Tandem lives in the menu bar and shows the battery level of the iPhone or
iPad plugged into this Mac, plus a matching WidgetKit widget for Notification
Centre and the desktop. It talks to the device over USB only; nothing is
uploaded anywhere.

The first time you plug a device in, unlock it and tap "Trust This Computer".

Third-party code
----------------
The Licenses folder in this image contains the licence texts for the
libimobiledevice and OpenSSL libraries bundled inside the app; the same files
are inside Tandem.app at Contents/Resources/Licenses.

Uninstalling
------------
Drag Tandem.app to the Trash and delete
~/Library/Application Support/Tandem.
EOF

# ----------------------------------------------------------------- the image
step "Building $DMG"
mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create \
    -volname "Tandem $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -quiet \
    "$DMG" || err "hdiutil create failed"

step "Verifying $DMG"
hdiutil verify "$DMG" 2>&1 | sed 's/^/    /' || err "hdiutil verify failed"

rm -rf "$STAGE"

# ------------------------------------------------------------------- report
step "Done"
echo "    $DMG"
echo "    $(du -h "$DMG" | awk '{print $1}')  ($(stat -f%z "$DMG") bytes)"
echo "    $(shasum -a 256 "$DMG")"
echo
echo "    Not notarised: tell testers to run"
echo "      xattr -dr com.apple.quarantine /Applications/Tandem.app"
echo "    or right-click -> Open. READ ME FIRST.txt in the image says so too."
