local XDG_CACHE = noctalia.getenv("XDG_CACHE_HOME")
local DEBUG_LOG_PATH = noctalia.expandPath(XDG_CACHE and XDG_CACHE ~= "" and XDG_CACHE or "~/.cache") .. "/noctalia-ytmusic/debug.log"

local function debug_enabled()
    return noctalia.getConfig("debug_logging") == true
end

local function log(tag, msg)
    if not debug_enabled() then return end
    local line = "[" .. tag .. "] " .. msg
    print(line)
    local prev = noctalia.readFile(DEBUG_LOG_PATH) or ""
    noctalia.writeFile(DEBUG_LOG_PATH, prev .. line .. "\n")
end

return {
    log = log,
    debug_enabled = debug_enabled,
    DEBUG_LOG_PATH = DEBUG_LOG_PATH
}