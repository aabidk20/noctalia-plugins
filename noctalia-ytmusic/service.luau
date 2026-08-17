local STATE = "noctalia_ytmusic.state"
local REQ = "noctalia_ytmusic.request"

local api = require("./api.luau")

local BROWSERS = {
    { id = "chrome", label = "Chrome" },
    { id = "chromium", label = "Chromium" },
    { id = "firefox", label = "Firefox" },
    { id = "edge", label = "Edge" },
    { id = "brave", label = "Brave" },
    { id = "opera", label = "Opera" },
    { id = "vivaldi", label = "Vivaldi" },
    { id = "whale", label = "Whale" },
    { id = "zen", label = "Zen" }
}

local handled_nonce = 0
local extraction_active = false
local playlist_wants_play = false

local state = {
    status = "idle",
    status_text = "Not logged in",
    browser = nil,
    browser_label = "",
    temp_dir = "",
    cookies_path = "",
    cookie_count = 0,
    available = {},
    extracting = false,
    last_error = "",
    player = {
        status = "stopped",
        title = "",
        artist = "",
        id = "",
        position = 0,
        duration = 0,
        volume = 100,
        queue = {},
        index = 0,
        shuffle = false,
        repeat_mode = "off"
    },
    search = {
        query = "",
        results = {},
        pending = false
    },
    cache_stats = {},
    settings = {
        autoplay = true
    },
    library = {},
    playlist = {
        id = "",
        title = "",
        tracks = {}
    },
    liked_ids = {},
    cached_audio_ids = {},
    downloaded_playlist_ids = {},
    quick_picks = {},
    home_mixes = {}
}

local publish
local audit_downloaded_playlists

local function sync_audio_cache()
    if api and api.get_cached_audio_ids then
        api.get_cached_audio_ids(function(set)
            if type(set) == "table" then
                state.cached_audio_ids = set
                audit_downloaded_playlists()
                publish()
            end
        end)
    end
end

audit_downloaded_playlists = function()
    if not api or not api.load_cached_playlist then return end
    state.downloaded_playlist_ids = {}
    for _, pl in ipairs(state.library) do
        local pid = tostring(pl.id or "")
        if pid ~= "" then
            local tracks = api.load_cached_playlist(pid)
            if tracks and #tracks > 0 and type(state.cached_audio_ids) == "table" then
                local all_dl = true
                for _, tr in ipairs(tracks) do
                    if tr.id and not state.cached_audio_ids[tr.id] then
                        all_dl = false
                        break
                    end
                end
                if all_dl then
                    state.downloaded_playlist_ids[pid] = true
                end
            end
        end
    end
end

publish = function()
    local snap = {}
    for k, v in pairs(state) do snap[k] = v end
    -- Only shallow-copy the actively-mutated tables (player, playlist)
    if type(state.player) == "table" then
        snap.player = {}
        for k, v in pairs(state.player) do snap.player[k] = v end
    end
    if type(state.playlist) == "table" then
        snap.playlist = {}
        for k, v in pairs(state.playlist) do snap.playlist[k] = v end
    end
    -- Pass direct references for large, rarely-changing lookup tables
    snap.liked_ids = state.liked_ids
    snap.cached_audio_ids = state.cached_audio_ids
    snap.downloaded_playlist_ids = state.downloaded_playlist_ids
    snap.quick_picks = state.quick_picks
    snap.home_mixes = state.home_mixes
    snap.cache_stats = state.cache_stats
    snap.settings = state.settings
    noctalia.state.set(STATE, snap)
end

local logger = require("./log.luau")
local function log(msg) logger.log("ytm", msg) end

local function browser_label(id)
    for _, b in ipairs(BROWSERS) do
        if b.id == id then return b.label end
    end
    return id or "Browser"
end

