# noctalia-plugins

A collection of plugins for [Noctalia v5](https://docs.noctalia.dev/v5/plugins/).

## Plugins

| Plugin | ID | Description | API |
| --- | --- | --- | --- |
| [YouTube Music](yt-music/) | `aabidk20/yt-music` | YouTube Music client - miniplayer & full view | 23 |

## Installing

Add this repo as a git source in Noctalia settings
(Settings → Plugins), using your GitHub repo URL, then enable the plugins.

## Development

Each plugin lives in its own subdirectory matching the part of the id after
the `/` (so `aabidk20/yt-music` lives at `yt-music/`). The
`catalog.toml` at the repo root indexes every plugin so Noctalia can list and
compat-check them without a full clone.

