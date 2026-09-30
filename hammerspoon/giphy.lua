-- Giphy trigger, pure Lua/Hammerspoon: Cmd+Shift+G pops a native 2026 WKWebView
-- search & carousel window, with search on Enter, animated previews, and instant copy/post.

local M = {}

math.randomseed(os.time())

local LOG_PATH = os.getenv("HOME") .. "/.giphy-hammerspoon.log"
local KEYCHAIN_SERVICE = "giphy-hammerspoon"
local KEYCHAIN_ACCOUNT = os.getenv("USER")
local RESULT_LIMIT = 25
local POOL_SIZE = 50
local MAX_RANDOM_OFFSET = 35
local WINDOW_SIZE = { w = 740, h = 580 }

local SETTINGS_KEY_CONSOLE_LOG = "giphy.consoleLogging"
local SETTINGS_KEY_HOTKEY = "giphy.hotkey"
local SETTINGS_KEY_DEFAULT_VIEW = "giphy.defaultView"
local DEFAULT_HOTKEY = { mods = { "cmd", "shift" }, key = "g" }

local cachedApiKey = nil
local currentSessionStart = nil

local function isConsoleLogging()
    return hs.settings.get(SETTINGS_KEY_CONSOLE_LOG) == true
end

local function getDefaultViewMode()
    local saved = hs.settings.get(SETTINGS_KEY_DEFAULT_VIEW)
    if saved == "carousel" or saved == "gallery" then
        return saved
    end
    return "gallery"
end

local function getTimestamp()
    local now = hs.timer.secondsSinceEpoch()
    local sec = math.floor(now)
    local ms = math.floor((now - sec) * 1000)
    return os.date("%H:%M:%S", sec) .. string.format(".%03d", ms)
end

local function formatDuration(ms)
    if not ms then return "0.0 ms" end
    if ms < 1.0 then
        return string.format("%.2f ms", ms)
    elseif ms < 1000.0 then
        return string.format("%.1f ms", ms)
    else
        return string.format("%.2f s", ms / 1000.0)
    end
end

local function formatBytes(bytes)
    if not bytes or bytes <= 0 then return "0 B" end
    if bytes < 1024 then
        return bytes .. " B"
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024.0)
    else
        return string.format("%.2f MB", bytes / (1024.0 * 1024.0))
    end
end

local function log(msg)
    local timestamp = getTimestamp()
    local fileLine = os.date("%Y-%m-%d ") .. timestamp .. " " .. msg
    local f = io.open(LOG_PATH, "a")
    if f then
        f:write(fileLine .. "\n")
        f:close()
    end
    if isConsoleLogging() then
        print(string.format("[Giphy] [%s] %s", timestamp, msg))
    end
end

local function logTiming(label, durationMs, details)
    local extra = (details and details ~= "") and (" (" .. details .. ")") or ""
    log(string.format("[TIMING] %-32s : %8s%s", label, formatDuration(durationMs), extra))
end

local function getApiKey(forceReload)
    if cachedApiKey and not forceReload then
        return cachedApiKey, 0, true
    end

    local tStart = hs.timer.absoluteTime()
    local cmd = string.format(
        "security find-generic-password -a '%s' -s '%s' -w 2>/dev/null",
        KEYCHAIN_ACCOUNT, KEYCHAIN_SERVICE
    )
    local out, ok = hs.execute(cmd)
    local durationMs = (hs.timer.absoluteTime() - tStart) / 1000000.0
    if not ok then
        return nil, durationMs, false
    end
    local key = out:gsub("%s+$", "")
    if key ~= "" then
        cachedApiKey = key
        return key, durationMs, false
    end
    return nil, durationMs, false
end

local function setApiKey(newKey)
    local tStart = hs.timer.absoluteTime()
    local safeKey = newKey:gsub("'", "'\\''")
    local cmd = string.format(
        "security add-generic-password -a '%s' -s '%s' -w '%s' -U",
        KEYCHAIN_ACCOUNT, KEYCHAIN_SERVICE, safeKey
    )
    local out, ok = hs.execute(cmd)
    local durationMs = (hs.timer.absoluteTime() - tStart) / 1000000.0
    if ok then
        cachedApiKey = newKey
    end
    return ok, durationMs
end

local currentHotkeyBinding = nil

local function getHotkeyConfig()
    local saved = hs.settings.get(SETTINGS_KEY_HOTKEY)
    if saved and type(saved) == "table" and saved.mods and saved.key then
        return saved
    end
    return DEFAULT_HOTKEY
end

local symbolMap = { cmd = "⌘", shift = "⇧", alt = "⌥", opt = "⌥", ctrl = "⌃" }
local function formatHotkeyDisplay(hotkey)
    if not hotkey or not hotkey.mods or not hotkey.key then return "⌘⇧G" end
    local order = { "cmd", "shift", "alt", "opt", "ctrl" }
    local parts = {}
    local seen = {}
    for _, modName in ipairs(order) do
        for _, m in ipairs(hotkey.mods) do
            local ml = tostring(m):lower()
            if ml == modName and not seen[modName] then
                table.insert(parts, symbolMap[modName] or modName)
                seen[modName] = true
            end
        end
    end
    for _, m in ipairs(hotkey.mods) do
        local ml = tostring(m):lower()
        if not seen[ml] then
            table.insert(parts, symbolMap[ml] or ml)
            seen[ml] = true
        end
    end
    local k = tostring(hotkey.key):upper()
    if k == "SPACE" then k = "Espace"
    elseif k == "RETURN" then k = "Entrée"
    elseif k == "DELETE" then k = "Effacer"
    elseif k == "LEFT" then k = "←"
    elseif k == "RIGHT" then k = "→"
    elseif k == "UP" then k = "↑"
    elseif k == "DOWN" then k = "↓"
    end
    table.insert(parts, k)
    return table.concat(parts, " ")
end

local function applyHotkey(cfg)
    local tStart = hs.timer.absoluteTime()
    if currentHotkeyBinding then
        currentHotkeyBinding:delete()
        currentHotkeyBinding = nil
    end
    local target = cfg or getHotkeyConfig()
    if target and target.mods and target.key and target.key ~= "" then
        local keyLower = tostring(target.key):lower()
        local ok, bindingOrErr = pcall(function()
            return hs.hotkey.bind(target.mods, keyLower, M.trigger)
        end)
        local bindMs = (hs.timer.absoluteTime() - tStart) / 1000000.0
        if ok and bindingOrErr then
            currentHotkeyBinding = bindingOrErr
            logTiming("Hotkey registered", bindMs, table.concat(target.mods, "+") .. "+" .. keyLower)
            return true
        else
            log("[ERROR] Failed to bind hotkey: " .. tostring(bindingOrErr))
            pcall(function()
                currentHotkeyBinding = hs.hotkey.bind(DEFAULT_HOTKEY.mods, DEFAULT_HOTKEY.key, M.trigger)
            end)
            return false, tostring(bindingOrErr)
        end
    end
    return false, "Missing mods or key"
end

local currentWebview = nil
local currentUCC = nil

local function closePreview()
    if currentHotkeyBinding then
        currentHotkeyBinding:enable()
    end
    if currentWebview then
        currentWebview:delete()
        currentWebview = nil
    end
    if currentUCC then
        currentUCC = nil
    end
end

local function pickPreview(images)
    local keys = { "fixed_height", "downsized", "downsized_medium", "downsized_large", "original" }
    for _, k in ipairs(keys) do
        local img = images[k]
        if img and img.url and img.url ~= "" then
            return img.url
        end
    end
    return nil
end

local function pickLarge(images)
    local keys = { "downsized_large", "downsized_medium", "original", "downsized", "fixed_height" }
    for _, k in ipairs(keys) do
        local img = images[k]
        if img and img.url and img.url ~= "" then
            return img.url
        end
    end
    return nil
end

local currentSearchBaseOffset = 0

