#!/bin/zsh
# Bundles Homebrew Ghostscript into the app so users need no dependencies:
#   Contents/Resources/gs/bin/gs      the binary (load paths rewritten)
#   Contents/Resources/gs/lib/        all non-system dylibs, recursively
#   Contents/Resources/gs/share/      Resource/, lib/, fonts/, iccprofiles/
# Ghostscript is AGPL-3.0; its license is copied into the bundle.
set -euo pipefail

APP="$1"
GS_REAL=$(readlink -f /opt/homebrew/bin/gs)
[ -x "$GS_REAL" ] || { echo "Homebrew ghostscript not found (brew install ghostscript)"; exit 1; }
GS_PREFIX=$(dirname "$(dirname "$GS_REAL")")   # …/Cellar/ghostscript/<version>
GS_VERSION=$(basename "$GS_PREFIX")

GS_DIR="$APP/Contents/Resources/gs"
BINDIR="$GS_DIR/bin"
LIBDIR="$GS_DIR/lib"
rm -rf "$GS_DIR"
mkdir -p "$BINDIR" "$LIBDIR"

cp "$GS_REAL" "$BINDIR/gs"
chmod u+w "$BINDIR/gs"

# Resource files live in share/ghostscript/ (some builds add a version subdir)
if [ -d "$GS_PREFIX/share/ghostscript/$GS_VERSION" ]; then
    cp -R "$GS_PREFIX/share/ghostscript/$GS_VERSION" "$GS_DIR/share"
else
    cp -R "$GS_PREFIX/share/ghostscript" "$GS_DIR/share"
fi
for lic in LICENSE COPYING; do
    [ -f "$GS_PREFIX/$lic" ] && cp "$GS_PREFIX/$lic" "$GS_DIR/$lic"
done

# Collect Homebrew dylib dependencies to a fixpoint. Deps appear either as
# absolute /opt/homebrew paths or as @rpath/… (resolved via /opt/homebrew/lib).
list_deps() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E '^(/opt/homebrew|@rpath)' || true
}
resolve_dep() {
    case "$1" in
        @rpath/*) echo "/opt/homebrew/lib/$(basename "$1")" ;;
        *)        echo "$1" ;;
    esac
}
while :; do
    before=$(ls "$LIBDIR" | wc -l)
    for f in "$BINDIR/gs" "$LIBDIR"/*(.N); do
        for dep in $(list_deps "$f"); do
            base=$(basename "$dep")
            src=$(resolve_dep "$dep")
            if [ ! -e "$LIBDIR/$base" ]; then
                cp "$(readlink -f "$src")" "$LIBDIR/$base"
                chmod u+w "$LIBDIR/$base"
            fi
        done
    done
    after=$(ls "$LIBDIR" | wc -l)
    [ "$before" -eq "$after" ] && break
done

# Rewrite load commands to be relative to the bundle.
for dep in $(list_deps "$BINDIR/gs"); do
    install_name_tool -change "$dep" "@executable_path/../lib/$(basename "$dep")" "$BINDIR/gs" 2>/dev/null
done
for lib in "$LIBDIR"/*(.N); do
    install_name_tool -id "@loader_path/$(basename "$lib")" "$lib" 2>/dev/null
    for dep in $(list_deps "$lib"); do
        install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$lib" 2>/dev/null
    done
done

# install_name_tool invalidates signatures — re-sign everything ad hoc.
codesign -f -s - "$LIBDIR"/*(.N) "$BINDIR/gs" 2>/dev/null

# Verify nothing still points at /opt/homebrew or an unresolved @rpath.
leftover=$(otool -L "$BINDIR/gs" "$LIBDIR"/*(.N) | tail -n +2 | grep -cE '(/opt/homebrew|@rpath)' || true)
if [ "$leftover" -ne 0 ]; then
    echo "❌ $leftover unresolved /opt/homebrew references remain"; exit 1
fi
echo "   Ghostscript $GS_VERSION bundled ($(du -sh "$GS_DIR" | awk '{print $1}'), $(ls "$LIBDIR" | wc -l | tr -d ' ') dylibs)"
