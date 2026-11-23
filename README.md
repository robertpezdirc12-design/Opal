<div align="center">

<img src="assets/logo.svg" width="72" alt="Opal" />

# Opal

### The open-source Netflix, Spotify, Crunchyroll and Plex/Jellyfin alternative — in one native binary.

#### Movies, shows, anime, live TV, torrents, music, podcasts, comics, manga and local AI

`Native player · Torrent streaming · Movie & TV hub · Anime · YouTube · Live TV<br>
Manga & comics · Jellyfin & Plex client · DLNA casting · Watch parties · Subtitles<br>
Downloads · RSS · Plugins · Local AI · Voice control · Agent automation`

[![Release](https://img.shields.io/github/v/release/robertpezdirc12-design/Opal?label=release&color=8b5cf6)](https://github.com/robertpezdirc12-design/Opal/releases/latest)
[![CI](https://github.com/robertpezdirc12-design/Opal/actions/workflows/ci.yml/badge.svg)](https://github.com/robertpezdirc12-design/Opal/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-8b5cf6)](LICENSE)
[![Zig 0.17](https://img.shields.io/badge/zig-0.17-f7a41d)](https://ziglang.org)

**Windows · macOS · Linux · iOS · Android (preview)**

[Releases](https://github.com/robertpezdirc12-design/Opal/releases) ·
[Features](#features) · [Install](#install) · [Build](#build-from-source) ·
[Docs](#documentation) · [Changelog](CHANGELOG.md)

</div>

![Sintel playing in Opal's native player.](assets/readme/sintel-player.webp)

<sub>Native UI preview. Sintel © Blender Foundation, [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). [Credits](assets/readme/CREDITS.md).</sub>

## About this repository

This is the **Windows-focused build of Opal**, tracking
[`debpalash/Opal`](https://github.com/debpalash/Opal) upstream. Upstream `main`
is merged automatically every week by the [sync workflow](.github/workflows/sync-upstream.yml),
so features and fixes arrive here without manual porting; the local work adds
**ready-to-run Windows artifacts** and **network casting to DLNA/UPnP televisions**.

| | |
| --- | --- |
| **Upstream** | [debpalash/Opal](https://github.com/debpalash/Opal) — original project by Palash |
| **This build** | Windows `.msi` / portable `.zip`, verified casting to living-room TVs |
| **Version** | `0.9.6` (see [`build.zig.zon`](build.zig.zon) and [CHANGELOG](CHANGELOG.md)) |
| **License** | GPL-3.0 |

## Why Opal

Streaming is split across subscriptions, servers and a dozen apps. Opal puts it
in **one native app**: no server to run, no account to create, no subscription,
no telemetry.

| | **Opal** | Netflix | Plex | Jellyfin |
| --- | :---: | :---: | :---: | :---: |
| Free & open source | ✅ | ❌ | ❌ | ✅ |
| No server required | ✅ | ✅ | ❌ | ❌ |
| No account or subscription | ✅ | ❌ | ❌ | ✅ |
| Your own files and sources | ✅ | ❌ | ✅ | ✅ |
| Torrent streaming | ✅ | ❌ | ❌ | ❌ |
| YouTube, live TV, manga in the same app | ✅ | ❌ | ❌ | ❌ |
| Local AI & agent automation | ✅ | ❌ | ❌ | ❌ |
| Plays both Plex & Jellyfin libraries | ✅ | ❌ | Plex only | Jellyfin only |

<sub>Opal is a player and source hub. It ships no catalog and no Netflix titles;
it connects to Plex and Jellyfin servers rather than replacing them.</sub>

<a id="features"></a>

## Features

| | |
| --- | --- |
| 🎬 **Movie & TV hub** | Netflix-style discovery, details, watchlists and resume, from your own files and sources. |
| 🧲 **Torrent streamer** | Stream a magnet while it downloads, with queues, transfer stats and an optional in-memory buffer. |
| 🌸 **Anime player** | Anime sources, airing schedules and subtitle tracks. |
| ▶️ **YouTube client** | Search and play, with SponsorBlock and browser handoff. |
| 📺 **Live TV** | IPTV and M3U channels from the sources you enable. |
| 📚 **Manga & comics** | A built-in reader with Suwayomi and Mihon/Tachiyomi extensions. |
| 🗂️ **Jellyfin & Plex client** | Browse and play your existing server libraries. |
| 📡 **DLNA casting** | Send the current stream or a local file to any UPnP/DLNA TV on your network — one click, no device picker when you own one TV. |
| 🌐 **Web browser** | Tabs, extensions and send-to-player. |
| 💬 **Subtitles & translation** | Pick tracks, fetch subtitles and translate them on the fly. |
| ⬇️ **Downloads & RSS** | Download queues, plus RSS feeds for torrents and podcasts. |
| 🧩 **Plugins** | Install only the sources you want; every source starts disabled. |
| 🧠 **Local AI & voice** | Optional on-device recommendations, voice control and OCR. |
| 🤖 **Agent automation** | 100+ MCP tools so Claude Code, Codex or any MCP client can search, play, queue and download. |

[Source coverage](docs/browse-sources.md) · [Roadmap](ROADMAP.md)

## See it

<table>
<tr>
<td width="50%"><img src="assets/readme/bunny-player.webp" alt="Big Buck Bunny playing in Opal's native player." /></td>
<td width="50%"><img src="assets/readme/connections.webp" alt="Opal's Connect screen for Plex, Jellyfin and other services." /></td>
</tr>
<tr>
<td align="center"><sub><b>Native player.</b> Big Buck Bunny © 2008 Blender Foundation, CC BY 3.0.</sub></td>
<td align="center"><sub><b>Connect.</b> Plex, Jellyfin, indexers and more.</sub></td>
</tr>
<tr>
<td width="50%"><a href="assets/media/stream-a-torrent.mp4"><img src="assets/readme/torrent.webp" alt="Sintel streaming from a torrent in Opal." /></a></td>
<td width="50%"><img src="assets/releases/v0.9.3/browser.png" alt="Opal's native browser with tabs and extensions." /></td>
</tr>
<tr>
<td align="center"><sub><b>Torrent streaming</b> (<a href="assets/media/stream-a-torrent.mp4">watch</a>). Sintel © Blender Foundation, CC BY 3.0.</sub></td>
<td align="center"><sub><b>Built-in browser</b> with tabs and extensions.</sub></td>
</tr>
</table>

<a id="install"></a>

## Install

### Windows (this build)

Grab the latest artifact from
[**Releases**](https://github.com/robertpezdirc12-design/Opal/releases/latest):

| Artifact | Use |
| --- | --- |
| `Opal-<version>-windows-x64.msi` | Standard installer |
| `Opal-<version>-windows-x64.zip` | Portable folder — unzip and run `opal.exe` |

Portable installs ship `opal-server.bat` (loopback) and `opal-server-lan.bat`
(home network) for the headless phone web UI; authentication still gates every
route. Windows builds are self-contained: no runtime, MPV or Python install
required.

<details>
<summary><b>Windows notes</b></summary>

- SmartScreen may warn about an unsigned installer — choose **More info → Run anyway**.
- Settings and cache live in `%APPDATA%\opal` and `%LOCALAPPDATA%\opal\cache`.
- Report problems with the [bug template](.github/ISSUE_TEMPLATE/bug_report.yml).

</details>

### macOS and Linux

Upstream packaging is distributed from
[debpalash/Opal releases](https://github.com/debpalash/Opal/releases):

| Platform | Install |
| --- | --- |
| **macOS** (Apple silicon) | `.dmg`, or `brew install debpalash/tap/opal` |
| **Linux** | AppImage, `.deb`, `.rpm`, or AUR `opal-media-player-bin` |
| **iOS** (preview) | Sideload the `.ipa`, or [build for your device](docs/ios.md) |
| **Android** (preview) | Sideload the `.apk`, or [build it](docs/android.md) |

Or build from source below — that path works for every platform.

**First launch:** browse **Movies & TV** right away, or add sources in
**Settings → General → Install source plugins**.

<a id="build-from-source"></a>

## Build from source

**Zig 0.17 · dvui · mpv** — one native binary, no Electron and no web runtime.

### Windows (MSYS2 / MINGW64)

```sh
# In an MSYS2 MINGW64 shell
pacman -S --needed base-devel mingw-w64-x86_64-toolchain \
  mingw-w64-x86_64-sqlite3 mingw-w64-x86_64-SDL2 \
  mingw-w64-x86_64-libwebp mingw-w64-x86_64-libtorrent-rasterbar

./scripts/install-mingw64-mpv.sh      # pinned libmpv built for MINGW64
git clone https://github.com/robertpezdirc12-design/Opal.git
cd Opal
zig build -Doptimize=ReleaseSafe
./zig-out/bin/opal.exe
```

`build.zig` reads `MINGW_PREFIX` for include and library paths (the counterpart
of `HOMEBREW_PREFIX` on macOS), and the torrent wrapper is built as
`torrent_wrapper.dll` by the same shell step.

### macOS

```sh
brew install mpv sqlite sdl2 libtorrent-rasterbar webp
git clone https://github.com/robertpezdirc12-design/Opal.git && cd Opal
zig build run
```

### Linux

```sh
./scripts/install-deps.sh
make run
```

Minimums: libmpv **0.34** (0.38+ recommended), libtorrent-rasterbar 2.0,
SDL 2.0.22, glibc 2.38+.

| Command | Purpose |
| --- | --- |
| `zig build run` | Build and launch |
| `zig build test` | Unit tests |
| `./dev.sh` | Hot reload |
| `just release` | Optimized build |
| `just test-all` | Full feature suite |

[Architecture](docs/architecture.md) · [Distribution notes](docs/DISTRIBUTION.md) ·
[Contributing](.github/CONTRIBUTING.md)

## Casting to a TV

Opal casts over **DLNA/UPnP**, so any modern smart TV works without a
Chromecast or an account.

1. Connect the PC and the TV to the same network.
2. Open a video and click the **cast icon** in the player footer.
3. The first click scans the LAN and casts to the television it finds; clicking
   again re-casts, and clicking while casting stops playback on the TV.

Local files are served straight from the PC over the LAN — the TV receives a
real HTTP URL instead of a Windows path, so files on disk play exactly like
streamed titles. Discovery probes every local IPv4 interface, which keeps
casting working while a VPN adapter (WARP, Tailscale) holds the default route.

## Control it from anywhere

- **From your phone:** enable **Settings → Web UI**, set **Network** to **LAN**
  and scan the QR code. [Phone guide](docs/web-companion.md)
- **From your browser:** the [Opal Connect](extension/README.md) extension for
  Chrome, Edge and Firefox sends videos to Opal and controls playback.
- **From an AI agent:** enable **Settings → Agent Access** and connect
  `opal-mcp` to Claude Code, Codex, Gemini CLI or any MCP client. Destructive
  tools stay off until you opt in. [Agent guide](docs/mcp.md)

<a id="documentation"></a>

## Documentation

| Document | Contents |
| --- | --- |
| [Architecture](docs/architecture.md) | Module layout, threading and the Zig–C seams |
| [Free sources](docs/FREE-SOURCES.md) | Legal catalogs: public-domain film, subtitles, archives |
| [Distribution](docs/DISTRIBUTION.md) | Packaging, CI artifacts and platform support |
| [Web companion](docs/web-companion.md) | Phone web UI and LAN setup |
| [Agent & MCP](docs/mcp.md) | Tool surface and automation |
| [Privacy](docs/PRIVACY.md) · [Content policy](docs/CONTENT_POLICY.md) | Data handling and acceptable use |
| [Roadmap](ROADMAP.md) · [Changelog](CHANGELOG.md) | What is next, what changed |

## Contributing

Issues and pull requests are welcome. Read
[CONTRIBUTING.md](.github/CONTRIBUTING.md) and the
[Code of Conduct](.github/CODE_OF_CONDUCT.md) first. A change should build with
`zig build`, pass `zig build test`, and keep the architecture gates green.

[Report a bug](.github/ISSUE_TEMPLATE/bug_report.yml) ·
[Request a feature](.github/ISSUE_TEMPLATE/feature_request.yml) ·
[Support](.github/SUPPORT.md) · [Security](.github/SECURITY.md)

## Support the project

The original project is maintained by Palash — if Opal is useful to you,
[star the upstream repository](https://github.com/debpalash/Opal/stargazers) or
support it through [Ko-fi](https://ko-fi.com/debpalash) /
[PayPal](https://paypal.me/palashCoder).

---

<sub>**GPL-3.0.** [License](LICENSE) · [Notices](docs/NOTICE.md). Opal plays
sources you configure; it hosts no media and provides no Netflix titles. Not
affiliated with Netflix, Plex or Jellyfin. Only access content you have the
right to use. BitTorrent shares your IP with peers.
[Content policy](docs/CONTENT_POLICY.md) · [Privacy](docs/PRIVACY.md) ·
[DMCA](docs/DMCA.md)</sub>
