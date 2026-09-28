-- Giphy trigger, pure Lua/Hammerspoon: Cmd+Shift+G prompts for a query, shows
-- an animated-gif carousel (native WKWebView), and types the chosen link
-- into whatever app had focus.

local M = {}

local LOG_PATH = os.getenv("HOME") .. "/.giphy-hammerspoon.log"
local KEYCHAIN_SERVICE = "giphy-hammerspoon"
local KEYCHAIN_ACCOUNT = os.getenv("USER")
local RESULT_LIMIT = 5
local WINDOW_SIZE = { w = 420, h = 520 }

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

-- Currently open preview webview, kept at module scope so the JS bridge
-- callback (a fresh closure per trigger) can always reach the right one.
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

local function buildHtml(results)
    local slides = {}
    for i, gif in ipairs(results) do
        table.insert(slides, string.format(
            '<div class="slide"><img src="%s" alt="gif %d"></div>',
            gif.previewUrl, i
        ))
    end

    return string.format([[
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: #1e1f22; color: #e7e7e7;
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    display: flex; flex-direction: column; height: 100vh; overflow: hidden;
  }
  #track {
    display: flex; flex: 1; transition: transform 0.2s ease-out;
  }
  .slide {
    flex: 0 0 100%%; display: flex; align-items: center; justify-content: center;
    padding: 16px;
  }
  .slide img {
    max-width: 100%%; max-height: 100%%; border-radius: 8px; object-fit: contain;
  }
  #counter {
    text-align: center; color: #9a9a9a; font-size: 12px; padding: 4px 0 8px;
  }
  #controls {
    display: flex; gap: 8px; padding: 12px; justify-content: center;
  }
  button {
    background: #2b2d31; color: #e7e7e7; border: none; border-radius: 6px;
    padding: 10px 16px; font-size: 13px; cursor: pointer;
  }
  button:hover { background: #35373c; }
  button:disabled { opacity: 0.35; cursor: default; }
  #post { background: #5865f2; font-weight: 600; }
  #post:hover { background: #4752c4; }
</style>
</head>
<body>
  <div id="counter"></div>
  <div id="track">%s</div>
  <div id="controls">
    <button id="prev">&larr; Pr&eacute;c&eacute;dent</button>
    <button id="cancel">Annuler</button>
    <button id="post">Poster</button>
    <button id="next">Suivant &rarr;</button>
  </div>
<script>
  let index = 0;
  const total = %d;
  const track = document.getElementById('track');
  const counter = document.getElementById('counter');
  const prevBtn = document.getElementById('prev');
  const nextBtn = document.getElementById('next');

  function render() {
    track.style.transform = `translateX(${-index * 100}%%)`;
    counter.textContent = (index + 1) + ' / ' + total;
    prevBtn.disabled = index === 0;
    nextBtn.disabled = index === total - 1;
  }

  document.getElementById('prev').onclick = () => { if (index > 0) { index--; render(); } };
  document.getElementById('next').onclick = () => { if (index < total - 1) { index++; render(); } };
  document.getElementById('post').onclick = () => {
    window.webkit.messageHandlers.giphyBridge.postMessage({action: 'post', index: index});
  };
  document.getElementById('cancel').onclick = () => {
    window.webkit.messageHandlers.giphyBridge.postMessage({action: 'cancel'});
  };
  document.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowLeft') prevBtn.click();
    if (e.key === 'ArrowRight') nextBtn.click();
    if (e.key === 'Escape') document.getElementById('cancel').click();
    if (e.key === 'Enter') document.getElementById('post').click();
  });

  render();
</script>
</body>
</html>
]], table.concat(slides), #results)
end

