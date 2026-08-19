--!strict

local logger = require("../log.luau")
local function log(msg) logger.log("ytapi", msg) end

local utils = require("../utils.luau")
local sanitize = utils.Utils.sanitize
local clean_artist = utils.Utils.clean_artist
local fmt_seconds = utils.Utils.fmt_seconds

local it = require("./innerTube.luau")
local innerTube = it.innerTube
local CONTEXT = it.CONTEXT

local EXPO = {}

function EXPO.search(query: string?, count: any, cb: (any?, string?) -> (), search_type: string?)
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

return EXPO