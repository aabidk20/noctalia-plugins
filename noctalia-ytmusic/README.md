# Noctalia YT Music

A YouTube Music client for Noctalia v5: a bar/item miniplayer and a full
shell panel. Inspired by [Omarchy-Spotify](https://github.com/stappmus/Omarchy-Spotify).

## Features

- **Miniplayer** — floating widget with track title/artist/art, play/pause,
  previous/next, shuffle and repeat (off/all/one), seek scrub bar, volume
  slider and mute, like/unlike, and a hover tooltip showing codec, bitrate,
  sample rate, and output
- **Full panel** — home feed (Quick Picks, recommended mixes & radios, your
  library), playlist view with pagination and "Play all", search, queue with
  jump-to-track, and a cookies & login page
- **Playback** — queue-based control (track, playlist, search, queue index),
  session restore on restart, and prefetching of upcoming streams to avoid gaps
- **Offline** — cache individual tracks or entire playlists; audio, stream,
  thumbnail, and playlist caches are sized and clearable in Settings
- **Auth** — cookie extraction from Chrome, Chromium, Firefox, Edge, Brave,
  Opera, Vivaldi, Whale, or Zen

## Shortcuts

- `Mod+M` — toggle the full panel (e.g. bound in your compositor's
  keybinds as `noctalia msg panel-toggle aabidk20/noctalia-ytmusic:panel`).
  Example for [niri](https://github.com/YaLTeR/niri):

  ```kdl
  Mod+M hotkey-overlay-title="YT Music: Toggle" { spawn "noctalia" "msg" "panel-toggle" "aabidk20/noctalia-ytmusic:panel"; }
  ```

## Dependencies

External tools the plugin shells out to:

- `yt-dlp` - stream URL resolution
- `mpv` - playback engine
- `mpris-mpv` - MPRIS control of mpv (optional)
- `jq` - JSON parsing in API scripts
- `curl` - YouTube API requests
- `nc` - mpv socket IPC

## License

MIT
