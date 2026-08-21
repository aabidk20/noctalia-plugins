local Downloader = {}

local store = require("./store.luau")
local api = require("../api.luau")
local logger = require("../utils/log.luau")
local library = require("./library.luau")

local const = require("../api/constants.luau")
local AUDIO_DIR = const.AUDIO_DIR
local THUMB_DIR = const.THUMB_DIR

local state = store.state
local log = logger.module("ytm", "downloader")

local publish = store.publish

local DL_CONCURRENCY = 2
local queue = {}         -- { plid = <playlist id or "">, id = <video id>, meta? }
local inflight = {}      -- video id -> plid
local active = 0
local pending = {}       -- plid -> number of queue entries waiting/done once

-- Standalone downloads (download button outside a playlist) keep their
-- metadata in state.offline_meta so the audit's Saved-Tracks rebuild can
-- label them. Lives on store state but is deliberately NOT published.

local function remember_saved_meta(id, meta)
    if type(meta) ~= "table" then return end
    state.offline_meta[id] = {
        title = meta.title,
        artist = meta.artist,
        duration = tonumber(meta.duration) or 0,
        thumbnail_url = meta.thumbnail_url
    }
end

local function note_offline_row(id, meta)
    local list = state.offline_tracks or {}
    for _, t in ipairs(list) do
        if t.id == id then return end
    end
    local m = meta or {}
    local info = noctalia.fileInfo(AUDIO_DIR .. "/" .. id .. ".opus")
    local thumb = THUMB_DIR .. "/" .. id .. ".jpg"
    table.insert(list, 1, {
        id = id,
        title = m.title,
        artist = m.artist or "",
        duration = tonumber(m.duration) or 0,
        thumbnail_url = m.thumbnail_url,
        thumb_path = noctalia.fileExists(thumb) and thumb or nil,
        added_at = (info and info.mtime) or os.time()
    })
    state.offline_tracks = list
end

local function pl_done(plid)
    local is_inflight = false
    for vid, pid in pairs(inflight) do
        if pid == plid then is_inflight = true break end
    end
    pending[plid] = nil
    return not is_inflight
end

local function unlock_playlist(plid)
    state.downloading_playlist_ids[plid] = nil
    library.audit_downloaded_playlists()
    publish()
end

local function pump()
    while #queue > 0 and active < DL_CONCURRENCY do
        local item = table.remove(queue, 1)
        local plid = item.plid or ""
        local id = item.id
        pending[plid] = (pending[plid] or 1) - 1
        if pending[plid] < 0 then pending[plid] = 0 end
        if id and id ~= "" and not inflight[id] and not state.cached_audio_ids[id] then
            inflight[id] = plid
            active = active + 1
            api.cache_audio(id, function(ok)
                active = active - 1
                inflight[id] = nil
                if ok then
                    state.cached_audio_ids[id] = true
                    if plid == "" then
                        note_offline_row(id, item.meta)
                    end
                else
                    log("download: failed for id=" .. tostring(id))
                end
                if pl_done(plid) then
                    if plid ~= "" then
                        unlock_playlist(plid)
                    elseif active == 0 and #queue == 0 then
                        library.audit_downloaded_playlists()
                        publish()
                    end
                end
                pump()
            end)
        end
    end
end

function Downloader.enqueue(id, plid, meta)
    if not id or id == "" or inflight[id] or state.cached_audio_ids[id] then
        return
    end
    local pid = plid or ""
    if pid == "" then
        remember_saved_meta(id, meta)
    end
    table.insert(queue, { plid = pid, id = id, meta = (pid == "") and state.offline_meta[id] or nil })
    pending[pid] = (pending[pid] or 0) + 1
    if pid ~= "" then
        state.downloading_playlist_ids[pid] = true
    end
    pump()
end

function Downloader.enqueue_playlist(tracks, plid)
    local pid = tostring(plid or "")
    local queued = 0
    if api and api.cache_audio and type(tracks) == "table" then
        for _, tr in ipairs(tracks) do
            if tr.id and tr.id ~= "" then
                Downloader.enqueue(tr.id, pid)
                queued = queued + 1
            end
        end
    end
    if queued > 0 then
        publish()
    end
    log("download_playlist: queued " .. queued .. " tracks")
    return queued
end

return Downloader