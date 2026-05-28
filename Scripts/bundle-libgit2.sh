#!/usr/bin/env bash
#
# bundle-libgit2.sh — recursively copy every Homebrew (or /usr/local) dylib
# that Yggdrasil.app links against into Contents/Frameworks/, rewriting each
# install name + load command to @rpath. Without the recursion, the bundled
# libgit2 still pulls libllhttp/libssh2/etc. from the user's Homebrew, which
# fails library validation on any machine signed with a different Team ID
# (v0.1.0 shipped with this bug — every user crashed at launch).
#
# Usage: Scripts/bundle-libgit2.sh /path/to/Yggdrasil.app
#
# Post-condition (asserted at the end): no Mach-O file inside Contents/ has
# any load command that points into /opt/homebrew or /usr/local.
#
set -euo pipefail

APP_PATH=${1:?"Usage: $0 <Yggdrasil.app>"}
BIN_PATH="$APP_PATH/Contents/MacOS/Yggdrasil"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: not a valid app bundle (no Mach-O at $BIN_PATH)" >&2
    exit 1
fi

mkdir -p "$FRAMEWORKS_DIR"

# We add @executable_path/../Frameworks as an LC_RPATH once, on the main
# binary; bundled dylibs reach each other via @rpath/<basename> and the
# loader resolves that against the running binary's rpath list.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN_PATH" 2>/dev/null || true

# resolve_real_path <path> — follow symlinks to the actual file. Falls back to
# python3 on systems where readlink(1) lacks `-f` (macOS coreutils-free).
resolve_real_path() {
    local p="$1"
    readlink -f "$p" 2>/dev/null \
        || python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$p"
}

# is_external <load-command-path> — true when the load command points into a
# directory we need to bundle (Homebrew or /usr/local). System libs
# (/usr/lib, /System/...) are platform binaries and stay where they are;
# @rpath/@loader_path entries already resolve to our bundled copies.
is_external() {
    case "$1" in
        /opt/homebrew/*|/usr/local/*) return 0 ;;
        *) return 1 ;;
    esac
}

# process <binary> — walk the load commands of <binary>, copy any external
# deps into Frameworks (once), rewrite <binary>'s load commands to point at
# @rpath/<basename>, and recurse so each newly-bundled dylib gets the same
# treatment for its own transitive deps.
process() {
    # Every loop-mutated variable MUST be local. Without `local dep`, the
    # recursive `process` call clobbers the caller's `$dep` mid-loop and the
    # subsequent `install_name_tool -change "$dep"` runs with an empty "from"
    # path — silently noop'ing the rewrite. (Found via the verifier; the
    # symptom was that the main binary still pointed at /opt/homebrew/...
    # after a full bundler pass.)
    local binary="$1"
    local deps dep resolved base bundled
    deps=$(otool -L "$binary" | awk 'NR>1 && $1 ~ /^\// {print $1}')

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        if ! is_external "$dep"; then
            continue
        fi
        resolved=$(resolve_real_path "$dep")
        base=$(basename "$resolved")
        bundled="$FRAMEWORKS_DIR/$base"

        if [[ ! -f "$bundled" ]]; then
            echo "Bundling $resolved -> $bundled"
            cp -f "$resolved" "$bundled"
            chmod u+w "$bundled"
            install_name_tool -id "@rpath/$base" "$bundled"
            # Recurse BEFORE we rewrite the caller — the bundled copy still
            # has its original brew-pointed load commands; recursion fixes
            # those and pulls in their deps too.
            process "$bundled"
        fi

        install_name_tool -change "$dep" "@rpath/$base" "$binary"
    done <<< "$deps"
}

process "$BIN_PATH"

# Verification: scan every Mach-O inside Contents/ and refuse to ship if
# anything still references Homebrew or /usr/local. This is the assertion
# that the old single-shot bundler quietly violated and that caused the
# v0.1.0 dyld crash for every user.
echo
echo "Verifying no Homebrew or /usr/local references remain..."
violations=0
while IFS= read -r mach_o; do
    if otool -L "$mach_o" 2>/dev/null | awk 'NR>1' \
        | grep -E -q '^[[:space:]]*(/opt/homebrew|/usr/local)/'; then
        echo "FAIL: $mach_o still references external paths:" >&2
        otool -L "$mach_o" | awk 'NR>1' \
            | grep -E '/opt/homebrew|/usr/local' >&2 || true
        violations=$((violations + 1))
    fi
done < <(find "$APP_PATH/Contents" -type f \
    \( -name '*.dylib' -o -path "*/MacOS/*" \) -perm -u+x 2>/dev/null)

if [[ $violations -gt 0 ]]; then
    echo "Bundler did not eliminate all external references; aborting." >&2
    exit 1
fi

echo "OK — every Mach-O in $APP_PATH/Contents resolves through @rpath."
echo
echo "Main binary load commands (libgit2 + friends):"
otool -L "$BIN_PATH" | grep -E '@rpath|libgit2' || true
