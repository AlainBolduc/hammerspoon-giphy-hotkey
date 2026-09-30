# giphy

Press **⌘⇧G** anywhere on macOS (Slack, Teams, iMessage, email…) to search Giphy,
preview animated results in a native carousel, and insert or copy the short link you pick.

No automatic NSFW filtering: the animated preview is the filter, left to you
before you click "Poster" or "Copier".

## How it works

[Hammerspoon](https://www.hammerspoon.org/) binds **⌘⇧G** globally (customizable in settings). When pressed:
- Opens the native 2026 WKWebView window immediately with cursor focused in the search bar (no default images loaded)
- **Deux modes d'affichage au choix** :
  - **Mode Galerie (⊞ / ⌘1)** : grille de 5 colonnes de large sur 3 rangées visibles, avec défilement continu. Au survol de chaque vignette, deux boutons d'action rapide apparaissent :
    - 🟢 **Copier** (vert) : copie le lien court et ferme la fenêtre
    - 🟣 **Poster** (mauve) : injecte le lien court directement dans votre application active et ferme la fenêtre
    - Double-clic (ou Espace) sur une vignette : ouvre le GIF en plein format dans le mode Carrousel
  - **Mode Carrousel (🗂 / ⌘2)** : affichage grand format d'un GIF à la fois avec navigation pas-à-pas
- **Scroll infini (Infinite Scroll)** : en mode Galerie (ou à la fin du carrousel), dès que vous atteignez le bas de la liste, 25 nouveaux GIFs sont automatiquement chargés et ajoutés sans doublon
- **Bascule rapide de mode** : boutons dédiés dans l'en-tête, ou raccourcis **⌘1** (Galerie), **⌘2** (Carrousel), **⌘M** (bascule)
- **Enter in search bar**: launches search on first press; advances to the **Next GIF** on subsequent presses if text hasn't changed. Modifying the text and pressing Enter starts a new search!
- **⌘← / ⌘→** (ou flèches clavier) : naviguer dans les GIFs trouvés (déplacement 5x3 dans la grille en mode Galerie)
- **⌘R**: re-fetches a fresh randomized batch of results
- **⌘C** (or click image / "Copier"): copies the short link (`http://gph.is/...`) to clipboard and closes window
- **Shift + Enter** (or Cmd + Enter): inserts the short link (`http://gph.is/...`) at the cursor into your active app (**Poster**)
- **⚙️ (or ⌘,)**: opens the Settings panel to toggle console logging, update your Giphy API key, choose your default view mode, or customize the global shortcut
- **Esc**: closes the settings panel (if open), clears search text, or cancels/closes the window

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

You can enter or update your API key in two ways:
- **Directly in the app UI**: Click the ⚙️ gear icon (or press **⌘,**) to open the settings panel and enter your key. It will be securely stored in the macOS Keychain.
- **Via install script**: `install.sh` stores it in the macOS Keychain (service `giphy-hammerspoon`, account = your username).

### Settings Panel (⚙️ or ⌘,)
- **Mode d'affichage par défaut** : Définissez si l'application s'ouvre par défaut en mode Galerie (grille) ou Carrousel (1 GIF).
- **Hammerspoon Console Logging**: Toggle high-precision debug & performance timing logs in the Hammerspoon Console (also written with millisecond timestamps to `~/.giphy-hammerspoon.log`).
  - **Window Startup**: Keychain lookup time, WKWebView creation time, and time until window is interactive and ready for input (`~60-200ms`).
  - **Giphy API**: HTTP request duration, payload size in KB, JSON parsing time, and Webview injection time.
  - **Image Rendering**: GIF preview load time, dimensions, and cache hit status.
  - **Action Execution**: Keystroke injection timing into the active application and total session duration.
- **Giphy API Key**: Update your API key with a visibility toggle; saved securely into macOS Keychain.
- **Global Keyboard Shortcut**: Customize using clickable modifier chips (⌘, ⇧, ⌥, ⌃), a key dropdown, or click "Enregistrer en tapant..." to record any shortcut directly (e.g., `⌘⇧G`, `⌘⌥Space`, `⌃Space`). Applied instantly without restarting Hammerspoon.

## Usage

Press **⌘⇧G** (or your custom shortcut) to pop the Giphy window directly:
- **Enter** → 1ère fois : lance la recherche. Fois suivantes : fait défiler (**Next**). Si vous modifiez le texte : relance une nouvelle recherche !
- **⌘1 / ⌘2 / ⌘M** → basculer entre vue Galerie (5 colonnes) et vue Carrousel (1 GIF)
- **Survol vignette (Galerie)** → boutons rapides 🟢 **Copier** et 🟣 **Poster**
- **Défilement bas de page** → chargement infini automatique (+25 GIFs par page)
- **⌘← / ⌘→** (ou flèches clavier) → naviguer dans les GIFs trouvés
- **⇧↵** (Shift + Enter) → insère le lien court dans votre application (**Poster**)
- **⌘C** (ou clic sur le GIF / bouton « Copier ») → copie l'URL courte et ferme la fenêtre
- **⌘R** → tire de nouveaux GIFs aléatoires
- **⚙️** (ou **⌘,**) → ouvre la fenêtre de configuration
- **Esc** → ferme les paramètres ou efface le texte / ferme la fenêtre

## Permissions

Hammerspoon needs **Accessibility** permission to inject keystrokes into other
apps: System Settings > Privacy & Security > Accessibility, then enable
Hammerspoon.

## Requirements

- macOS 10.15+ (Mojave or newer)
- Hammerspoon 0.9.99+
- Giphy free API key (no quota for personal use)
