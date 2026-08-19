local API = {}

local utils = require("./utils.luau")

local const = require("./api/constants.luau")
local COOKIE_PATH = const.COOKIE_PATH

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

local extract_thumb_url = utils.Utils.extract_thumb_url

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
-- thumbnail helpers live in ./api/thumbnails.luau
for k, v in pairs(require("./api/thumbnails.luau")) do
    API[k] = v
end
-- like/unlike endpoints live in ./api/likes.luau
for k, v in pairs(require("./api/likes.luau")) do
    API[k] = v
end
-- on-disk cache read/write lives in ./api/cache.luau
for k, v in pairs(require("./api/cache.luau")(API)) do
    API[k] = v
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


return API