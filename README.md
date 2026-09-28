# giphy

Press **⌘⇧G** anywhere on macOS (Slack, Teams, iMessage, email…) to search Giphy,
preview animated results in a native carousel, and insert or copy the short link you pick.

No automatic NSFW filtering: the animated preview is the filter, left to you
before you click "Poster" or "Copier".

## How it works

[Hammerspoon](https://www.hammerspoon.org/) binds **⌘⇧G** globally. When pressed:
- Opens the native 2026 WKWebView window immediately with cursor focused in the search bar (no default images loaded)
- **Enter in search bar**: launches search on first press; advances to the **Next GIF** on subsequent presses if text hasn't changed. Modifying the text and pressing Enter starts a new search!
- **⌘← / ⌘→** (or arrow keys): navigate back and forth continuously through all 25 GIFs
- **⌘R**: re-fetches a fresh randomized batch of 25 results
- **⌘C** (or click image / "Copier"): copies the short link (`http://gph.is/...`) to clipboard and closes window
- **Shift + Enter** (or Cmd + Enter): inserts the short link (`http://gph.is/...`) at the cursor into your active app (**Poster**)
- **Esc**: clears search text or cancels/closes window

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

Press **⌘⇧G** to pop the Giphy window directly:
- **Enter** → 1ère fois : lance la recherche. Fois suivantes : fait défiler (**Next**). Si vous modifiez le texte : relance une nouvelle recherche !
- **⌘←** (ou bouton Précédent) → reculer dans les GIFs trouvés
- **⇧↵** (Shift + Enter) → insère le lien court dans votre application (**Poster**)
- **⌘C** (ou clic sur le GIF / bouton « Copier ») → copie l'URL courte et ferme la fenêtre
- **⌘R** → tire 25 nouveaux GIFs aléatoires
- **Esc** → efface le texte ou ferme la fenêtre

## Permissions

Hammerspoon needs **Accessibility** permission to inject keystrokes into other
apps: System Settings > Privacy & Security > Accessibility, then enable
Hammerspoon.

## Requirements

- macOS 10.15+ (Mojave or newer)
- Hammerspoon 0.9.99+
- Giphy free API key (no quota for personal use)
