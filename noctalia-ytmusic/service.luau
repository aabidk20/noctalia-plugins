local REQ_KEY = "noctalia_ytmusic.request"

local api = require("./api.luau")
local store = require("./modules/store.luau")
local state = store.state

local handled_nonce = 0

local logger = require("./log.luau")
local log = logger.module("ytm", "service")

-- Domain logic lives in dedicated backend modules under modules/.
-- Service keeps the wiring: logging, and request dispatch.
local auth = require("./modules/auth.luau")
local home = require("./modules/home.luau")
local library = require("./modules/library.luau")
local mpv = require("./modules/mpv.luau")
local player = require("./modules/player.luau")
local downloader = require("./modules/downloader.luau")

noctalia.state.watch(REQ_KEY, function(req)
    if type(req) ~= "table" or not req.nonce or req.nonce <= handled_nonce then return end
    handled_nonce = req.nonce
    log("request nonce=" .. req.nonce .. " action=" .. tostring(req.action))

    if req.action == "extract" then
        auth.extract_cookies(req.browser)
    elseif req.action == "open_login" then
        auth.open_login(req.browser)
    elseif req.action == "search" then
        if api and api.search then
            local stype = (req.type == "playlists" or req.type == "top") and req.type or "songs"
            state.search.pending = true
            state.search.query = tostring(req.query or "")
            state.search.type = stype
            store.publish()
            api.search(state.search.query, 25, function(results)
                state.search.pending = false
                state.search.results = results or {}
                store.publish()
                noctalia.runAsync("true", function()
                    api.ensure_thumbnails(state.search.results, store.publish, "search")
                end)
            end, stype)
        end
    elseif req.action == "play" then
        log("play: id=" .. tostring(req.item and req.item.id) .. " title='" .. tostring(req.item and req.item.title) .. "'")
        player.play(req.item or {})
    elseif req.action == "play_next" then
        player.play_next(req.item or {})
    elseif req.action == "play_queue_index" then
        player.play_index(req.index or 1)
elseif req.action == "play_with_queue" then
        if req.queue and #req.queue > 0 then
            if req.source_playlist and req.source_playlist ~= "" then
                local spid = tostring(req.source_playlist)
                local is_library = false
                for _, pl in ipairs(state.library) do
                    if tostring(pl.id or "") == spid then is_library = true break end
                end
                if not is_library then
                    library.remember_playlist(spid, state.playlist.title or "Playlist")
                end
            end
            state.player.source_playlist = req.source_playlist
            player.play_index(req.index or 1, req.queue)
        elseif req.item then
            player.play(req.item)
        end
    elseif req.action == "play_playlist" then
        local pid = req.id or req.playlist_id
        if pid and pid ~= "" then
            state.playlist.id = pid
            state.playlist.title = tostring(req.title or "Playlist")
            local cached = api and api.load_cached_playlist and api.load_cached_playlist(pid)
            if cached and #cached > 0 then
                state.playlist.tracks = cached
                player.play_index(1, cached)
            else
                state.playlist.tracks = {}
            end
            store.publish()
            if api and api.playlist_tracks then
                api.playlist_tracks(pid)
            end
        end
    elseif req.action == "refresh_playlist" then
        local pid = req.id or req.playlist_id or state.playlist.id
        if pid and pid ~= "" then
            state.playlist.id = pid
            state.playlist.tracks = {}
            state.playlist.next_token = nil
            state.playlist.fetching = true
            store.publish()
            if api and api.playlist_page then
                api.playlist_page(pid, nil, function(res)
                    state.playlist.fetching = false
                    state.playlist.next_token = res.next_token
                    state.playlist.tracks = res.tracks or {}
                    if api.save_playlist_cache then
                        noctalia.runAsync("true", function()
                            api.save_playlist_cache(pid, state.playlist.tracks)
                        end)
                    end
                    store.publish()
                    if api and api.ensure_thumbnails then
                        noctalia.runAsync("true", function()
                            api.ensure_thumbnails(state.playlist.tracks, store.publish, "playlist")
                        end)
                    end
                end)
            end
        end
    elseif req.action == "toggle_like" then
        local vid = req.id or req.video_id or state.player.id
        log("toggle_like: vid=" .. tostring(vid) .. " current=" .. tostring(state.liked_ids and state.liked_ids[vid]))
        if vid and vid ~= "" then
            if api and api.invalidate_playlist_cache then
                api.invalidate_playlist_cache("VLLM")
            end
            if state.liked_ids[vid] then
                state.liked_ids[vid] = nil
                log("toggle_like: unliking vid=" .. tostring(vid))
                store.publish()
                if api and api.unlike_video then
                    api.unlike_video(vid, function(ok) end)
                end
            else
                state.liked_ids[vid] = true
                log("toggle_like: liking vid=" .. tostring(vid))
                store.publish()
                if api and api.like_video then
                    api.like_video(vid, function(ok) end)
                end
            end
        end
    elseif req.action == "toggle_shuffle" then
        player.toggle_shuffle()
    elseif req.action == "refresh_quick_picks" then
        if api and api.fetch_quick_picks then
            api.fetch_quick_picks(function(qp, mixes)
                if type(qp) == "table" and #qp > 0 then
                    state.quick_picks = qp
                end
                if type(mixes) == "table" and #mixes > 0 then
                    state.home_mixes = mixes
                end
                store.publish()
                home.fetch_home_thumbs()
            end)
        end
    elseif req.action == "cycle_repeat" then
        player.cycle_repeat()
    elseif req.action == "download_track" then
        local vid = req.id or req.video_id
        if vid and vid ~= "" then
            log("download_track: queued for id=" .. tostring(vid))
            downloader.enqueue(vid, "")
        end
    elseif req.action == "download_playlist" then
        local plid = tostring(state.playlist.id or "")
        local queued = 0
        if api and api.cache_audio and type(state.playlist.tracks) == "table" then
            for _, tr in ipairs(state.playlist.tracks) do
                if tr.id and tr.id ~= "" then
                    downloader.enqueue(tr.id, plid)
                    queued = queued + 1
                end
            end
        end
        if queued > 0 then
            store.publish()
        end
        log("download_playlist: queued " .. queued .. " tracks")
    elseif req.action == "open_playlist" then
        local pid = req.id or req.playlist_id
        if pid and pid ~= "" then
            state.playlist.id = pid
            state.playlist.title = tostring(req.title or "Playlist")
            
            local cached = api and api.load_cached_playlist and api.load_cached_playlist(pid)
            if cached and #cached > 0 then
                state.playlist.tracks = cached
                if pid == "VLLM" then library.sync_liked_tracks(cached) end
            else
                state.playlist.tracks = {}
            end

            state.playlist.next_token = nil
            state.playlist.fetching = true
            store.publish()

            if api and api.playlist_page then
                api.playlist_page(pid, nil, function(res)
                    state.playlist.fetching = false
                    state.playlist.next_token = res.next_token
                    if res.total_count and res.total_count > 0 then
                        state.playlist.count = res.total_count
                    end
                    if res.tracks and #res.tracks > 0 then
                        if pid == "VLLM" then library.sync_liked_tracks(res.tracks) end
                        local existing = {}
                        local merged = {}
                        for _, tr in ipairs(res.tracks) do
                            if tr.id and not existing[tr.id] then
                                table.insert(merged, tr)
                                existing[tr.id] = true
                            end
                        end
                        for _, tr in ipairs(state.playlist.tracks) do
                            if tr.id and not existing[tr.id] then
                                table.insert(merged, tr)
                                existing[tr.id] = true
                            end
                        end
                        state.playlist.tracks = merged
                    end
                    store.publish()
                    noctalia.runAsync("true", function()
                        if api.save_playlist_cache then
                            api.save_playlist_cache(pid, state.playlist.tracks)
                        end
                    end)
                    noctalia.runAsync("true", function()
                        if api and api.ensure_thumbnails then
                            api.ensure_thumbnails(state.playlist.tracks, store.publish, "playlist")
                        end
                    end)
                end)
            end
        end
    elseif req.action == "fetch_next_page" then
        local pid = req.playlist_id or state.playlist.id
        local token = req.token or state.playlist.next_token
        if pid and token and token ~= "" and not state.playlist.fetching then
            state.playlist.fetching = true
            log("fetch_next_page for pid='" .. pid .. "'")
            if api and api.playlist_page then
                local function do_fetch(fetch_token)
                    api.playlist_page(pid, fetch_token, function(res)
                        local existing = {}
                        for _, t in ipairs(state.playlist.tracks) do
                            if t.id then existing[t.id] = true end
                        end

                        local added_count = 0
                        local queue_sync = (state.player.source_playlist == pid)
                        if res.tracks and #res.tracks > 0 then
                            for _, tr in ipairs(res.tracks) do
                                if tr.id and not existing[tr.id] then
                                    table.insert(state.playlist.tracks, tr)
                                    if queue_sync then
                                        player.append_to_queue(tr)
                                    end
                                    existing[tr.id] = true
                                    added_count = added_count + 1
                                end
                            end
                        end

                        local new_token = res.next_token
                        local token_valid = (new_token and new_token ~= "" and new_token ~= fetch_token)

                        if added_count == 0 and token_valid then
                            log("fetch_next_page: all duplicates, skipping to next page")
                            noctalia.runAsync("true", function()
                                do_fetch(new_token)
                            end)
                            return
                        end

                        if not token_valid then
                            state.playlist.next_token = nil
                        else
                            state.playlist.next_token = new_token
                        end

                        state.playlist.fetching = false
                        log("fetch_next_page: added " .. added_count .. " new tracks (total " .. #state.playlist.tracks .. "), next_token=" .. tostring(state.playlist.next_token ~= nil))
                        store.publish()
                        noctalia.runAsync("true", function()
                            if api.save_playlist_cache then
                                api.save_playlist_cache(pid, state.playlist.tracks)
                            end
                        end)
                        noctalia.runAsync("true", function()
                            if api and api.ensure_thumbnails then
                                api.ensure_thumbnails(state.playlist.tracks, store.publish, "playlist")
                            end
                        end)
                    end)
                end
                do_fetch(token)
            end
        end
    elseif req.action == "toggle" then
        player.toggle()
    elseif req.action == "next" then
        player.next()
    elseif req.action == "prev" then
        player.prev()
    elseif req.action == "seek" then
        player.seek(req.seconds or req.value or req.position)
    elseif req.action == "volume" then
        player.volume(req.value)
    elseif req.action == "toggle_mute" then
        player.mute()
    elseif req.action == "stop" then
        player.stop()
    elseif req.action == "prefetch" then
        if api and api.prefetch_track and req.item then
            api.prefetch_track(req.item)
        end
    elseif req.action == "fetch_cache_stats" then
        noctalia.runAsync([[
            CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic"
            [ -d "$CACHE" ] || exit 0
            du -sh "$CACHE"/audio "$CACHE"/streams "$CACHE"/thumbnails "$CACHE"/playlists 2>/dev/null | awk '{print $1"|"$2}'
        ]], function(res)
            if type(res) ~= "table" or not res.stdout then return end
            state.cache_stats = {}
            for line in res.stdout:gmatch("[^\r\n]+") do
                local size, path = line:match("([^|]+)|(.+)")
                if size and path then
                    local name = path:match("([^/]+)$")
                    if name then
                        state.cache_stats[name] = size
                    end
                end
            end
            store.publish()
        end)
    elseif req.action == "clear_cache" and req.target then
        noctalia.runAsync(([[
            CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic"
            rm -rf "$CACHE/%s"/*
        ]]):format(req.target), function()
            -- After clearing, fetch the stats directly
            noctalia.runAsync([[
                CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic"
                [ -d "$CACHE" ] || exit 0
                du -sh "$CACHE"/audio "$CACHE"/streams "$CACHE"/thumbnails "$CACHE"/playlists 2>/dev/null | awk '{print $1"|"$2}'
            ]], function(res)
                if type(res) ~= "table" or not res.stdout then return end
                state.cache_stats = {}
                for line in res.stdout:gmatch("[^\r\n]+") do
                    local size, path = line:match("([^|]+)|(.+)")
                    if size and path then
                        local name = path:match("([^/]+)$")
                        if name then
                            state.cache_stats[name] = size
                        end
                    end
                end
                store.publish()
            end)
        end)
    elseif req.action == "toggle_autoplay" then
        state.settings.autoplay = not state.settings.autoplay
        store.publish()
    end
end)

function update()
    player.poll()
    if api.library_pending() then
        api.finish_library(function(playlists)
            state.library = type(playlists) == "table" and playlists or {}
            store.publish()
            if type(playlists) == "table" then
                log("ytmusic: loaded " .. #playlists .. " library playlists")
                noctalia.runAsync("true", function()
                    api.ensure_thumbnails(state.library, store.publish, "library")
                end)
            else
                log("ytmusic: library decode failed")
            end
        end)
    end
end

noctalia.setUpdateInterval(1000)

log("boot: service started, api=" .. tostring(type(api)) .. " library=" .. tostring(type(api and api.library)))
mpv.kill()
auth.detect_browsers()
auth.load_cached_cookies()
if api and api.load_cached_library then
    local cached_lib = api.load_cached_library()
    if cached_lib then
        state.library = cached_lib
    end
end
if api and api.load_cached_recent_playlists then
    local cached_recent = api.load_cached_recent_playlists()
    if cached_recent then
        state.recent_playlists = cached_recent
    end
end
if api and api.load_session then
    local sess = api.load_session()
    if type(sess) == "table" and sess.id and sess.id ~= "" then
        player.restore_session(sess)
    end
end
if api and api.library then
    api.library()
end
store.publish()

function onStop()
    if api and api.save_session then
        api.save_session(state.player)
    end
end