#!/bin/zsh
# Installs PDF Compressor.app into /Applications and the
# "Compress PDF" Quick Action into Finder's right-click menu.
set -euo pipefail
cd "$(dirname "$0")"

[ -d "dist/PDF Compressor.app" ] || ./build.sh

echo "── Installing app to /Applications…"
rm -rf "/Applications/PDF Compressor.app"
cp -R "dist/PDF Compressor.app" "/Applications/PDF Compressor.app"

echo "── Installing Quick Action…"
SERVICES="$HOME/Library/Services"
mkdir -p "$SERVICES"
rm -rf "$SERVICES/Compress PDF.workflow"
cp -R "QuickAction/Compress PDF.workflow" "$SERVICES/Compress PDF.workflow"

# Refresh the Services registry so it shows up without a logout
/System/Library/CoreServices/pbs -flush 2>/dev/null || true
/System/Library/CoreServices/pbs -update 2>/dev/null || true

echo "✅ Installed. Right-click a PDF in Finder → Quick Actions → Compress PDF"
