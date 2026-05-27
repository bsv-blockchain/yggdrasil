#!/usr/bin/env bash
#
# bundle-libgit2.sh — copy libgit2 into Yggdrasil.app/Contents/Frameworks and
# rewrite the binary's load command so the app runs without a Homebrew
# install of libgit2. Required before Developer ID signing + notarization.
#
# Usage: Scripts/bundle-libgit2.sh /path/to/Yggdrasil.app
#
set -euo pipefail

APP_PATH=${1:?"Usage: $0 <Yggdrasil.app>"}
BIN_PATH="$APP_PATH/Contents/MacOS/Yggdrasil"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: not a valid app bundle (no Mach-O at $BIN_PATH)" >&2
    exit 1
fi

# Resolve the absolute path of the libgit2 dylib the binary currently links
# against. We accept either Homebrew (arm or x86) or a manual install.
HOST_DYLIB=$(otool -L "$BIN_PATH" \
    | awk '/libgit2[.0-9]*\.dylib/ {print $1; exit}')

if [[ -z "$HOST_DYLIB" ]]; then
    echo "error: no libgit2 load command found in $BIN_PATH" >&2
    exit 1
fi

# Follow symlinks to the real file. otool may report a versioned symlink
# (e.g. libgit2.1.9.dylib).
RESOLVED=$(readlink -f "$HOST_DYLIB" 2>/dev/null || python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$HOST_DYLIB")
DYLIB_BASENAME=$(basename "$RESOLVED")

echo "Bundling $RESOLVED into $FRAMEWORKS_DIR/$DYLIB_BASENAME"
mkdir -p "$FRAMEWORKS_DIR"
cp -f "$RESOLVED" "$FRAMEWORKS_DIR/$DYLIB_BASENAME"
chmod u+w "$FRAMEWORKS_DIR/$DYLIB_BASENAME"

# Give the bundled copy a stable install name and rewrite the binary's
# load command to look in @rpath. Add an @rpath entry pointing at the
# Frameworks dir so dyld resolves the dylib at runtime.
install_name_tool \
    -id "@rpath/$DYLIB_BASENAME" \
    "$FRAMEWORKS_DIR/$DYLIB_BASENAME"
install_name_tool \
    -change "$HOST_DYLIB" "@rpath/$DYLIB_BASENAME" \
    "$BIN_PATH"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN_PATH" 2>/dev/null || true

echo "Verified load command:"
otool -L "$BIN_PATH" | grep libgit2 || true
