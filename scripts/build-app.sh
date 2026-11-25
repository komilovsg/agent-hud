#!/bin/bash
# Build AgentHUD.app from source (Command Line Tools are enough).
#
#   scripts/build-app.sh            build dist/AgentHUD.app
#   scripts/build-app.sh --install  also copy it to ~/Applications and link ~/.local/bin/agenthud-hook
#                                   and ~/.local/bin/agenthud-mcp
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AgentHud
swift build -c release --product agenthud-hook
swift build -c release --product agenthud-mcp
BIN="$(swift build -c release --show-bin-path)"

APP=dist/AgentHUD.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
# The executable inside the bundle is named AgentHUD, as in Info.plist.
cp "$BIN/AgentHud" "$APP/Contents/MacOS/AgentHUD"
cp "$BIN/agenthud-hook" "$APP/Contents/Helpers/agenthud-hook"
# The screen tools server for agents: it only forwards calls to the app, which holds the permissions.
cp "$BIN/agenthud-mcp" "$APP/Contents/Helpers/agenthud-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Fonts (OFL): Golos Text, IBM Plex Mono
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles, if any
for b in "$BIN"/*.bundle; do [ -e "$b" ] && case "$b" in *Tests*) ;; *) cp -R "$b" "$APP/Contents/Resources/";; esac; done
# Signature: without one macOS does not remember any permission. An ad-hoc signature changes with every build,
# so the permissions are asked again each time. A certificate named "Agent HUD Local Signing" in the keychain
# (or the one named in AGENTHUD_SIGN_IDENTITY) keeps them across builds; see the README.
SIGN="${AGENTHUD_SIGN_IDENTITY:-Agent HUD Local Signing}"
security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN\"" || SIGN=-
codesign --force --sign "$SIGN" "$APP/Contents/Helpers/agenthud-hook"
codesign --force --sign "$SIGN" "$APP/Contents/Helpers/agenthud-mcp"
codesign --force --sign "$SIGN" "$APP"
[ "$SIGN" = - ] && echo "Signed ad hoc" || echo "Signed with: $SIGN"
echo "Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications" "$HOME/.local/bin"
    pkill -x AgentHUD 2>/dev/null || true
    rm -rf "$HOME/Applications/AgentHUD.app"
    cp -R "$APP" "$HOME/Applications/AgentHUD.app"
    ln -sfn "$HOME/Applications/AgentHUD.app/Contents/Helpers/agenthud-hook" "$HOME/.local/bin/agenthud-hook"
    ln -sfn "$HOME/Applications/AgentHUD.app/Contents/Helpers/agenthud-mcp" "$HOME/.local/bin/agenthud-mcp"
    echo "Installed: ~/Applications/AgentHUD.app, hook: ~/.local/bin/agenthud-hook, screen tools: ~/.local/bin/agenthud-mcp"
    echo "Run: open ~/Applications/AgentHUD.app"
fi
