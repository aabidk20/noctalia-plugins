local STATE = "noctalia_ytmusic.state"

local REQ = "noctalia_ytmusic.request"
local theme = require("./theme.luau")

local req_nonce = os.time() * 1000

local BROWSERS = {
    { id = "chrome", label = "Chrome", icon = "brand-chrome" },
    { id = "chromium", label = "Chromium", icon = "device-desktop" },
    { id = "firefox", label = "Firefox", icon = "flame" },
    { id = "edge", label = "Edge", icon = "wind" },
    { id = "brave", label = "Brave", icon = "shield" },
    { id = "opera", label = "Opera", icon = "circle" },
    { id = "vivaldi", label = "Vivaldi", icon = "triangle" },
    { id = "whale", label = "Whale", icon = "droplet" },
    { id = "zen", label = "Zen", icon = "activity" }
}

local NAV_ITEMS = {
    { id = "home", label = "For you", icon = "home" },
    { id = "discover", label = "Search", icon = "search" },
    { id = "queue", label = "Queue", icon = "library" },
    { id = "settings", label = "Settings", icon = "settings" }
}

local state = {
    status = "idle",
    status_text = "Not logged in",
    browser = nil,
    browser_label = "",
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
        volume = 70,
        queue = {},
        index = 0
    },
    search = { query = "", results = {}, pending = false },
    library = {},
    playlist = { id = "", title = "", tracks = {} },
    quick_picks = {},
    home_mixes = {},
    cache_stats = {},
    settings = { autoplay = true }
}

local content_page = "home"
local search_query = ""
local playlist_view_page = 0
local playlist_pending_advance = false
local queue_view_page = 0

local function request(action, payload)
    req_nonce = math.max(req_nonce + 1, os.time() * 1000)
    local msg = { action = action, nonce = req_nonce }
    for k, v in pairs(payload or {}) do
        msg[k] = v
    end
    noctalia.state.set(REQ, msg)
end

local function logged_in()
    return state.status == "ready"
end

local function fmt_pos(seconds)
    seconds = tonumber(seconds) or 0
    local m = math.floor(seconds / 60)
    local s = math.floor(seconds % 60)
    return string.format("%d:%02d", m, s)
end

local function icon_btn(glyph, onClick, variant)
    local v = "ghost"
    if type(variant) == "boolean" then
        v = variant and "primary" or "ghost"
    elseif type(variant) == "string" and variant ~= "" then
        v = variant
    end
    return ui.button({
        glyph = glyph,
        variant = v,
        controlSize = "sm",
        onClick = onClick or function() end
    })
end

