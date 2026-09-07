#!/bin/bash
#
# bundle-dylibs.sh — make Tandem.app self-contained.
#
# BatteryCore links the libimobiledevice / libusbmuxd / libimobiledevice-glue /
# libplist / OpenSSL chain out of /opt/homebrew (see BatteryCore/NOTES.md §2
# and §7). Without this script the built .app only runs on a Mac that has the
# same Homebrew kegs installed at the same absolute paths.
#
# This script:
#   1. walks the *closure* of non-system dylibs reachable from every Mach-O in
#      Tandem.app/Contents/MacOS (in Debug that is Tandem, Tandem.debug.dylib
#      and __preview.dylib; in Release just Tandem),
#   2. copies each one into Tandem.app/Contents/Frameworks,
#   3. rewrites its LC_ID_DYLIB and every dependent reference to @rpath/<name>,
#   4. deletes the /opt/homebrew/lib LC_RPATH if a stale build left one behind,
#   5. copies the upstream licence files into Contents/Resources/Licenses,
#   6. ad-hoc re-signs every dylib it touched and then the app bundle,
#   7. verifies that nothing under Contents/ still mentions /opt/homebrew.
#
# It is idempotent: the copy/rewrite is done from the pristine Homebrew
# originals every time, so running it twice (or on an already-bundled app)
# produces the same bytes. It fails loudly — non-zero, with a message Xcode
# shows as an error — if a dylib in the closure cannot be found.
#
# Usage:  bundle-dylibs.sh [/path/to/Tandem.app]
# With no argument it uses "$BUILT_PRODUCTS_DIR/$WRAPPER_NAME" from the Xcode
# build environment (that is how the Tandem target's post-build phase calls it,
# see TandemApp/project.yml).

set -euo pipefail

err() { echo "error: bundle-dylibs.sh: $*" >&2; exit 1; }
note() { echo "note: bundle-dylibs.sh: $*"; }

