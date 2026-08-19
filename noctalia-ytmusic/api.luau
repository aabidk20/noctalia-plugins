local API = {}

local bit = bit32

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

local sanitize = utils.Utils.sanitize
local fmt_duration = utils.Utils.fmt_duration

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

function API.search(query, count, cb, search_type)
    query = sanitize(query):gsub("^%s+", ""):gsub("%s+$", "")
    count = tonumber(count) or 25
    search_type = tostring(search_type or "songs")
    log("search query='" .. query .. "' type='" .. search_type .. "'")
    if query == "" then
        cb({})
        return
    end
    local params = "EgWKAQIIAWoQChADEAQQCRAFEAoQBRAE"
    if search_type == "playlists" then
        params = "EgWKAQIKAWoQChADEAQQCRAFEAoQBRAE"
    elseif search_type == "top" then
        params = ""
    end
    innerTube("search", {
        context = CONTEXT.context,
        query = query,
        params = params,
    }, function(raw_body, err)
        if not raw_body or raw_body == "" then
            cb(nil, err or "empty response")
            return
        end
        local raw_file = "/tmp/noctalia-ytmusic-search-raw.json"
        local clean_file = "/tmp/noctalia-ytmusic-search-clean.json"
        noctalia.writeFile(raw_file, raw_body)

        local script
        if search_type == "top" then
            script = ([=[
jq '
  ([.. | objects | select(has("musicCardShelfRenderer")) | .musicCardShelfRenderer] | .[0] // null) as $rawcard
  |
  ([
    .. | objects | select(has("musicCardShelfRenderer")) | .musicCardShelfRenderer |
    .contents[]? |
    .. | objects | select(has("musicResponsiveListItemRenderer")) |
    .musicResponsiveListItemRenderer |
    (.playlistItemData.videoId // "")
  ] | map(select(. != ""))) as $skip
  |
  ([$rawcard | select((.onTap.watchEndpoint.videoId // "") != "") | {
    id: .onTap.watchEndpoint.videoId,
    kind: "song",
    title: (.title.runs[0].text // ""),
    artist: ([.subtitle.runs[].text] | join("")),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  }] | .[0]) as $card
  |
  {
    results: reduce (
      ($card // empty),
      (.. | select(.musicResponsiveListItemRenderer? != null) | .musicResponsiveListItemRenderer |
        ((.playlistItemData.videoId // .overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId // .doubleTapCommand.watchEndpoint.videoId // "") as $vid |
         (.navigationEndpoint.browseEndpoint.browseId // "") as $bid |
         select($vid != "" or $bid != "") |
         select(($skip | index($vid)) == null) |
         {
           id: (if $vid != "" then $vid else $bid end),
           kind: (if $vid != "" then "song" else if $bid != "" then "playlist" else "other" end end),
           title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
           artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs | map(select(.text != null).text) | join("") // ""),
           album: (.flexColumns[2].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
           duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""),
           thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
         }))
    ) as $it ([]; if (map(.id) | index($it.id)) then . else . + [$it] end)
  }
' "%s" > "%s" 2>/dev/null
echo "STATUS=OK"
]=]):format(raw_file, clean_file)
        elseif search_type == "playlists" then
            script = ([=[
jq '{
  playlists: [.. | select(.musicResponsiveListItemRenderer? != null) | .musicResponsiveListItemRenderer | {
    id: (.navigationEndpoint.browseEndpoint.browseId // ""),
    title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs | map(select(.text != null).text) | join("") // ""),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.id != "" and .title != "")] | unique_by(.id)
}' "%s" > "%s" 2>/dev/null
echo "STATUS=OK"
]=]):format(raw_file, clean_file)
        else
            script = ([=[
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
        end

        noctalia.runAsync(script, function(res)
            local out = {}
            if noctalia.fileExists(clean_file) then
                local raw_clean = noctalia.readFile(clean_file)
                local data = noctalia.json.decode(raw_clean or "")
                local raw_key = (search_type == "playlists") and "playlists" or ((search_type == "top") and "results" or "tracks")
                local raw_items = (type(data) == "table" and type(data[raw_key]) == "table") and data[raw_key] or {}
                for _, tr in ipairs(raw_items) do
                    if search_type == "playlists" or (search_type == "top" and tr.kind == "playlist") then
                        table.insert(out, {
                            type = "playlist",
                            id = tr.id,
                            title = tr.title,
                            artist = clean_artist(tr.artist),
                            thumbnail_url = tr.thumbnail_url
                        })
                    else
                        table.insert(out, {
                            id = tr.id,
                            title = tr.title,
                            artist = clean_artist(tr.artist),
                            album = tr.album,
                            duration = fmt_seconds(tr.duration_text),
                            duration_text = tr.duration_text,
                            thumbnail_url = tr.thumbnail_url
                        })
                    end
                    if #out >= count then break end
                end
            end
            log(string.format("search got %d results type='%s' first='%s'", #out, search_type, tostring(out[1] and out[1].title)))
            cb(out)
        end)
    end, true)
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
    local launched = noctalia.runAsync(cmd, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local ok = noctalia.fileExists(path) or out:find("STATUS=OK") ~= nil
        if callback then callback(ok) end
    end, 120000)
    if not launched and callback then
        callback(false)
    end
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

local STATS_CACHE_DIR = noctalia.expandPath("~/.cache/noctalia-ytmusic/stats")
local STATS_TTL = 7 * 24 * 3600
local stats_cache = {}
local stats_in_flight = {}

function API.track_stats(video_id, cb)
    if type(video_id) ~= "string" or video_id == "" then
        if cb then cb() end
        return
    end

    local cached = stats_cache[video_id]
    if cached and (os.time() - cached.timestamp) < STATS_TTL then
        if cb then cb(cached.views, cached.likes) end
        return
    end

    local safe_id = video_id:gsub("[^%w%-_]", "_")
    local cache_file = STATS_CACHE_DIR .. "/" .. safe_id .. ".txt"
    if noctalia.fileExists(cache_file) then
        local raw = sanitize_str(noctalia.readFile(cache_file) or "")
        local views = tonumber(raw:match("VIEWS=(%d+)")) or 0
        local likes = tonumber(raw:match("LIKES=(%d+)")) or 0
        local fetched = tonumber(raw:match("FETCHED=(%d+)")) or 0
        if (os.time() - fetched) < STATS_TTL then
            stats_cache[video_id] = { views = views, likes = likes, timestamp = fetched }
            if cb then cb(views, likes) end
            return
        end
    end

    if stats_in_flight[video_id] then
        table.insert(stats_in_flight[video_id], cb)
        return
    end
    stats_in_flight[video_id] = { cb }

    local script = ([=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
OUT="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic/cookies.txt"
CACHE_DIR="]=] .. STATS_CACHE_DIR .. [=["
CACHE_FILE="$CACHE_DIR/VIDEO.txt"
NOW=$(date +%s)
[ -s "$OUT" ] || { echo "NOCACHE=1"; exit 0; }
LINE=$(yt-dlp --skip-download --no-playlist --no-warnings --cookies "$OUT" --print "%(view_count)s|%(like_count)s" "https://www.youtube.com/watch?v=VIDEO" 2>/dev/null | tail -1)
VIEWS=$(printf '%s' "$LINE" | cut -d'|' -f1)
LIKES=$(printf '%s' "$LINE" | cut -d'|' -f2)
case "$VIEWS" in
  ''|*[!0-9]*) VIEWS=0;;
esac
case "$LIKES" in
  ''|*[!0-9]*) LIKES=0;;
esac
mkdir -p "$CACHE_DIR"
printf 'VIEWS=%s\nLIKES=%s\nFETCHED=%s\n' "$VIEWS" "$LIKES" "$NOW" > "$CACHE_FILE"
echo "STATS=$VIEWS|$LIKES"
]=]):gsub("VIDEO", safe_id)
    noctalia.runAsync(script, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local views_likes = out:match("STATS=([%d|]+)")
        local views = 0
        local likes = 0
        if views_likes then
            local v, l = views_likes:match("^(%d*)|(%d*)$")
            views = tonumber(v) or 0
            likes = tonumber(l) or 0
        end
        if out:find("NOCACHE") then
            views, likes = 0, 0
        end
        stats_cache[video_id] = { views = views, likes = likes, timestamp = os.time() }
        local callbacks = stats_in_flight[video_id] or {}
        stats_in_flight[video_id] = nil
        for _, callback in ipairs(callbacks) do
            if callback then callback(views, likes) end
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
  } | select(.id != "" and .title != "" and .videoId == "" and (.id | test("^VL")) and (.subtitle != "Album") and (.subtitle != "Playlist") and (.subtitle != "Song") and (.subtitle != "Single") and (.subtitle | endswith("subscribers") | not))] | unique_by(.id) | .[0:24]
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
                math.randomseed(os.time() + #mixes)
                for i = #mixes, 2, -1 do
                    local j = math.random(1, i)
                    mixes[i], mixes[j] = mixes[j], mixes[i]
                end
                for i = #mixes, 7, -1 do
                    table.remove(mixes)
                end
                API.attach_cached_thumbs(mixes)
            end
            if callback then callback(tracks, mixes) end
        else
            if callback then callback({}, {}) end
        end
    end, 15000)
end


return API