local function chunk_rows(cells, per_row, key_prefix, gap)
    local rows = {}
    for i = 1, #cells, per_row do
        local row_children = { cells[i] }
        for j = i + 1, math.min(i + per_row - 1, #cells) do
            table.insert(row_children, cells[j])
        end
        table.insert(rows, ui.row({
            key = key_prefix .. "-row-" .. i,
            gap = gap or 10,
            align = "stretch"
        }, row_children))
    end
    return rows
end

local function on_nav(id)
    content_page = id
    if id ~= "playlist" then
        state.playlist.id = ""
    end
    if id == "settings" then
        request("fetch_cache_stats")
    end
    render_panel()
end

local last_searched_query = ""
local search_timer_nonce = 0

local function do_search(query)
    query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then return end
    last_searched_query = query
    content_page = "discover"
    search_query = query
    state.search.pending = true
    state.search.query = query
    state.search.results = {}
    request("search", { query = query })
    render_panel()
end

local function on_search_type(val)
    search_query = val or ""
    search_timer_nonce = search_timer_nonce + 1
    local current_nonce = search_timer_nonce
    local target_q = (val or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if target_q == "" or #target_q < 2 then
        last_searched_query = ""
        state.search.query = target_q
        state.search.results = {}
        render_panel()
        return
    end

    noctalia.runAsync("sleep 0.4", function()
        if search_timer_nonce == current_nonce then
            do_search(target_q)
        end
    end)
end

local loading_track_id = nil

local function open_playlist(pl)
    content_page = "playlist"
    playlist_view_page = 0
    state.playlist.id = tostring(pl.id or "")
    state.playlist.title = tostring(pl.title or "Playlist")
    state.playlist.tracks = {}
    request("open_playlist", { id = pl.id, title = pl.title })
    render_panel()
end

local function play_item(item)
    if item and item.id then
        loading_track_id = item.id
        state.player.id = item.id
        state.player.title = item.title or "Loading..."
        state.player.artist = item.artist or ""
        state.player.status = "loading"
        if item.thumb_path then state.player.thumb_path = item.thumb_path end
    end
    request("play", { item = item })
    render_panel()
end

local function play_playlist(pl)
    request("play_playlist", { id = pl.id, title = pl.title })
end

local function play_query(query)
    content_page = "discover"
    search_query = query
    state.search.query = query
    state.search.pending = true
    state.search.results = {}
    request("play_query", { query = query })
    render_panel()
end

local function request_extract(id)
    request("extract", { browser = id })
end

local function build_browser_cells()
    local cells = {}
    for _, b in ipairs(BROWSERS) do
        local is_avail = state.available[b.id]
        local is_current = (state.extracting and state.browser == b.id)
        local key = "browser-btn-" .. b.id
        local is_hovered = (hovered_card_key == key)
        
        if is_current then
            table.insert(cells, ui.row({
                key = key,
                align = "center",
                justify = "center",
                gap = 12,
                paddingV = 16,
                paddingH = 20,
                borderWidth = 1,
                border = "primary",
                fill = "primary/0.1",
                flexGrow = 1,
                onClick = function() request_extract(b.id) end
            }, {
                ui.glyph({ name = "loader", size = 24, color = "primary" })
            }))
        elseif is_avail then
            table.insert(cells, ui.row({
                key = key,
                align = "center",
                justify = "center",
                gap = 12,
                paddingV = 16,
                paddingH = 20,
                borderWidth = 1,
                border = is_hovered and "primary" or "outline",
                fill = is_hovered and "surface_variant/0.8" or "surface_variant/0.4",
                flexGrow = 1,
                onClick = function() request_extract(b.id) end,
                onHover = function(h)
                    if h == "true" then
                        if hovered_card_key ~= key then hovered_card_key = key; render_panel() end
                    else
                        if hovered_card_key == key then hovered_card_key = nil; render_panel() end
                    end
                end
            }, {
                ui.glyph({ name = b.icon, size = 24, color = is_hovered and "primary" or "on_surface" }),
                ui.label({ text = b.label, fontSize = theme.fontTitle, fontWeight = "bold", color = is_hovered and "primary" or "on_surface" })
            }))
        else
            table.insert(cells, ui.row({
                key = "browser-off-" .. b.id,
                align = "center",
                justify = "center",
                gap = 12,
                paddingV = 16,
                paddingH = 20,
                borderWidth = 1,
                border = "outline/0.3",
                fill = "surface_variant/0.1",
                flexGrow = 1
            }, {
                ui.glyph({ name = b.icon, size = 24, color = "on_surface_variant/0.4" }),
                ui.label({ text = b.label, fontSize = theme.fontTitle, fontWeight = "bold", color = "on_surface_variant/0.4" })
            }))
        end
    end
    return cells
end

local function build_topbar()
    return ui.row({ key = "topbar", align = "center", gap = 12, paddingH = 16, paddingV = 10, borderWidth = 0 }, {
        ui.input({
            key = "search-input",
            placeholder = "Search songs, artists, albums",
            value = search_query,
            flexGrow = 1,
            onChange = function(val) on_search_type(val) end,
            onSubmit = function() do_search(search_query) end
        })
    })
end

local hovered_sidebar_key = nil
local hovered_track_key = nil
local hovered_card_key = nil

function onSidebarHover(hover_state, key)
    if hover_state == "true" then
        if hovered_sidebar_key ~= key then
            hovered_sidebar_key = key
            render_panel()
        end
    else
        if hovered_sidebar_key ~= nil then
            hovered_sidebar_key = nil
            render_panel()
        end
    end
end

function onTrackHover(hover_state, key)
    if hover_state == "true" then
        if hovered_track_key ~= key then
            hovered_track_key = key
            render_panel()
        end
    else
        if hovered_track_key ~= nil then
            hovered_track_key = nil
            render_panel()
        end
    end
end

function onCardHover(hover_state, key)
    if hover_state == "true" then
        if hovered_card_key ~= key then
            hovered_card_key = key
            render_panel()
        end
    else
        if hovered_card_key ~= nil then
            hovered_card_key = nil
            render_panel()
        end
    end
end

local function sidebar_row(key, icon, label, subtext, active, onClick, thumb_path, bold_active)
    local is_hovered = (hovered_sidebar_key == key)
    local fill_color = active and "primary/0.2" or (is_hovered and "primary/0.25" or "surface_variant/0.15")
    local glyph_color = (active or is_hovered) and "primary" or "on_surface_variant"

    local icon_elem
    if thumb_path and noctalia.fileExists(thumb_path) then
        icon_elem = ui.image({ path = thumb_path, width = 26, height = 26, fit = "cover" })
    else
        icon_elem = ui.glyph({ name = icon, size = 17, color = glyph_color })
    end

    return ui.row({
        key = key,
        gap = 10,
        align = "center",
        padding = 8,
        borderWidth = 0,
        fill = fill_color,
        onClick = function()
            hovered_sidebar_key = nil
            onClick()
        end,
        onHover = "onSidebarHover"
    }, {
        icon_elem,
        ui.column({ gap = 1, flexGrow = 1 }, {
ui.label({
                text = label,
                fontSize = theme.fontTitle,
                maxLines = 1,
                fontWeight = (active and bold_active ~= false) and "bold" or "medium",
                color = active and "primary" or "on_surface",
                flexGrow = 1
            }),
            subtext and ui.label({
                text = subtext,
                fontSize = theme.fontBody,
                color = "on_surface_variant"
            }) or nil
        })
    })
end

local function build_sidebar()
    local sidebar_items = {}

    table.insert(sidebar_items, ui.row({ key = "side-brand", align = "center", gap = 9, padding = 6, borderWidth = 0 }, {
        ui.glyph({ name = "brand-youtube-filled", size = 30, color = "primary" }),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({ text = "Music", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface" }),
            ui.label({ text = "for YouTube Music", fontSize = theme.fontBody, color = "on_surface_variant" })
        })
    }))

    table.insert(sidebar_items, ui.separator({ key = "sep-brand", color = "outline", spacing = 8 }))

    for idx, item in ipairs(NAV_ITEMS) do
        local key = "nav-" .. idx
        local active = (content_page == item.id)
        table.insert(sidebar_items, sidebar_row(key, item.icon, item.label, nil, active, function()
            on_nav(item.id)
        end))
    end

    table.insert(sidebar_items, ui.separator({ key = "sep-side", color = "outline", spacing = 8 }))

    table.insert(sidebar_items, ui.row({ key = "label-library", gap = 0, padding = 6, borderWidth = 0 }, {
        ui.label({
            text = "YOUR LIBRARY",
            fontSize = theme.fontBody,
            fontWeight = "bold",
            color = "on_surface_variant"
        })
    }))

    local library_list = {}
    if #state.library == 0 then
        table.insert(library_list, ui.label({
            text = logged_in() and "Loading your playlists..." or "Sign in to see your playlists",
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        }))
    else
        for idx, pl in ipairs(state.library) do
            local pl_id = tostring(pl.id or "")
            local key = "pl-" .. idx
            local active = (content_page == "playlist" and pl_id ~= "" and state.playlist.id == pl_id)
            local row_icon = (pl.title and pl.title:lower():find("liked", 1, true)) and "heart" or "playlist"
            table.insert(library_list, sidebar_row(key, row_icon, pl.title, nil, active, function()
                open_playlist(pl)
            end, nil, false))
        end
    end

    table.insert(sidebar_items, ui.scroll({ key = "library-scroll", flexGrow = 1, gap = 0 }, library_list))

    return ui.column({ key = "sidebar", width = 256, gap = 2, paddingH = 12, paddingV = 12, borderWidth = 1, border = "primary/0.4", fill = "primary/0.04" }, sidebar_items)
end

local last_service_pos = 0
local vol_drag_state = nil

local function audio_spec_tooltip()
    local player = state.player or {}
    local codec_str = (player.codec and player.codec ~= "") and string.upper(player.codec) or "OPUS"
    local bitrate_str = (player.bitrate and tonumber(player.bitrate) > 0) and (math.floor(tonumber(player.bitrate) / 1000) .. " kbps") or "256 kbps"
    local rate_str = (player.samplerate and tonumber(player.samplerate) > 0) and string.format("%.1f kHz", tonumber(player.samplerate) / 1000) or "48.0 kHz"
    local title = (player.title ~= nil and player.title ~= "") and player.title or "Nothing playing"
    local artist = (player.artist ~= nil and player.artist ~= "") and player.artist or "—"
    return ("%s\n%s\n\nCodec: %s\nBitrate: %s\nSample rate: %s\nOutput driver: PipeWire\nVolume: %d%%")
        :format(title, artist, codec_str, bitrate_str, rate_str, tonumber(player.volume) or 70)
end

local function build_player_bar()
    local player = state.player
    local is_playing = (player.status == "playing")
    local track_label = player.title or ""
    if track_label == "" then
        track_label = "Nothing playing"
    end

    local track_meta = (player.artist ~= nil and player.artist ~= "") and player.artist or "Pick something to play"

    local duration = tonumber(player.duration) or 0
    local position = math.min(tonumber(player.position) or 0, duration)
    last_service_pos = position

    local player_thumb
    if player.thumb_path and noctalia.fileExists(player.thumb_path) then
        player_thumb = ui.image({ path = player.thumb_path, width = 64, height = 64, fit = "cover" })
    else
        player_thumb = ui.row({
            width = 64,
            height = 64,
            align = "center",
            justify = "center",
            fill = "surface_variant/0.3",
            borderWidth = 0
        }, {
            ui.glyph({ name = "music", size = 24, color = is_playing and "primary" or "on_surface_variant" })
        })
    end

    local now_playing = ui.row({ key = "pb-now", align = "center", gap = 10, width = 300 }, {
        player_thumb,
        ui.column({ gap = 2, flexGrow = 1 }, {
            ui.row({ key = "pb-title-row", align = "center", gap = 6 }, {
                ui.label({
                    text = track_label,
                    fontSize = theme.fontTitle,
                    maxLines = 1,
                    fontWeight = "bold",
                    color = "on_surface",
                    flexGrow = 1
                }),
                (function()
                    local is_liked = (state.liked_ids and player.id and state.liked_ids[player.id] == true)
                    return icon_btn("heart", function()
                        if player.id and player.id ~= "" then
                            request("toggle_like", { id = player.id })
                        end
                    end, is_liked)
                end)(),
                ui.button({
                    glyph = "activity",
                    variant = "ghost",
                    controlSize = "sm",
                    tooltip = audio_spec_tooltip(),
                    onHover = function() end
                })
            }),
            ui.label({
                text = track_meta,
                fontSize = theme.fontTitle,
                maxLines = 1,
                color = is_playing and "primary" or "on_surface_variant"
            })
        })
    })

    if seek_drag_state and seek_drag_state.track_id ~= state.player.id then
        seek_drag_state = nil
    end
    local is_drag_active = seek_drag_state and seek_drag_state.track_id == state.player.id and seek_drag_state.dragging
    local slider_val = tonumber((is_drag_active and seek_drag_state.position) or position) or 0

    local is_loading = (state.player.status == "loading")
    local is_playing = (state.player.status == "playing")
    local play_glyph = is_loading and "loader" or (is_playing and "player-pause" or "player-play")
    local shuffle_active = (state.player.shuffle == true)
    local rep_mode = state.player.repeat_mode or "off"
    local rep_active = (rep_mode ~= "off")
    local rep_glyph = (rep_mode == "one") and "repeat-once" or "repeat"
    local rep_tooltip = (rep_mode == "one") and "Repeat Track (1)" or ((rep_mode == "all") and "Repeat Queue" or "Repeat Off")

    local controls = {
        icon_btn("arrows-shuffle", function() request("toggle_shuffle") end, shuffle_active),
        icon_btn("player-skip-back", function() request("prev") end),
        ui.button({
            glyph = play_glyph,
            variant = "primary",
            controlSize = "md",
            onClick = function() request("toggle") end
        }),
        icon_btn("player-skip-forward", function() request("next") end),
        ui.button({
            glyph = rep_glyph,
            variant = rep_active and "primary" or "ghost",
            controlSize = "sm",
            tooltip = rep_tooltip,
            onClick = function() request("cycle_repeat") end
        })
    }

    local transport = ui.column({
        key = "pb-center-col",
        align = "center",
        gap = 1,
        flexGrow = 1,
        justify = "center"
    }, {
        ui.row({ key = "pb-scrub", align = "center", gap = 10, width = 900 }, {
            ui.label({ key = "pb-pos-label", text = fmt_pos(slider_val), fontSize = theme.fontCaption, color = "on_surface_variant" }),
            ui.slider({
                key = "pb-seek",
                min = 0,
                max = math.max(1, duration),
                step = 1,
                value = math.floor(slider_val),
                flexGrow = 1,
                controlSize = "sm",
                onChange = function(v)
                    local num = tonumber(v)
                    -- Ignore programmatic onChange events (which echo back the current value)
                    if num and num ~= math.floor(position) then
                        seek_drag_state = { dragging = true, position = num, timestamp = os.time(), track_id = state.player.id }
                    end
                end,
                onDragEnd = function()
                    local target = (seek_drag_state and seek_drag_state.position) or position
                    seek_drag_state = nil
                    request("seek", { seconds = target, value = target })
                end
            }),
            ui.label({ key = "pb-dur-label", text = fmt_pos(duration), fontSize = theme.fontCaption, color = "on_surface_variant" })
        }),
        ui.row({ key = "pb-controls", align = "center", justify = "center", gap = 3 }, controls)
    })

    local vol = player.volume or 70
    local vol_icon = "volume"
    if vol == 0 then
        vol_icon = "volume-off"
    elseif vol < 50 then
        vol_icon = "volume-2"
    end

    local output_controls = ui.row({ key = "pb-right", align = "center", gap = 8, width = 170, justify = "end" }, {
        icon_btn(vol_icon, function() request("toggle_mute") end),
        ui.slider({
            key = "pb-volume",
            min = 0,
            max = 100,
            step = 5,
            value = vol,
            flexGrow = 1,
            onChange = function(v)
                local num = tonumber(v)
                if num and num ~= math.floor(vol) then
                    vol_drag_state = { dragging = true, value = num, timestamp = os.time() }
                end
            end,
            onDragEnd = function()
                local target = (vol_drag_state and vol_drag_state.value) or vol
                vol_drag_state = nil
                request("volume", { value = target })
            end
        }),
        ui.label({ text = tostring(vol) .. "%", fontSize = theme.fontCaption, color = "on_surface_variant" })
    })

    return ui.row({
        key = "player-bar",
        align = "center",
        gap = 12,
        paddingH = 12,
        paddingV = 10,
        borderWidth = 1,
        border = "primary/0.4",
        fill = "primary/0.04"
    }, {
        now_playing,
        transport,
        output_controls
    })
end

function onTrackHover(hover_state, key)
    if hover_state == "true" then
        if hovered_track_key ~= key then
            hovered_track_key = key
            render_panel()
        end
    else
        if hovered_track_key == key then
            hovered_track_key = nil
            render_panel()
        end
    end
end

local function media_row(item, idx, custom_click, is_active)
    local handler = custom_click or function() play_item(item) end
    local row_key = "track-" .. idx
    local is_hovered = (hovered_track_key == row_key)
    local is_playing = (state.player.id ~= "" and item.id ~= nil and state.player.id == item.id and state.player.status == "playing")
    local is_loading = (loading_track_id ~= nil and item.id ~= nil and loading_track_id == item.id) or (state.player.id ~= "" and item.id ~= nil and state.player.id == item.id and state.player.status == "loading")
    local is_current = is_active or is_playing or is_loading

    local track_thumb
    if item.thumb_path and noctalia.fileExists(item.thumb_path) then
        track_thumb = ui.image({ path = item.thumb_path, width = 54, height = 54, fit = "cover" })
    else
        track_thumb = ui.row({
width = 54,
                    height = 54,
                    align = "center",
                    justify = "center",
                    fill = is_current and "primary/0.2" or "surface_variant/0.3",
                    borderWidth = 0
        }, {
            ui.glyph({ name = "music", size = 20, color = (is_current or is_hovered) and "primary" or "on_surface_variant" })
        })
    end

    local status_glyph
    if is_loading then
        status_glyph = ui.glyph({ name = "loader", size = 16, color = "primary" })
    elseif is_playing then
        status_glyph = ui.glyph({ name = "volume", size = 16, color = "primary" })
    else
        status_glyph = ui.glyph({ name = "player-play", size = 16, color = (is_current or is_hovered) and "primary" or "on_surface_variant/0.5" })
    end

    return ui.row({
        key = row_key,
        gap = 14,
        align = "center",
        padding = 8,
        borderWidth = 0,
        fill = (is_loading or is_current) and "primary/0.2" or (is_hovered and "primary/0.25" or "surface_variant/0.15"),
        onClick = function()
            hovered_track_key = nil
            if item and item.id then loading_track_id = item.id end
            handler()
            render_panel()
        end,
        onHover = "onTrackHover"
    }, {
        track_thumb,
        ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({ text = item.title or "Unknown Track", fontSize = theme.fontTitle, maxLines = 1, color = (is_loading or is_current) and "primary" or "on_surface" }),
            ui.label({ text = item.artist or "", fontSize = theme.fontTitle, color = "on_surface_variant" })
        }),
        ui.label({
            text = item.duration_text or "",
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        }),
        (function()
            local is_cached = (state.cached_audio_ids and item.id and state.cached_audio_ids[item.id] == true)
            if is_cached then
                return ui.glyph({ name = "check", size = 16, color = "primary" })
            else
                return ui.button({
                    glyph = "download",
                    variant = "ghost",
                    controlSize = "sm",
                    tooltip = "Download for offline",
                    onClick = function()
                        if item.id and item.id ~= "" then
                            request("download_track", { id = item.id })
                        end
                    end
                })
            end
        end)()
    })
