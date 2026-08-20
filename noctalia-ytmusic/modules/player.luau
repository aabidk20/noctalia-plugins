local Player = {}

local store = require("./store.luau")
local api = require("../api.luau")
local logger = require("../utils/log.luau")
local mpv = require("./mpv.luau")

local state = store.state
local log = logger.module("ytm", "player")

local publish = store.publish

local last_action_time = 0

local function player_set(item, stream_url)
    state.player.title = item.title or "Unknown track"
    state.player.artist = item.artist or ""
    state.player.id = item.id or ""
    local thumb_url = item.thumbnail_url or (item.id and ("https://i.ytimg.com/vi/" .. item.id .. "/hqdefault.jpg") or nil)
    state.player.thumbnail_url = thumb_url
    state.player.thumb_path = item.thumb_path or (api and api.get_thumbnail_path and api.get_thumbnail_path(item.id, thumb_url, nil) or nil)
    state.player.duration = tonumber(item.duration) or 0
    state.player.status = "playing"
    state.player.position = 0
    state.player.codec_fetched = false
    state.player.bitrate = nil
    state.player.codec = nil
    state.player.samplerate = nil
    state.player.views = 0
    state.player.likes = 0
    state.search.pending = false

    if api and api.track_stats and item.id and item.id ~= "" then
        api.track_stats(item.id, function(views, likes)
            state.player.views = views or 0
            state.player.likes = likes or 0
            publish()
        end)
    end

    local title = item.title or "Unknown track"
    if item.artist and item.artist ~= "" then
        title = item.title .. " - " .. item.artist
    end
    noctalia.writeFile("/tmp/noctalia-ytmusic-title.txt", title)

    if api and api.cache_audio and item.id and item.id ~= "" then
        api.cache_audio(item.id)
    end

    mpv.play(stream_url, state.player.volume)
    if api and api.save_session then
        noctalia.runAsync("true", function()
            api.save_session(state.player)
        end)
    end
    publish()
end