local function fetchGifs(query, apiKey, offset, callback)
    if type(offset) == "function" then
        callback = offset
        offset = 0
    end
    offset = tonumber(offset) or 0
    local isInitial = (offset == 0)

    local queryTrimmed = query and query:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if queryTrimmed == "" then
        callback({}, nil)
        return
    end

    local tFetchStart = hs.timer.absoluteTime()
    if isInitial then
        currentSearchBaseOffset = math.random(0, MAX_RANDOM_OFFSET)
    end
    local effectiveOffset = currentSearchBaseOffset + offset
    local poolLimit = RESULT_LIMIT

    local baseUrl = "https://api.giphy.com/v1/gifs/search?api_key=" .. hs.http.encodeForQuery(apiKey)
        .. "&q=" .. hs.http.encodeForQuery(queryTrimmed)
        .. "&limit=" .. poolLimit

    local urlWithOffset = baseUrl .. "&offset=" .. effectiveOffset
    log(string.format("Giphy API request dispatch: offset=%d (base=%d + %d), limit=%d", effectiveOffset, currentSearchBaseOffset, offset, poolLimit))

    local function parseAndCallback(body, httpDurationMs)
        local tParseStart = hs.timer.absoluteTime()
        local ok, decoded = pcall(hs.json.decode, body)
        if not ok or not decoded then
            log(string.format("[ERROR] Giphy JSON decode failed after %s", formatDuration(httpDurationMs)))
            callback(nil, "Réponse Giphy invalide")
            return
        end

        if decoded.meta and decoded.meta.status == 403 then
            log(string.format("[ERROR] Giphy API key rejected (403) after %s", formatDuration(httpDurationMs)))
            callback(nil, "Clé Giphy invalide (403)")
            return
        end

        local data = decoded.data or {}
        local rawCount = #data
        if rawCount == 0 then
            local totalMs = (hs.timer.absoluteTime() - tFetchStart) / 1000000.0
            logTiming("Giphy returned 0 results", totalMs, "query: '" .. queryTrimmed .. "'")
            callback({}, isInitial and ("Aucun résultat pour « " .. queryTrimmed .. " »") or nil)
            return
        end

        local results = {}
        for _, gif in ipairs(data) do
            local images = gif.images or {}
            local preview = pickPreview(images)
            local large = pickLarge(images)
            if preview then
                local short = (gif.bitly_gif_url and gif.bitly_gif_url ~= "" and gif.bitly_gif_url)
                    or (gif.bitly_url and gif.bitly_url ~= "" and gif.bitly_url)
                    or gif.url
                table.insert(results, {
                    previewUrl = preview,
                    largeUrl = large or preview,
                    shortUrl = short,
                    pageUrl = gif.url,
                    title = gif.title or "",
                })
                if #results >= RESULT_LIMIT then
                    break
                end
            end
        end

        local parseDurationMs = (hs.timer.absoluteTime() - tParseStart) / 1000000.0
        local totalFetchMs = (hs.timer.absoluteTime() - tFetchStart) / 1000000.0

        logTiming("Giphy JSON parsed", parseDurationMs, string.format("%d raw -> %d results", rawCount, #results))
        logTiming("Total Giphy API fetch duration", totalFetchMs, string.format("HTTP: %s", formatDuration(httpDurationMs)))

        callback(results, nil)
    end

    local tHttpStart = hs.timer.absoluteTime()
    hs.http.asyncGet(urlWithOffset, nil, function(status, body)
        local httpDurationMs = (hs.timer.absoluteTime() - tHttpStart) / 1000000.0
        local bodyBytes = body and #body or 0
        logTiming("Giphy API HTTP response", httpDurationMs, string.format("status %d, %s", status, formatBytes(bodyBytes)))

        if status == 200 then
            local ok, decoded = pcall(hs.json.decode, body)
            local data = (ok and decoded and decoded.data) or {}
            -- If random offset produced 0 items, fallback to offset 0
            if #data == 0 and isInitial and currentSearchBaseOffset > 0 then
                log(string.format("Base offset %d returned 0 items, retrying with offset 0...", currentSearchBaseOffset))
                currentSearchBaseOffset = 0
                local tRetryStart = hs.timer.absoluteTime()
                hs.http.asyncGet(baseUrl .. "&offset=0", nil, function(status2, body2)
                    local retryHttpDurationMs = (hs.timer.absoluteTime() - tRetryStart) / 1000000.0
                    local retryBytes = body2 and #body2 or 0
                    logTiming("Retry HTTP response (offset 0)", retryHttpDurationMs, string.format("status %d, %s", status2, formatBytes(retryBytes)))
                    if status2 ~= 200 then
                        callback(nil, "Erreur Giphy (HTTP " .. tostring(status2) .. ")")
                        return
                    end
                    parseAndCallback(body2, httpDurationMs + retryHttpDurationMs)
                end)
                return
            end
            parseAndCallback(body, httpDurationMs)
        else
            callback(nil, "Erreur Giphy (HTTP " .. tostring(status) .. ")")
        end
    end)
end

local function buildHtml(initialConfig)
    local configJson = hs.json.encode(initialConfig or {})
    return [[
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  :root {
    --bg-base: #0c0e12;
    --bg-surface: rgba(255, 255, 255, 0.05);
    --bg-surface-hover: rgba(255, 255, 255, 0.09);
    --border-subtle: rgba(255, 255, 255, 0.08);
    --border-highlight: rgba(99, 102, 241, 0.5);
    --text-primary: #f9fafb;
    --text-secondary: #9ca3af;
    --text-muted: #6b7280;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; user-select: none; -webkit-user-select: none; }
  body {
    background: radial-gradient(circle at 50% -10%, rgba(99, 102, 241, 0.22) 0%, rgba(12, 14, 18, 0) 65%), var(--bg-base);
    color: var(--text-primary);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", sans-serif;
    display: flex;
    flex-direction: column;
    height: 100vh;
    overflow: hidden;
  }

  /* Header / Search bar */
  #header {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 16px 8px;
    flex-shrink: 0;
    border-bottom: 1px solid var(--border-subtle);
  }

  .search-box {
    flex: 1;
    display: flex;
    align-items: center;
    gap: 8px;
    background: var(--bg-surface);
    border: 1px solid var(--border-subtle);
    border-radius: 10px;
    padding: 6px 10px;
    transition: all 0.2s ease;
  }
  .search-box:focus-within {
    border-color: var(--border-highlight);
    background: rgba(255, 255, 255, 0.08);
    box-shadow: 0 0 14px rgba(99, 102, 241, 0.25);
  }

  .search-icon {
    color: var(--text-secondary);
    flex-shrink: 0;
    cursor: pointer;
    transition: color 0.15s ease;
  }
  .search-icon:hover {
    color: #818cf8;
  }

  #search-input {
    flex: 1;
    background: transparent;
    border: none;
    outline: none;
    color: var(--text-primary);
    font-family: inherit;
    font-size: 13px;
    font-weight: 500;
  }
  #search-input::placeholder {
    color: var(--text-muted);
  }

  .icon-btn {
    background: transparent;
    border: none;
    outline: none;
    color: var(--text-muted);
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2px;
    border-radius: 4px;
    transition: color 0.15s ease;
  }
  .icon-btn:hover {
    color: var(--text-primary);
  }

  .spinner {
    width: 14px;
    height: 14px;
    border: 2px solid rgba(255, 255, 255, 0.15);
    border-top-color: #818cf8;
    border-radius: 50%;
    animation: spin 0.6s linear infinite;
    flex-shrink: 0;
  }
  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }

  .counter-badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 3px 9px;
    border-radius: 999px;
    background: var(--bg-surface);
    border: 1px solid var(--border-subtle);
    color: var(--text-secondary);
    font-size: 11px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    letter-spacing: 0.3px;
    white-space: nowrap;
    flex-shrink: 0;
  }

  /* View Mode Switcher */
  .view-toggle-group {
    display: inline-flex;
    align-items: center;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    padding: 2px;
    gap: 2px;
    flex-shrink: 0;
  }
  .view-toggle-btn {
    appearance: none;
    -webkit-appearance: none;
    border: none;
    outline: none;
    background: transparent;
    color: var(--text-muted);
    padding: 3px 6px;
    border-radius: 6px;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    transition: all 0.15s ease;
  }
  .view-toggle-btn:hover {
    color: var(--text-primary);
  }
  .view-toggle-btn.active {
    background: linear-gradient(135deg, rgba(99, 102, 241, 0.45) 0%, rgba(79, 70, 229, 0.65) 100%);
    color: #ffffff;
    box-shadow: 0 1px 4px rgba(0, 0, 0, 0.3);
  }

  /* Viewport & View Panels */
  #viewport {
    flex: 1;
    min-height: 0;
    position: relative;
    overflow: hidden;
    display: flex;
  }
  .view-panel {
    width: 100%;
    height: 100%;
    min-height: 0;
    position: relative;
    display: flex;
  }

  /* Mode 1: Carousel */
  #carousel-view {
    flex: 1;
    min-height: 0;
    position: relative;
    overflow: hidden;
    display: flex;
  }
  #track {
    display: none;
    height: 100%;
    width: 100%;
    transition: transform 0.25s cubic-bezier(0.2, 0.8, 0.2, 1);
  }

  .slide {
    flex: 0 0 100%;
    width: 100%;
    height: 100%;
    min-height: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 10px 20px;
    box-sizing: border-box;
    cursor: pointer;
  }
  .card {
    position: relative;
    width: 100%;
    height: 100%;
    max-width: 580px;
    max-height: 440px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 16px;
    background: rgba(0, 0, 0, 0.35);
    border: 1px solid var(--border-subtle);
    box-shadow: 0 14px 40px -6px rgba(0, 0, 0, 0.65);
    overflow: hidden;
    transition: all 0.2s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  .card:hover {
    border-color: rgba(99, 102, 241, 0.45);
    box-shadow: 0 18px 46px -6px rgba(0, 0, 0, 0.8), 0 0 20px rgba(99, 102, 241, 0.15);
    transform: translateY(-1px);
  }
  .card img {
    width: 100%;
    height: 100%;
    max-width: 100%;
    max-height: 100%;
    object-fit: contain;
    display: block;
    border-radius: 14px;
    transition: transform 0.2s ease;
  }
  .card:hover img {
    transform: scale(1.015);
  }

  /* Mode 2: Gallery Grid (5 wide, 3 rows high, scroll for more) */
  #gallery-view {
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    padding: 12px 14px 16px;
    box-sizing: border-box;
    scroll-behavior: smooth;
    -webkit-overflow-scrolling: touch;
    display: flex;
    flex-direction: column;
  }
  #gallery-view::-webkit-scrollbar {
    width: 6px;
  }
  #gallery-view::-webkit-scrollbar-track {
    background: transparent;
  }
  #gallery-view::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.16);
    border-radius: 999px;
  }
  #gallery-view::-webkit-scrollbar-thumb:hover {
    background: rgba(255, 255, 255, 0.3);
  }

  .gallery-grid {
    display: grid;
    grid-template-columns: repeat(5, 1fr);
    gap: 8px;
    width: 100%;
    box-sizing: border-box;
  }

  .gallery-card {
    position: relative;
    border-radius: 9px;
    overflow: hidden;
    background: rgba(0, 0, 0, 0.35);
    border: 1px solid var(--border-subtle);
    aspect-ratio: 4 / 3;
    cursor: pointer;
    transition: transform 0.16s ease, border-color 0.16s ease, box-shadow 0.16s ease;
    display: flex;
    align-items: center;
    justify-content: center;
    box-sizing: border-box;
    user-select: none;
    -webkit-user-select: none;
    outline: none;
  }
  .gallery-card:hover, .gallery-card:focus-visible, .gallery-card.selected {
    transform: translateY(-2px);
    border-color: rgba(99, 102, 241, 0.85);
    box-shadow: 0 6px 18px rgba(0, 0, 0, 0.7), 0 0 0 1px rgba(99, 102, 241, 0.4);
    z-index: 2;
  }
  .gallery-img-wrapper {
    width: 100%;
    height: 100%;
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .gallery-card img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
    transition: transform 0.22s ease;
  }
  .gallery-card:hover img {
    transform: scale(1.05);
  }

  /* Card Hover Overlay & Action Buttons */
  .gallery-card-overlay {
    position: absolute;
    inset: 0;
    background: linear-gradient(to top, rgba(12, 14, 18, 0.94) 0%, rgba(12, 14, 18, 0.45) 55%, transparent 100%);
    display: flex;
    flex-direction: column;
    justify-content: flex-end;
    padding: 5px;
    box-sizing: border-box;
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.16s ease;
  }
  .gallery-card:hover .gallery-card-overlay,
  .gallery-card:focus-visible .gallery-card-overlay,
  .gallery-card.selected .gallery-card-overlay {
    opacity: 1;
    pointer-events: auto;
  }

  .gallery-card-actions {
    display: flex;
    align-items: center;
    gap: 4px;
    width: 100%;
  }

  .gallery-btn {
    flex: 1;
    padding: 4px 5px;
    font-size: 10px;
    font-weight: 600;
    border-radius: 6px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 3px;
    cursor: pointer;
    border: none;
    outline: none;
    color: white;
    transition: all 0.14s ease;
    white-space: nowrap;
    text-shadow: 0 1px 2px rgba(0,0,0,0.5);
  }
  /* Vert / Green - Copier */
  .gallery-btn-copy {
    background: linear-gradient(135deg, #10b981 0%, #059669 100%);
    box-shadow: 0 2px 6px rgba(16, 185, 129, 0.35);
  }
  .gallery-btn-copy:hover {
    background: linear-gradient(135deg, #059669 0%, #047857 100%);
    box-shadow: 0 3px 10px rgba(16, 185, 129, 0.5);
    transform: translateY(-1px);
  }
  /* Mauve / Purple - Poster */
  .gallery-btn-post {
    background: linear-gradient(135deg, #6366f1 0%, #4f46e5 100%);
    box-shadow: 0 2px 6px rgba(99, 102, 241, 0.35);
  }
  .gallery-btn-post:hover {
    background: linear-gradient(135deg, #4f46e5 0%, #4338ca 100%);
    box-shadow: 0 3px 10px rgba(99, 102, 241, 0.5);
    transform: translateY(-1px);
  }

  .gallery-loading-more {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 16px 0 10px;
    color: var(--text-secondary);
    font-size: 11.5px;
    font-weight: 500;
  }
  .spinner-sm {
    width: 12px;
    height: 12px;
    border: 2px solid rgba(255, 255, 255, 0.2);
    border-top-color: #818cf8;
    border-radius: 50%;
    animation: spin 0.6s linear infinite;
    flex-shrink: 0;
  }
  .gallery-end-msg {
    text-align: center;
    padding: 14px 0 8px;
    color: var(--text-muted);
    font-size: 11px;
    font-weight: 500;
  }

  .copy-pill {
    position: absolute;
    bottom: 14px;
    background: rgba(12, 14, 18, 0.88);
    backdrop-filter: blur(16px);
    -webkit-backdrop-filter: blur(16px);
    color: #f3f4f6;
    font-size: 11.5px;
    font-weight: 500;
    padding: 6px 14px;
    border-radius: 999px;
    border: 1px solid rgba(255, 255, 255, 0.16);
    box-shadow: 0 8px 20px rgba(0, 0, 0, 0.5);
    opacity: 0;
    transform: translateY(8px);
    transition: all 0.2s cubic-bezier(0.2, 0.8, 0.2, 1);
    pointer-events: none;
    display: flex;
    align-items: center;
    gap: 7px;
  }
  .card:hover .copy-pill {
    opacity: 1;
    transform: translateY(0);
  }

  .copied-flash {
    position: absolute;
    inset: 0;
    background: rgba(16, 185, 129, 0.25);
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    display: flex;
    align-items: center;
    justify-content: center;
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.12s ease;
    border-radius: 14px;
  }
  .copied-flash.active {
    opacity: 1;
  }
  .copied-flash-box {
    background: rgba(16, 185, 129, 0.95);
    color: white;
    padding: 10px 22px;
    border-radius: 12px;
    font-weight: 600;
    font-size: 13px;
    box-shadow: 0 10px 25px rgba(0, 0, 0, 0.4);
    display: flex;
    align-items: center;
    gap: 8px;
    transform: scale(0.9);
    transition: transform 0.15s cubic-bezier(0.34, 1.56, 0.64, 1);
  }
  .copied-flash.active .copied-flash-box {
    transform: scale(1);
  }

  /* Welcome & Empty states */
  .state-container {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    padding: 24px;
    text-align: center;
  }
  .state-icon {
    color: #818cf8;
    opacity: 0.8;
  }
  .state-title {
    font-size: 15px;
    font-weight: 600;
    color: var(--text-primary);
  }
  .state-sub {
    font-size: 12.5px;
    color: var(--text-secondary);
    line-height: 1.5;
  }
  .shortcuts-legend {
    display: flex;
    gap: 12px;
    margin-top: 14px;
    padding: 8px 14px;
    background: var(--bg-surface);
    border: 1px solid var(--border-subtle);
    border-radius: 10px;
    font-size: 11px;
    color: var(--text-secondary);
  }
  .shortcuts-legend span {
    display: flex;
    align-items: center;
    gap: 5px;
  }

  /* Controls Footer */
  #controls {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 10px 14px 14px;
    background: rgba(12, 14, 18, 0.75);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    border-top: 1px solid var(--border-subtle);
    flex-shrink: 0;
    box-sizing: border-box;
    width: 100%;
  }
  .nav-group {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
  }
  .action-group {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }
  button {
    appearance: none;
    -webkit-appearance: none;
    border: none;
    outline: none;
    font-family: inherit;
    font-size: 12px;
    font-weight: 500;
    padding: 7px 11px;
    border-radius: 9px;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    gap: 5px;
    white-space: nowrap;
    transition: all 0.15s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  .icon-nav-btn {
    padding: 7px 10px;
  }
  .btn-ghost {
    background: var(--bg-surface);
    color: var(--text-secondary);
    border: 1px solid var(--border-subtle);
  }
  .btn-ghost:hover:not(:disabled) {
    background: var(--bg-surface-hover);
    color: var(--text-primary);
    border-color: rgba(255, 255, 255, 0.16);
  }
  .btn-ghost:disabled {
    opacity: 0.25;
    cursor: default;
  }
  .btn-copy {
    background: linear-gradient(135deg, #10b981 0%, #059669 100%);
    color: white;
    font-weight: 600;
    box-shadow: 0 2px 10px rgba(16, 185, 129, 0.25);
  }
  .btn-copy:hover:not(:disabled) {
    background: linear-gradient(135deg, #059669 0%, #047857 100%);
    box-shadow: 0 4px 16px rgba(16, 185, 129, 0.4);
    transform: translateY(-1px);
  }
  .btn-copy:disabled {
    opacity: 0.25;
    cursor: default;
    box-shadow: none;
  }
  .btn-post {
    background: linear-gradient(135deg, #6366f1 0%, #4f46e5 100%);
    color: white;
    font-weight: 600;
    box-shadow: 0 2px 10px rgba(99, 102, 241, 0.3);
  }
  .btn-post:hover:not(:disabled) {
    background: linear-gradient(135deg, #4f46e5 0%, #4338ca 100%);
    box-shadow: 0 4px 16px rgba(99, 102, 241, 0.45);
    transform: translateY(-1px);
  }
  .btn-post:disabled {
    opacity: 0.25;
    cursor: default;
    box-shadow: none;
  }
  .kbd {
    background: rgba(255, 255, 255, 0.12);
    border: 1px solid rgba(255, 255, 255, 0.15);
    color: rgba(255, 255, 255, 0.85);
    font-size: 10px;
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-weight: 600;
    padding: 1px 5px;
    border-radius: 4px;
    line-height: 1.2;
  }

  /* Gear Button */
  .gear-btn {
    color: var(--text-muted);
    transition: color 0.15s ease, transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1);
  }
  .gear-btn:hover {
    color: var(--text-primary);
    transform: rotate(45deg);
  }

  /* Settings Overlay Panel */
  #settings-panel {
    position: absolute;
    inset: 0;
    z-index: 100;
    background: radial-gradient(circle at 50% 0%, rgba(99, 102, 241, 0.16) 0%, rgba(12, 14, 18, 0.98) 70%);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    display: flex;
    flex-direction: column;
    animation: fadeIn 0.16s ease-out;
  }
  @keyframes fadeIn {
    from { opacity: 0; transform: scale(0.98); }
    to { opacity: 1; transform: scale(1); }
  }
  .settings-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 13px 18px 11px;
    border-bottom: 1px solid var(--border-subtle);
    flex-shrink: 0;
  }
  .settings-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.2px;
  }
  .settings-content {
    flex: 1;
    overflow-y: auto;
    padding: 16px 18px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .setting-card {
    background: var(--bg-surface);
    border: 1px solid var(--border-subtle);
    border-radius: 12px;
    padding: 12px 14px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }
  .setting-card.vertical {
    flex-direction: column;
    align-items: stretch;
    gap: 8px;
  }
  .setting-info {
    display: flex;
    flex-direction: column;
    gap: 3px;
  }
  .setting-label {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
  }
  .setting-desc {
    font-size: 11px;
    color: var(--text-muted);
    line-height: 1.35;
  }
  .setting-desc code {
    background: rgba(255, 255, 255, 0.08);
    padding: 1px 4px;
    border-radius: 4px;
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 10px;
  }
  .setting-error {
    font-size: 11px;
    color: #f87171;
    font-weight: 500;
  }

  /* Toggle Switch */
  .toggle-switch {
    position: relative;
    display: inline-block;
    width: 40px;
    height: 22px;
    flex-shrink: 0;
  }
  .toggle-switch input {
    opacity: 0;
    width: 0;
    height: 0;
  }
  .toggle-slider {
    position: absolute;
    cursor: pointer;
    inset: 0;
    background-color: rgba(255, 255, 255, 0.15);
    transition: all 0.22s cubic-bezier(0.2, 0.8, 0.2, 1);
    border-radius: 22px;
    border: 1px solid var(--border-subtle);
  }
  .toggle-slider:before {
    position: absolute;
    content: "";
    height: 16px;
    width: 16px;
    left: 2px;
    bottom: 2px;
    background-color: #f9fafb;
    transition: all 0.22s cubic-bezier(0.2, 0.8, 0.2, 1);
    border-radius: 50%;
    box-shadow: 0 2px 4px rgba(0, 0, 0, 0.35);
  }
  input:checked + .toggle-slider {
    background: linear-gradient(135deg, #6366f1 0%, #4f46e5 100%);
    border-color: #818cf8;
  }
  input:checked + .toggle-slider:before {
    transform: translateX(18px);
  }

  /* API Key Input */
  .api-key-box {
    display: flex;
    align-items: center;
    gap: 6px;
    background: rgba(0, 0, 0, 0.25);
    border: 1px solid var(--border-subtle);
    border-radius: 9px;
    padding: 6px 10px;
    transition: all 0.2s ease;
  }
  .api-key-box:focus-within {
    border-color: var(--border-highlight);
    background: rgba(255, 255, 255, 0.06);
    box-shadow: 0 0 12px rgba(99, 102, 241, 0.25);
  }
  .api-key-box input {
    flex: 1;
    background: transparent;
    border: none;
    outline: none;
    color: var(--text-primary);
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 12px;
  }
  .api-key-box input::placeholder {
    color: var(--text-muted);
  }

  /* Hotkey Modifier Chips & Selector */
  .hotkey-modifiers-row {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
    margin-top: 2px;
  }
  .mod-chip {
    flex: 1;
    min-width: 68px;
    padding: 6px 8px;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    color: var(--text-secondary);
    font-size: 11px;
    font-weight: 600;
    cursor: pointer;
    text-align: center;
    transition: all 0.18s ease;
    user-select: none;
    outline: none;
  }
  .mod-chip:hover {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text-primary);
    border-color: rgba(255, 255, 255, 0.2);
  }
  .mod-chip.active {
    background: linear-gradient(135deg, rgba(99, 102, 241, 0.35) 0%, rgba(79, 70, 229, 0.5) 100%);
    border-color: #818cf8;
    color: #ffffff;
    box-shadow: 0 0 10px rgba(99, 102, 241, 0.3);
  }

  .hotkey-controls-row {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-top: 4px;
  }
  .key-select-wrapper {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
  }
  .field-mini-label {
    font-size: 11px;
    color: var(--text-muted);
    font-weight: 500;
  }
  .hotkey-select {
    background: rgba(0, 0, 0, 0.35);
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    color: var(--text-primary);
    font-size: 12px;
    font-weight: 600;
    padding: 6px 10px;
    outline: none;
    cursor: pointer;
    transition: all 0.18s ease;
  }
  .hotkey-select:focus {
    border-color: var(--border-highlight);
    background: rgba(255, 255, 255, 0.08);
  }
  .hotkey-select option {
    background: #181a20;
    color: #f9fafb;
  }

  .hotkey-recorder-btn {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    min-height: 32px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px dashed var(--border-subtle);
    border-radius: 8px;
    padding: 6px 10px;
    color: var(--text-secondary);
    font-size: 11px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.2s ease;
    user-select: none;
    outline: none;
  }
  .hotkey-recorder-btn:hover {
    border-color: rgba(255, 255, 255, 0.3);
    background: rgba(255, 255, 255, 0.09);
    color: var(--text-primary);
  }
  .hotkey-recorder-btn.recording {
    border: 1px solid #ef4444;
    background: rgba(239, 68, 68, 0.14);
    color: #fca5a5;
    box-shadow: 0 0 12px rgba(239, 68, 68, 0.3);
    animation: pulseRecording 1.1s infinite;
  }
  @keyframes pulseRecording {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.55; }
  }

  .hotkey-preview-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: rgba(0, 0, 0, 0.2);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: 8px;
    padding: 6px 10px;
    margin-top: 4px;
  }
  .preview-label {
    font-size: 11px;
    color: var(--text-muted);
  }
  .hotkey-display {
    display: flex;
    align-items: center;
    gap: 4px;
  }
  .hotkey-badge {
    background: rgba(255, 255, 255, 0.14);
    border: 1px solid rgba(255, 255, 255, 0.18);
    color: var(--text-primary);
    font-size: 11px;
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-weight: 600;
    padding: 2px 7px;
    border-radius: 5px;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.25);
  }

  /* Settings Footer */
  .settings-footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    padding: 10px 18px 14px;
    border-top: 1px solid var(--border-subtle);
    background: rgba(12, 14, 18, 0.85);
    backdrop-filter: blur(12px);
    flex-shrink: 0;
  }
  .btn-save {
    background: linear-gradient(135deg, #6366f1 0%, #4f46e5 100%);
    color: white;
    font-weight: 600;
    box-shadow: 0 2px 10px rgba(99, 102, 241, 0.3);
  }
  .btn-save:hover:not(:disabled) {
    background: linear-gradient(135deg, #4f46e5 0%, #4338ca 100%);
    box-shadow: 0 4px 16px rgba(99, 102, 241, 0.45);
    transform: translateY(-1px);
  }
  .btn-sm {
    padding: 6px 10px;
    font-size: 11px;
  }
</style>
</head>
<body>
  <header id="header">
    <div class="search-box">
      <svg id="loupe-icon" class="search-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" title="Rechercher (Entrée)"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg>
      <input type="text" id="search-input" placeholder="Rechercher sur Giphy..." autocomplete="off" spellcheck="false">
      <button id="clear-btn" class="icon-btn" style="display: none;" title="Effacer">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
      </button>
      <span class="kbd" style="font-size: 9px; padding: 1px 4px; opacity: 0.5;" title="Appuyer sur Entrée pour chercher">↵</span>
      <div id="spinner" class="spinner" style="display: none;"></div>
    </div>
    <div class="header-right">
      <div class="view-toggle-group">
        <button id="view-btn-gallery" class="view-toggle-btn active" title="Vue Galerie (⌘1)" type="button">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7"></rect><rect x="14" y="3" width="7" height="7"></rect><rect x="14" y="14" width="7" height="7"></rect><rect x="3" y="14" width="7" height="7"></rect></svg>
        </button>
        <button id="view-btn-carousel" class="view-toggle-btn" title="Vue Carrousel (⌘2)" type="button">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="14" rx="2" ry="2"></rect><line x1="8" y1="21" x2="16" y2="21"></line><line x1="12" y1="17" x2="12" y2="21"></line></svg>
        </button>
      </div>
      <div class="counter-badge" id="counter" style="display: none;">0 / 0</div>
      <button id="gear-btn" class="icon-btn gear-btn" title="Paramètres (⌘,)" aria-label="Paramètres">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"></path></svg>
      </button>
    </div>
  </header>
  <main id="viewport">
    <!-- Mode 1: Carrousel (1 GIF à la fois) -->
    <div id="carousel-view" style="display: none;">
      <div id="track"></div>
    </div>

    <!-- Mode 2: Galerie (5 colonnes x 3 rangées visibles, scroll) -->
    <div id="gallery-view">
      <div id="gallery-grid" class="gallery-grid"></div>
      <div id="gallery-loading-more" class="gallery-loading-more" style="display: none;">
        <div class="spinner-sm"></div>
        <span>Chargement de plus de GIFs...</span>
      </div>
      <div id="gallery-end-msg" class="gallery-end-msg" style="display: none;">
        <span>Fin des résultats</span>
      </div>
    </div>

    <!-- Welcome state (initial start with no image) -->
    <div id="welcome-state" class="state-container">
      <svg class="state-icon" width="42" height="42" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
        <circle cx="11" cy="11" r="8"></circle>
        <line x1="21" y1="21" x2="16.65" y2="16.65"></line>
      </svg>
      <div class="state-title">Rechercher un GIF</div>
      <div class="state-sub">Tapez votre recherche et appuyez sur <span class="kbd">↵</span></div>
      <div class="shortcuts-legend">
        <span><span class="kbd">↵</span> Chercher / Suivant</span>
        <span><span class="kbd">⌘1 / ⌘2</span> Galerie / Carrousel</span>
        <span><span class="kbd">⌘C</span> Copier</span>
        <span><span class="kbd">⇧↵</span> Poster</span>
        <span><span class="kbd">⌘R</span> Mélanger</span>
      </div>
    </div>

    <!-- Empty error state -->
    <div id="empty-state" class="state-container" style="display: none;">
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
      <span id="empty-msg" class="state-title">Aucun résultat</span>
    </div>
  </main>
  <footer id="controls">
    <div class="nav-group">
      <button id="prev" class="btn-ghost icon-nav-btn" disabled title="Précédent (⌘←)">
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="19" y1="12" x2="5" y2="12"></line><polyline points="12 19 5 12 12 5"></polyline></svg>
      </button>
      <button id="next" class="btn-ghost icon-nav-btn" disabled title="Suivant (⌘→)">
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="5" y1="12" x2="19" y2="12"></line><polyline points="12 5 19 12 12 19"></polyline></svg>
      </button>
      <button id="cancel" class="btn-ghost" title="Annuler (Esc)">
        <span>Annuler</span>
      </button>
    </div>
    <div class="action-group">
      <button id="copy" class="btn-copy" disabled title="Copier le lien court (⌘C / Clic)">
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
        <span>Copier</span>
        <span class="kbd">⌘C</span>
      </button>
      <button id="post" class="btn-post" disabled title="Poster le lien court (⇧↵)">
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"></line><polygon points="22 2 15 22 11 13 2 9 22 2"></polygon></svg>
        <span>Poster</span>
        <span class="kbd">⇧↵</span>
      </button>
    </div>
  </footer>

  <!-- Settings View Overlay -->
  <div id="settings-panel" style="display: none;">
    <div class="settings-header">
      <div class="settings-title">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"></path></svg>
        <span>Configuration</span>
      </div>
      <button id="close-settings-btn" class="icon-btn" title="Fermer (Esc)" aria-label="Fermer">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
      </button>
    </div>

    <div class="settings-content">
      <!-- Setting 0: Default view mode -->
      <div class="setting-card">
        <div class="setting-info">
          <label for="cfg-defaultview" class="setting-label">Mode d'affichage par défaut</label>
          <div class="setting-desc">Vue par défaut à l'ouverture (Galerie ou Carrousel)</div>
        </div>
        <select id="cfg-defaultview" class="hotkey-select" style="min-width: 125px;">
          <option value="gallery">Galerie (grille)</option>
          <option value="carousel">Carrousel (1 GIF)</option>
        </select>
      </div>

      <!-- Setting 1: Console logging -->
      <div class="setting-card">
        <div class="setting-info">
          <label for="cfg-logging" class="setting-label">Logging console</label>
          <div class="setting-desc">Affiche les logs d'activité dans la console Hammerspoon</div>
        </div>
        <label class="toggle-switch">
          <input type="checkbox" id="cfg-logging">
          <span class="toggle-slider"></span>
        </label>
      </div>

      <!-- Setting 2: Giphy API key -->
      <div class="setting-card vertical">
        <div class="setting-info">
          <label for="cfg-apikey" class="setting-label">Clé API Giphy</label>
          <div class="setting-desc">Enregistrée de façon sécurisée dans le Trousseau macOS</div>
        </div>
        <div class="api-key-box">
          <input type="password" id="cfg-apikey" placeholder="Collez votre clé API Giphy..." autocomplete="off" spellcheck="false">
          <button id="toggle-key-visibility" class="icon-btn" type="button" title="Afficher/Masquer la clé">
            <svg id="eye-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"></path><circle cx="12" cy="12" r="3"></circle></svg>
          </button>
        </div>
      </div>

      <!-- Setting 3: Keyboard shortcut -->
      <div class="setting-card vertical">
        <div class="setting-info">
          <span class="setting-label">Raccourci clavier global</span>
          <div class="setting-desc">Sélectionnez les modificateurs et la touche, ou cliquez pour enregistrer en tapant</div>
        </div>

        <!-- Modifiers row -->
        <div class="hotkey-modifiers-row">
          <button type="button" class="mod-chip" data-mod="cmd">⌘ Cmd</button>
          <button type="button" class="mod-chip" data-mod="shift">⇧ Shift</button>
          <button type="button" class="mod-chip" data-mod="alt">⌥ Option</button>
          <button type="button" class="mod-chip" data-mod="ctrl">⌃ Ctrl</button>
        </div>

        <div class="hotkey-controls-row">
          <div class="key-select-wrapper">
            <span class="field-mini-label">Touche :</span>
            <select id="hotkey-key-select" class="hotkey-select"></select>
          </div>
          <div id="hotkey-recorder" class="hotkey-recorder-btn" tabindex="0" role="button" title="Cliquez puis tapez votre raccourci">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"></circle><polyline points="12 6 12 12 16 14"></polyline></svg>
            <span id="recording-status">Enregistrer en tapant...</span>
          </div>
          <button id="reset-hotkey-btn" class="btn-ghost btn-sm" type="button" title="Rétablir le raccourci par défaut (⌘⇧G)">
            Rétablir
          </button>
        </div>

        <div class="hotkey-preview-row">
          <span class="preview-label">Aperçu :</span>
          <div id="hotkey-display" class="hotkey-display"></div>
        </div>

        <div id="hotkey-error" class="setting-error" style="display: none;"></div>
      </div>
    </div>

    <div class="settings-footer">
      <button id="cancel-settings-btn" class="btn-ghost" type="button">Annuler</button>
      <button id="save-settings-btn" class="btn-save" type="button">
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
        <span>Enregistrer</span>
      </button>
    </div>
  </div>
<script>
  const tPageInit = performance.now();
  window.__INITIAL_CONFIG__ = ]] .. configJson .. [[;

  let activeConfig = window.__INITIAL_CONFIG__ || {
    consoleLogging: false,
    apiKey: '',
    hotkey: { mods: ['cmd', 'shift'], key: 'g' },
    defaultView: 'gallery'
  };
  let pendingHotkey = Object.assign({}, activeConfig.hotkey);
  let isRecordingHotkey = false;

  let results = [];
  let index = 0;
  let searchSeq = 0;
  let copying = false;
  let lastSearchedQuery = '';
  let isSearching = false;
  let isLoadingMore = false;
  let hasMore = true;
  let viewMode = (activeConfig.defaultView === 'carousel') ? 'carousel' : 'gallery';
  const reportedImages = new Set();

  function reportImageTiming(idx, loadMs, imgEl, fromCache) {
    if (reportedImages.has(idx)) return;
    reportedImages.add(idx);
    try {
      window.webkit.messageHandlers.giphyBridge.postMessage({
        action: 'imageLoaded',
        index: idx,
        loadMs: loadMs,
        width: imgEl ? imgEl.naturalWidth : 0,
        height: imgEl ? imgEl.naturalHeight : 0,
        fromCache: fromCache === true
      });
    } catch(e) {}
  }

  function reportImageError(idx, url) {
    try {
      window.webkit.messageHandlers.giphyBridge.postMessage({
        action: 'imageError',
        index: idx,
        url: url
      });
    } catch(e) {}
  }

  const input = document.getElementById('search-input');
  const clearBtn = document.getElementById('clear-btn');
  const spinner = document.getElementById('spinner');
  const loupeIcon = document.getElementById('loupe-icon');
  const track = document.getElementById('track');
  const counter = document.getElementById('counter');
  const welcomeState = document.getElementById('welcome-state');
  const emptyState = document.getElementById('empty-state');
  const emptyMsg = document.getElementById('empty-msg');
  const prevBtn = document.getElementById('prev');
  const nextBtn = document.getElementById('next');
  const copyBtn = document.getElementById('copy');
  const postBtn = document.getElementById('post');
  const carouselView = document.getElementById('carousel-view');
  const galleryView = document.getElementById('gallery-view');
  const galleryGrid = document.getElementById('gallery-grid');
  const galleryLoadingMore = document.getElementById('gallery-loading-more');
  const galleryEndMsg = document.getElementById('gallery-end-msg');
  const viewBtnGallery = document.getElementById('view-btn-gallery');
  const viewBtnCarousel = document.getElementById('view-btn-carousel');

  function escapeHtml(str) {
    if (!str) return '';
    return str.replace(/[&<>"']/g, function(m) {
      switch (m) {
        case '&': return '&amp;';
        case '<': return '&lt;';
        case '>': return '&gt;';
        case '"': return '&quot;';
        case "'": return '&#039;';
        default: return m;
      }
    });
  }

  function setViewMode(mode, savePref = true) {
    if (mode !== 'carousel' && mode !== 'gallery') return;
    viewMode = mode;
    if (viewMode === 'gallery') {
      viewBtnGallery.classList.add('active');
      viewBtnCarousel.classList.remove('active');
      if (results.length > 0) {
        carouselView.style.display = 'none';
        galleryView.style.display = 'flex';
        selectCard(index, false);
      }
    } else {
      viewBtnCarousel.classList.add('active');
      viewBtnGallery.classList.remove('active');
      if (results.length > 0) {
        galleryView.style.display = 'none';
        carouselView.style.display = 'flex';
        renderCarousel();
      }
    }
    updateControlsUI();
    if (savePref) {
      try {
        localStorage.setItem('giphy_view_mode', mode);
        window.webkit.messageHandlers.giphyBridge.postMessage({
          action: 'setDefaultView',
          mode: mode
        });
      } catch(e) {}
    }
  }

  viewBtnGallery.addEventListener('click', () => setViewMode('gallery'));
  viewBtnCarousel.addEventListener('click', () => setViewMode('carousel'));

  function createGalleryCard(gif, idx) {
    const card = document.createElement('div');
    card.className = 'gallery-card' + (idx === index ? ' selected' : '');
    card.dataset.index = idx;
    card.tabIndex = -1;

    card.innerHTML = `
      <div class="gallery-img-wrapper">
        <img src="${gif.previewUrl}" alt="${escapeHtml(gif.title || 'GIF')}" loading="lazy">
      </div>
      <div class="gallery-card-overlay">
        <div class="gallery-card-actions">
          <button type="button" class="gallery-btn gallery-btn-copy" title="Copier le lien court (⌘C)">
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
            <span>Copier</span>
          </button>
          <button type="button" class="gallery-btn gallery-btn-post" title="Poster directement (⇧↵)">
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"></line><polygon points="22 2 15 22 11 13 2 9 22 2"></polygon></svg>
            <span>Poster</span>
          </button>
        </div>
      </div>
      <div class="copied-flash">
        <div class="copied-flash-box" style="padding: 6px 12px; font-size: 11px;">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
          <span>Copié !</span>
        </div>
      </div>
    `;

    const copyBtn = card.querySelector('.gallery-btn-copy');
    const postBtn = card.querySelector('.gallery-btn-post');

    copyBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      triggerCopy(idx);
    });

    postBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      triggerPost(idx);
    });

    card.addEventListener('click', (e) => {
      if (e.target.closest('.gallery-btn')) return;
      selectCard(idx);
      triggerCopy(idx);
    });

    card.addEventListener('dblclick', (e) => {
      e.stopPropagation();
      index = idx;
      setViewMode('carousel');
    });

    return card;
  }

  function createCarouselSlide(gif, idx) {
    const slide = document.createElement('div');
    slide.className = 'slide';
    slide.dataset.index = idx;
    const srcAttr = (idx <= 2) ? `src="${gif.largeUrl || gif.previewUrl}"` : '';
    slide.innerHTML = `
      <div class="card">
        <img ${srcAttr} data-src="${gif.largeUrl || gif.previewUrl}" alt="gif ${idx + 1}">
        <div class="copy-pill">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
          <span>Cliquer pour copier</span>
        </div>
        <div class="copied-flash">
          <div class="copied-flash-box">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
            <span>Lien court copié !</span>
          </div>
        </div>
      </div>`;

    const card = slide.querySelector('.card');
    card.onclick = () => triggerCopy(idx);
    return slide;
  }

  function selectCard(idx, scrollIntoView = false) {
    if (idx < 0) idx = 0;
    if (idx >= results.length) idx = results.length - 1;
    index = idx;

    const cards = galleryGrid.querySelectorAll('.gallery-card');
    cards.forEach((c, i) => {
      if (i === index) {
        c.classList.add('selected');
        if (scrollIntoView) {
          c.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'smooth' });
        }
      } else {
        c.classList.remove('selected');
      }
    });

    updateControlsUI();
  }

  function watchSlideImage(idx) {
    if (reportedImages.has(idx)) return;
    const slide = track.querySelector(`.slide[data-index="${idx}"]`);
    if (!slide) return;
    const img = slide.querySelector('img');
    if (!img) return;
    const tStart = performance.now();
    if (img.complete && img.naturalWidth > 0) {
      reportImageTiming(idx, 0, img, true);
    } else {
      img.addEventListener('load', () => {
        reportImageTiming(idx, performance.now() - tStart, img, false);
      }, { once: true });
      img.addEventListener('error', () => {
        reportImageError(idx, img.src);
      }, { once: true });
    }
  }

  function updatePreloads() {
    const total = results.length;
    if (total === 0) return;
    const indices = [
      index,
      (index + 1) % total,
      (index + 2) % total,
      (index - 1 + total) % total,
      (index - 2 + total) % total
    ];
    indices.forEach(idx => {
      const slide = track.querySelector(`.slide[data-index="${idx}"]`);
      if (slide) {
        const img = slide.querySelector('img');
        if (img && !img.src && img.dataset.src) {
          img.src = img.dataset.src;
        }
      }
    });
  }

  function renderCarousel() {
    const total = results.length;
    if (total === 0) return;
    if (index >= total) index = total - 1;
    if (index < 0) index = 0;

    track.style.display = 'flex';
    track.style.transform = `translateX(${-index * 100}%)`;
    updatePreloads();
    watchSlideImage(index);
    updateControlsUI();
  }

  function updateControlsUI() {
    const total = results.length;
    if (total === 0) {
      counter.style.display = 'none';
      prevBtn.disabled = true;
      nextBtn.disabled = true;
      copyBtn.disabled = true;
      postBtn.disabled = true;
      return;
    }

    counter.style.display = 'inline-flex';
    counter.textContent = (index + 1) + ' / ' + total;
    copyBtn.disabled = false;
    postBtn.disabled = false;
    prevBtn.disabled = total <= 1;
    nextBtn.disabled = total <= 1;
  }

  function goPrev() {
    if (results.length > 1) {
      index = (index - 1 + results.length) % results.length;
      if (viewMode === 'carousel') {
        renderCarousel();
      } else {
        selectCard(index, true);
      }
    }
  }

  function goNext() {
    if (results.length > 1) {
      if (index >= results.length - 2 && hasMore && !isLoadingMore) {
        loadMoreGifs();
      }
      index = (index + 1) % results.length;
      if (viewMode === 'carousel') {
        renderCarousel();
      } else {
        selectCard(index, true);
      }
    }
  }

  function loadMoreGifs() {
    if (isLoadingMore || !hasMore || isSearching || !lastSearchedQuery) return;
    isLoadingMore = true;
    galleryLoadingMore.style.display = 'flex';
    window.webkit.messageHandlers.giphyBridge.postMessage({
      action: 'search',
      query: lastSearchedQuery,
      offset: results.length,
      append: true,
      seq: searchSeq
    });
  }

  galleryView.addEventListener('scroll', () => {
    if (viewMode !== 'gallery') return;
    if (galleryView.scrollHeight - galleryView.scrollTop - galleryView.clientHeight < 140) {
      loadMoreGifs();
    }
  });

  function setResults(newResults, err, isAppend) {
    isSearching = false;
    isLoadingMore = false;
    spinner.style.display = 'none';
    galleryLoadingMore.style.display = 'none';
    clearBtn.style.display = input.value ? 'flex' : 'none';

    if (err) {
      if (!isAppend) {
        results = [];
        lastSearchedQuery = '';
        welcomeState.style.display = 'none';
        emptyState.style.display = 'flex';
        emptyMsg.textContent = err;
        carouselView.style.display = 'none';
        galleryView.style.display = 'none';
        updateControlsUI();
      }
      return;
    }

    if (isAppend) {
      if (!newResults || newResults.length === 0) {
        hasMore = false;
        galleryEndMsg.style.display = 'block';
        return;
      }
      if (newResults.length < 25) {
        hasMore = false;
        galleryEndMsg.style.display = 'block';
      }

      const startIndex = results.length;
      results = results.concat(newResults);

      const gridFrag = document.createDocumentFragment();
      for (let i = 0; i < newResults.length; i++) {
        gridFrag.appendChild(createGalleryCard(newResults[i], startIndex + i));
      }
      galleryGrid.appendChild(gridFrag);

      const trackFrag = document.createDocumentFragment();
      for (let i = 0; i < newResults.length; i++) {
        trackFrag.appendChild(createCarouselSlide(newResults[i], startIndex + i));
      }
      track.appendChild(trackFrag);

      updateControlsUI();
      if (viewMode === 'carousel') {
        updatePreloads();
      }
      return;
    }

    if (!newResults || newResults.length === 0) {
      results = [];
      lastSearchedQuery = '';
      welcomeState.style.display = 'none';
      emptyState.style.display = 'flex';
      emptyMsg.textContent = 'Aucun résultat';
      carouselView.style.display = 'none';
      galleryView.style.display = 'none';
      updateControlsUI();
      return;
    }

    reportedImages.clear();
    results = newResults;
    index = 0;
    hasMore = (results.length >= 25);
    galleryEndMsg.style.display = 'none';
    welcomeState.style.display = 'none';
    emptyState.style.display = 'none';

    galleryGrid.innerHTML = '';
    const gridFrag = document.createDocumentFragment();
    for (let i = 0; i < results.length; i++) {
      gridFrag.appendChild(createGalleryCard(results[i], i));
    }
    galleryGrid.appendChild(gridFrag);
    galleryView.scrollTop = 0;

    track.innerHTML = '';
    const trackFrag = document.createDocumentFragment();
    for (let i = 0; i < results.length; i++) {
      trackFrag.appendChild(createCarouselSlide(results[i], i));
    }
    track.appendChild(trackFrag);

    setViewMode(viewMode, false);
    selectCard(0);
    renderCarousel();
  }

  window.onGiphyResults = function(data, err, seq, isAppend) {
    if (seq !== searchSeq) return;
    setResults(data, err, isAppend === true || isAppend === 'true');
  };

  function doSearch() {
    const q = input.value.trim();
    if (!q) return;
    lastSearchedQuery = q;
    isSearching = true;
    searchSeq++;
    spinner.style.display = 'block';
    welcomeState.style.display = 'none';
    emptyState.style.display = 'none';
    window.webkit.messageHandlers.giphyBridge.postMessage({
      action: 'search',
      query: q,
      offset: 0,
      append: false,
      seq: searchSeq
    });
  }

  function triggerCopy(idx) {
    if (copying || !results[idx]) return;
    copying = true;
    if (viewMode === 'carousel') {
      const slide = track.querySelector(`.slide[data-index="${idx}"]`);
      const flash = slide ? slide.querySelector('.copied-flash') : null;
      if (flash) flash.classList.add('active');
    } else {
      const card = galleryGrid.querySelector(`.gallery-card[data-index="${idx}"]`);
      const flash = card ? card.querySelector('.copied-flash') : null;
      if (flash) flash.classList.add('active');
    }

    setTimeout(() => {
      window.webkit.messageHandlers.giphyBridge.postMessage({
        action: 'copy',
        chosen: results[idx]
      });
    }, 120);
  }

  function triggerPost(idx) {
    if (!results[idx]) return;
    window.webkit.messageHandlers.giphyBridge.postMessage({
      action: 'post',
      chosen: results[idx]
    });
  }

  input.addEventListener('input', () => {
    clearBtn.style.display = input.value ? 'flex' : 'none';
  });

  input.addEventListener('keydown', (e) => {
    if (e.metaKey && e.key === '1') {
      e.preventDefault();
      setViewMode('gallery');
      return;
    }
    if (e.metaKey && e.key === '2') {
      e.preventDefault();
      setViewMode('carousel');
      return;
    }
    if (e.metaKey && (e.key === 'm' || e.key === 'M')) {
      e.preventDefault();
      setViewMode(viewMode === 'gallery' ? 'carousel' : 'gallery');
      return;
    }
    if (e.metaKey && e.key === 'ArrowLeft') {
      e.preventDefault();
      goPrev();
      return;
    }
    if (e.metaKey && e.key === 'ArrowRight') {
      e.preventDefault();
      goNext();
      return;
    }
    if (e.metaKey && (e.key === 'r' || e.key === 'R')) {
      e.preventDefault();
      doSearch();
      return;
    }
    if (e.metaKey && (e.key === 'c' || e.key === 'C')) {
      if (results.length > 0) {
        e.preventDefault();
        triggerCopy(index);
        return;
      }
    }
    if (e.key === 'Enter') {
      e.preventDefault();
      if (e.shiftKey || e.metaKey) {
        triggerPost(index);
        return;
      }
      const q = input.value.trim();
      if (!q) return;
      if (isSearching) return;
      if (q === lastSearchedQuery && results.length > 0) {
        goNext();
      } else {
        doSearch();
      }
      return;
    }
    if (e.metaKey && e.key === ',') {
      e.preventDefault();
      toggleSettings();
      return;
    }
    if (e.key === 'Escape') {
      if (document.getElementById('settings-panel').style.display === 'flex') {
        closeSettings();
        return;
      }
      if (input.value) {
        input.value = '';
        clearBtn.style.display = 'none';
        lastSearchedQuery = '';
      } else {
        window.webkit.messageHandlers.giphyBridge.postMessage({action: 'cancel'});
      }
      return;
    }
    if (e.key === 'ArrowDown' || e.key === 'Tab') {
      e.preventDefault();
      input.blur();
      if (results.length > 0) {
        selectCard(index, true);
      }
      return;
    }
  });

  loupeIcon.addEventListener('click', () => {
    doSearch();
  });

  clearBtn.addEventListener('click', () => {
    input.value = '';
    clearBtn.style.display = 'none';
    lastSearchedQuery = '';
    input.focus();
  });

  prevBtn.onclick = goPrev;
  nextBtn.onclick = goNext;
  postBtn.onclick = () => triggerPost(index);
  copyBtn.onclick = () => triggerCopy(index);
  document.getElementById('cancel').onclick = () => {
    window.webkit.messageHandlers.giphyBridge.postMessage({action: 'cancel'});
  };

  document.addEventListener('keydown', (e) => {
    const isSettingsOpen = (document.getElementById('settings-panel').style.display === 'flex');
    if (isSettingsOpen) {
      if (e.key === 'Escape') {
        e.preventDefault();
        closeSettings();
        return;
      }
      if (e.metaKey && (e.key === 's' || e.key === 'S')) {
        e.preventDefault();
        document.getElementById('save-settings-btn').click();
        return;
      }
      return;
    }

    if (document.activeElement === input) return;

    if (e.metaKey && e.key === '1') {
      e.preventDefault();
      setViewMode('gallery');
      return;
    }
    if (e.metaKey && e.key === '2') {
      e.preventDefault();
      setViewMode('carousel');
      return;
    }
    if (e.metaKey && (e.key === 'm' || e.key === 'M')) {
      e.preventDefault();
      setViewMode(viewMode === 'gallery' ? 'carousel' : 'gallery');
      return;
    }
    if (e.metaKey && e.key === ',') {
      e.preventDefault();
      toggleSettings();
      return;
    }
    if (e.metaKey && (e.key === 'r' || e.key === 'R')) {
      e.preventDefault();
      doSearch();
      return;
    }
    if (e.key === 'Escape') {
      window.webkit.messageHandlers.giphyBridge.postMessage({action: 'cancel'});
      return;
    }
    if (e.key === '/' || (e.metaKey && (e.key === 'f' || e.key === 'F'))) {
      e.preventDefault();
      input.focus();
      input.select();
      return;
    }

    if (viewMode === 'gallery') {
      if (e.key === 'ArrowRight' || (e.metaKey && e.key === 'ArrowRight')) {
        e.preventDefault();
        goNext();
        return;
      }
      if (e.key === 'ArrowLeft' || (e.metaKey && e.key === 'ArrowLeft')) {
        e.preventDefault();
        goPrev();
        return;
      }
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        if (index + 5 < results.length) {
          selectCard(index + 5, true);
        } else if (hasMore && !isLoadingMore) {
          loadMoreGifs();
        }
        return;
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        if (index < 5) {
          input.focus();
          input.select();
        } else {
          selectCard(index - 5, true);
        }
        return;
      }
      if (e.key === ' ') {
        e.preventDefault();
        setViewMode('carousel');
        return;
      }
      if (e.key === 'Enter') {
        e.preventDefault();
        if (e.shiftKey || e.metaKey) {
          triggerPost(index);
        } else {
          triggerCopy(index);
        }
        return;
      }
      if ((e.metaKey && (e.key === 'c' || e.key === 'C')) || e.key === 'c' || e.key === 'C') {
        e.preventDefault();
        triggerCopy(index);
        return;
      }
    } else {
      if (e.key === 'ArrowRight' || (e.metaKey && e.key === 'ArrowRight')) {
        e.preventDefault();
        goNext();
        return;
      }
      if (e.key === 'ArrowLeft' || (e.metaKey && e.key === 'ArrowLeft')) {
        e.preventDefault();
        goPrev();
        return;
      }
      if (e.key === ' ') {
        e.preventDefault();
        goNext();
        return;
      }
      if (e.key === 'Enter') {
        e.preventDefault();
        if (e.shiftKey || e.metaKey) {
          triggerPost(index);
        } else {
          if (results.length > 0) goNext();
        }
        return;
      }
      if ((e.metaKey && (e.key === 'c' || e.key === 'C')) || e.key === 'c' || e.key === 'C') {
        e.preventDefault();
        triggerCopy(index);
        return;
      }
    }

    const num = parseInt(e.key, 10);
    if (!isNaN(num) && num >= 1 && num <= results.length) {
      index = num - 1;
      if (viewMode === 'carousel') {
        renderCarousel();
      } else {
        selectCard(index, true);
      }
    }
  });

  // --- Settings & Hotkey Logic ---
  const MODIFIER_NAMES = {
    cmd: '⌘',
    shift: '⇧',
    alt: '⌥',
    ctrl: '⌃'
  };

  const KEY_LABELS = {
    space: 'Espace',
    return: 'Entrée',
    tab: 'Tab',
    escape: 'Échap',
    delete: 'Effacer',
    left: '←',
    right: '→',
    up: '↑',
    down: '↓'
  };

  const AVAILABLE_KEYS = [
    { value: 'g', label: 'G (défaut)' },
    { value: 'space', label: 'Espace (Space)' },
    { value: 'a', label: 'A' },
    { value: 'b', label: 'B' },
    { value: 'c', label: 'C' },
    { value: 'd', label: 'D' },
    { value: 'e', label: 'E' },
    { value: 'f', label: 'F' },
    { value: 'h', label: 'H' },
    { value: 'i', label: 'I' },
    { value: 'j', label: 'J' },
    { value: 'k', label: 'K' },
    { value: 'l', label: 'L' },
    { value: 'm', label: 'M' },
    { value: 'n', label: 'N' },
    { value: 'o', label: 'O' },
    { value: 'p', label: 'P' },
    { value: 'q', label: 'Q' },
    { value: 'r', label: 'R' },
    { value: 's', label: 'S' },
    { value: 't', label: 'T' },
    { value: 'u', label: 'U' },
    { value: 'v', label: 'V' },
    { value: 'w', label: 'W' },
    { value: 'x', label: 'X' },
    { value: 'y', label: 'Y' },
    { value: 'z', label: 'Z' },
    { value: '0', label: '0' },
    { value: '1', label: '1' },
    { value: '2', label: '2' },
    { value: '3', label: '3' },
    { value: '4', label: '4' },
    { value: '5', label: '5' },
    { value: '6', label: '6' },
    { value: '7', label: '7' },
    { value: '8', label: '8' },
    { value: '9', label: '9' },
    { value: 'tab', label: 'Tab' },
    { value: 'return', label: 'Entrée (Return)' },
    { value: 'delete', label: 'Effacer (Delete)' },
    { value: 'left', label: '← Flèche gauche' },
    { value: 'right', label: '→ Flèche droite' },
    { value: 'up', label: '↑ Flèche haut' },
    { value: 'down', label: '↓ Flèche bas' },
    { value: 'f1', label: 'F1' },
    { value: 'f2', label: 'F2' },
    { value: 'f3', label: 'F3' },
    { value: 'f4', label: 'F4' },
    { value: 'f5', label: 'F5' },
    { value: 'f6', label: 'F6' },
    { value: 'f7', label: 'F7' },
    { value: 'f8', label: 'F8' },
    { value: 'f9', label: 'F9' },
    { value: 'f10', label: 'F10' },
    { value: 'f11', label: 'F11' },
    { value: 'f12', label: 'F12' }
  ];

  const keySelect = document.getElementById('hotkey-key-select');
  AVAILABLE_KEYS.forEach(item => {
    const opt = document.createElement('option');
    opt.value = item.value;
    opt.textContent = item.label;
    keySelect.appendChild(opt);
  });

  function formatHotkey(hotkey) {
    if (!hotkey || !hotkey.mods || !hotkey.key) return ['⌘', '⇧', 'G'];
    const parts = [];
    const order = ['cmd', 'shift', 'alt', 'ctrl'];
    order.forEach(m => {
      if (hotkey.mods.includes(m)) parts.push(MODIFIER_NAMES[m] || m);
    });
    hotkey.mods.forEach(m => {
      if (!order.includes(m)) parts.push(m);
    });
    const k = (hotkey.key || '').toLowerCase();
    const keyDisplay = KEY_LABELS[k] || k.toUpperCase();
    parts.push(keyDisplay);
    return parts;
  }

  function renderHotkeyDisplay() {
    const parts = formatHotkey(pendingHotkey);
    const container = document.getElementById('hotkey-display');
    if (!container) return;
    container.innerHTML = parts.map(p => `<span class="hotkey-badge">${p}</span>`).join('');
  }

  function updateHotkeyUI() {
    // Sync modifier chips
    document.querySelectorAll('.mod-chip').forEach(chip => {
      const mod = chip.dataset.mod;
      if (pendingHotkey.mods && pendingHotkey.mods.includes(mod)) {
        chip.classList.add('active');
      } else {
        chip.classList.remove('active');
      }
    });

    // Sync key select dropdown
    if (pendingHotkey.key) {
      const k = pendingHotkey.key.toLowerCase();
      let found = false;
      for (let i = 0; i < keySelect.options.length; i++) {
        if (keySelect.options[i].value === k) {
          found = true;
          break;
        }
      }
      if (!found) {
        const opt = document.createElement('option');
        opt.value = k;
        opt.textContent = KEY_LABELS[k] || k.toUpperCase();
        keySelect.appendChild(opt);
      }
      keySelect.value = k;
    }

    // Sync live preview badges
    renderHotkeyDisplay();
  }

  // Modifier chip click events
  document.querySelectorAll('.mod-chip').forEach(chip => {
    chip.addEventListener('click', () => {
      if (isRecordingHotkey) stopRecording();
      const mod = chip.dataset.mod;
      if (!pendingHotkey.mods) pendingHotkey.mods = [];
      if (pendingHotkey.mods.includes(mod)) {
        pendingHotkey.mods = pendingHotkey.mods.filter(m => m !== mod);
      } else {
        pendingHotkey.mods.push(mod);
      }
      if (pendingHotkey.mods.length === 0) {
        hotkeyError.textContent = 'Au moins un modificateur (⌘, ⌥, ⌃ ou ⇧) est requis.';
        hotkeyError.style.display = 'block';
      } else {
        hotkeyError.style.display = 'none';
      }
      updateHotkeyUI();
    });
  });

  // Key select change event
  keySelect.addEventListener('change', () => {
    if (isRecordingHotkey) stopRecording();
    pendingHotkey.key = keySelect.value;
    hotkeyError.style.display = 'none';
    updateHotkeyUI();
  });

  // Reset button
  document.getElementById('reset-hotkey-btn').addEventListener('click', () => {
    pendingHotkey = { mods: ['cmd', 'shift'], key: 'g' };
    hotkeyError.style.display = 'none';
    stopRecording();
    updateHotkeyUI();
  });

  // Recorder logic
  const recorderBtn = document.getElementById('hotkey-recorder');
  const recordingStatus = document.getElementById('recording-status');
  const hotkeyError = document.getElementById('hotkey-error');

  function startRecording() {
    isRecordingHotkey = true;
    recorderBtn.classList.add('recording');
    recordingStatus.textContent = 'Tapez votre raccourci...';
    hotkeyError.style.display = 'none';
    recorderBtn.focus();
  }

  function stopRecording() {
    isRecordingHotkey = false;
    recorderBtn.classList.remove('recording');
    recordingStatus.textContent = 'Enregistrer en tapant...';
  }

  recorderBtn.addEventListener('click', () => {
    if (isRecordingHotkey) {
      stopRecording();
    } else {
      startRecording();
    }
  });

  document.addEventListener('mousedown', (e) => {
    if (isRecordingHotkey && !recorderBtn.contains(e.target)) {
      stopRecording();
    }
  });

  function normalizeKeyFromCode(code, key) {
    if (!code) return null;
    if (code.startsWith('Key')) return code.slice(3).toLowerCase();
    if (code.startsWith('Digit')) return code.slice(5);
    if (code.startsWith('Numpad') && /^Numpad\d$/.test(code)) return code.slice(6);
    if (code === 'Space') return 'space';
    if (code === 'Enter' || code === 'NumpadEnter') return 'return';
    if (code === 'Tab') return 'tab';
    if (code === 'Backspace' || code === 'Delete') return 'delete';
    if (code === 'ArrowLeft') return 'left';
    if (code === 'ArrowRight') return 'right';
    if (code === 'ArrowUp') return 'up';
    if (code === 'ArrowDown') return 'down';
    if (/^F\d+$/.test(code)) return code.toLowerCase();
    if (code === 'Minus') return '-';
    if (code === 'Equal') return '=';
    if (code === 'Comma') return ',';
    if (code === 'Period') return '.';
    if (code === 'Slash') return '/';
    if (code === 'Semicolon') return ';';
    if (code === 'Quote') return "'";
    if (code === 'Backquote') return '`';
    if (code === 'BracketLeft') return '[';
    if (code === 'BracketRight') return ']';
    if (key && /^[a-zA-Z0-9]$/.test(key)) return key.toLowerCase();
    return null;
  }

  window.addEventListener('keydown', (e) => {
    if (!isRecordingHotkey) return;

    e.preventDefault();
    e.stopPropagation();

    if (e.key === 'Escape') {
      stopRecording();
      return;
    }

    const currentMods = [];
    if (e.ctrlKey) currentMods.push('ctrl');
    if (e.altKey) currentMods.push('alt');
    if (e.shiftKey) currentMods.push('shift');
    if (e.metaKey) currentMods.push('cmd');

    if (['Meta', 'Shift', 'Alt', 'Control', 'CapsLock'].includes(e.key)) {
      if (currentMods.length > 0) {
        pendingHotkey.mods = currentMods;
        updateHotkeyUI();
      }
      return;
    }

    if (currentMods.length === 0) {
      hotkeyError.textContent = 'Au moins un modificateur (⌘, ⌥, ⌃ ou ⇧) est requis.';
      hotkeyError.style.display = 'block';
      return;
    }

    const normKey = normalizeKeyFromCode(e.code, e.key);
    if (!normKey) {
      hotkeyError.textContent = 'Touche non supportée. Utilisez A-Z, 0-9, Espace, etc.';
      hotkeyError.style.display = 'block';
      return;
    }

    pendingHotkey.mods = currentMods;
    pendingHotkey.key = normKey;
    hotkeyError.style.display = 'none';
    updateHotkeyUI();
    stopRecording();
  }, true);

  window.addEventListener('keyup', (e) => {
    if (!isRecordingHotkey) return;
    const currentMods = [];
    if (e.ctrlKey) currentMods.push('ctrl');
    if (e.altKey) currentMods.push('alt');
    if (e.shiftKey) currentMods.push('shift');
    if (e.metaKey) currentMods.push('cmd');
    if (currentMods.length > 0) {
      pendingHotkey.mods = currentMods;
      updateHotkeyUI();
    }
  }, true);

  function openSettings() {
    input.blur();
    document.getElementById('cfg-logging').checked = activeConfig.consoleLogging;
    document.getElementById('cfg-apikey').value = activeConfig.apiKey || '';
    const defaultViewEl = document.getElementById('cfg-defaultview');
    if (defaultViewEl) {
      defaultViewEl.value = activeConfig.defaultView || 'gallery';
    }
    pendingHotkey = {
      mods: (activeConfig.hotkey && activeConfig.hotkey.mods) ? activeConfig.hotkey.mods.slice() : ['cmd', 'shift'],
      key: (activeConfig.hotkey && activeConfig.hotkey.key) ? activeConfig.hotkey.key : 'g'
    };
    updateHotkeyUI();
    stopRecording();
    document.getElementById('settings-panel').style.display = 'flex';
    try {
      window.webkit.messageHandlers.giphyBridge.postMessage({ action: 'openSettings' });
    } catch(e) {}
  }

  function closeSettings() {
    stopRecording();
    document.getElementById('settings-panel').style.display = 'none';
    try {
      window.webkit.messageHandlers.giphyBridge.postMessage({ action: 'closeSettings' });
    } catch(e) {}
    input.focus();
  }

  function toggleSettings() {
    const panel = document.getElementById('settings-panel');
    if (panel.style.display === 'flex') {
      closeSettings();
    } else {
      openSettings();
    }
  }

  document.getElementById('gear-btn').addEventListener('click', toggleSettings);
  document.getElementById('close-settings-btn').addEventListener('click', closeSettings);
  document.getElementById('cancel-settings-btn').addEventListener('click', closeSettings);

  const keyInput = document.getElementById('cfg-apikey');
  const toggleKeyBtn = document.getElementById('toggle-key-visibility');
  toggleKeyBtn.addEventListener('click', () => {
    if (keyInput.type === 'password') {
      keyInput.type = 'text';
      toggleKeyBtn.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"></path><line x1="1" y1="1" x2="23" y2="23"></line></svg>`;
    } else {
      keyInput.type = 'password';
      toggleKeyBtn.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"></path><circle cx="12" cy="12" r="3"></circle></svg>`;
    }
  });

  document.getElementById('save-settings-btn').addEventListener('click', () => {
    const loggingChecked = document.getElementById('cfg-logging').checked;
    const apiKeyVal = document.getElementById('cfg-apikey').value.trim();
    const defaultViewEl = document.getElementById('cfg-defaultview');
    const defaultViewVal = defaultViewEl ? defaultViewEl.value : 'gallery';

    if (!pendingHotkey.mods || pendingHotkey.mods.length === 0) {
      hotkeyError.textContent = 'Au moins un modificateur (⌘, ⌥, ⌃ ou ⇧) est requis.';
      hotkeyError.style.display = 'block';
      return;
    }

    if (!pendingHotkey.key || pendingHotkey.key === '') {
      hotkeyError.textContent = 'Veuillez sélectionner une touche.';
      hotkeyError.style.display = 'block';
      return;
    }

    window.webkit.messageHandlers.giphyBridge.postMessage({
      action: 'saveConfig',
      config: {
        consoleLogging: loggingChecked,
        apiKey: apiKeyVal,
        hotkey: pendingHotkey,
        defaultView: defaultViewVal
      }
    });
  });

  window.onConfigSaved = function(success, newConfig, errMsg) {
    if (!success) {
      hotkeyError.textContent = errMsg || 'Erreur: raccourci invalide ou en conflit';
      hotkeyError.style.display = 'block';
      return;
    }
    if (newConfig) {
      activeConfig = newConfig;
      if (newConfig.defaultView) {
        activeConfig.defaultView = newConfig.defaultView;
        const defaultViewEl = document.getElementById('cfg-defaultview');
        if (defaultViewEl) defaultViewEl.value = activeConfig.defaultView;
      }
      pendingHotkey = {
        mods: (activeConfig.hotkey && activeConfig.hotkey.mods) ? activeConfig.hotkey.mods.slice() : ['cmd', 'shift'],
        key: (activeConfig.hotkey && activeConfig.hotkey.key) ? activeConfig.hotkey.key : 'g'
      };
      document.getElementById('cfg-logging').checked = activeConfig.consoleLogging;
      document.getElementById('cfg-apikey').value = activeConfig.apiKey || '';
      updateHotkeyUI();
      closeSettings();
    }
  };

  updateHotkeyUI();
  if (window.__INITIAL_CONFIG__ && window.__INITIAL_CONFIG__.openSettings) {
    openSettings();
  }

  // Focus input on startup without loading any default images
  setTimeout(() => {
    if (!window.__INITIAL_CONFIG__ || !window.__INITIAL_CONFIG__.openSettings) {
      input.focus();
    }
    const tReady = performance.now() - tPageInit;
    try {
      window.webkit.messageHandlers.giphyBridge.postMessage({
        action: 'ready',
        domReadyMs: tReady
      });
    } catch(e) {}
  }, 40);
