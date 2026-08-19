local API = {}

local logger = require("./log.luau")
local function log(msg) logger.log("ytapi", msg) end

local utils = require("./utils.luau")

local it = require("./api/innerTube.luau")
local KEY = it.KEY
local BASE = it.BASE
local ORIGIN = it.ORIGIN
local COOKIE_PATH = it.COOKIE_PATH
local CONTEXT = it.CONTEXT
local build_auth = it.build_auth
local innerTube = it.innerTube

-- ----------------------------------------------------------------------------
-- helpers
-- ----------------------------------------------------------------------------

local fmt_duration = utils.Utils.fmt_duration
local fmt_seconds = utils.Utils.fmt_seconds
local clean_artist = utils.Utils.clean_artist

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

local extract_thumb_url = utils.Utils.extract_thumb_url

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
-- auth + request (sha1, build_auth, innerTube, CONTEXT live in ./api/innerTube.luau)

-- ----------------------------------------------------------------------------
-- public API
-- ----------------------------------------------------------------------------

-- search endpoint lives in ./api/search.luau
API.search = require("./api/search.luau").search
-- like/unlike endpoints live in ./api/likes.luau
for k, v in pairs(require("./api/likes.luau")) do
    API[k] = v
end

local CACHE_DIR = noctalia.expandPath(XDG_CACHE and XDG_CACHE ~= "" and XDG_CACHE or "~/.cache") .. "/noctalia-ytmusic"
local LIBRARY_CACHE_PATH = CACHE_DIR .. "/library.json"
local RECENT_PLAYLISTS_CACHE_PATH = CACHE_DIR .. "/recent_playlists.json"
local PLAYLISTS_CACHE_DIR = CACHE_DIR .. "/playlists"

function API.load_cached_recent_playlists()
    if not noctalia.fileExists(RECENT_PLAYLISTS_CACHE_PATH) then return nil end
    local raw = noctalia.readFile(RECENT_PLAYLISTS_CACHE_PATH)
    if not raw or raw == "" then return nil end
    local data, _ = noctalia.json.decode(raw)
    if type(data) == "table" and #data > 0 then
        return data
    end
    return nil
end

function API.save_recent_playlists_cache(playlists)
    if type(playlists) ~= "table" or #playlists == 0 then return end
    local encoded = noctalia.json.encode(playlists)
    if encoded then
        noctalia.writeFile(RECENT_PLAYLISTS_CACHE_PATH, encoded)
        log("saved " .. #playlists .. " playlists to recent_playlists cache")
    end
end

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

-- browse/home/library endpoints live in ./api/browse.luau
for k, v in pairs(require("./api/browse.luau")(API)) do
    API[k] = v
end
-- stream resolution, audio cache, stats, prefetch live in ./api/resolve.luau
for k, v in pairs(require("./api/resolve.luau")(API)) do
    API[k] = v
end

function API.cookies_available(cb)
    cb(noctalia.fileExists(COOKIE_PATH))
end

-- like/unlike endpoints live in ./api/likes.luau

function API.invalidate_playlist_cache(playlist_id)
    if type(playlist_id) ~= "string" or playlist_id == "" then return end
    local safe_id = playlist_id:gsub("[^%w%-_]", "_")
    local path = PLAYLISTS_CACHE_DIR .. "/" .. safe_id .. ".json"
    local script = string.format("rm -f '%s'", path)
    noctalia.runAsync(script, function() end, 2000)
end


return API