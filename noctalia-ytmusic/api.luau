local API = {}

local bit = bit32

local logger = require("./log.luau")
local function log(msg) logger.log("ytapi", msg) end

local KEY = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
local CLIENT_VERSION = "1.20240813.01.00"
local BASE = "https://music.youtube.com/youtubei/v1/"
local ORIGIN = "https://music.youtube.com"

local COOKIE_PATH = noctalia.expandPath(XDG_CACHE and XDG_CACHE ~= "" and XDG_CACHE or "~/.cache") .. "/noctalia-ytmusic/cookies.txt"

-- ----------------------------------------------------------------------------
-- Pure-Luau SHA-1 (FIPS 180-1), uint32 math via bit32
-- ----------------------------------------------------------------------------

local function sha1(msg)
    local mod32 = 0xFFFFFFFF
    local function hex32(n)
        local h = "0123456789abcdef"
        local out = {}
        for i = 1, 8 do
            local d = n % 16
            out[9 - i] = h:sub(d + 1, d + 1)
            n = math.floor(n / 16)
        end
        return table.concat(out)
    end
    local bytes = { string.byte(msg, 1, -1) }
    local bits = #bytes * 8
    table.insert(bytes, 0x80)
    while #bytes % 64 ~= 56 do
        table.insert(bytes, 0)
    end
    for i = 1, 8 do
        local shift = (8 - i) * 8
        table.insert(bytes, math.floor(bits / (2 ^ shift)) % 256)
    end

    local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0

    for pos = 1, #bytes, 64 do
        local w = {}
        for i = 0, 15 do
            local o = pos + i * 4
            w[i] = bit.bor(
                bit.lshift(bytes[o], 24),
                bit.lshift(bytes[o + 1], 16),
                bit.lshift(bytes[o + 2], 8),
                bytes[o + 3]
            )
        end
        for i = 16, 79 do
            w[i] = bit.lrotate(
                bit.bxor(bit.bxor(w[i - 3], w[i - 8]), bit.bxor(w[i - 14], w[i - 16])),
                1
            )
        end
        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 0, 79 do
            local f, k
            if i <= 19 then
                f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d))
                k = 0x5A827999
            elseif i <= 39 then
                f = bit.bxor(bit.bxor(b, c), d)
                k = 0x6ED9EBA1
            elseif i <= 59 then
                f = bit.bor(bit.bor(bit.band(b, c), bit.band(b, d)), bit.band(c, d))
                k = 0x8F1BBCDC
            else
                f = bit.bxor(bit.bxor(b, c), d)
                k = 0xCA62C1D6
            end
            local temp = (bit.lrotate(a, 5) + f + e + k + w[i]) % (mod32 + 1)
            e, d, c, b, a = d, c, bit.lrotate(b, 30), a, temp
        end
        h0 = (h0 + a) % (mod32 + 1)
        h1 = (h1 + b) % (mod32 + 1)
        h2 = (h2 + c) % (mod32 + 1)
        h3 = (h3 + d) % (mod32 + 1)
        h4 = (h4 + e) % (mod32 + 1)
    end

    return hex32(h0) .. hex32(h1) .. hex32(h2) .. hex32(h3) .. hex32(h4)
end

do
    local abc = sha1("abc")
    log("sha1 self-test sha1(abc)=" .. abc .. (abc == "a9993e364706816aba3e25717850c26c9cd0d89d" and " OK" or " MISMATCH"))
end

-- ----------------------------------------------------------------------------
-- helpers
-- ----------------------------------------------------------------------------

local function sanitize(s)
    s = tostring(s or "")
    return s:gsub("[\r\n]", "")
end

local function fmt_duration(secs)
    secs = tonumber(secs) or 0
    local m = math.floor(secs / 60)
    local s = secs % 60
    return string.format("%d:%02d", m, s)
end

local function fmt_seconds(text)
    text = tostring(text or "")
    local h, m, s = text:match("(%d+):(%d%d):(%d%d)")
    if h then
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    end
    local mm, ss = text:match("(%d+):(%d%d)")
    if mm then
        return tonumber(mm) * 60 + tonumber(ss)
    end
    return 0
end

