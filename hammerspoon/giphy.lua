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
local WINDOW_SIZE = { w = 480, h = 570 }

local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. "\n")
        f:close()
    end
end

local function getApiKey()
    local cmd = string.format(
        "security find-generic-password -a '%s' -s '%s' -w 2>/dev/null",
        KEYCHAIN_ACCOUNT, KEYCHAIN_SERVICE
    )
    local out, ok = hs.execute(cmd)
    if not ok then
        return nil
    end
    local key = out:gsub("%s+$", "")
    return key ~= "" and key or nil
end

local currentWebview = nil
local currentUCC = nil

local function closePreview()
    if currentWebview then
        currentWebview:delete()
        currentWebview = nil
    end
    if currentUCC then
        currentUCC = nil
    end
end

local function pickPreview(images)
    local keys = { "downsized_large", "downsized_medium", "original", "downsized", "fixed_height" }
    for _, k in ipairs(keys) do
        local img = images[k]
        if img and img.url and img.url ~= "" then
            return img.url
        end
    end
    return nil
end

local function fetchGifs(query, apiKey, callback)
    local queryTrimmed = query and query:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if queryTrimmed == "" then
        callback({}, nil)
        return
    end

    local randomOffset = math.random(0, MAX_RANDOM_OFFSET)
    local baseUrl = "https://api.giphy.com/v1/gifs/search?api_key=" .. hs.http.encodeForQuery(apiKey)
        .. "&q=" .. hs.http.encodeForQuery(queryTrimmed)
        .. "&limit=" .. POOL_SIZE

    local urlWithOffset = baseUrl .. "&offset=" .. randomOffset
    log("fetch starting: query='" .. queryTrimmed .. "' offset=" .. randomOffset)

    local function parseAndCallback(body)
        local ok, decoded = pcall(hs.json.decode, body)
        if not ok or not decoded then
            callback(nil, "Réponse Giphy invalide")
            return
        end

        if decoded.meta and decoded.meta.status == 403 then
            callback(nil, "Clé Giphy invalide (403)")
            return
        end

        local data = decoded.data or {}
        if #data == 0 then
            callback({}, "Aucun résultat pour « " .. queryTrimmed .. " »")
            return
        end

        -- Fisher-Yates shuffle on the candidate pool for randomized diversity
        for i = #data, 2, -1 do
            local j = math.random(i)
            data[i], data[j] = data[j], data[i]
        end

        local results = {}
        for _, gif in ipairs(data) do
            local images = gif.images or {}
            local preview = pickPreview(images)
            if preview then
                local short = (gif.bitly_gif_url and gif.bitly_gif_url ~= "" and gif.bitly_gif_url)
                    or (gif.bitly_url and gif.bitly_url ~= "" and gif.bitly_url)
                    or gif.url
                table.insert(results, {
                    previewUrl = preview,
                    shortUrl = short,
                    pageUrl = gif.url,
                    title = gif.title or "",
                })
                if #results >= RESULT_LIMIT then
                    break
                end
            end
        end

        callback(results, nil)
    end

    hs.http.asyncGet(urlWithOffset, nil, function(status, body)
        if status == 200 then
            local ok, decoded = pcall(hs.json.decode, body)
            local data = (ok and decoded and decoded.data) or {}
            -- If random offset produced 0 items, fallback to offset 0
            if #data == 0 and randomOffset > 0 then
                log("offset " .. randomOffset .. " returned 0, retrying with offset 0")
                hs.http.asyncGet(baseUrl .. "&offset=0", nil, function(status2, body2)
                    if status2 ~= 200 then
                        callback(nil, "Erreur Giphy (HTTP " .. tostring(status2) .. ")")
                        return
                    end
                    parseAndCallback(body2)
                end)
                return
            end
            parseAndCallback(body)
        else
            callback(nil, "Erreur Giphy (HTTP " .. tostring(status) .. ")")
        end
    end)
end