function Player.play_index(index, queue)
    queue = queue or state.player.queue
    if #queue == 0 then return end
    index = math.max(1, math.min(index, #queue))
    state.player.queue = queue
    state.player.index = index
    local item = queue[index]
    mpv.send((noctalia.json.encode({ command = { "set_property", "pause", true } })))
    state.player.id = item.id or ""
    state.player.title = item.title or "Loading track..."
    state.player.artist = item.artist or ""
    state.player.thumbnail_url = item.thumbnail_url
    state.player.thumb_path = item.thumb_path or (api and api.get_thumbnail_path and api.get_thumbnail_path(item.id, item.thumbnail_url, nil) or nil)
    state.player.duration = tonumber(item.duration) or 0
    state.player.position = 0
    state.player.status = "loading"
    publish()

    if api and api.ensure_thumbnails then
        noctalia.runAsync("true", function()
            api.ensure_thumbnails(state.player.queue, publish, "queue")
        end)
    end
    log("play_index: " .. index .. "/" .. #queue .. " id=" .. tostring(item.id) .. " title='" .. tostring(item.title) .. "'")

    if api and api.prefetch_queue then
        api.prefetch_queue(queue, index)
    elseif api and api.prefetch_track then
        if queue[index + 1] then api.prefetch_track(queue[index + 1]) end
        if queue[index + 2] then api.prefetch_track(queue[index + 2]) end
    end

    api.resolve_stream(item.id, function(url)
        if not url or url == "" then
            state.player.status = "stopped"
            state.status_text = "Could not resolve stream for " .. tostring(item.title)
            publish()
            log("play_index: stream resolve FAILED for '" .. tostring(item.title) .. "'")
            return
        end
        log("play_index: stream resolved (" .. #url .. " chars), dispatching to mpv")
        player_set(item, url)
    end)
end

function Player.play(item)
    table.insert(state.player.queue, {
        id = item.id,
        title = item.title,
        artist = item.artist or "",
        duration = tonumber(item.duration) or 0,
        thumbnail_url = item.thumbnail_url,
        thumb_path = item.thumb_path
    })
    Player.play_index(#state.player.queue)
end

function Player.play_next(item)
    if not item or not item.id or item.id == "" then return end
    local insert_at
    if state.player.index > 0 and #state.player.queue > 0 then
        insert_at = math.min(state.player.index + 1, #state.player.queue + 1)
    else
        insert_at = #state.player.queue + 1
    end
    table.insert(state.player.queue, insert_at, {
        id = item.id,
        title = item.title,
        artist = item.artist or "",
        duration = tonumber(item.duration) or 0,
        thumbnail_url = item.thumbnail_url,
        thumb_path = item.thumb_path
    })
    log("play_next: inserted '" .. tostring(item.title) .. "' at queue position " .. insert_at)
    if state.player.status == "stopped" then
        Player.play_index(insert_at)
    else
        publish()
    end
end

function Player.stop()
    mpv.kill()
    state.player.status = "stopped"
    state.player.queue = {}
    state.player.index = 0
    state.player.title = ""
    state.player.artist = ""
    state.player.position = 0
    state.player.duration = 0
    publish()
end

function Player.toggle()
    last_action_time = os.time()
    if state.player.status == "playing" then
        mpv.send((noctalia.json.encode({ command = { "set_property", "pause", true } })))
        state.player.status = "paused"
        publish()
    elseif state.player.status == "paused" then
        noctalia.runAsync([[
            SOCK="${XDG_RUNTIME_DIR:-/tmp}/noctalia-ytmusic-mpv.sock"
            [ -S "$SOCK" ] && echo "YES" || echo "NO"
        ]], function(res)
            if res and res.stdout and res.stdout:find("YES") then
                mpv.send((noctalia.json.encode({ command = { "set_property", "pause", false } })))
                state.player.status = "playing"
                publish()
            else
                if #state.player.queue > 0 then
                    local idx = state.player.index > 0 and state.player.index or 1
                    Player.play_index(idx)
                elseif state.player.id and state.player.id ~= "" then
                    Player.play(state.player)
                end
            end
        end)
    elseif state.player.status == "stopped" or state.player.status == "idle" then
        if #state.player.queue > 0 then
            local idx = state.player.index > 0 and state.player.index or 1
            Player.play_index(idx)
        elseif state.player.id and state.player.id ~= "" then
            Player.play(state.player)
        end
    end
end

function Player.next(is_natural_end)
    if #state.player.queue == 0 then return end

    if is_natural_end and state.player.repeat_mode == "one" then
        log("next: repeat_mode=one, looping track id=" .. tostring(state.player.id))
        mpv.send((noctalia.json.encode({ command = { "set_property", "pause", false } })))
        mpv.send((noctalia.json.encode({ command = { "seek", 0, "absolute" } })))
        state.player.position = 0
        state.player.status = "playing"
        publish()
        return
    end

    if state.player.shuffle and #state.player.queue > 1 then
        math.randomseed(os.time())
        local rand_idx = math.random(1, #state.player.queue)
        if rand_idx == state.player.index then
            rand_idx = (rand_idx % #state.player.queue) + 1
        end
        Player.play_index(rand_idx)
        return
    end

    local next_idx = state.player.index + 1
    if next_idx > #state.player.queue then
        if state.player.repeat_mode == "all" then
            next_idx = 1
        else
            state.player.status = "stopped"
            publish()
            return
        end
    end
    Player.play_index(next_idx)
end

function Player.prev()
    if #state.player.queue == 0 then return end
    if state.player.position > 3 then
        mpv.send((noctalia.json.encode({ command = { "seek", 0, "absolute" } })))
        state.player.position = 0
        publish()
    else
        local prev_idx = state.player.index - 1
        if prev_idx < 1 then
            prev_idx = #state.player.queue
        end
        Player.play_index(prev_idx)
    end
end

function Player.seek(seconds)
    local val = tonumber(seconds)
    if not val then return end
    last_action_time = os.time()
    local dur = tonumber(state.player.duration) or 0
    local sec = val
    if dur > 1 and val >= 0 and val <= 1.0 then
        sec = val * dur
    end
    if dur > 0 then
        sec = math.max(0, math.min(sec, dur))
    else
        sec = math.max(0, sec)
    end
    log("seek: raw=" .. tostring(seconds) .. " resolved=" .. tostring(sec) .. " dur=" .. tostring(dur))
    state.player.position = sec
    publish()
    mpv.send((noctalia.json.encode({ command = { "seek", sec, "absolute" } })))
end

function Player.volume(value)
    value = tonumber(value) or 100
    state.player.volume = math.max(0, math.min(100, value))
    if state.player.volume > 0 then
        state.player.last_volume = state.player.volume
    end
    mpv.send((noctalia.json.encode({ command = { "set_property", "volume", state.player.volume } })))
    publish()
end

function Player.mute()
    if (state.player.volume or 0) > 0 then
        state.player.last_volume = state.player.volume
        Player.volume(0)
    else
        Player.volume(state.player.last_volume or 70)
    end
end

function Player.toggle_shuffle()
    state.player.shuffle = not state.player.shuffle
    log("toggle_shuffle: " .. tostring(state.player.shuffle))
    publish()
end

function Player.cycle_repeat()
    local current = state.player.repeat_mode or "off"
    if current == "off" then
        state.player.repeat_mode = "all"
    elseif current == "all" then
        state.player.repeat_mode = "one"
    else
        state.player.repeat_mode = "off"
    end
    log("cycle_repeat: " .. tostring(state.player.repeat_mode))
    publish()
end

function Player.append_to_queue(track)
    table.insert(state.player.queue, track)
end

function Player.restore_session(sess)
    state.player.id = sess.id
    state.player.title = sess.title or ""
    state.player.artist = sess.artist or ""
    state.player.thumbnail_url = sess.thumbnail_url
    state.player.thumb_path = sess.thumb_path
    state.player.duration = sess.duration or 0
    state.player.position = sess.position or 0
    state.player.volume = sess.volume or 70
    state.player.index = sess.index or 0
    state.player.queue = type(sess.queue) == "table" and sess.queue or {}
    state.player.status = "paused"
    log("session restored: '" .. state.player.title .. "' queue=" .. #state.player.queue)
    if api and api.track_stats and sess.id and sess.id ~= "" then
        api.track_stats(sess.id, function(views, likes)
            state.player.views = views or 0
            state.player.likes = likes or 0
            publish()
        end)
    end
end

function Player.poll()
    mpv.poll(function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        log("poll output: " .. out:gsub("\n", " "))
        if out:find("NOMPV=1") then
            if state.player.status == "playing" then
                state.player.status = "paused"
                publish()
            end
            return
        end
        local changed = false
        local pos = tonumber(out:match("POS=([^\n]+)") or "") or nil
        local dur = tonumber(out:match("DUR=([^\n]+)") or "") or nil
        if state.player.status ~= "loading" then
            if pos and pos ~= state.player.position then
                state.player.position = pos
                changed = true
            end
            if dur and dur ~= state.player.duration then
                state.player.duration = dur
                changed = true
            end
        end
        if (os.time() - last_action_time) >= 2 then
            local pause = out:match("PAUSE=([^\n]+)")
            if pause ~= nil then
                local paused = (pause == "true" or pause == "1")
                if paused and state.player.status == "playing" then
                    state.player.status = "paused"
                    changed = true
                elseif not paused and state.player.status == "paused" then
                    state.player.status = "playing"
                    changed = true
                end
            end
        end
        if not state.player.codec_fetched then
            local bitrate = out:match("BITRATE=([^\n]+)")
            local codec = out:match("CODEC=([^\n]+)")
            local rate = out:match("RATE=([^\n]+)")
            if codec or bitrate then
                state.player.bitrate = tonumber(bitrate) or 256000
                state.player.codec = codec or "opus"
                state.player.samplerate = tonumber(rate) or 48000
                state.player.codec_fetched = true
                changed = true
            end
        end
        if changed then
            publish()
        end
        local dur_pos = (state.player.duration or 0) - (state.player.position or 0)
        if dur_pos > 0 and dur_pos < 5.0 then
            log("poll check: status=" .. tostring(state.player.status) .. " dur=" .. tostring(state.player.duration) .. " pos=" .. tostring(state.player.position) .. " dur_pos=" .. tostring(dur_pos) .. " eof=" .. tostring(out:find("eof-reached") ~= nil))
        end
        if (state.player.status == "playing" or (state.player.status == "paused" and out:find("eof-reached")))
            and state.player.duration > 0
            and state.player.position > 0
            and (state.player.duration - state.player.position) < 2.0 then
            log("poll: condition met, calling next(true)")
            Player.next(true)
        elseif state.player.status == "playing"
            and state.player.duration > 0
            and state.player.position > 0
            and (state.player.duration - state.player.position) < 1.5 then
            log("poll: condition met, calling next(true)")
            Player.next(true)
        end
    end)
end

return Player