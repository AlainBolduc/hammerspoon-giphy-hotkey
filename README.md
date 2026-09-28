# giphy

Press **⌘⇧G** anywhere on macOS (Slack, Teams, iMessage, email…) to search Giphy,
preview animated results in a native carousel, and insert the link you pick.

No automatic NSFW filtering: the animated preview is the filter, left to you
before you click "Poster".

## How it works

[Hammerspoon](https://www.hammerspoon.org/) binds **⌘⇧G** globally. When pressed:
- Shows a text-input dialog for your search query
- Searches Giphy API
- Displays 5 results in an animated WKWebView carousel
- Navigation: ← Précédent / Suivant → (or arrow keys), Enter to post, Esc to cancel
- On "Poster": restores keyboard focus to the app you were using, then injects the link via `hs.eventtap.keyStrokes()`

## Install

```bash
brew install --cask hammerspoon
./install.sh
```

The install script:
1. Installs/checks Hammerspoon via Homebrew
2. Copies `hammerspoon/giphy.lua` into `~/.hammerspoon/`
3. Adds the module to `~/.hammerspoon/init.lua` if not already there
4. Prompts for your Giphy API key and stores it in the macOS Keychain

## Configuration

You need a free Giphy API key. Get one at [developers.giphy.com/dashboard](https://developers.giphy.com/dashboard/):

1. Sign up or log in
2. Create an app
3. Copy the API key from your app dashboard

`install.sh` prompts for it and stores it in the macOS Keychain (service
`giphy-hammerspoon`, account = your username) — nothing is written to disk in
plain text. Re-run `./install.sh` any time to replace a stored key.

## Usage

Press **⌘⇧G** and type your search. The carousel appears in ~200ms (network
time). Browse with arrow keys or buttons, then:
- **Poster** (or Enter) → inserts the link into your current app
- **Suivant** (or →) → next result
- **Précédent** (or ←) → previous result
- **Annuler** (or Esc) → close without inserting

## Permissions

Hammerspoon needs **Accessibility** permission to inject keystrokes into other
apps: System Settings > Privacy & Security > Accessibility, then enable
Hammerspoon.

## Requirements

- macOS 10.15+ (Mojave or newer)
- Hammerspoon 0.9.99+
- Giphy free API key (no quota for personal use)
