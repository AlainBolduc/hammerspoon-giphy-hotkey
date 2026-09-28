# AGENTS.md

Context for AI agents (Antigravity, Claude, etc.) working on this repo.

## What this is

A macOS global hotkey (⌘⇧G) that searches Giphy, shows an animated preview
carousel, and types the chosen link at the cursor. Pure Lua/Hammerspoon, no
other runtime dependency.

## Architecture

- **Trigger**: [hammerspoon/giphy.lua:294](hammerspoon/giphy.lua:294) —
  `hs.hotkey.bind({ "cmd", "shift" }, "g", M.trigger)`
- **Flow**: `M.trigger()` → `hs.dialog.textPrompt()` for the query →
  `searchGifs()` (async `hs.http.asyncGet` to Giphy API) → `showPreview()`
  (native `hs.webview` / WKWebView carousel with HTML/CSS/JS) → on "Poster",
  reactivate the previously-frontmost app, then `hs.eventtap.keyStrokes()`
  injects the link.
- **Loading**: `~/.hammerspoon/init.lua` does `require("giphy")`, which
  Lua resolves to `~/.hammerspoon/giphy.lua` (copied there by `install.sh`
  from `hammerspoon/giphy.lua` in this repo — editing the repo file has no
  effect until you re-run `install.sh` or manually re-copy + `hs.reload()`).
- **API key**: macOS Keychain, service `giphy-hammerspoon`, account =
  `$USER`. Read via `security find-generic-password` shelled out from Lua.
  No env var override exists (removed when Python fallback was dropped).

## Why it looks the way it does (history matters here)

This started as an Espanso (text-expander) + Python/Tk daemon architecture.
Both were replaced. Don't reintroduce either without re-reading this section.

1. **Espanso couldn't reliably inject into Slack.** Slack's Electron
   composer would wipe injected text right after insertion (text appears,
   then vanishes, and for shell-var expansions it happened 100% of the time
   in Slack specifically — confirmed via Espanso's own bundled `:shell`
   demo match, which has zero custom code and still failed the same way).
   `hs.eventtap.keyStrokes()` uses a different injection path and does not
   have this problem.

2. **Tk (via a persistent Python daemon) was dropped for latency +
   complexity.** Tk() init cost ~700ms-2s per invocation; a daemon was built
   to pay that cost once. `hs.webview` (WKWebView) is a system component —
   no interpreter/toolkit init, so the daemon workaround became unnecessary
   entirely, not just faster.

3. **Focus restoration is mandatory, not optional.** Any preview window
   (Tk or webview) steals keyboard focus from the app you were typing in.
   macOS does **not** automatically restore it once that window closes —
   your own app (Hammerspoon) stays frontmost. Skipping this causes a
   system beep and no text injected. Fix: capture
   `hs.application.frontmostApplication()` **before** opening the search
   dialog (not after — by the time the dialog returns, Hammerspoon itself
   is frontmost), then call `:activate()` on it before `keyStrokes()`, with
   a short `hs.timer.doAfter(0.15, ...)` delay before injecting.

4. **`hs.webview:title()` is not a setter** — it throws "incorrect number
   of arguments" if called with an argument. Use `:windowTitle()` instead.

## Development / debugging

- Edit `hammerspoon/giphy.lua`, then copy to `~/.hammerspoon/giphy.lua` and
  reload: `cp hammerspoon/giphy.lua ~/.hammerspoon/giphy.lua && hs -c "hs.reload()"`
- `hs -c "<lua>"` runs Lua directly against the live Hammerspoon instance —
  requires `require("hs.ipc")` in `init.lua` (already there) and, once per
  machine, `hs -c "hs.ipc.cliInstall()"`.
- **`hs -c` does not print async callback output** (`hs.http.asyncGet`,
  webview callbacks) — the CLI call returns before those fire. Either write
  results to a file from inside the callback, or check the Hammerspoon
  Console (menu bar icon → Console) / `~/.giphy-hammerspoon.log`.
- Lua runtime errors inside async callbacks (HTTP responses, webview
  bridge messages) do not raise in your `hs -c` shell — they only show in
  the Hammerspoon Console as `ERROR: LuaSkin: ...`. Check there first when
  something silently does nothing.
- App log: `~/.giphy-hammerspoon.log` (written by the `log()` helper in
  `giphy.lua`).

## Distribution

- `install.sh` is idempotent: safe to re-run to update the key or the
  Lua module.
- Keep the repo free of machine-specific paths/usernames — it's meant to be
  cloned by other people. Check with
  `grep -rn "/Users/\|$(whoami)" --include="*.lua" --include="*.sh" .`
  before committing.