</script>
</body>
</html>
]]
end

function M.trigger()
    currentSessionStart = hs.timer.absoluteTime()
    local previousApp = hs.application.frontmostApplication()
    local previousAppName = previousApp and previousApp:name() or "inconnu"

    log("══════════════════════════════════════════════════════")
    log("─── Hotkey triggered (frontmost: " .. previousAppName .. ") ───")

    local apiKey, keychainMs, isCached = getApiKey()
    apiKey = apiKey or ""
    logTiming("Keychain API key lookup", keychainMs, isCached and "cached in memory" or (apiKey ~= "" and "retrieved from Keychain" or "not found"))

    local openSettings = (apiKey == "")
    if openSettings then
        log("No API key found in Keychain, opening Settings panel")
    end

    local tCloseStart = hs.timer.absoluteTime()
    closePreview()
    local closeMs = (hs.timer.absoluteTime() - tCloseStart) / 1000000.0
    if closeMs > 0.5 then
        logTiming("Previous preview cleanup", closeMs)
    end

    local tSetupStart = hs.timer.absoluteTime()
    currentUCC = hs.webview.usercontent.new("giphyBridge")
    currentUCC:setCallback(function(msg)
        local body = msg.body or {}
        local action = body.action

        if action == "ready" then
            local totalReadyMs = currentSessionStart and ((hs.timer.absoluteTime() - currentSessionStart) / 1000000.0) or 0
            logTiming("Window ready & interactive", totalReadyMs, string.format("JS DOM+focus: %s", formatDuration(body.domReadyMs or 0)))
        elseif action == "imageLoaded" then
            local idx = (body.index or 0) + 1
            local dims = (body.width and body.height and body.width > 0) and string.format("%dx%d", body.width, body.height) or ""
            local note = body.fromCache and "cached" or dims
            logTiming(string.format("GIF #%d preview rendered", idx), body.loadMs or 0, note)
        elseif action == "imageError" then
            local idx = (body.index or 0) + 1
            log(string.format("[WARN] GIF #%d failed to load: %s", idx, body.url or ""))
        elseif action == "openSettings" or action == "pauseHotkey" then
            if currentHotkeyBinding then
                currentHotkeyBinding:disable()
                log("Global hotkey paused for settings")
            end
        elseif action == "closeSettings" or action == "resumeHotkey" then
            if currentHotkeyBinding then
                currentHotkeyBinding:enable()
                log("Global hotkey resumed")
            end
        elseif action == "saveConfig" then
            local tSaveStart = hs.timer.absoluteTime()
            local cfg = body.config or {}
            log(string.format("─── Saving configuration (consoleLogging=%s) ───", tostring(cfg.consoleLogging)))

            if cfg.consoleLogging ~= nil then
                hs.settings.set(SETTINGS_KEY_CONSOLE_LOG, cfg.consoleLogging == true)
            end

            if cfg.apiKey and cfg.apiKey ~= "" then
                local ok, keyDuration = setApiKey(cfg.apiKey)
                apiKey = cfg.apiKey
                logTiming("Keychain API key saved", keyDuration, ok and "success" or "failed")
            end

            local hotkeySaved = false
            local hotkeyErrorMsg = nil
            local target = nil
            if cfg.hotkey and type(cfg.hotkey) == "table" and cfg.hotkey.mods and cfg.hotkey.key then
                target = {
                    mods = cfg.hotkey.mods,
                    key = tostring(cfg.hotkey.key):lower()
                }
                local ok, err = applyHotkey(target)
                if ok then
                    hs.settings.set(SETTINGS_KEY_HOTKEY, target)
                    hotkeySaved = true
                    log(string.format("New hotkey applied & saved: %s", table.concat(target.mods, "+") .. "+" .. target.key))
                else
                    hotkeyErrorMsg = err
                end
            end

            if cfg.defaultView and (cfg.defaultView == "gallery" or cfg.defaultView == "carousel") then
                hs.settings.set(SETTINGS_KEY_DEFAULT_VIEW, cfg.defaultView)
            end

            if hotkeyErrorMsg then
                hs.alert.show("Erreur: raccourci invalide ou en conflit", 2)
                if currentWebview then
                    currentWebview:evaluateJavaScript(string.format(
                        "window.onConfigSaved(false, null, %s)",
                        hs.json.encode(hotkeyErrorMsg)
                    ))
                end
                return
            end

            if hotkeySaved and target then
                local hotkeyDisplay = formatHotkeyDisplay(target)
                hs.alert.show(string.format("Raccourci %s enregistré !", hotkeyDisplay), 1.5)
            else
                hs.alert.show("Configuration enregistrée !", 1.5)
            end

            if currentWebview then
                local savedCfg = {
                    consoleLogging = isConsoleLogging(),
                    apiKey = getApiKey() or "",
                    hotkey = getHotkeyConfig(),
                    defaultView = getDefaultViewMode()
                }
                currentWebview:evaluateJavaScript(string.format("window.onConfigSaved(true, %s)", hs.json.encode(savedCfg)))
            end
            local totalSaveMs = (hs.timer.absoluteTime() - tSaveStart) / 1000000.0
            logTiming("Configuration save completed", totalSaveMs)
        elseif action == "setDefaultView" then
            local mode = body.mode
            if mode == "gallery" or mode == "carousel" then
                hs.settings.set(SETTINGS_KEY_DEFAULT_VIEW, mode)
                log(string.format("Default view mode set to: %s", mode))
            end
        elseif action == "search" then
            local query = body.query or ""
            local seq = body.seq or 0
            local offset = tonumber(body.offset) or 0
            local isAppend = (body.append == true)
            local tSearchDispatch = hs.timer.absoluteTime()
            log(string.format("─── Search initiated: '%s' (seq=%d, offset=%d, append=%s) ───", query, seq, offset, tostring(isAppend)))
            if not apiKey or apiKey == "" then
                log("[WARN] No API key configured, displaying notice")
                if currentWebview then
                    currentWebview:evaluateJavaScript(string.format(
                        "window.onGiphyResults([], %s, %d, %s)",
                        hs.json.encode("Veuillez configurer votre clé API dans les paramètres ⚙️"),
                        seq,
                        tostring(isAppend)
                    ))
                end
                return
            end
            fetchGifs(query, apiKey, offset, function(results, err)
                if currentWebview then
                    local tInjectStart = hs.timer.absoluteTime()
                    local errJson = err and hs.json.encode(err) or "null"
                    local js = string.format(
                        "window.onGiphyResults(%s, %s, %d, %s)",
                        hs.json.encode(results or {}),
                        errJson,
                        seq,
                        tostring(isAppend)
                    )
                    currentWebview:evaluateJavaScript(js)
                    local injectMs = (hs.timer.absoluteTime() - tInjectStart) / 1000000.0
                    local totalSearchMs = (hs.timer.absoluteTime() - tSearchDispatch) / 1000000.0
                    logTiming("Results injected in WKWebView", injectMs, string.format("total search: %s, count: %d", formatDuration(totalSearchMs), results and #results or 0))
                end
            end)
        elseif action == "post" then
            local tActionStart = hs.timer.absoluteTime()
            local chosen = body.chosen
            local sessionDuration = currentSessionStart and ((hs.timer.absoluteTime() - currentSessionStart) / 1000000.0) or 0
            closePreview()
            if chosen and chosen.shortUrl then
                local url = chosen.shortUrl
                log(string.format("Post action initiated: '%s'", url))
                if previousApp then
                    previousApp:activate()
                end
                hs.timer.doAfter(0.15, function()
                    hs.eventtap.keyStrokes(url)
                    local totalPostMs = (hs.timer.absoluteTime() - tActionStart) / 1000000.0
                    logTiming("Post keystrokes injected", totalPostMs, string.format("app: '%s', session: %s", previousAppName, formatDuration(sessionDuration)))
                end)
            else
                log("[WARN] Post action called without chosen GIF")
            end
        elseif action == "copy" then
            local tActionStart = hs.timer.absoluteTime()
            local chosen = body.chosen
            local sessionDuration = currentSessionStart and ((hs.timer.absoluteTime() - currentSessionStart) / 1000000.0) or 0
            closePreview()
            if chosen and chosen.shortUrl then
                hs.pasteboard.setContents(chosen.shortUrl)
                if previousApp then
                    previousApp:activate()
                end
                hs.alert.show("URL copiée dans le presse-papier !", 1.5)
                local totalCopyMs = (hs.timer.absoluteTime() - tActionStart) / 1000000.0
                logTiming("Copy to pasteboard", totalCopyMs, string.format("session: %s", formatDuration(sessionDuration)))
            else
                log("[WARN] Copy action called without chosen GIF")
            end
        elseif action == "cancel" then
            local sessionDuration = currentSessionStart and ((hs.timer.absoluteTime() - currentSessionStart) / 1000000.0) or 0
            closePreview()
            log(string.format("Window closed by user (open for: %s)", formatDuration(sessionDuration)))
        end
    end)

    local screen = hs.screen.mainScreen():frame()
    local rect = hs.geometry.rect(
        screen.x + (screen.w - WINDOW_SIZE.w) / 2,
        screen.y + (screen.h - WINDOW_SIZE.h) / 2,
        WINDOW_SIZE.w, WINDOW_SIZE.h
    )

    currentWebview = hs.webview.new(rect, { developerExtrasEnabled = false }, currentUCC)
    currentWebview:windowStyle({ "titled", "closable", "utility" })
    currentWebview:windowTitle("Giphy")
    currentWebview:allowGestures(true)
    currentWebview:allowTextEntry(true)

    local initialConfig = {
        consoleLogging = isConsoleLogging(),
        apiKey = apiKey,
        hotkey = getHotkeyConfig(),
        openSettings = openSettings,
        defaultView = getDefaultViewMode()
    }

    local html = buildHtml(initialConfig)
    currentWebview:html(html)
    currentWebview:show()
    currentWebview:bringToFront()

    local win = currentWebview:hswindow()
    if win then
        win:focus()
    end

    local showMs = (hs.timer.absoluteTime() - tSetupStart) / 1000000.0
    local totalUntilShow = (hs.timer.absoluteTime() - currentSessionStart) / 1000000.0
    logTiming("WKWebView created & show() called", showMs, string.format("total since hotkey: %s", formatDuration(totalUntilShow)))
end

applyHotkey(getHotkeyConfig())

-- Preload API key in memory cache so the very first hotkey press is instantaneous
hs.timer.doAfter(0.05, function()
    getApiKey()
end)

M._fetchGifs = fetchGifs
M._getApiKey = getApiKey
M._getWebview = function() return currentWebview end
M.close = closePreview

return M
