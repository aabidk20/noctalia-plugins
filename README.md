# noctalia-plugins

A collection of plugins for [Noctalia v5](https://docs.noctalia.dev/v5/plugins/).

## Plugins

| Plugin | ID | Description | API |
| --- | --- | --- | --- |
| [Noctalia YT Music](noctalia-ytmusic/) | `aabidk20/noctalia-ytmusic` | YouTube Music client - miniplayer & full view | 22 |

## Installing

Add this repo as a git source in Noctalia settings
(Settings → Plugins), using your GitHub repo URL, then enable the plugins.

## Development

Each plugin lives in its own subdirectory matching the part of the id after
the `/` (so `aabidk20/noctalia-ytmusic` lives at `noctalia-ytmusic/`). The
`catalog.toml` at the repo root indexes every plugin so Noctalia can list and
compat-check them without a full clone.