end

local function build_signin_prompt()
    local browser_rows = {}
    for _, row in ipairs(chunk_rows(build_browser_cells(), 3, "browser-grid", 12)) do
        table.insert(browser_rows, row)
    end

    return ui.column({
        key = "signin-prompt",
        align = "center",
        justify = "center",
        gap = 10,
        padding = 40,
        flexGrow = 1
    }, {
        ui.glyph({ name = "music", size = 44, color = "primary" }),
        ui.label({ text = "Noctalia YT Music", fontSize = theme.fontHero, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = "Pick the browser you're signed into YouTube Music with", fontSize = theme.fontTitle, color = "on_surface_variant" }),
        ui.label({
            text = state.status_text,
            fontSize = theme.fontBody,
            color = state.status == "error" and "error" or "on_surface_variant"
        }),
        ui.column({ gap = 8, width = "fill" }, browser_rows)
    })
end

local function build_home()
    local feed = {}

    table.insert(feed, ui.row({ key = "qp-header", align = "center", justify = "space_between" }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = "sparkles", size = 18, color = "primary" }),
            ui.column({ gap = 1 }, {
                ui.label({ text = "QUICK PICKS", fontSize = theme.fontHeading, fontWeight = "bold", color = "primary" }),
                ui.label({ text = "Start listening to tracks picked for you", fontSize = theme.fontBody, color = "on_surface_variant" })
            })
        }),
        ui.button({
            key = "btn-sync-qp",
            glyph = "refresh",
            variant = "ghost",
            controlSize = "sm",
            tooltip = "Refresh Quick Picks",
            onClick = function() request("refresh_quick_picks") end
        })
    }))

    if type(state.quick_picks) == "table" and #state.quick_picks > 0 then
        local qp_cells = {}
        for idx, t in ipairs(state.quick_picks) do
            local cell_key = "qp-" .. idx
            local is_current = (state.player.id ~= "" and t.id ~= nil and state.player.id == t.id)
            local is_hovered = (hovered_track_key == cell_key)

            local thumb
            if t.thumb_path and noctalia.fileExists(t.thumb_path) then
                thumb = ui.image({ path = t.thumb_path, width = 54, height = 54, fit = "cover" })
            else
                thumb = ui.row({
width = 54,
            height = 54,
            align = "center",
            justify = "center",
            fill = is_current and "primary/0.2" or "surface_variant/0.3",
            borderWidth = 0
                }, {
                    ui.glyph({ name = "music", size = 20, color = is_current and "primary" or "on_surface_variant" })
                })
            end

            table.insert(qp_cells, ui.row({
                key = cell_key,
                gap = 8,
                align = "center",
                padding = 6,
                borderWidth = 0,
                fill = is_current and "primary/0.2" or (is_hovered and "primary/0.25" or "surface_variant/0.15"),
                flexGrow = 1,
                onClick = function()
                    hovered_track_key = nil
                    request("play_with_queue", { item = t, index = idx, queue = state.quick_picks })
                end,
                onHover = function(hover_state)
                    if hover_state == "true" then
                        if hovered_track_key ~= cell_key then
                            hovered_track_key = cell_key
                            render_panel()
                        end
                    else
                        if hovered_track_key ~= nil then
                            hovered_track_key = nil
                            render_panel()
                        end
                    end
                end
            }, {
                thumb,
                ui.column({ gap = 1, flexGrow = 1 }, {
                    ui.label({ text = t.title or "Unknown Track", fontSize = theme.fontTitle, maxLines = 1, color = is_current and "primary" or "on_surface" }),
                    ui.label({ text = t.artist or "", fontSize = theme.fontTitle, maxLines = 1, color = "on_surface_variant" })
                })
            }))
        end
        for _, row in ipairs(chunk_rows(qp_cells, 3, "qp-grid", 8)) do
            table.insert(feed, row)
        end
    else
        table.insert(feed, ui.label({
            text = logged_in() and "Loading Quick Picks recommendations..." or "Sign in to load recommendations.",
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        }))
    end
    table.insert(feed, ui.row({ key = "spacer-above-sep-qp", height = 4, borderWidth = 0 }))
    table.insert(feed, ui.separator({ key = "sep-qp", color = "outline/0.3" }))

    local mixes_source = (type(state.home_mixes) == "table" and #state.home_mixes > 0) and state.home_mixes or nil

    if mixes_source then
        table.insert(feed, ui.row({ key = "spacer-mixes", height = 4, borderWidth = 0 }))
        table.insert(feed, ui.label({ text = "RECOMMENDED MIXES & RADIOS", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface_variant" }))

        local mix_cards = {}
        for _, mix in ipairs(mixes_source) do
            local item_title = mix.title or "Mix"
            local item_sub = (mix.subtitle and mix.subtitle ~= "") and mix.subtitle or "YouTube Radio"
            local mix_key = "mix-" .. tostring(mix.id or item_title)
            local mix_hovered = (hovered_card_key == mix_key)
            table.insert(mix_cards, ui.column({
                key = mix_key,
                gap = 10,
                padding = 10,
                borderWidth = 1,
                border = "primary/0.4",
                fill = mix_hovered and "primary/0.12" or "primary/0.04",
                flexGrow = 1,
                onClick = function()
                    hovered_card_key = nil
                    if mix.id and mix.id ~= "" then
                        open_playlist({ id = mix.id, title = item_title })
                    else
                        play_query(item_title .. " mix")
                    end
                end,
                onHover = "onCardHover"
            }, {
                mix.thumb_path and noctalia.fileExists(mix.thumb_path)
                    and ui.image({ path = mix.thumb_path, width = 200, height = 200, fit = "cover" })
                    or ui.row({
                        align = "center",
                        justify = "center",
                        height = 200,
                        borderWidth = 0,
                        fill = mix_hovered and "primary/0.2" or "surface_variant/0.6"
                    }, {
                        ui.glyph({ name = "disc", size = 38, color = "primary" })
                    }),
                ui.column({ gap = 2, flexGrow = 1 }, {
                    ui.label({ text = item_title, fontSize = theme.fontTitle, maxLines = 1, color = "on_surface" }),
                    ui.label({ text = item_sub, fontSize = theme.fontBody, maxLines = 1, color = "on_surface_variant" })
                })
            }))
        end
        for _, row in ipairs(chunk_rows(mix_cards, 6, "mix-grid", 14)) do
            table.insert(feed, row)
        end
    end

    table.insert(feed, ui.row({ key = "spacer-above-sep-mixes", height = 4, borderWidth = 0 }))
    table.insert(feed, ui.separator({ key = "sep-mixes", color = "outline/0.3" }))
    table.insert(feed, ui.row({ key = "spacer-library", height = 4, borderWidth = 0 }))

    table.insert(feed, ui.label({ text = "YOUR LIBRARY", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface_variant" }))

    if #state.library == 0 then
        table.insert(feed, ui.label({
            text = logged_in() and "Loading playlists..." or "Sign in to load your library.",
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        }))
    else
        local cards = {}
        for _, pl in ipairs(state.library) do
            local card_key = "pl-card-" .. pl.id
            local card_hovered = (hovered_card_key == card_key)

            local pl_id = tostring(pl.id or "")
            local is_pl_downloaded = (state.downloaded_playlist_ids and state.downloaded_playlist_ids[pl_id] == true)

            table.insert(cards, ui.column({
                key = card_key,
                gap = 10,
                padding = 10,
                borderWidth = 1,
                border = "primary/0.4",
                fill = card_hovered and "primary/0.12" or "primary/0.04",
                flexGrow = 1,
                onClick = function()
                    hovered_card_key = nil
                    open_playlist(pl)
                end,
                onHover = "onCardHover"
            }, {
                pl.thumb_path and noctalia.fileExists(pl.thumb_path)
                    and ui.image({ path = pl.thumb_path, width = 200, height = 200, fit = "cover" })
                    or ui.row({
                        align = "center",
                        justify = "center",
                        height = 200,
                        borderWidth = 0,
                        fill = card_hovered and "primary/0.2" or "surface_variant/0.6"
                    }, {
                        ui.glyph({ name = "playlist", size = 38, color = "primary" })
                    }),
                ui.column({ gap = 2, flexGrow = 1 }, {
                    ui.row({ align = "center", justify = "space_between" }, {
                        ui.label({ text = pl.title, fontSize = theme.fontTitle, maxLines = 1, color = "on_surface", flexGrow = 1 }),
                        is_pl_downloaded and ui.glyph({ name = "check", size = 16, color = "primary" }) or nil
                    }),
                    ui.label({
                        text = (pl.count and pl.count > 0) and (pl.count .. " tracks") or "Playlist",
                        fontSize = theme.fontBody,
                        color = "on_surface_variant"
                    })
                })
            }))
        end
        for _, row in ipairs(chunk_rows(cards, 6, "pl-grid", 14)) do
            table.insert(feed, row)
        end
    end

    return feed
end

local function build_playlist_view()
    local pl = state.playlist
    local view = {}

    local downloaded_count = 0
    if #pl.tracks > 0 then
        for _, tr in ipairs(pl.tracks) do
            if tr.id and state.cached_audio_ids and state.cached_audio_ids[tr.id] == true then
                downloaded_count = downloaded_count + 1
            end
        end
    end
    local all_cached = (#pl.tracks > 0 and downloaded_count == #pl.tracks)

    local download_btn
    if all_cached then
        download_btn = ui.button({
            key = "btn-download-pl",
            glyph = "check",
            variant = "secondary",
            controlSize = "md",
            tooltip = "All tracks downloaded for offline playback"
        })
    else
        download_btn = ui.button({
            key = "btn-download-pl",
            glyph = "download",
            variant = "secondary",
            controlSize = "md",
            tooltip = "Download all tracks in playlist for offline",
            onClick = function() request("download_playlist") end
        })
    end

    table.insert(view, ui.row({ key = "pl-header", align = "center", justify = "space_between" }, {
        ui.row({ key = "pl-title-row", align = "center", gap = 10 }, {
            ui.label({ text = pl.title or "Playlist", fontSize = theme.fontHero, fontWeight = "bold", color = "on_surface" })
        }),
        ui.row({ gap = 8, align = "center" }, {
            ui.column({ key = "pl-count-col", gap = 1, align = "end" }, {
                ui.label({
                    key = "pl-downloaded-label",
                    text = downloaded_count .. " downloaded",
                    fontSize = theme.fontBody,
                    fontWeight = "medium",
                    color = "on_surface"
                }),
                ui.label({
                    key = "pl-total-label",
                    text = #pl.tracks .. " total",
                    fontSize = theme.fontCaption,
                    color = "on_surface_variant"
                })
            }),
            download_btn,
            ui.button({
                key = "btn-sync-pl",
                glyph = "refresh",
                variant = "secondary",
                controlSize = "md",
                tooltip = "Refresh playlist",
                onClick = function() request("refresh_playlist", { playlist_id = pl.id }) end
            }),
            ui.button({
                key = "btn-play-all",
                text = "Play all",
                glyph = "player-play",
                variant = "primary",
                controlSize = "md",
                onClick = function() play_playlist(pl) end
            })
        })
    }))

    table.insert(view, ui.separator({ key = "sep-pl", color = "outline" }))

    local PAGE_SIZE = 100
    local total = #pl.tracks
    local total_pages = math.max(1, math.ceil(total / PAGE_SIZE))
    if playlist_view_page >= total_pages then
        playlist_view_page = math.max(0, total_pages - 1)
    end
    local page_start = playlist_view_page * PAGE_SIZE + 1
    local page_end = math.min(page_start + PAGE_SIZE - 1, total)

    local tracks = {}
    if total == 0 then
        table.insert(tracks, ui.label({
            text = pl.fetching and "Loading tracks..." or "No tracks found in playlist.",
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        }))
    else
        for abs_idx = page_start, page_end do
            local t = pl.tracks[abs_idx]
            if t then
                table.insert(tracks, media_row(t, abs_idx, function()
                    request("play_with_queue", { item = t, index = abs_idx, queue = pl.tracks, source_playlist = pl.id })
                end, state.player.id == t.id))
            end
        end

        -- Pagination controls
        local has_prev = (playlist_view_page > 0)
        local has_next_page = (playlist_view_page < total_pages - 1)
        local can_fetch_more = (pl.next_token and pl.next_token ~= "")
        local has_next = has_next_page or can_fetch_more

        local page_controls = {}
        if has_prev then
            table.insert(page_controls, ui.button({
                key = "pl-prev-page",
                text = "← Previous",
                variant = "outline",
                controlSize = "sm",
                onClick = function()
                    playlist_view_page = playlist_view_page - 1
                    render_panel()
                end
            }))
        end

        table.insert(page_controls, ui.label({
            text = page_start .. "–" .. page_end .. " of " .. total,
            fontSize = theme.fontBody,
            fontWeight = "medium",
            color = "on_surface_variant"
        }))

        if has_next then
            table.insert(page_controls, ui.button({
                key = "pl-next-page",
                text = pl.fetching and "Loading..." or "Next →",
                variant = "outline",
                controlSize = "sm",
                onClick = function()
                    local cur_total = #state.playlist.tracks
                    local cur_pages = math.max(1, math.ceil(cur_total / PAGE_SIZE))
                    if playlist_view_page < cur_pages - 1 then
                        playlist_view_page = playlist_view_page + 1
                        render_panel()
                    elseif state.playlist.next_token and state.playlist.next_token ~= "" then
                        playlist_pending_advance = true
                        request("fetch_next_page", { playlist_id = state.playlist.id, token = state.playlist.next_token })
                        render_panel()
                    end
                end
            }))
        end

        table.insert(tracks, ui.row({
            key = "pl-pagination",
            align = "center",
            justify = "center",
            gap = 12,
            padding = 10,
            borderWidth = 0
        }, page_controls))
    end

    table.insert(view, ui.column({ key = "pl-track-list", gap = 0, borderWidth = 0 }, tracks))

    return view
end

local function build_discover()
    local view = {}

    table.insert(view, ui.row({ key = "discover-title", align = "center", justify = "space_between" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "search", size = 18, color = "primary" }),
            ui.label({ text = "SEARCH RESULTS", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface_variant" })
        }),
        ui.label({
            text = state.search.query ~= "" and ("\"" .. state.search.query .. "\"") or "",
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        })
    }))

    table.insert(view, ui.separator({ key = "sep-discover", color = "outline" }))

    local rows = {}
    if state.search.pending then
        table.insert(rows, ui.label({
            text = "Searching...",
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        }))
    elseif #state.search.results == 0 then
        table.insert(rows, ui.label({
            text = "Type a query in the search bar above and press Enter.",
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        }))
    else
        for idx, t in ipairs(state.search.results) do
            table.insert(rows, media_row(t, idx, function()
                request("play_with_queue", { item = t, index = idx, queue = state.search.results })
            end, state.player.id == t.id))
        end
    end

    table.insert(view, ui.column({ key = "discover-track-list", gap = 0, borderWidth = 0 }, rows))

    return view
end

local function build_queue()
    local player = state.player
    local view = {}

    table.insert(view, ui.label({ text = "QUEUE", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface_variant" }))

    if #player.queue == 0 then
        table.insert(view, ui.label({
            text = "Nothing queued yet.",
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        }))
    else
        local PAGE_SIZE = 100
        local total = #player.queue
        local total_pages = math.max(1, math.ceil(total / PAGE_SIZE))
        if queue_view_page >= total_pages then
            queue_view_page = math.max(0, total_pages - 1)
        end
        local page_start = queue_view_page * PAGE_SIZE + 1
        local page_end = math.min(page_start + PAGE_SIZE - 1, total)

        local rows = {}
        for idx = page_start, page_end do
            local item = player.queue[idx]
            if item then
                local is_current = (idx == player.index)
                table.insert(rows, media_row(item, idx, function()
                    request("play_queue_index", { index = idx })
                end, is_current))
            end
        end

        local has_prev = (queue_view_page > 0)
        local has_next = (queue_view_page < total_pages - 1)

        local page_controls = {}
        if has_prev then
            table.insert(page_controls, ui.button({
                key = "q-prev-page",
                text = "← Previous",
                variant = "outline",
                controlSize = "sm",
                onClick = function()
                    queue_view_page = queue_view_page - 1
                    render_panel()
                end
            }))
        end

        table.insert(page_controls, ui.label({
            text = page_start .. "–" .. page_end .. " of " .. total,
            fontSize = theme.fontBody,
            fontWeight = "medium",
            color = "on_surface_variant"
        }))

        if has_next then
            table.insert(page_controls, ui.button({
                key = "q-next-page",
                text = "Next →",
                variant = "outline",
                controlSize = "sm",
                onClick = function()
                    queue_view_page = queue_view_page + 1
                    render_panel()
                end
            }))
        end

        table.insert(view, ui.column({ key = "queue-track-list", gap = 0, borderWidth = 0 }, rows))
        table.insert(view, ui.row({
            key = "q-pagination",
            align = "center",
            justify = "center",
            gap = 12,
            padding = 10,
            borderWidth = 0
        }, page_controls))
    end

    return view
end

local function build_cookies_page()
    local page = {}

    table.insert(page, ui.row({ key = "cookie-title", align = "center", justify = "space_between" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "login", size = 18, color = "primary" }),
            ui.label({ text = "COOKIES & LOGIN", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface_variant" })
        }),
        ui.button({
            text = "Back to Home",
            variant = "ghost",
            controlSize = "sm",
            onClick = function() on_nav("home") end
        })
    }))

    local status_color = "on_surface_variant"
    if state.status == "ready" then
        status_color = "primary"
    elseif state.status == "error" then
        status_color = "error"
    end

    local status_children = {
        ui.label({ text = "COOKIE STATUS", fontSize = theme.fontHeading, fontWeight = "bold", color = status_color }),
        ui.label({ text = state.status_text, fontSize = theme.fontTitle, fontWeight = "medium", color = "on_surface" })
    }
    if state.status == "ready" then
        table.insert(status_children, ui.label({
            text = "YouTube cookies: " .. state.cookie_count,
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        }))
    elseif state.status == "error" and state.last_error and state.last_error ~= "" then
        local err = state.last_error
        if #err > 220 then err = err:sub(1, 220) .. "..." end
        table.insert(status_children, ui.label({
            text = err,
            fontSize = theme.fontCaption,
            color = "on_surface_variant"
        }))
    end

    table.insert(page, ui.column({
        key = "cookie-status-card",
        gap = 8,
        padding = 14,
        borderWidth = 0,
        fill = "surface_variant/0.5"
    }, status_children))

    table.insert(page, ui.separator({ key = "sep-cookie", color = "outline" }))

    table.insert(page, ui.label({ text = "LOG IN & EXTRACT", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface_variant" }))

    local cells = build_browser_cells()

    for _, row in ipairs(chunk_rows(cells, 3, "browser-grid", 12)) do
        table.insert(page, row)
    end

    table.insert(page, ui.separator({ key = "sep-cookie-2", color = "outline" }))

    table.insert(page, ui.row({ key = "cookie-hint", align = "center", gap = 8, padding = 4 }, {
        ui.glyph({ name = "info-circle", size = 15, color = "on_surface_variant" }),
        ui.label({
            text = "Sign in to YouTube Music in a browser, then click its button to export YouTube cookies. If the browser has no session, the login page opens for you.",
            fontSize = theme.fontBody,
            color = "on_surface_variant",
            flexGrow = 1
        })
    }))

    return page
end

local function build_settings()
    local items = {}
    table.insert(items, ui.row({ key = "set-head", padding = 20 }, {
        ui.label({ text = "Settings", fontSize = theme.fontHeading, fontWeight = "bold" })
    }))

    local caches = {
        { id = "audio", name = "Audio Cache", desc = "Cached tracks for offline playback." },
        { id = "streams", name = "Stream URLs", desc = "Cached streaming URLs to speed up playback." },
        { id = "thumbnails", name = "Thumbnails", desc = "Cached album and video thumbnail images." },
        { id = "playlists", name = "Playlists", desc = "Cached library playlists and metadata." }
    }

    local cache_rows = {}
    for _, c in ipairs(caches) do
        local size = state.cache_stats and state.cache_stats[c.id] or "0"
        table.insert(cache_rows, ui.row({ key = "cache-" .. c.id, align = "center", justify = "space_between", paddingV = 12 }, {
            ui.column({ gap = 2 }, {
                ui.label({ text = c.name, fontWeight = "bold" }),
                ui.label({ text = c.desc, fontSize = theme.fontCaption, color = "on_surface_variant" })
            }),
            ui.row({ gap = 16, align = "center" }, {
                ui.label({ text = size, fontWeight = "bold", color = "primary" }),
                ui.button({
                    text = "Clear",
                    variant = "outline",
                    controlSize = "sm",
                    onClick = function()
                        request("clear_cache", { target = c.id })
                    end
                })
            })
        }))
        table.insert(cache_rows, ui.separator({ key = "sep-" .. c.id, color = "outline" }))
    end

    table.insert(items, ui.column({ 
        key = "set-card", 
        padding = 16, 
        gap = 8, 
        borderWidth = 1, 
        border = "outline", 
        fill = "surface_variant/0.2", 
        radius = 12 
    }, {
        ui.label({ text = "Storage & Cache", fontSize = theme.fontTitle, fontWeight = "bold" }),
        ui.label({ text = "Manage local cache sizes to free up disk space.", color = "on_surface_variant" }),
        ui.column({ gap = 0, paddingV = 12 }, cache_rows)
    }))

    table.insert(items, ui.row({ key = "set-spacer-1", height = 16, borderWidth = 0 }))

    for _, item in ipairs(build_cookies_page()) do
        table.insert(items, item)
    end

    return items
end

local function build_content()
    local content = {}

    if content_page == "playlist" then
        for _, item in ipairs(build_playlist_view()) do
            table.insert(content, item)
        end
    elseif content_page == "discover" then
        for _, item in ipairs(build_discover()) do
            table.insert(content, item)
        end
    elseif content_page == "queue" then
        for _, item in ipairs(build_queue()) do
            table.insert(content, item)
        end
    elseif content_page == "settings" then
        for _, item in ipairs(build_settings()) do
            table.insert(content, item)
        end
    else
        if not logged_in() then
            table.insert(content, build_signin_prompt())
        else
            for _, item in ipairs(build_home()) do
                table.insert(content, item)
            end
        end
    end

    return ui.scroll({ key = "content-scroll", flexGrow = 1, gap = 12, paddingH = 16, paddingV = 12 }, content)
end

render_panel = function()
    local body = {}

    table.insert(body, ui.row({
        key = "main-row",
        align = "stretch",
        flexGrow = 1,
        gap = 12,
        borderWidth = 0
    }, {
        build_sidebar(),

        ui.column({
            key = "right-col",
            flexGrow = 1,
            borderWidth = 0,
            gap = 0
        }, {
            build_topbar(),
            ui.separator({ key = "sep-top", color = "outline" }),
            build_content()
        })
    }))

    table.insert(body, ui.row({ key = "player-spacer", height = 12, borderWidth = 0 }))

    table.insert(body, ui.row({ key = "sep-player", height = 1, fill = "on_surface/0.3", borderWidth = 0 }))

    table.insert(body, build_player_bar())

    panel.render(ui.column({
        key = "ytmusic-root",
        gap = 0,
        padding = 0,
        flexGrow = 1
    }, body))
end

local function apply_state(s)
    if type(s) ~= "table" then return end
    state.status = s.status or state.status
    state.status_text = s.status_text or state.status_text
    state.browser = s.browser or state.browser
    state.browser_label = s.browser_label or state.browser_label
    state.cookie_count = s.cookie_count or 0
    state.extracting = (s.extracting == true)
    state.last_error = s.last_error or state.last_error
    if type(s.player) == "table" then
        local old_index = state.player.index
        for k, v in pairs(s.player) do state.player[k] = v end
        if state.player.index and state.player.index ~= old_index then
            queue_view_page = math.max(0, math.floor((state.player.index - 1) / 100))
        end
    end
    if type(s.search) == "table" then
        for k, v in pairs(s.search) do state.search[k] = v end
    end
    if type(s.library) == "table" then
        state.library = s.library
    end
    if type(s.playlist) == "table" then
        local old_count = #state.playlist.tracks
        for k, v in pairs(s.playlist) do state.playlist[k] = v end
        state.playlist.next_token = s.playlist.next_token
        state.playlist.fetching = (s.playlist.fetching == true)
        if playlist_pending_advance and #state.playlist.tracks > old_count then
            playlist_pending_advance = false
            playlist_view_page = playlist_view_page + 1
        end
    end
    if type(s.liked_ids) == "table" then
        state.liked_ids = s.liked_ids
    end
    if type(s.cached_audio_ids) == "table" then
        state.cached_audio_ids = s.cached_audio_ids
    end
    if type(s.downloaded_playlist_ids) == "table" then
        state.downloaded_playlist_ids = s.downloaded_playlist_ids
    end
    if type(s.quick_picks) == "table" then
        state.quick_picks = s.quick_picks
    end
    if type(s.home_mixes) == "table" then
        state.home_mixes = s.home_mixes
    end
    if type(s.system_radius) == "number" then
        state.system_radius = s.system_radius
    end
    if type(s.cache_stats) == "table" then
        state.cache_stats = s.cache_stats
    end
    if type(s.settings) == "table" then
        state.settings = s.settings
    end
    if type(s.available) == "table" then
        state.available = {}
        for k, v in pairs(s.available) do state.available[k] = v end
    end
    render_panel()
end

function onOpen(_context)
    local curr = noctalia.state.get(STATE)
    if curr then apply_state(curr) end
end

if noctalia.state and noctalia.state.watch then
    noctalia.state.watch(STATE, apply_state)
    local curr = noctalia.state.get(STATE)
    if curr then apply_state(curr) end
end

render_panel()