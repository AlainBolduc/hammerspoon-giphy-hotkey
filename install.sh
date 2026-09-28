#!/usr/bin/env bash
# Installs giphy for macOS: Hammerspoon hotkey + Keychain API key storage.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMERSPOON_DIR="$HOME/.hammerspoon"
HAMMERSPOON_GIPHY="$HAMMERSPOON_DIR/giphy.lua"
KEYCHAIN_SERVICE="giphy-hammerspoon"
KEYCHAIN_ACCOUNT="$(whoami)"

# --- Check Hammerspoon ---
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install it first." >&2
  exit 1
fi

if [ ! -d "/Applications/Hammerspoon.app" ]; then
  echo "Hammerspoon not found. Installing via Homebrew..." >&2
  brew install --cask hammerspoon
fi

# --- Install Hammerspoon giphy module ---
mkdir -p "$HAMMERSPOON_DIR"
ln -sf "$REPO_DIR/hammerspoon/giphy.lua" "$HAMMERSPOON_GIPHY"

# --- Ensure init.lua loads giphy ---
INIT_LUA="$HAMMERSPOON_DIR/init.lua"
if [ ! -f "$INIT_LUA" ]; then
  cat > "$INIT_LUA" << 'EOF'
require("hs.ipc")
package.path = package.path .. ";" .. os.getenv("HOME") .. "/.hammerspoon/?.lua"
require("giphy")
EOF
else
  if ! grep -q 'require("giphy")' "$INIT_LUA"; then
    echo 'require("giphy")' >> "$INIT_LUA"
  fi
fi

# --- Giphy API key: prompt and store in the macOS Keychain ---
EXISTING_KEY="$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
if [ -n "$EXISTING_KEY" ]; then
  read -r -p "A Giphy API key is already stored in the Keychain. Replace it? [y/N] " REPLACE
  if [[ ! "$REPLACE" =~ ^[Yy]$ ]]; then
    echo "Keeping existing key."
  else
    EXISTING_KEY=""
  fi
fi

if [ -z "$EXISTING_KEY" ]; then
  echo "Get a free Giphy API key at https://developers.giphy.com/dashboard/"
  read -r -s -p "Giphy API key: " GIPHY_KEY
  echo
  if [ -z "$GIPHY_KEY" ]; then
    echo "No key entered, skipping Keychain setup. You can re-run this script later." >&2
  else
    security add-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w "$GIPHY_KEY" -U
    echo "Stored in the macOS Keychain (service: $KEYCHAIN_SERVICE)."
  fi
fi

# --- Reload Hammerspoon ---
if pgrep -q Hammerspoon; then
  if command -v hs >/dev/null 2>&1; then
    hs -c "hs.reload()" 2>/dev/null || true
  else
    osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"' 2>/dev/null || true
  fi
else
  open -a Hammerspoon
fi

cat <<EOF

Installed: $HAMMERSPOON_GIPHY

Usage: Press ⌘⇧G anywhere (Slack, TextEdit, etc.) to open Giphy:
  1. Window opens directly with search bar focused (no default images)
  2. Type query and press Enter (↵) to search (loads 25 GIFs)
  3. Press Enter (↵) again to cycle to the Next GIF!
  4. Press ⌘← to go back to any previous GIF
  5. Press ⇧↵ (or ⌘↵ / "Poster") to insert the short link into active app
  6. Click image or press ⌘C to copy the short link & close
  7. Modifying text and pressing Enter (↵) launches a new search
  8. Click ⚙️ (or press ⌘,) to configure API key, hotkey, or console logging

Note: Hammerspoon needs Accessibility permission (System Settings > Privacy &
Security > Accessibility) to inject text into other apps.

EOF