local function buildHtml()
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

  /* Viewport & Carousel */
  #viewport {
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
    padding: 8px 16px;
    box-sizing: border-box;
    cursor: pointer;
  }
  .card {
    position: relative;
    width: 100%;
    height: 100%;
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
      <div class="counter-badge" id="counter" style="display: none;">0 / 0</div>
    </div>
  </header>
  <main id="viewport">
    <div id="track"></div>

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
        <span><span class="kbd">⌘←</span> Reculer</span>
        <span><span class="kbd">⌘R</span> Mélanger</span>
        <span><span class="kbd">⌘C</span> Copier</span>
        <span><span class="kbd">⇧↵</span> Poster</span>
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
<script>
  let results = [];
  let index = 0;
  let searchSeq = 0;
  let copying = false;
  let lastSearchedQuery = '';
  let isSearching = false;

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
      const slide = document.querySelector(`.slide[data-index="${idx}"]`);
      if (slide) {
        const img = slide.querySelector('img');
        if (img && !img.src && img.dataset.src) {
          img.src = img.dataset.src;
        }
      }
    });
  }

  function goPrev() {
    if (results.length > 1) {
      index = (index - 1 + results.length) % results.length;
      render();
    }
  }

  function goNext() {
    if (results.length > 1) {
      index = (index + 1) % results.length;
      render();
    }
  }

  function render() {
    const total = results.length;
    if (total === 0) {
      track.style.display = 'none';
      counter.style.display = 'none';
      prevBtn.disabled = true;
      nextBtn.disabled = true;
      copyBtn.disabled = true;
      postBtn.disabled = true;
      return;
    }

    welcomeState.style.display = 'none';
    emptyState.style.display = 'none';
    track.style.display = 'flex';
    counter.style.display = 'inline-flex';
    copyBtn.disabled = false;
    postBtn.disabled = false;
    prevBtn.disabled = total <= 1;
    nextBtn.disabled = total <= 1;

    if (index >= total) index = total - 1;
    if (index < 0) index = 0;

    track.style.transform = `translateX(${-index * 100}%)`;
    counter.textContent = (index + 1) + ' / ' + total;

    updatePreloads();
  }

  function setResults(newResults, err) {
    isSearching = false;
    spinner.style.display = 'none';
    clearBtn.style.display = input.value ? 'flex' : 'none';

    if (err || !newResults || newResults.length === 0) {
      results = [];
      lastSearchedQuery = '';
      welcomeState.style.display = 'none';
      emptyState.style.display = 'flex';
      emptyMsg.textContent = err || 'Aucun résultat';
      render();
      return;
    }

    results = newResults;
    index = 0;

    let slidesHtml = '';
    for (let i = 0; i < results.length; i++) {
      const gif = results[i];
      const srcAttr = (i <= 2) ? `src="${gif.previewUrl}"` : '';
      slidesHtml += `
        <div class="slide" data-index="${i}">
          <div class="card">
            <img ${srcAttr} data-src="${gif.previewUrl}" alt="gif ${i + 1}">
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
          </div>
        </div>`;
    }

    track.innerHTML = slidesHtml;

    document.querySelectorAll('.card').forEach((card) => {
      card.onclick = () => triggerCopy(index);
    });

    render();
  }

  window.onGiphyResults = function(data, err, seq) {
    if (seq !== searchSeq) return;
    setResults(data, err);
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
    window.webkit.messageHandlers.giphyBridge.postMessage({action: 'search', query: q, seq: searchSeq});
  }

  function triggerCopy(idx) {
    if (copying || !results[idx]) return;
    copying = true;
    const slide = document.querySelector(`.slide:nth-child(${idx + 1})`);
    const flash = slide ? slide.querySelector('.copied-flash') : null;
    if (flash) flash.classList.add('active');
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

  // Input event: only toggles clear button visibility, NO search on input
  input.addEventListener('input', () => {
    clearBtn.style.display = input.value ? 'flex' : 'none';
  });

  input.addEventListener('keydown', (e) => {
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
        // Shift + Enter or Cmd + Enter = poster!
        triggerPost(index);
        return;
      }
      const q = input.value.trim();
      if (!q) return;
      if (isSearching) return;
      if (q === lastSearchedQuery && results.length > 0) {
        // Query has not changed and results are loaded -> Next GIF!
        goNext();
      } else {
        // Query changed or first search -> New search!
        doSearch();
      }
      return;
    }
    if (e.key === 'Escape') {
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

  // Keyboard navigation when input is NOT focused
  document.addEventListener('keydown', (e) => {
    if (document.activeElement === input) return;

    if (e.key === 'Enter') {
      e.preventDefault();
      if (e.shiftKey || e.metaKey) {
        triggerPost(index);
      } else {
        if (results.length > 0) {
          goNext();
        }
      }
    } else if ((e.metaKey && (e.key === 'c' || e.key === 'C')) || e.key === 'c' || e.key === 'C') {
      e.preventDefault();
      triggerCopy(index);
    } else if (e.key === 'ArrowLeft' || (e.metaKey && e.key === 'ArrowLeft')) {
      e.preventDefault();
      goPrev();
    } else if (e.key === 'ArrowRight' || (e.metaKey && e.key === 'ArrowRight')) {
      e.preventDefault();
      goNext();
    } else if ((e.metaKey && (e.key === 'r' || e.key === 'R')) || e.key === 'r' || e.key === 'R') {
      e.preventDefault();
      doSearch();
    } else if (e.key === 'Escape') {
      window.webkit.messageHandlers.giphyBridge.postMessage({action: 'cancel'});
    } else if (e.key === '/' || (e.metaKey && (e.key === 'f' || e.key === 'F'))) {
      e.preventDefault();
      input.focus();
      input.select();
    }
    const num = parseInt(e.key, 10);
    if (!isNaN(num) && num >= 1 && num <= results.length) {
      index = num - 1;
      render();
    }
  });

  // Focus input on startup without loading any default images
  setTimeout(() => {
    input.focus();
  }, 40);
</script>
</body>
</html>
]]
end

