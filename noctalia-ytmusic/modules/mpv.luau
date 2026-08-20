local Mpv = {}
local Bash = require("../utils.luau").Bash

function Mpv.play(url, volume)
    noctalia.writeFile("/tmp/noctalia-ytmusic-url.txt", url)
    Bash.run_script("mpv.sh", "mpv_play", function() end, 10000, tostring(volume or 100))
end

function Mpv.send(payload_json)
    Bash.run_script("mpv.sh", "mpv_send", function() end, 5000, payload_json)
end

function Mpv.kill()
    Bash.run_script("mpv.sh", "mpv_kill", function() end, 2000)
end

function Mpv.poll(cb, timeout)
    Bash.run_script("mpv.sh", "mpv_poll", cb, timeout or 6000)
end

return Mpv