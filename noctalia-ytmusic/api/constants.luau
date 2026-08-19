--!strict

-- Shared YT Music API constants.
-- Scope: api/* only. service.luau / panel.luau never touch these directly.

local XDG_CACHE = noctalia.getenv("XDG_CACHE_HOME")

local EXPO = {}

EXPO.KEY = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
EXPO.CLIENT_VERSION = "1.20240813.01.00"
EXPO.BASE = "https://music.youtube.com/youtubei/v1/"
EXPO.ORIGIN = "https://music.youtube.com"
EXPO.COOKIE_PATH = noctalia.expandPath(XDG_CACHE and XDG_CACHE ~= "" and XDG_CACHE or "~/.cache") .. "/noctalia-ytmusic/cookies.txt"
EXPO.CONTEXT = {
    context = {
        client = {
            clientName = "WEB_REMIX",
            clientVersion = EXPO.CLIENT_VERSION,
            hl = "en",
        },
    },
}

return EXPO