local function clean_artist(meta)
    meta = tostring(meta or "")
    meta = meta:gsub("%s*•%s*[%d.,]+[KMB]?%s*views.*$", "")
    meta = meta:gsub("%s*•%s*%d+:?%d*$", "")
    local parts = {}
    for part in (meta .. " • "):gmatch("([^•]+) • ") do
        local p = part:gsub("^%s+", ""):gsub("%s+$", "")
        if p ~= "Song" and p ~= "Video" and p ~= "Episode" and p ~= "" then
            table.insert(parts, p)
        end
    end
    if #parts > 0 then return parts[1] end
    return (meta:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function runs_text(runs)
    if type(runs) ~= "table" then return "" end
    local parts = {}
    for _, r in ipairs(runs) do
        if type(r) == "table" and r.text ~= nil then
            table.insert(parts, tostring(r.text))
        end
    end
    return table.concat(parts)
end

local function collect_from_content(content, renderer_key, out)
    out = out or {}
    if type(content) ~= "table" then return out end

    local sl = content.sectionListRenderer or content
    local section_list = (type(sl) == "table" and type(sl.contents) == "table") and sl.contents or { content }

    for _, sec in ipairs(section_list) do
        if type(sec) == "table" then
            if type(sec[renderer_key]) == "table" then
                table.insert(out, sec[renderer_key])
            end

            local containers = { sec }
            for _, k in ipairs({ "itemSectionRenderer", "musicShelfRenderer", "musicCardShelfRenderer", "musicPlaylistShelfRenderer", "gridRenderer" }) do
                if type(sec[k]) == "table" then
                    table.insert(containers, sec[k])
                end
            end

            for _, container in ipairs(containers) do
                local items = type(container.contents) == "table" and container.contents or (type(container.items) == "table" and container.items or nil)
                if type(items) == "table" then
                    for _, item in ipairs(items) do
                        if type(item) == "table" and type(item[renderer_key]) == "table" then
                            table.insert(out, item[renderer_key])
                        end
                    end
                end
            end
        end
    end

    return out
end

local function page_content(data)
    if type(data) ~= "table" or type(data.contents) ~= "table" then return nil end
    local c = data.contents
    local base = c.singleColumnBrowseResultsRenderer or c.twoColumnBrowseResultsRenderer or c.tabbedSearchResultsRenderer
    if type(base) == "table" and type(base.tabs) == "table" then
        for _, tab in ipairs(base.tabs) do
            if type(tab.tabRenderer) == "table" and type(tab.tabRenderer.content) == "table" then
                return tab.tabRenderer.content
            end
        end
    end
end

local function find_continuation_token(data, depth)
    depth = depth or 0
    if depth > 8 or type(data) ~= "table" then return nil end

    if type(data.continuationContents) == "table" then
        local cc = data.continuationContents
        for _, shelf in pairs(cc) do
            if type(shelf) == "table" and type(shelf.continuations) == "table" then
                for _, c in ipairs(shelf.continuations) do
                    if type(c) == "table" and type(c.nextContinuationData) == "table" then
                        local tok = c.nextContinuationData.continuation
                        if type(tok) == "string" and tok ~= "" then return tok end
                    end
                end
            end
        end
    end

    if type(data.continuationItemRenderer) == "table" then
        local cir = data.continuationItemRenderer
        local ep = cir.continuationEndpoint
        if type(ep) == "table" then
            if type(ep.continuationCommand) == "table" and type(ep.continuationCommand.token) == "string" then
                return ep.continuationCommand.token
            end
            if type(ep.browseContinuationEndpoint) == "table" and type(ep.browseContinuationEndpoint.continuation) == "string" then
                return ep.browseContinuationEndpoint.continuation
            end
        end
    end

    for k, v in pairs(data) do
        if type(v) == "table" and k ~= "musicResponsiveListItemRenderer" and k ~= "navigationEndpoint" and k ~= "menu" then
            local tok = find_continuation_token(v, depth + 1)
            if tok then return tok end
        end
    end

    return nil
end

local THUMB_DIR = noctalia.expandPath("~/.cache/noctalia-ytmusic/thumbnails")

local function extract_thumb_url(node)
    if type(node) ~= "table" then return nil end
    local th = node.thumbnail or node.thumbnailRenderer
    if type(th) == "table" then
        local tr = th.musicThumbnailRenderer or th
        local t_list = type(tr) == "table" and (tr.thumbnail and tr.thumbnail.thumbnails or tr.thumbnails) or nil
        if type(t_list) == "table" and #t_list > 0 then
            local last = t_list[#t_list]
            if type(last) == "table" and type(last.url) == "string" and last.url ~= "" then
                return last.url
            end
        end
    end
    return nil
end

function API.get_thumbnail_path(id, url, callback)
    if type(id) ~= "string" or id == "" then return nil end
    local safe_id = id:gsub("[^%w%-_]", "_")
    local path = THUMB_DIR .. "/" .. safe_id .. ".jpg"

    if noctalia.fileExists(path) then
        return path
    end

    if type(url) == "string" and url ~= "" then
        noctalia.runAsync("mkdir -p '" .. THUMB_DIR .. "' && curl -s -L -o '" .. path .. "' '" .. url .. "'", function()
            if noctalia.fileExists(path) and callback then
                callback(path)
            end
        end, 10000)
    end

    return nil
end

local known_thumb_files = {}

local function preload_thumb_cache()
    noctalia.runAsync("find /tmp -name 'noctalia-ytmusic-thumb-*.jpg' 2>/dev/null", function(res)
        local out = type(res) == "table" and res.stdout or ""
        for line in out:gmatch("[^\r\n]+") do
            known_thumb_files[line] = true
        end
    end)
end
preload_thumb_cache()

function API.ensure_thumbnails(items, on_updated, tag)
    if type(items) ~= "table" or #items == 0 then return end

    local missing = {}
    local updated_cached = false

    for _, item in ipairs(items) do
        if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
            if not item.thumb_path then
                local safe_id = item.id:gsub("[^%w%-_]", "_")
                local path = THUMB_DIR .. "/" .. safe_id .. ".jpg"
                if known_thumb_files[path] then
                    item.thumb_path = path
                    updated_cached = true
                else
                    local url = (type(item.thumbnail_url) == "string" and item.thumbnail_url ~= "") and item.thumbnail_url or ("https://i.ytimg.com/vi/" .. item.id .. "/hqdefault.jpg")
                    table.insert(missing, { item = item, path = path, url = url })
                end
            end
        end
    end

    if #missing == 0 then 
        if updated_cached and type(on_updated) == "function" then
            on_updated()
        end
        return 
    end

    local safe_tag = (type(tag) == "string" and tag ~= "") and tag:gsub("[^%w%-_]", "_") or "batch"
    local configFile = string.format("/tmp/noctalia-ytmusic-thumb-%s.txt", safe_tag)
    local lines = {}
    for _, m in ipairs(missing) do
        table.insert(lines, string.format("output = \"%s\"\nurl = \"%s\"", m.path, m.url))
    end
    noctalia.writeFile(configFile, table.concat(lines, "\n"))

    local script = ([=[
mkdir -p "%s"
if command -v curl >/dev/null 2>&1; then
  curl -s --parallel --parallel-max 16 --parallel-immediate -K "%s" >/dev/null 2>&1
fi
rm -f "%s"
echo "THUMBS_DONE=1"
]=]):format(THUMB_DIR, configFile, configFile)

    noctalia.runAsync(script, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        if out:find("THUMBS_DONE=1") then
            for _, m in ipairs(missing) do
                known_thumb_files[m.path] = true
                m.item.thumb_path = m.path
            end
            if type(on_updated) == "function" then
                on_updated()
            end
        end
    end, 15000)
end

function API.attach_cached_thumbs(items)
    if type(items) ~= "table" then return end
    local count = #items
    if count > 50 then count = 50 end
    for i = 1, count do
        local item = items[i]
        if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
            local safe_id = item.id:gsub("[^%w%-_]", "_")
            local path = THUMB_DIR .. "/" .. safe_id .. ".jpg"
            if noctalia.fileExists(path) then
                item.thumb_path = path
            end
        end
    end
end

local function extract_track(node)
    if type(node) ~= "table" then return nil end
    local videoId
    if type(node.playlistItemData) == "table" then
        videoId = node.playlistItemData.videoId
    end
    if not videoId and type(node.navigationEndpoint) == "table" and type(node.navigationEndpoint.watchEndpoint) == "table" then
        videoId = node.navigationEndpoint.watchEndpoint.videoId
    end
    if not videoId then return nil end
    local title = ""
    local meta = ""
    if type(node.flexColumns) == "table" then
        local c1 = type(node.flexColumns[1]) == "table" and node.flexColumns[1].musicResponsiveListItemFlexColumnRenderer
        local c2 = type(node.flexColumns[2]) == "table" and node.flexColumns[2].musicResponsiveListItemFlexColumnRenderer
        if type(c1) == "table" then
            title = runs_text(type(c1.text) == "table" and c1.text.runs)
        end
        if type(c2) == "table" then
            meta = runs_text(type(c2.text) == "table" and c2.text.runs)
        end
    end
    local durtext = ""
    if type(node.fixedColumns) == "table" then
        local fc = type(node.fixedColumns[1]) == "table" and node.fixedColumns[1].musicResponsiveListItemFixedColumnRenderer
        if type(fc) == "table" then
            local rt = runs_text(type(fc.text) == "table" and fc.text.runs)
            durtext = rt:match("^[^%s,]+") or rt
        end
    end

    local thumb_url = extract_thumb_url(node)
    if not thumb_url and videoId then
        thumb_url = "https://i.ytimg.com/vi/" .. videoId .. "/hqdefault.jpg"
    end

    return {
        id = videoId,
        title = title,
        artist = clean_artist(meta),
        duration = fmt_seconds(durtext),
        duration_text = durtext,
        thumbnail_url = thumb_url
    }
end

local function extract_playlist(node)
    if type(node) ~= "table" then return nil end
    local ne = node.navigationEndpoint
    if type(ne) ~= "table" or type(ne.browseEndpoint) ~= "table" then return nil end
    local pid = ne.browseEndpoint.browseId
    if type(pid) ~= "string" or pid == "" then return nil end
    local title = runs_text(type(node.title) == "table" and node.title.runs)
    local sub = runs_text(type(node.subtitle) == "table" and node.subtitle.runs)
    local count = tonumber(sub:match("(%d+) songs?") or sub:match("(%d+) tracks?") or "0") or 0
    local thumb_url = extract_thumb_url(node)
    return {
        id = pid,
        title = title,
        count = count,
        thumbnail_url = thumb_url
    }
end

-- ----------------------------------------------------------------------------
-- auth + request
-- ----------------------------------------------------------------------------

local function load_cookie_values()
    local values = {}
    local raw = noctalia.readFile(COOKIE_PATH)
    if not raw then
        log("readFile failed on " .. COOKIE_PATH)
        return values
    end
    log("cookies: path=" .. COOKIE_PATH .. " len=" .. #raw)
    for line in raw:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" then
            local fields = {}
            for f in line:gmatch("([^\t]+)") do
                table.insert(fields, f)
            end
            if #fields >= 7 and fields[6] == "SAPISID" then
                log("cookies: SAPISID line has " .. #fields .. " fields")
            end
            local name = fields[6]
            local value = fields[7]
            if name then
                values[name] = value
            end
        end
    end
    local names = {}
    for k in pairs(values) do table.insert(names, k) end
    table.sort(names)
    log("cookies: parsed " .. #names .. " (" .. table.concat(names, ",") .. "), values not logged")
    return values
end

local function build_auth()
    local values = load_cookie_values()
    local sapisid = values["SAPISID"]
    if not sapisid or sapisid == "" then
        return nil, nil
    end
    local ts = math.floor(noctalia.nowMs() / 1000)
    local hash = sha1(ts .. " " .. sapisid .. " " .. ORIGIN)
    local auth = "SAPISIDHASH " .. ts .. "_" .. hash
    local cookieParts = {}
    for k, v in pairs(values) do
        table.insert(cookieParts, k .. "=" .. v)
    end
    return auth, table.concat(cookieParts, "; ")
end

local function innerTube(endpoint, request, cb, defer)
    local auth, cookie = build_auth()
    if not auth then
        log("innerTube: no SAPISID auth, request dropped")
        cb(nil, "no auth")
        return
    end
    local payload, perr = noctalia.json.encode(request)
    if not payload then
        log("innerTube: json encode failed " .. tostring(perr))
        cb(nil, tostring(perr))
        return
    end
    log("innerTube POST " .. endpoint .. " body=" .. #payload .. " bytes")
    local accepted = noctalia.http({
        url = BASE .. endpoint .. "?key=" .. KEY .. "&prettyPrint=false",
        method = "POST",
        body = payload,
        headers = {
            "Content-Type: application/json",
            "Authorization: " .. auth,
            "Origin: " .. ORIGIN,
            "Cookie: " .. cookie,
            "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
        },
    }, function(resp)
        if not resp then
            log("innerTube " .. endpoint .. ": no response")
            cb(nil, "no response")
            return
        end
        if not resp.ok then
            log("innerTube " .. endpoint .. ": http status=" .. tostring(resp.status))
            cb(nil, "http " .. tostring(resp.status))
            return
        end
        if defer then
            log("innerTube " .. endpoint .. ": got " .. #resp.body .. " bytes (deferred)")
            cb(resp.body)
            return
        end
        local data, jerr = noctalia.json.decode(resp.body)
        if not data then
            log("innerTube " .. endpoint .. ": json decode failed " .. tostring(jerr))
            cb(nil, "json " .. tostring(jerr))
            return
        end
        log("innerTube " .. endpoint .. ": got " .. #resp.body .. " bytes, parsed ok")
        cb(data)
    end)
    if not accepted then
        log("innerTube " .. endpoint .. ": request rejected by host")
        cb(nil, "request rejected")
    end
end

-- ----------------------------------------------------------------------------
-- public API
-- ----------------------------------------------------------------------------

local CONTEXT = {
    context = {
        client = {
            clientName = "WEB_REMIX",
            clientVersion = CLIENT_VERSION,
            hl = "en",
        },
    },
}

function API.search(query, count, cb)
    query = sanitize(query):gsub("^%s+", ""):gsub("%s+$", "")
    count = tonumber(count) or 25
    log("search query='" .. query .. "'")
    if query == "" then
        cb({})
        return
    end
    innerTube("search", {
        context = CONTEXT.context,
        query = query,
        params = "EgWKAQIIAWoQChADEAQQCRAFEAoQBRAE",
    }, function(raw_body, err)
        if not raw_body or raw_body == "" then
            cb(nil, err or "empty response")
            return
        end
        local raw_file = "/tmp/noctalia-ytmusic-search-raw.json"
        local clean_file = "/tmp/noctalia-ytmusic-search-clean.json"
        noctalia.writeFile(raw_file, raw_body)

        local script = ([=[
jq '{
  tracks: [.. | select(.musicResponsiveListItemRenderer? != null) | .musicResponsiveListItemRenderer | {
    id: (.playlistItemData.videoId // .overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId // .doubleTapCommand.watchEndpoint.videoId // ""),
    title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    album: (.flexColumns[2].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.id != "" and .title != "")] | unique_by(.id)
}' "%s" > "%s" 2>/dev/null
echo "STATUS=OK"
]=]):format(raw_file, clean_file)

        noctalia.runAsync(script, function(res)
            local out = {}
            if noctalia.fileExists(clean_file) then
                local raw_clean = noctalia.readFile(clean_file)
                local data = noctalia.json.decode(raw_clean or "")
                local raw_tracks = (type(data) == "table" and type(data.tracks) == "table") and data.tracks or {}
                for _, tr in ipairs(raw_tracks) do
                    table.insert(out, {
                        id = tr.id,
                        title = tr.title,
                        artist = clean_artist(tr.artist),
                        album = tr.album,
                        duration = fmt_seconds(tr.duration_text),
                        duration_text = tr.duration_text,
                        thumbnail_url = tr.thumbnail_url
                    })
                    if #out >= count then break end
                end
            end
            log(string.format("search got %d results, first='%s'", #out, tostring(out[1] and out[1].title)))
            cb(out)
        end)
    end, true)
end

local CACHE_DIR = noctalia.expandPath(XDG_CACHE and XDG_CACHE ~= "" and XDG_CACHE or "~/.cache") .. "/noctalia-ytmusic"
local LIBRARY_CACHE_PATH = CACHE_DIR .. "/library.json"
local PLAYLISTS_CACHE_DIR = CACHE_DIR .. "/playlists"

function API.load_cached_library()
    if not noctalia.fileExists(LIBRARY_CACHE_PATH) then return nil end
    local raw = noctalia.readFile(LIBRARY_CACHE_PATH)
    if not raw or raw == "" then return nil end
    local data, jerr = noctalia.json.decode(raw)
    if type(data) == "table" and #data > 0 then
        API.attach_cached_thumbs(data)
        log("loaded " .. #data .. " playlists from library cache")
        return data
    end
    return nil
end

function API.save_library_cache(playlists)
    if type(playlists) ~= "table" or #playlists == 0 then return end
    local encoded = noctalia.json.encode(playlists)
    if encoded then
        noctalia.writeFile(LIBRARY_CACHE_PATH, encoded)
        log("saved " .. #playlists .. " playlists to library cache")
    end
end

function API.load_cached_playlist(playlist_id)
    if type(playlist_id) ~= "string" or playlist_id == "" then return nil end
    local safe_id = playlist_id:gsub("[^%w%-_]", "_")
    local path = PLAYLISTS_CACHE_DIR .. "/" .. safe_id .. ".json"
    if not noctalia.fileExists(path) then return nil end
    local raw = noctalia.readFile(path)
    if not raw or raw == "" then return nil end
    local data, jerr = noctalia.json.decode(raw)
    if type(data) == "table" and #data > 0 then
        API.attach_cached_thumbs(data)
        log("loaded " .. #data .. " tracks from cache for playlist " .. playlist_id)
        return data
    end
    return nil
end

function API.save_playlist_cache(playlist_id, tracks)
    if type(playlist_id) ~= "string" or playlist_id == "" or type(tracks) ~= "table" or #tracks == 0 then return end
    local safe_id = playlist_id:gsub("[^%w%-_]", "_")
    local path = PLAYLISTS_CACHE_DIR .. "/" .. safe_id .. ".json"
    local encoded = noctalia.json.encode(tracks)
    if encoded then
        noctalia.runAsync("mkdir -p '" .. PLAYLISTS_CACHE_DIR .. "'", function()
            noctalia.writeFile(path, encoded)
            log("saved " .. #tracks .. " tracks to cache for playlist " .. playlist_id)
        end, 5000)
    end
end

local SESSION_CACHE_PATH = CACHE_DIR .. "/session.json"

function API.load_session()
    if not noctalia.fileExists(SESSION_CACHE_PATH) then return nil end
    local raw = noctalia.readFile(SESSION_CACHE_PATH)
    if not raw or raw == "" then return nil end
    local data = noctalia.json.decode(raw)
    if type(data) == "table" then
        if type(data.queue) == "table" then
            API.attach_cached_thumbs(data.queue)
        end
        log("loaded session: title='" .. tostring(data.title) .. "' index=" .. tostring(data.index))
        return data
    end
    return nil
end

function API.save_session(player)
    if type(player) ~= "table" then return end
    local session = {
        id = player.id or "",
        title = player.title or "",
        artist = player.artist or "",
        thumbnail_url = player.thumbnail_url or "",
        thumb_path = player.thumb_path or "",
        duration = player.duration or 0,
        position = player.position or 0,
        volume = player.volume or 70,
        index = player.index or 0,
        queue = player.queue or {}
    }
    local encoded = noctalia.json.encode(session)
    if encoded then
        noctalia.writeFile(SESSION_CACHE_PATH, encoded)
    end
end

local pending_library = nil

function API.library()
    log("library called")
    local body_json = noctalia.json.encode({ context = CONTEXT.context, browseId = "FEmusic_liked_playlists" })
    local auth, cookie = build_auth()
    local auth_header = auth and ("-H \"Authorization: " .. auth .. "\"") or ""
    local origin_header = "-H \"Origin: " .. ORIGIN .. "\""

    local tmp_payload = "/tmp/noctalia-ytmusic-library-payload.json"
    local tmp_out = "/tmp/noctalia-ytmusic-library.json"
    noctalia.writeFile(tmp_payload, body_json)

    local script = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
C_ARG=""
if [ -s "]=] .. COOKIE_PATH .. [=[" ]; then
  C_ARG="--cookie ]=] .. COOKIE_PATH .. [=["
fi

curl -s -X POST "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false" \
  -H "Content-Type: application/json" \
  ]=] .. origin_header .. [=[ \
  ]=] .. auth_header .. [=[ \
  $C_ARG \
  -d @"/tmp/noctalia-ytmusic-library-payload.json" > "/tmp/noctalia-ytmusic-library-raw.json" 2>/dev/null

jq '{
  playlists: [.. | select(.musicTwoRowItemRenderer? != null) | .musicTwoRowItemRenderer | {
    id: (.navigationEndpoint.browseEndpoint.browseId // ""),
    title: (.title.runs[0].text // ""),
    count_text: (.subtitle.runs[0].text // ""),
    thumbnail_url: (.thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.id != "" and .title != "")] | unique_by(.id)
}' "/tmp/noctalia-ytmusic-library-raw.json" > "]=] .. tmp_out .. [=[" 2>/dev/null
echo "STATUS=OK"
]=]

    noctalia.runAsync(script, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        if out:find("STATUS=OK") and noctalia.fileExists(tmp_out) then
            local raw = noctalia.readFile(tmp_out)
            local data = noctalia.json.decode(raw or "")
            local raw_pls = (type(data) == "table" and type(data.playlists) == "table") and data.playlists or {}
            local playlists = {}
            for _, item in ipairs(raw_pls) do
                local cnt = tonumber(tostring(item.count_text or ""):match("(%d+)")) or 0
                table.insert(playlists, {
                    id = item.id,
                    title = item.title,
                    count = cnt,
                    thumbnail_url = item.thumbnail_url
                })
            end
            if #playlists > 0 then
                API.attach_cached_thumbs(playlists)
                API.save_library_cache(playlists)
            end
            pending_library = playlists
        else
            pending_library = {}
        end
    end, 15000)
end

function API.library_pending()
    return pending_library ~= nil
end

function API.finish_library(cb)
    local playlists = pending_library
    pending_library = nil
    if cb then cb(playlists or {}) end
end

local pending_tracks = nil
local pending_playlist_id = nil

function API.playlist_page(playlist_id, continuation_token, cb)
    if type(playlist_id) ~= "string" or playlist_id == "" then
        cb({ tracks = {}, next_token = nil })
        return
    end
    local pid = sanitize(playlist_id)

    local is_cont = continuation_token and continuation_token ~= ""
    local body_json
    if is_cont then
        body_json = noctalia.json.encode({ context = CONTEXT.context, continuation = continuation_token })
    else
        body_json = noctalia.json.encode({ context = CONTEXT.context, browseId = pid })
    end

    local auth, cookie = build_auth()
    local auth_header = auth and ("-H \"Authorization: " .. auth .. "\"") or ""
    local origin_header = "-H \"Origin: " .. ORIGIN .. "\""

    local tmp_payload = "/tmp/noctalia-ytmusic-payload.json"
    local tmp_out = "/tmp/noctalia-ytmusic-page.json"
    noctalia.writeFile(tmp_payload, body_json)

    local script = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
C_ARG=""
if [ -s "]=] .. COOKIE_PATH .. [=[" ]; then
  C_ARG="--cookie ]=] .. COOKIE_PATH .. [=["
fi

curl -s -X POST "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false" \
  -H "Content-Type: application/json" \
  ]=] .. origin_header .. [=[ \
  ]=] .. auth_header .. [=[ \
  $C_ARG \
  -d @"/tmp/noctalia-ytmusic-payload.json" > "/tmp/noctalia-ytmusic-raw.json"

jq '{
  tracks: [.. | .musicResponsiveListItemRenderer? | select(. != null) | {
    id: (.playlistItemData.videoId // .navigationEndpoint.watchEndpoint.videoId // ""),
    title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.id != "")],
  count_text: ([.. | .musicResponsiveHeaderRenderer? | select(. != null) | (.subtitle?.runs // []) + (.secondSubtitle?.runs // []) | .[]?.text | select(. != null and test("song|track"))] | .[0] // null),
  next_token: ([.. | (.continuationCommand?.token // .nextContinuationData?.continuation) | select(. != null and . != "")] | .[0] // null)
}' "/tmp/noctalia-ytmusic-raw.json" > "]=] .. tmp_out .. [=["
]=]

    noctalia.runAsync(script, function()
        if not noctalia.fileExists(tmp_out) then
            cb({ tracks = {}, next_token = nil })
            return
        end
        local raw = noctalia.readFile(tmp_out)
        if not raw or raw == "" then
            cb({ tracks = {}, next_token = nil })
            return
        end
        local data = noctalia.json.decode(raw)
        if type(data) == "table" then
            local tracks = type(data.tracks) == "table" and data.tracks or {}
            for _, tr in ipairs(tracks) do
                if tr.duration_text and tr.duration_text ~= "" then
                    tr.duration = fmt_seconds(tr.duration_text)
                end
                tr.artist = clean_artist(tr.artist)
            end
            local next_tok = type(data.next_token) == "string" and data.next_token ~= "" and data.next_token or nil
            local count_text = type(data.count_text) == "string" and data.count_text or ""
            local count_num = tonumber(count_text:match("(%d+)"))
            log("jq playlist page got " .. #tracks .. " tracks, next_token=" .. tostring(next_tok ~= nil) .. ", count_num=" .. tostring(count_num))
            if #tracks > 0 then
                API.attach_cached_thumbs(tracks)
            end
            cb({ tracks = tracks, next_token = next_tok, total_count = count_num })
        else
            cb({ tracks = {}, next_token = nil })
        end
    end, 15000)
end

local STREAMS_CACHE_DIR = noctalia.expandPath("~/.cache/noctalia-ytmusic/streams")

local RESOLVE_SCRIPT = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
OUT="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic/cookies.txt"
CACHE_FILE="]=] .. STREAMS_CACHE_DIR .. [=[/VIDEO.url"
if [ -s "$CACHE_FILE" ]; then
  URL=$(cat "$CACHE_FILE")
  if [ -n "$URL" ]; then
    echo "URL=$URL"
    exit 0
  fi
fi

[ -s "$OUT" ] || { echo "NOCACHE=1"; exit 0; }
URL=$(yt-dlp -f bestaudio/best -g --no-playlist --no-warnings --cookies "$OUT" "https://www.youtube.com/watch?v=VIDEO" 2>/dev/null | tail -1)
if [ -n "$URL" ]; then
  mkdir -p "]=] .. STREAMS_CACHE_DIR .. [=["
  echo "$URL" > "$CACHE_FILE"
  echo "URL=$URL"
else
  echo "ERR=1"
fi
]=]

local AUDIO_DIR = noctalia.expandPath("~/.cache/noctalia-ytmusic/audio")
local stream_cache = {}
local prefetching_ids = {}

function API.get_audio_cache_path(video_id)
    if type(video_id) ~= "string" or video_id == "" then return nil end
    local safe_id = video_id:gsub("[^%w%-_]", "_")
    local path = AUDIO_DIR .. "/" .. safe_id .. ".opus"
    if noctalia.fileExists(path) then
        return path
    end
    return nil
end

function API.get_cached_audio_ids(callback)
    local cmd = string.format("mkdir -p '%s' && ls '%s' 2>/dev/null", AUDIO_DIR, AUDIO_DIR)
    noctalia.runAsync(cmd, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local set = {}
        for id in out:gmatch("([%w%-_]+)%.opus") do
            set[id] = true
        end
        if callback then callback(set) end
    end, 5000)
end

function API.cache_audio(video_id, callback)
    if type(video_id) ~= "string" or video_id == "" then
        if callback then callback(false) end
        return
    end
    local safe_id = video_id:gsub("[^%w%-_]", "_")
    local path = AUDIO_DIR .. "/" .. safe_id .. ".opus"
    if noctalia.fileExists(path) then
        if callback then callback(true) end
        return
    end

    local cmd = string.format(
        "mkdir -p '%s' && export PATH=\"/etc/profiles/per-user/$USER/bin:$PATH\" && yt-dlp -f bestaudio -o '%s' --cookies '%s' 'https://www.youtube.com/watch?v=%s' >/dev/null 2>&1 && echo 'STATUS=OK'",
        AUDIO_DIR, path, COOKIE_PATH, video_id
    )
    noctalia.runAsync(cmd, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local ok = noctalia.fileExists(path) or out:find("STATUS=OK") ~= nil
        if callback then callback(ok) end
    end, 120000)
end

local function sanitize_str(str)
    if type(str) ~= "string" then return "" end
    return (str:gsub("[^\32-\126]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local resolving_in_flight = {}

function API.resolve_stream(video_id, cb)
    if type(video_id) ~= "string" or video_id == "" then
        if cb then cb(nil) end
        return
    end

    local local_audio = API.get_audio_cache_path(video_id)
    if local_audio then
        log("audio_disk_cache HIT for id=" .. video_id)
        if cb then cb(local_audio) end
        return
    end

    local cached = stream_cache[video_id]
    if cached and (os.time() - cached.timestamp) < 14400 then
        log("stream_cache HIT for id=" .. video_id)
        if cb then cb(cached.url) end
        return
    end

    local safe_id = video_id:gsub("[^%w%-_]", "_")
    local disk_url_path = STREAMS_CACHE_DIR .. "/" .. safe_id .. ".url"
    if noctalia.fileExists(disk_url_path) then
        local raw_disk = noctalia.readFile(disk_url_path)
        if raw_disk and #raw_disk > 20 then
            local clean_url = sanitize_str(raw_disk)
            stream_cache[video_id] = { url = clean_url, timestamp = os.time() }
            log("stream_disk_cache HIT for id=" .. video_id)
            if cb then cb(clean_url) end
            return
        end
    end

    if resolving_in_flight[video_id] then
        table.insert(resolving_in_flight[video_id], cb)
        return
    end

    resolving_in_flight[video_id] = { cb }

    log("resolving stream URL for id=" .. video_id)
    local script = RESOLVE_SCRIPT:gsub("VIDEO", safe_id)
    noctalia.runAsync(script, function(res)
        local out = type(res) == "table" and res.stdout or ""
        local raw_url = out:match("URL=([^\n\r]+)")
        local url = sanitize_str(raw_url)
        local callbacks = resolving_in_flight[video_id] or {}
        resolving_in_flight[video_id] = nil

        if url ~= "" then
            log("stream resolved successfully (" .. #url .. " bytes) for id=" .. video_id)
            stream_cache[video_id] = { url = url, timestamp = os.time() }
            for _, callback in ipairs(callbacks) do
                if callback then callback(url) end
            end
        else
            log("stream resolution failed for id=" .. video_id)
            for _, callback in ipairs(callbacks) do
                if callback then callback(nil) end
            end
        end
    end, 30000)
end

function API.prefetch_track(item)
    if type(item) ~= "table" or not item.id or item.id == "" then return end
    local id = item.id

    if item.thumbnail_url or id ~= "" then
        local url = item.thumbnail_url or ("https://i.ytimg.com/vi/" .. id .. "/hqdefault.jpg")
        API.get_thumbnail_path(id, url, nil)
    end

    if API.get_audio_cache_path(id) then return end

    local cached = stream_cache[id]
    if not cached or (os.time() - cached.timestamp) >= 7200 then
        prefetching_ids[id] = true
        log("prefetching stream URL into memory for id=" .. id)
        API.resolve_stream(id, function(url)
            prefetching_ids[id] = nil
        end)
    end
end

function API.prefetch_queue(queue, current_index)
    if type(queue) ~= "table" or #queue == 0 then return end
    current_index = current_index or 1
    -- Only prefetch 1 track ahead to prevent thread pool exhaustion and UI freezing
    for offset = 1, 1 do
        local target = queue[current_index + offset]
        if target and target.id and target.id ~= "" then
            API.prefetch_track(target)
        end
    end
end

function API.cookies_available(cb)
    cb(noctalia.fileExists(COOKIE_PATH))
end

function API.like_video(video_id, callback)
    if type(video_id) ~= "string" or video_id == "" then
        if callback then callback(false) end
        return
    end
    local safe_id = sanitize(video_id)
    local body_json = noctalia.json.encode({
        context = CONTEXT.context,
        target = { videoId = safe_id }
    })
    local auth, cookie = build_auth()
    local auth_header = auth and ("-H \"Authorization: " .. auth .. "\"") or ""
    local origin_header = "-H \"Origin: " .. ORIGIN .. "\""
    local tmp_payload = "/tmp/noctalia-ytmusic-like-payload.json"
    noctalia.writeFile(tmp_payload, body_json)

    local script = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
C_ARG=""
if [ -s "]=] .. COOKIE_PATH .. [=[" ]; then
  C_ARG="--cookie ]=] .. COOKIE_PATH .. [=["
fi

curl -s -X POST "https://music.youtube.com/youtubei/v1/like/like?prettyPrint=false" \
  -H "Content-Type: application/json" \
  ]=] .. origin_header .. [=[ \
  ]=] .. auth_header .. [=[ \
  $C_ARG \
  -d @"/tmp/noctalia-ytmusic-like-payload.json" >/dev/null 2>&1
echo "STATUS=OK"
]=]
    noctalia.runAsync(script, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local ok = out:find("STATUS=OK") ~= nil
        if callback then callback(ok) end
    end, 10000)
end

function API.unlike_video(video_id, callback)
    if type(video_id) ~= "string" or video_id == "" then
        if callback then callback(false) end
        return
    end
    local safe_id = sanitize(video_id)
    local body_json = noctalia.json.encode({
        context = CONTEXT.context,
        target = { videoId = safe_id }
    })
    local auth, cookie = build_auth()
    local auth_header = auth and ("-H \"Authorization: " .. auth .. "\"") or ""
    local origin_header = "-H \"Origin: " .. ORIGIN .. "\""
    local tmp_payload = "/tmp/noctalia-ytmusic-unlike-payload.json"
    noctalia.writeFile(tmp_payload, body_json)

    local script = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
C_ARG=""
if [ -s "]=] .. COOKIE_PATH .. [=[" ]; then
  C_ARG="--cookie ]=] .. COOKIE_PATH .. [=["
fi

curl -s -X POST "https://music.youtube.com/youtubei/v1/like/removelike?prettyPrint=false" \
  -H "Content-Type: application/json" \
  ]=] .. origin_header .. [=[ \
  ]=] .. auth_header .. [=[ \
  $C_ARG \
  -d @"/tmp/noctalia-ytmusic-unlike-payload.json" >/dev/null 2>&1
echo "STATUS=OK"
]=]
    noctalia.runAsync(script, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local ok = out:find("STATUS=OK") ~= nil
        if callback then callback(ok) end
    end, 10000)
end

function API.invalidate_playlist_cache(playlist_id)
    if type(playlist_id) ~= "string" or playlist_id == "" then return end
    local safe_id = playlist_id:gsub("[^%w%-_]", "_")
    local path = PLAYLISTS_CACHE_DIR .. "/" .. safe_id .. ".json"
    local script = string.format("rm -f '%s'", path)
    noctalia.runAsync(script, function() end, 2000)
end

local QUICK_PICKS_CACHE_PATH = CACHE_DIR .. "/quick_picks.json"

function API.load_cached_quick_picks()
    if not noctalia.fileExists(QUICK_PICKS_CACHE_PATH) then return nil end
    local raw = noctalia.readFile(QUICK_PICKS_CACHE_PATH)
    if not raw or raw == "" then return nil end
    local data = noctalia.json.decode(raw)
    if type(data) == "table" and #data > 0 then
        API.attach_cached_thumbs(data)
        return data
    end
    return nil
end

function API.save_quick_picks_cache(tracks)
    if type(tracks) ~= "table" or #tracks == 0 then return end
    local encoded = noctalia.json.encode(tracks)
    if encoded then
        noctalia.writeFile(QUICK_PICKS_CACHE_PATH, encoded)
    end
end

function API.fetch_quick_picks(callback)
    local body_json = noctalia.json.encode({ context = CONTEXT.context, browseId = "FEmusic_home" })
    local auth, cookie = build_auth()
    local auth_header = auth and ("-H \"Authorization: " .. auth .. "\"") or ""
    local origin_header = "-H \"Origin: " .. ORIGIN .. "\""

    local tmp_payload = "/tmp/noctalia-ytmusic-home-payload.json"
    local tmp_out = "/tmp/noctalia-ytmusic-quickpicks.json"
    noctalia.writeFile(tmp_payload, body_json)

    local script = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
C_ARG=""
if [ -s "]=] .. COOKIE_PATH .. [=[" ]; then
  C_ARG="--cookie ]=] .. COOKIE_PATH .. [=["
fi

curl -s -X POST "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false" \
  -H "Content-Type: application/json" \
  ]=] .. origin_header .. [=[ \
  ]=] .. auth_header .. [=[ \
  $C_ARG \
  -d @"/tmp/noctalia-ytmusic-home-payload.json" > "/tmp/noctalia-ytmusic-home-raw.json"

jq '{
  tracks: [.. | select(.musicResponsiveListItemRenderer? != null) | .musicResponsiveListItemRenderer | {
    id: (.playlistItemData.videoId // .navigationEndpoint.watchEndpoint.videoId // ""),
    title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.id != "" and .title != "")] | unique_by(.id) | .[0:20],
  mixes: [.. | select(.musicTwoRowItemRenderer? != null) | .musicTwoRowItemRenderer | {
    id: (.navigationEndpoint.browseEndpoint.browseId // .navigationEndpoint.watchEndpoint.playlistId // ""),
    title: (.title.runs[0].text // ""),
    subtitle: (.subtitle.runs[0].text // ""),
    videoId: (.navigationEndpoint.watchEndpoint.videoId // ""),
    thumbnail_url: (.thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // .thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.id != "" and .title != "" and .videoId == "" and (.id | test("^VLR")) and (.subtitle | test("[0-9]+ tracks") | not) and (.subtitle != "Album") and (.subtitle != "Playlist") and (.subtitle != "Song") and (.subtitle != "Single") and (.subtitle | endswith("subscribers") | not))] | unique_by(.id) | .[0:6]
}' "/tmp/noctalia-ytmusic-home-raw.json" > "]=] .. tmp_out .. [=[" 2>/dev/null
echo "STATUS=OK"
]=]

    noctalia.runAsync(script, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        if out:find("STATUS=OK") and noctalia.fileExists(tmp_out) then
            local raw = noctalia.readFile(tmp_out)
            local data = noctalia.json.decode(raw or "")
            local tracks = (type(data) == "table" and type(data.tracks) == "table") and data.tracks or {}
            local mixes = (type(data) == "table" and type(data.mixes) == "table") and data.mixes or {}
            if #tracks > 0 then
                API.attach_cached_thumbs(tracks)
                API.save_quick_picks_cache(tracks)
            end
            if #mixes > 0 then
                API.attach_cached_thumbs(mixes)
            end
            if callback then callback(tracks, mixes) end
        else
            if callback then callback({}, {}) end
        end
    end, 15000)
end


return API