# ---------------------------------------------------------------- the bundle
if [ $# -ge 1 ]; then
    APP="$1"
else
    [ -n "${BUILT_PRODUCTS_DIR:-}" ] && [ -n "${WRAPPER_NAME:-}" ] \
        || err "no app path given and BUILT_PRODUCTS_DIR/WRAPPER_NAME are unset"
    APP="$BUILT_PRODUCTS_DIR/$WRAPPER_NAME"
fi
[ -d "$APP" ] || err "not a bundle: $APP"

MACOS_DIR="$APP/Contents/MacOS"
FRAMEWORKS="$APP/Contents/Frameworks"
LICENSES="$APP/Contents/Resources/Licenses"

CODESIGN="${CODESIGN:-/usr/bin/codesign}"
INSTALL_NAME_TOOL="${INSTALL_NAME_TOOL:-/usr/bin/install_name_tool}"
OTOOL="${OTOOL:-/usr/bin/otool}"

# Where an original (un-rewritten) copy of a third-party dylib can be found.
# Homebrew symlinks every keg's libs into <prefix>/lib, so one directory covers
# the whole chain.
SOURCE_DIRS=("${HOMEBREW_PREFIX:-/opt/homebrew}/lib" /usr/local/lib)

# Classify one entry of otool -L. Echoes the absolute path of the original
# library we must bundle, or nothing if the dependency needs no work.
#
# The @rpath case is what makes this script idempotent: on a second run the
# app's binaries already say @rpath/libplist-2.0.4.dylib, and we have to map
# that back to the Homebrew original rather than conclude there is nothing to
# do (and then ship an app whose Frameworks/ and Licenses/ we just emptied).
locate_dep() {
    local dep="$1" name
    case "$dep" in
        /usr/lib/*|/System/*) return 0 ;;
        /*) echo "$dep"; return 0 ;;
        @rpath/*)
            name="${dep#@rpath/}"
            # A product of this build (Tandem.debug.dylib) — already a root.
            [ -e "$MACOS_DIR/$name" ] && return 0
            # Something a previous run of this script already bundled.
            if [ -e "$FRAMEWORKS/$name" ]; then
                local d
                for d in "${SOURCE_DIRS[@]}"; do
                    [ -e "$d/$name" ] && { echo "$d/$name"; return 0; }
                done
                err "$name is already in Contents/Frameworks but its original is gone from ${SOURCE_DIRS[*]} — install it (brew install libimobiledevice libusbmuxd libimobiledevice-glue libplist openssl@3) and build again"
            fi
            return 0 ;;
        *) return 0 ;;
    esac
}

# realpath(1) is not on every macOS this has to build on, and the Homebrew
# paths are two symlinks deep (/opt/homebrew/opt/<f> -> ../Cellar/<f>/<v>),
# which matters: libssl names libcrypto by its Cellar path while everything
# else names it by its opt path, and both have to resolve to one entry.
resolve() {
    local p="$1" d b
    while [ -L "$p" ]; do
        d="$(cd "$(dirname "$p")" && pwd -P)"
        b="$(readlink "$p")"
        case "$b" in /*) p="$b" ;; *) p="$d/$b" ;; esac
    done
    d="$(cd "$(dirname "$p")" && pwd -P)"
    printf '%s/%s\n' "$d" "$(basename "$p")"
}

# install_name_tool always warns "changes ... will invalidate the code
# signature" — we re-sign right afterwards, so that line is pure noise in the
# Xcode log. Swallow it, keep everything else, and still fail on a real error.
int_quiet() {
    local out status
    out="$("$INSTALL_NAME_TOOL" "$@" 2>&1)" && status=0 || status=$?
    printf '%s' "$out" | grep -v 'will invalidate the code signature' | grep -v '^$' >&2 || true
    [ $status -eq 0 ] || err "install_name_tool $* failed"
}

# otool -L minus the first line (the file's own name) and minus the trailing
# "(compatibility version ...)".
deps_of() {
    "$OTOOL" -L "$1" | tail -n +2 | sed -e 's/ (compatibility.*//' -e 's/^[[:space:]]*//'
}

# ------------------------------------------------------- roots of the closure
roots=()
while IFS= read -r -d '' f; do
    file -b "$f" | grep -q 'Mach-O' && roots+=("$f")
done < <(find "$MACOS_DIR" -type f -print0)
[ ${#roots[@]} -gt 0 ] || err "no Mach-O binaries in $MACOS_DIR"

# ------------------------------------------------ breadth-first over the deps
# sources[i] is an absolute, symlink-resolved path to an original dylib;
# names[i] its basename, which is what it becomes in Contents/Frameworks.
sources=()
names=()

have_source() {
    local s
    for s in ${sources[@]+"${sources[@]}"}; do [ "$s" = "$1" ] && return 0; done
    return 1
}

queue=("${roots[@]}")
while [ ${#queue[@]} -gt 0 ]; do
    current="${queue[0]}"
    queue=("${queue[@]:1}")
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        orig="$(locate_dep "$dep")"
        [ -n "$orig" ] || continue
        [ -f "$orig" ] || err "missing dependency $dep (needed by $current) — install it (brew install libimobiledevice libusbmuxd libimobiledevice-glue libplist openssl@3) and build again"
        real="$(resolve "$orig")"
        [ -f "$real" ] || err "dangling dependency $dep -> $real (needed by $current)"
        have_source "$real" && continue
        sources+=("$real")
        names+=("$(basename "$real")")
        queue+=("$real")
    done < <(deps_of "$current")
done

if [ ${#sources[@]} -eq 0 ]; then
    note "no non-system dylibs to bundle"
else
    note "bundling ${#sources[@]} dylib(s): ${names[*]}"
fi

# Two different libraries with the same basename would collide in Frameworks.
if [ ${#names[@]} -gt 0 ]; then
    dupes="$(printf '%s\n' "${names[@]}" | sort | uniq -d)"
    [ -z "$dupes" ] || err "two dependencies share a basename, they would collide in Contents/Frameworks: $dupes"
fi

# Map basename -> is it one of ours? (used when rewriting references)
is_bundled_name() {
    local n
    for n in ${names[@]+"${names[@]}"}; do [ "$n" = "$1" ] && return 0; done
    return 1
}

# ------------------------------------------------------- copy + rewrite names
mkdir -p "$FRAMEWORKS"
i=0
while [ $i -lt ${#sources[@]} ]; do
    src="${sources[$i]}"
    name="${names[$i]}"
    dst="$FRAMEWORKS/$name"
    # Always re-copy from the pristine original: that is what makes a second
    # run produce the same bytes as the first, rather than rewriting an
    # already-rewritten copy.
    rm -f "$dst"
    cp "$src" "$dst"
    chmod u+w "$dst"
    int_quiet -id "@rpath/$name" "$dst"
    i=$((i + 1))
done

# Rewrite dependent references, in the copies and in the app's own binaries.
rewrite_refs() {
    local bin="$1" dep base
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        case "$dep" in @rpath/*) continue ;; esac   # already done
        [ -n "$(locate_dep "$dep")" ] || continue
        base="$(basename "$dep")"
        is_bundled_name "$base" || err "$bin references $dep, which is not in the bundled set"
        int_quiet -change "$dep" "@rpath/$base" "$bin"
    done < <(deps_of "$bin")
}

for name in ${names[@]+"${names[@]}"}; do rewrite_refs "$FRAMEWORKS/$name"; done
for bin in "${roots[@]}"; do
    chmod u+w "$bin"
    rewrite_refs "$bin"
    # @executable_path/../Frameworks must be on the runpath, and /opt/homebrew
    # must not: project.yml no longer adds the latter, but a binary carried
    # over from an older build might still have it.
    if "$OTOOL" -l "$bin" | grep -q ' path /opt/homebrew/lib '; then
        int_quiet -delete_rpath /opt/homebrew/lib "$bin"
        note "removed stale /opt/homebrew/lib rpath from $(basename "$bin")"
    fi
    if ! "$OTOOL" -l "$bin" | grep -q ' path @executable_path/../Frameworks '; then
        int_quiet -add_rpath @executable_path/../Frameworks "$bin"
    fi
done

# ------------------------------------------------------------------ licences
# All six dylibs are LGPL-2.1-or-later (libimobiledevice, libusbmuxd,
# libimobiledevice-glue, libplist) or Apache-2.0 (OpenSSL 3). Ship the
# upstream texts out of the keg the dylib actually came from, so the version in
# Contents/Frameworks and the licence beside it always match.
rm -rf "$LICENSES"
mkdir -p "$LICENSES"
{
    echo "Third-party libraries bundled in Tandem.app/Contents/Frameworks."
    echo
} > "$LICENSES/README.txt"

i=0
while [ $i -lt ${#sources[@]} ]; do
    src="${sources[$i]}"
    name="${names[$i]}"
    i=$((i + 1))
    # /opt/homebrew/Cellar/<formula>/<version>/lib/<dylib> -> keg root
    keg="$(dirname "$(dirname "$src")")"
    formula="$(basename "$(dirname "$keg")")"
    version="$(basename "$keg")"
    found=""
    for lic in COPYING COPYING.LESSER LICENSE LICENSE.txt NOTICE; do
        [ -f "$keg/$lic" ] || continue
        mkdir -p "$LICENSES/$formula"
        cp "$keg/$lic" "$LICENSES/$formula/$lic"
        found="$found $lic"
    done
    [ -n "$found" ] || err "no licence file found in $keg for $name — cannot ship it without one"
    echo "$name — $formula $version —$found" >> "$LICENSES/README.txt"
done

# ------------------------------------------------------------------- signing
# Ad hoc, because this machine has no signing identity (TandemApp/README.md,
# "Limitations without a signing identity").
#
# Not --deep on the app: TandemWidget.appex carries its own sandbox
# entitlements, and a deep re-sign would drop them and break the container
# trick the widget depends on. Nested code is signed individually instead, and
# the app's own signature then seals it by cdhash.
sign() { "$CODESIGN" --force --sign - --timestamp=none "$1" >/dev/null 2>&1 || err "codesign failed on $1"; }

for name in ${names[@]+"${names[@]}"}; do sign "$FRAMEWORKS/$name"; done
# Contents/MacOS/*.dylib (Xcode's Debug "debug dylib" and __preview.dylib) are
# sealed as resources of the app, not signed by the app's CodeSign step, so
# they need their own signature after install_name_tool touched them.
for bin in "${roots[@]}"; do
    case "$bin" in *.dylib) sign "$bin" ;; esac
done
sign "$APP"

# -------------------------------------------------------------- verification
bad=0
while IFS= read -r -d '' f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    if deps_of "$f" | grep -q '^/opt/'; then
        echo "error: bundle-dylibs.sh: $f still links something outside the bundle:" >&2
        deps_of "$f" | grep '^/opt/' >&2
        bad=1
    fi
    if "$OTOOL" -l "$f" | grep -q ' path /opt/'; then
        echo "error: bundle-dylibs.sh: $f still has an /opt runpath" >&2
        bad=1
    fi
done < <(find "$APP/Contents" -type f -print0)
[ $bad -eq 0 ] || err "verification failed"

note "Contents/Frameworks is self-contained ($APP)"