local OPEN_SCRIPT = [=[
open_browser() {
  case "$1" in
    chrome)   B="google-chrome"; command -v google-chrome-stable >/dev/null 2>&1 && B="google-chrome-stable" ;;
    chromium) B="chromium" ;;
    firefox)  B="firefox" ;;
    edge)     B="microsoft-edge" ;;
    brave)    B="brave-browser" ;;
    opera)    B="opera" ;;
    vivaldi)  B="vivaldi" ;;
    whale)    B="whale" ;;
    zen)      B="zen" ;;
    *)        B="" ;;
  esac
  if [ -n "$B" ] && command -v "$B" >/dev/null 2>&1; then
    "$B" "https://music.youtube.com" >/dev/null 2>&1 &
  else
    xdg-open "https://music.youtube.com" >/dev/null 2>&1 &
  fi
}
]=]

local function open_login(browser)
    local target = (type(browser) == "string" and browser ~= "") and browser or "default"
    noctalia.runAsync(OPEN_SCRIPT .. "\nopen_browser " .. target, function() end, 5000)
end

local ZEN_CFB = [=[
ZEN_P=$(awk -F= '/^Path=/{p=substr($0,6)} /^Default=1/{print p; exit}' "$HOME/.zen/profiles.ini" 2>/dev/null)
if [ -z "$ZEN_P" ]; then
  for d in "$HOME/.zen"/*/; do
    [ -d "$d" ] && [ -f "${d}places.sqlite" ] && { ZEN_P=$(basename "$d"); break; }
  done
fi
case "$ZEN_P" in
  /*) CFB="firefox:$ZEN_P" ;;
  *)  CFB="firefox:$HOME/.zen/$ZEN_P" ;;
esac
]=]

local EXTRACT_SCRIPT = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
TMPD=$(mktemp -d /tmp/noctalia-ytmusic.XXXXXX 2>/dev/null)
[ -n "$TMPD" ] || { TMPD=/tmp/noctalia-ytmusic; mkdir -p "$TMPD"; }
RAW="$TMPD/raw_BROWSER.txt"
OUT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/cookies.txt"
CFB_ARG
LOG=$(timeout 45 yt-dlp --cookies-from-browser "$CFB" --cookies "$RAW" --skip-download --no-warnings --no-playlist "https://music.youtube.com" 2>&1 | tr '\n' ' ')
grep -iE '^#|(youtube\.com|youtu\.be|youtube-nocookie\.com|ytimg\.com|googlevideo\.com|yt\.be|youtubeeducation\.com)' "$RAW" > "$OUT" 2>/dev/null
TOTAL=$(grep -vc '^#' "$RAW" 2>/dev/null || echo 0)
KEPT=$(grep -vc '^#' "$OUT" 2>/dev/null || echo 0)
rm -rf "$TMPD"
echo "DIR=$OUT_DIR"
echo "RAW=$RAW"
echo "OUT=$OUT"
echo "TOTAL=$TOTAL"
echo "KEPT=$KEPT"
echo "LOG=$LOG"
]=]

local function extract_cookies(browser)
    if extraction_active then return end
    if type(browser) ~= "string" or browser == "" then return end
    local label = browser_label(browser)
    extraction_active = true
    state.extracting = true
    state.browser = browser
    state.browser_label = label
    state.status = "extracting"
    state.status_text = "Extracting cookies from " .. label .. "..."
    state.last_error = ""
    publish()

    local cfb_line = 'CFB="' .. browser .. '"'
    if browser == "zen" then
        cfb_line = ZEN_CFB
    end
    local cmd = (EXTRACT_SCRIPT:gsub("BROWSER", browser):gsub("CFB_ARG", cfb_line))
    noctalia.runAsync(cmd, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local dir = out:match("DIR=([^\n]+)") or ""
        local cookies = out:match("OUT=([^\n]+)") or ""
        local total = tonumber(out:match("TOTAL=([^\n]+)") or "0") or 0
        local kept = tonumber(out:match("KEPT=([^\n]+)") or "0") or 0
        local log = out:match("LOG=([^\n]*)") or ""

        extraction_active = false
        state.extracting = false

        if kept > 0 then
            state.status = "ready"
            state.temp_dir = dir
            state.cookies_path = cookies
            state.cookie_count = kept
            state.last_error = ""
            state.status_text = string.format("Saved %d YouTube cookies from %s (filtered %d others)",
                kept, label, math.max(0, total - kept))
            if noctalia.notify then
                noctalia.notify("Noctalia YT Music", state.status_text)
            end
            if api and api.library then
                api.library()
            end
            if api and api.fetch_quick_picks then
                api.fetch_quick_picks(function(qp, mixes)
                    if type(qp) == "table" and #qp > 0 then
                        state.quick_picks = qp
                    end
                    if type(mixes) == "table" and #mixes > 0 then
                        state.home_mixes = mixes
                    end
                    publish()
                    if api.ensure_thumbnails then
                        if #state.quick_picks > 0 then api.ensure_thumbnails(state.quick_picks, publish) end
                        if #state.home_mixes > 0 then api.ensure_thumbnails(state.home_mixes, publish) end
                    end
                end)
            end
        else
            state.status = "error"
            state.cookies_path = ""
            state.temp_dir = dir
            state.cookie_count = 0
            state.last_error = log
            state.status_text = "No YouTube session found in " .. label
            open_login(browser)
            if noctalia.notify then
                noctalia.notify("Noctalia YT Music", "No YouTube login in " .. label .. ". Opening YouTube Music — sign in, then click the button again.")
            end
        end
        publish()
    end, 60000)
end

local LOAD_CACHE_SCRIPT = [=[
OUT="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic/cookies.txt"
if [ -s "$OUT" ]; then
  KEPT=$(grep -vc '^#' "$OUT" 2>/dev/null || echo 0)
  if [ "$KEPT" -gt 0 ]; then
    echo "FOUND=1"
    echo "KEPT=$KEPT"
    echo "OUT=$OUT"
  else
    echo "FOUND=0"
  fi
else
  echo "FOUND=0"
fi
]=]

local function sync_liked_tracks(tracks)
    if type(tracks) ~= "table" then return end
    for _, tr in ipairs(tracks) do
        if tr.id and tr.id ~= "" then
            state.liked_ids[tr.id] = true
        end
    end
end

local function load_cached_cookies()
    noctalia.runAsync(LOAD_CACHE_SCRIPT, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        if out:find("FOUND=1") then
            local kept = tonumber(out:match("KEPT=([^\n]+)") or "0") or 0
            local cookies = out:match("OUT=([^\n]+)") or ""
            if kept > 0 then
                state.status = "ready"
                state.cookies_path = cookies
                state.cookie_count = kept
                state.last_error = ""
                if state.status_text == "Not logged in" then
                    state.status_text = string.format("Loaded %d saved YouTube cookies", kept)
                end
                if api and api.load_cached_playlist then
                    local vllm = api.load_cached_playlist("VLLM")
                    if vllm then sync_liked_tracks(vllm) end
                end
                if api and api.load_cached_quick_picks then
                    local qp = api.load_cached_quick_picks()
                    if qp then state.quick_picks = qp end
                end
                sync_audio_cache()
                publish()
                if api and api.fetch_quick_picks then
                    api.fetch_quick_picks(function(qp, mixes)
                        if type(qp) == "table" and #qp > 0 then
                            state.quick_picks = qp
                        end
                        if type(mixes) == "table" and #mixes > 0 then
                            state.home_mixes = mixes
                        end
                        publish()
                        if api.ensure_thumbnails then
                            if #state.quick_picks > 0 then api.ensure_thumbnails(state.quick_picks, publish) end
                            if #state.home_mixes > 0 then api.ensure_thumbnails(state.home_mixes, publish) end
                        end
                    end)
                end
            end
        end
    end, 8000)
end

local DETECT_SCRIPT = [=[
check() { [ -d "$1" ] && echo "FOUND=$2"; }
check "$HOME/.config/google-chrome" chrome
check "$HOME/.config/chromium" chromium
check "$HOME/.mozilla/firefox" firefox
check "$HOME/.config/microsoft-edge" edge
check "$HOME/.config/BraveSoftware/Brave-Browser" brave
check "$HOME/.config/opera" opera
check "$HOME/.config/vivaldi" vivaldi
check "$HOME/.config/whale" whale
check "$HOME/.zen" zen
echo "DONE=1"
]=]

local function detect_browsers()
    noctalia.runAsync(DETECT_SCRIPT, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local available = {}
        for found in out:gmatch("FOUND=([^\n]+)") do
            available[found] = true
        end
        state.available = available
        publish()
    end, 8000)
end

local MPV_PLAY = [=[
PIDFILE="/tmp/noctalia-ytmusic-mpv.pid"
SOCK="${XDG_RUNTIME_DIR:-/tmp}/noctalia-ytmusic-mpv.sock"
URL=$(cat /tmp/noctalia-ytmusic-url.txt)
TITLE=$(cat /tmp/noctalia-ytmusic-title.txt 2>/dev/null)
if [ -f "$PIDFILE" ]; then
  PREV=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$PREV" ] && kill "$PREV" >/dev/null 2>&1
  rm -f "$PIDFILE"
fi
pkill -f "input-ipc-server=$SOCK" >/dev/null 2>&1
sleep 0.3
rm -f "$SOCK"
nohup mpv "$URL" --no-video --vo=null --vd=null --audio-display=no --no-osc --no-osd-bar \
  --demuxer-max-bytes=20M --demuxer-readahead-secs=60 --really-quiet --no-terminal \
  --keep-open=yes \
  --force-media-title="$TITLE" \
  --input-ipc-server="$SOCK" --ao=pipewire \
  >/dev/null 2>&1 &
echo $! > "$PIDFILE"
for i in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "$SOCK" ] && printf '' | nc -U -N -w1 "$SOCK" >/dev/null 2>&1 && break
  sleep 0.2
done
[ -S "$SOCK" ] && { 
  echo "READY=1"
  printf '{"command":["set_property","volume",VOLUME]}\n' | nc -U -N -w1 "$SOCK" >/dev/null 2>&1
}
]=]

local function mpv_play(m3u8_url)
    noctalia.writeFile("/tmp/noctalia-ytmusic-url.txt", m3u8_url)
    noctalia.runAsync(MPV_PLAY:gsub("VOLUME", tostring(state.player.volume or 100)), function() end, 10000)
end

local function mpv_send(payload_json)
    local script = ([[
SOCK="${XDG_RUNTIME_DIR:-/tmp}/noctalia-ytmusic-mpv.sock"
[ -S "$SOCK" ] || exit 0
TMP=$(mktemp)
cat <<'PAYLOAD' > "$TMP"
%s
PAYLOAD
nc -U -N -w2 "$SOCK" < "$TMP" >/dev/null 2>&1
rm -f "$TMP"
]]):format(payload_json)
    noctalia.runAsync(script, function() end, 5000)
end


local POLL_SCRIPT = [=[
SOCK="${XDG_RUNTIME_DIR:-/tmp}/noctalia-ytmusic-mpv.sock"
[ -S "$SOCK" ] || { echo "NOMPV=1"; exit 0; }
RES=$(printf '{"command":["get_property","time-pos"]}\n{"command":["get_property","duration"]}\n{"command":["get_property","pause"]}\n{"command":["get_property","audio-bitrate"]}\n{"command":["get_property","audio-codec-name"]}\n{"command":["get_property","audio-params/samplerate"]}\n{"command":["get_property","eof-reached"]}\n' | nc -U -N -w1 "$SOCK" 2>/dev/null)
[ -n "$RES" ] || exit 0
echo "$RES" | awk -F'"data":' '
  NR==1 && NF>1 { split($2,a,"[,}]"); if (a[1] != "null") print "POS=" a[1] }
  NR==2 && NF>1 { split($2,a,"[,}]"); if (a[1] != "null") print "DUR=" a[1] }
  NR==3 && NF>1 { split($2,a,"[,}]"); if (a[1] != "null") print "PAUSE=" a[1] }
  NR==4 && NF>1 { split($2,a,"[,}]"); if (a[1] != "null") print "BITRATE=" a[1] }
  NR==5 && NF>1 { split($2,a,"[\",}]"); if (a[2] != "null") print "CODEC=" a[2] }
  NR==6 && NF>1 { split($2,a,"[,}]"); if (a[1] != "null") print "RATE=" a[1] }
  NR==7 && NF>1 { split($2,a,"[,}]"); if (a[1] != "null" && a[1] == "true") print "eof-reached=true" }
'
]=]


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
    state.search.pending = false

    local title = item.title or "Unknown track"
    if item.artist and item.artist ~= "" then
        title = item.title .. " - " .. item.artist
    end
    noctalia.writeFile("/tmp/noctalia-ytmusic-title.txt", title)

    if api and api.cache_audio and item.id and item.id ~= "" then
        api.cache_audio(item.id)
    end

    mpv_play(stream_url)
    if api and api.save_session then
        api.save_session(state.player)
    end
    publish()
end

local function play_index(index, queue)
    queue = queue or state.player.queue
    if #queue == 0 then return end
    index = math.max(1, math.min(index, #queue))
    state.player.queue = queue
    state.player.index = index
    local item = queue[index]
    state.player.status = "loading"
    publish()
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

local function play(item)
    table.insert(state.player.queue, {
        id = item.id,
        title = item.title,
        artist = item.artist or "",
        duration = tonumber(item.duration) or 0,
        thumbnail_url = item.thumbnail_url,
        thumb_path = item.thumb_path
    })
    play_index(#state.player.queue)
end

local function play_query(query)
    if type(query) ~= "string" or query == "" then return end
    log("play_query: '" .. query .. "'")
    state.search.pending = true
    state.search.query = query
    state.player.status = state.player.status == "stopped" and "stopped" or state.player.status
    publish()
    api.search(query, 25, function(results)
        state.search.pending = false
        state.search.results = results or {}
        state.search.query = query
        if results and #results > 0 then
            log("play_query: got " .. #results .. " results, playing first")
            play_index(1, results)
        else
            state.search.results = {}
            state.status_text = "No results for \"" .. query .. "\""
            publish()
            log("play_query: no results")
        end
    end)
end

local MPV_KILL = [=[
PIDFILE="/tmp/noctalia-ytmusic-mpv.pid"
SOCK="${XDG_RUNTIME_DIR:-/tmp}/noctalia-ytmusic-mpv.sock"
if [ -f "$PIDFILE" ]; then
  PREV=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$PREV" ] && kill -9 "$PREV" >/dev/null 2>&1
  rm -f "$PIDFILE"
fi
pkill -9 -f "input-ipc-server=$SOCK" >/dev/null 2>&1
rm -f "$SOCK" /tmp/noctalia-ytmusic-url.txt
]=]

local function mpv_kill()
    noctalia.runAsync(MPV_KILL, function() end, 2000)
end

local function stop_playback()
    mpv_kill()
    state.player.status = "stopped"
    state.player.queue = {}
    state.player.index = 0
    state.player.title = ""
    state.player.artist = ""
    state.player.position = 0
    state.player.duration = 0
    publish()
end


local last_action_time = 0

local function toggle_playback()
    last_action_time = os.time()
    if state.player.status == "playing" then
        mpv_send(noctalia.json.encode({ command = { "set_property", "pause", true } }))
        state.player.status = "paused"
        publish()
    elseif state.player.status == "paused" then
        noctalia.runAsync([[
            SOCK="${XDG_RUNTIME_DIR:-/tmp}/noctalia-ytmusic-mpv.sock"
            [ -S "$SOCK" ] && echo "YES" || echo "NO"
        ]], function(res)
            if res and res.stdout and res.stdout:find("YES") then
                mpv_send(noctalia.json.encode({ command = { "set_property", "pause", false } }))
                state.player.status = "playing"
                publish()
            else
                if #state.player.queue > 0 then
                    local idx = state.player.index > 0 and state.player.index or 1
                    play_index(idx)
                elseif state.player.id and state.player.id ~= "" then
                    play(state.player)
                end
            end
        end)
    elseif state.player.status == "stopped" or state.player.status == "idle" then
        if #state.player.queue > 0 then
            local idx = state.player.index > 0 and state.player.index or 1
            play_index(idx)
        elseif state.player.id and state.player.id ~= "" then
            play(state.player)
        end
    end
end

local function next_track(is_natural_end)
    if #state.player.queue == 0 then return end

    if is_natural_end and state.player.repeat_mode == "one" then
        log("next_track: repeat_mode=one, looping track id=" .. tostring(state.player.id))
        mpv_send(noctalia.json.encode({ command = { "set_property", "pause", false } }))
        mpv_send(noctalia.json.encode({ command = { "seek", 0, "absolute" } }))
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
        play_index(rand_idx)
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
    play_index(next_idx)
end

local function prev_track()
    if #state.player.queue == 0 then return end
    if state.player.position > 3 then
        mpv_send(noctalia.json.encode({ command = { "seek", 0, "absolute" } }))
        state.player.position = 0
        publish()
    else
        local prev_idx = state.player.index - 1
        if prev_idx < 1 then
            prev_idx = #state.player.queue
        end
        play_index(prev_idx)
    end
end

local last_seek_time = 0

local function seek_to(seconds)
    local val = tonumber(seconds)
    if not val then return end
    last_action_time = os.time()
    last_seek_time = os.time()
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
    log("seek_to: raw=" .. tostring(seconds) .. " resolved=" .. tostring(sec) .. " dur=" .. tostring(dur))
    state.player.position = sec
    publish()
    mpv_send(noctalia.json.encode({ command = { "seek", sec, "absolute" } }))
end

local function set_volume(value)
    value = tonumber(value) or 100
    state.player.volume = math.max(0, math.min(100, value))
    if state.player.volume > 0 then
        state.player.last_volume = state.player.volume
    end
    mpv_send(noctalia.json.encode({ command = { "set_property", "volume", state.player.volume } }))
    publish()
end

local function toggle_mute()
    if (state.player.volume or 0) > 0 then
        state.player.last_volume = state.player.volume
        set_volume(0)
    else
        set_volume(state.player.last_volume or 70)
    end
end

local function poll_player()
    noctalia.runAsync(POLL_SCRIPT, function(res)
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
        if pos and pos ~= state.player.position then
            state.player.position = pos
            changed = true
        end
        if dur and dur ~= state.player.duration then
            state.player.duration = dur
            changed = true
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
            log("poll_player check: status=" .. tostring(state.player.status) .. " dur=" .. tostring(state.player.duration) .. " pos=" .. tostring(state.player.position) .. " dur_pos=" .. tostring(dur_pos) .. " eof=" .. tostring(out:find("eof-reached") ~= nil))
        end
        if (state.player.status == "playing" or (state.player.status == "paused" and out:find("eof-reached"))) 
            and state.player.duration > 0
            and state.player.position > 0
            and (state.player.duration - state.player.position) < 2.0 then
            log("poll_player: condition met, calling next_track(true)")
            next_track(true)
        elseif state.player.status == "playing" 
            and state.player.duration > 0
            and state.player.position > 0
            and (state.player.duration - state.player.position) < 1.5 then
            log("poll_player: condition met, calling next_track(true)")
            next_track(true)
        end
    end, 6000)
end

noctalia.state.watch(REQ, function(req)
    if type(req) ~= "table" or not req.nonce or req.nonce <= handled_nonce then return end
    handled_nonce = req.nonce
    log("request nonce=" .. req.nonce .. " action=" .. tostring(req.action))

    if req.action == "extract" then
        extract_cookies(req.browser)
    elseif req.action == "open_login" then
        open_login(req.browser)
    elseif req.action == "search" then
        if api and api.search then
            state.search.pending = true
            state.search.query = tostring(req.query or "")
            publish()
            api.search(state.search.query, 25, function(results)
                state.search.pending = false
                state.search.results = results or {}
                api.ensure_thumbnails(state.search.results, publish)
                publish()
            end)
        end
    elseif req.action == "play" then
        log("play: id=" .. tostring(req.item and req.item.id) .. " title='" .. tostring(req.item and req.item.title) .. "'")
        play(req.item or {})
    elseif req.action == "play_queue_index" then
        play_index(req.index or 1)
    elseif req.action == "play_with_queue" then
        if req.queue and #req.queue > 0 then
            play_index(req.index or 1, req.queue)
        elseif req.item then
            play(req.item)
        end
    elseif req.action == "play_query" then
        play_query(req.query)
    elseif req.action == "play_playlist" then
        local pid = req.id or req.playlist_id
        if pid and pid ~= "" then
            state.playlist.id = pid
            state.playlist.title = tostring(req.title or "Playlist")
            local cached = api and api.load_cached_playlist and api.load_cached_playlist(pid)
            if cached and #cached > 0 then
                state.playlist.tracks = cached
                play_index(1, cached)
                playlist_wants_play = false
            else
                state.playlist.tracks = {}
                playlist_wants_play = true
            end
            publish()
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
            publish()
            if api and api.playlist_page then
                api.playlist_page(pid, nil, function(res)
                    state.playlist.fetching = false
                    state.playlist.next_token = res.next_token
                    state.playlist.tracks = res.tracks or {}
                    if api.save_playlist_cache then
                        api.save_playlist_cache(pid, state.playlist.tracks)
                    end
                    publish()
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
                publish()
                if api and api.unlike_video then
                    api.unlike_video(vid, function(ok) end)
                end
            else
                state.liked_ids[vid] = true
                log("toggle_like: liking vid=" .. tostring(vid))
                publish()
                if api and api.like_video then
                    api.like_video(vid, function(ok) end)
                end
            end
        end
    elseif req.action == "toggle_shuffle" then
        state.player.shuffle = not state.player.shuffle
        log("toggle_shuffle: " .. tostring(state.player.shuffle))
        publish()
    elseif req.action == "refresh_quick_picks" then
        if api and api.fetch_quick_picks then
            api.fetch_quick_picks(function(qp, mixes)
                if type(qp) == "table" and #qp > 0 then
                    state.quick_picks = qp
                end
                if type(mixes) == "table" and #mixes > 0 then
                    state.home_mixes = mixes
                end
                publish()
                if api.ensure_thumbnails then
                    if #state.quick_picks > 0 then api.ensure_thumbnails(state.quick_picks, publish) end
                    if #state.home_mixes > 0 then api.ensure_thumbnails(state.home_mixes, publish) end
                end
            end)
        end
    elseif req.action == "cycle_repeat" then
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
    elseif req.action == "download_track" then
        local vid = req.id or req.video_id
        if vid and vid ~= "" then
            log("download_track: starting for id=" .. tostring(vid))
            if api and api.cache_audio then
                api.cache_audio(vid, function(ok)
                    if ok then
                        state.cached_audio_ids[vid] = true
                        log("download_track: complete for id=" .. tostring(vid))
                        publish()
                    end
                end)
            end
        end
    elseif req.action == "download_playlist" then
        log("download_playlist: starting batch download for " .. #state.playlist.tracks .. " tracks")
        if api and api.cache_audio and type(state.playlist.tracks) == "table" then
            for _, tr in ipairs(state.playlist.tracks) do
                if tr.id and tr.id ~= "" and not state.cached_audio_ids[tr.id] then
                    api.cache_audio(tr.id, function(ok)
                        if ok then
                            state.cached_audio_ids[tr.id] = true
                            publish()
                        end
                    end)
                end
            end
        end
    elseif req.action == "open_playlist" then
        local pid = req.id or req.playlist_id
        if pid and pid ~= "" then
            state.playlist.id = pid
            state.playlist.title = tostring(req.title or "Playlist")
            
            local cached = api and api.load_cached_playlist and api.load_cached_playlist(pid)
            if cached and #cached > 0 then
                state.playlist.tracks = cached
                if pid == "VLLM" then sync_liked_tracks(cached) end
            else
                state.playlist.tracks = {}
            end

            state.playlist.next_token = nil
            state.playlist.fetching = true
            publish()

            if api and api.playlist_page then
                api.playlist_page(pid, nil, function(res)
                    state.playlist.fetching = false
                    state.playlist.next_token = res.next_token
                    if res.tracks and #res.tracks > 0 then
                        if pid == "VLLM" then sync_liked_tracks(res.tracks) end
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
                        if api.save_playlist_cache then
                            api.save_playlist_cache(pid, state.playlist.tracks)
                        end
                    end
                    publish()
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
                api.playlist_page(pid, token, function(res)
                    state.playlist.fetching = false

                    local existing = {}
                    for _, t in ipairs(state.playlist.tracks) do
                        if t.id then existing[t.id] = true end
                    end

                    local added_count = 0
                    if res.tracks and #res.tracks > 0 then
                        for _, tr in ipairs(res.tracks) do
                            if tr.id and not existing[tr.id] then
                                table.insert(state.playlist.tracks, tr)
                                existing[tr.id] = true
                                added_count = added_count + 1
                            end
                        end
                    end

                    if added_count == 0 or not res.next_token or res.next_token == "" or res.next_token == token then
                        state.playlist.next_token = nil
                    else
                        state.playlist.next_token = res.next_token
                    end

                    log("fetch_next_page: added " .. added_count .. " new tracks (total " .. #state.playlist.tracks .. "), next_token=" .. tostring(state.playlist.next_token ~= nil))
                    if api.save_playlist_cache then
                        api.save_playlist_cache(pid, state.playlist.tracks)
                    end
                    publish()
                end)
            end
        end
    elseif req.action == "toggle" then
        toggle_playback()
    elseif req.action == "next" then
        next_track()
    elseif req.action == "prev" then
        prev_track()
    elseif req.action == "seek" then
        seek_to(req.seconds or req.value or req.position)
    elseif req.action == "volume" then
        set_volume(req.value)
    elseif req.action == "toggle_mute" then
        toggle_mute()
    elseif req.action == "stop" then
        stop_playback()
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
            publish()
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
                publish()
            end)
        end)
    elseif req.action == "toggle_autoplay" then
        state.settings.autoplay = not state.settings.autoplay
        publish()
    end
end)

function update()
    poll_player()
    if api.library_pending() then
        api.finish_library(function(playlists)
            state.library = type(playlists) == "table" and playlists or {}
            publish()
            if type(playlists) == "table" then
                log("ytmusic: loaded " .. #playlists .. " library playlists")
                noctalia.runAsync("true", function()
                    api.ensure_thumbnails(state.library, publish)
                end)
            else
                log("ytmusic: library decode failed")
            end
        end)
    end
end

noctalia.setUpdateInterval(1000)

log("boot: service started, api=" .. tostring(type(api)) .. " library=" .. tostring(type(api and api.library)))
mpv_kill()
detect_browsers()
load_cached_cookies()
if api and api.load_cached_library then
    local cached_lib = api.load_cached_library()
    if cached_lib then
        state.library = cached_lib
    end
end
if api and api.load_session then
    local sess = api.load_session()
    if type(sess) == "table" and sess.id and sess.id ~= "" then
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
    end
end
if api and api.library then
    api.library()
end
publish()

function onStop()
    if api and api.save_session then
        api.save_session(state.player)
    end
end