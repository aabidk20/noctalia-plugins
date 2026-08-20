local store = require("./store.luau")
local api = require("../api.luau")

local state = store.state

local Home = {}

function Home.fetch_home_thumbs()
    if not (api and api.ensure_thumbnails) then return end
    local combined = {}
    if type(state.quick_picks) == "table" then
        for _, item in ipairs(state.quick_picks) do table.insert(combined, item) end
    end
    if type(state.home_mixes) == "table" then
        for _, item in ipairs(state.home_mixes) do table.insert(combined, item) end
    end
    if #combined > 0 then
        noctalia.runAsync("true", function()
            api.ensure_thumbnails(combined, store.publish, "home")
        end)
    end
end

return Home