local function showPreview(query, results, onChosen)
    log("showPreview called with " .. tostring(#results) .. " results")
    closePreview()

    currentUCC = hs.webview.usercontent.new("giphyBridge")
    log("UCC created")

    currentUCC:setCallback(function(msg)
        local body = msg.body
        log("UCC callback: action=" .. tostring(body and body.action))
        if body.action == "post" then
            local chosen = results[body.index + 1]
            log("posted: " .. chosen.pageUrl)
            closePreview()
            onChosen(chosen.pageUrl)
        elseif body.action == "cancel" then
            log("cancelled")
            closePreview()
            onChosen(nil)
        end
    end)

    local screen = hs.screen.mainScreen():frame()
    local rect = hs.geometry.rect(
        screen.x + (screen.w - WINDOW_SIZE.w) / 2,
        screen.y + (screen.h - WINDOW_SIZE.h) / 2,
        WINDOW_SIZE.w, WINDOW_SIZE.h
    )

    log("creating webview at rect: " .. hs.inspect(rect))
    currentWebview = hs.webview.new(rect, { developerExtrasEnabled = false }, currentUCC)
    log("webview created, setting styles")

    currentWebview:windowStyle({ "titled", "closable", "utility" })
    currentWebview:windowTitle("giphy — " .. query)
    currentWebview:allowGestures(true)

    local html = buildHtml(results)
    log("html built, len=" .. tostring(#html) .. ", showing webview")

    currentWebview:html(html)
    currentWebview:show()
    currentWebview:bringToFront()

    log("webview shown and brought to front")
end

local function searchGifs(query, apiKey, callback)
    local url = "https://api.giphy.com/v1/gifs/search?api_key=" .. hs.http.encodeForQuery(apiKey)
        .. "&q=" .. hs.http.encodeForQuery(query)
        .. "&limit=" .. RESULT_LIMIT

    log("search starting: url=" .. url)

    hs.http.asyncGet(url, nil, function(status, body)
        log("search callback triggered: status=" .. tostring(status) .. " body_len=" .. tostring(#(body or "")))

        if status ~= 200 then
            log("search http error: status=" .. tostring(status))
            callback(nil, "Erreur Giphy (HTTP " .. tostring(status) .. ")")
            return
        end

        local ok, decoded = pcall(hs.json.decode, body)
        if not ok or not decoded then
            log("search json decode error: ok=" .. tostring(ok))
            callback(nil, "Réponse Giphy invalide")
            return
        end

        if decoded.meta and decoded.meta.status == 403 then
            log("search 403 error")
            callback(nil, "Clé Giphy invalide (403)")
            return
        end

        local data = decoded.data or {}
        log("search results count: " .. tostring(#data))

        if #data == 0 then
            callback(nil, "Aucun résultat pour « " .. query .. " »")
            return
        end

        local results = {}
        for _, gif in ipairs(data) do
            local images = gif.images or {}
            local preview = (images.fixed_height and images.fixed_height.url)
                or (images.original and images.original.url)
            if preview then
                table.insert(results, { previewUrl = preview, pageUrl = gif.url })
            end
        end

        log("search callback invoking with " .. tostring(#results) .. " results")
        callback(results, nil)
    end)
end

function M.trigger()
    -- Capture this BEFORE the prompt: once our own dialog opens, Hammerspoon
    -- itself becomes frontmost and we'd hand focus back to the wrong app.
    local previousApp = hs.application.frontmostApplication()

    local button, query = hs.dialog.textPrompt(
        "Giphy",
        "Mots-clés à chercher :",
        "",
        "OK",
        "Annuler"
    )

    if button ~= "OK" or not query or query == "" then
        log("query cancelled")
        return
    end

    log("query submitted: " .. query)

    local apiKey = getApiKey()
    if not apiKey then
        hs.alert.show("giphy: aucune clé API dans le Keychain (service " .. KEYCHAIN_SERVICE .. ")")
        log("no API key found")
        return
    end

    searchGifs(query, apiKey, function(results, err)
        log("search callback (M.trigger) invoked: err=" .. tostring(err) .. " results=" .. tostring(type(results)))

        if err then
            log("search failed, showing alert: " .. err)
            hs.alert.show("giphy: " .. err)
            return
        end

        log("previousApp=" .. tostring(previousApp and previousApp:name()))
        log("search succeeded, showing preview with " .. tostring(#results) .. " results")
        showPreview(query, results, function(chosenUrl)
            log("preview done, chosenUrl=" .. tostring(chosenUrl))
            if chosenUrl then
                if previousApp then
                    previousApp:activate()
                    log("reactivated: " .. previousApp:name())
                end
                hs.timer.doAfter(0.15, function()
                    hs.eventtap.keyStrokes(chosenUrl)
                end)
            end
        end)
    end)
end

hs.hotkey.bind({ "cmd", "shift" }, "g", M.trigger)

return M