function M.trigger()
    local previousApp = hs.application.frontmostApplication()

    local apiKey = getApiKey()
    if not apiKey then
        hs.alert.show("giphy: aucune clé API dans le Keychain (service " .. KEYCHAIN_SERVICE .. ")")
        log("no API key found")
        return
    end

    closePreview()

    currentUCC = hs.webview.usercontent.new("giphyBridge")
    currentUCC:setCallback(function(msg)
        local body = msg.body or {}
        local action = body.action
        log("UCC callback: action=" .. tostring(action))

        if action == "search" then
            local query = body.query or ""
            local seq = body.seq or 0
            log("UCC search requested: query='" .. query .. "' seq=" .. seq)
            fetchGifs(query, apiKey, function(results, err)
                log("fetchGifs returned: results=" .. tostring(results and #results) .. " err=" .. tostring(err))
                if currentWebview then
                    local errJson = err and hs.json.encode(err) or "null"
                    local js = string.format(
                        "window.onGiphyResults(%s, %s, %d)",
                        hs.json.encode(results or {}),
                        errJson,
                        seq
                    )
                    currentWebview:evaluateJavaScript(js)
                end
            end)
        elseif action == "post" then
            local chosen = body.chosen
            closePreview()
            if chosen and chosen.shortUrl then
                log("posted: " .. chosen.shortUrl)
                if previousApp then
                    previousApp:activate()
                    log("reactivated: " .. previousApp:name())
                end
                hs.timer.doAfter(0.15, function()
                    hs.eventtap.keyStrokes(chosen.shortUrl)
                end)
            end
        elseif action == "copy" then
            local chosen = body.chosen
            closePreview()
            if chosen and chosen.shortUrl then
                log("copied: " .. chosen.shortUrl)
                hs.pasteboard.setContents(chosen.shortUrl)
                if previousApp then
                    previousApp:activate()
                    log("reactivated: " .. previousApp:name())
                end
                hs.alert.show("URL copiée dans le presse-papier !", 1.5)
            end
        elseif action == "cancel" then
            log("cancelled")
            closePreview()
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

    local html = buildHtml()
    currentWebview:html(html)
    currentWebview:show()
    currentWebview:bringToFront()

    local win = currentWebview:hswindow()
    if win then
        win:focus()
    end
end

hs.hotkey.bind({ "cmd", "shift" }, "g", M.trigger)

return M
