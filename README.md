<p align="center">
  <img src="assets/images/tater-tube-readme.png" alt="Tater Tube" width="520">
  <br>
  <a href="https://tatertube.tv">Tatertube.tv</a>
  ·
  <a href="https://github.com/TaterTotterson/tater-tube-server">Tater Tube Server</a>
</p>

# Tater Tube

Tater Tube is a retro VCR-style media frontend for Raspberry Pi appliance builds.

It ships as ready-to-flash Raspberry Pi images for:

- Raspberry Pi 4 composite NTSC
- Raspberry Pi 4 composite PAL
- Raspberry Pi 5 HDMI auto-resolution

The image boots straight into Tater Tube with the boot screen, Argon IR defaults, Bluetooth gamepad pairing, SSH for debugging, RetroArch support, yt-dlp support, and the module runtime already installed.

## Modules

### The Tube

The Tube connects Tater Tube to [Tater Tube Server](https://github.com/TaterTotterson/tater-tube-server). This is the server-backed module for Newznab streaming, local server libraries, server-side transcoding, and custom Local TV Mode channels.

- Pair with a short PIN from the Tater Tube Server web UI
- Browse Stream and Local sections separately
- Stream includes Newznab movie, TV, music, search, and trending views
- Local includes movie, TV, and folder libraries configured on the server
- Local TV Mode supports custom channels, automatic channels, commercials, and live timeline channel switching
- Player-side quality options can request Auto, CRT 480p, HDMI 1080p, or HDMI 4K transcoding
- Server keeps Newznab credentials, local media paths, hardware transcoding settings, and library scanning off the Pi

Run Tater Tube Server on a NAS, desktop, or home server, usually through Docker. Map `/config` for server settings, map any local media folders you want to expose, and pass hardware devices such as `/dev/dri` when using hardware transcoding. Full server setup lives in the [server repo](https://github.com/TaterTotterson/tater-tube-server).

### Video on Demand

- Emby, Jellyfin, and Plex library browsing
- Plex PIN sign in through `https://plex.tv/link`
- Movies, TV, Other Videos, resume playback, autoplay next episode, audio tracks, and subtitles
- TV Mode creates movie, TV, genre, cartoon, classic, and decade-style channels when metadata is available
- Custom TV Mode channels can be created in Web Setup from selected movies and series
- Local commercial categories can be used between videos and as optional mid-roll breaks

### Tape Deck

- Streams music from Emby/Jellyfin, Plex, or Tater Tube Server
- Shows each album as a tape
- Cassette-style playback screen with audio-reactive VU bars
- Next track uses a short tape-style fast-forward effect

### Over The Air

- Direct HDHomeRun playback
- No guide required
- Opens like an old TV tuner
- Up/down changes channels during playback

### Public Access

- Plays saved YouTube playlists through mpv and yt-dlp
- Accepts a full playlist URL or just the playlist code
- Supports multiple playlists, playlist refresh, autoplay next, and shuffle
- TV Mode turns playlists into shuffled channels with optional local commercials

### Game Center

- Browses RetroNAS/MiSTer-style ROM folders
- Launches directly into RetroArch
- Supports common Pi-friendly systems up through PlayStation when matching cores are available
- Uses one global RetroPad controller map across cores

### PC Link

- Pairs with Sunshine hosts through Moonlight
- Lists and launches Sunshine apps
- Includes CRT, HD, 1440p, and 4K stream presets
- Controller streaming depends on host-side virtual gamepad support

### Local Files

- Browses folders on the Pi
- Plays common video formats
- Supports `m3u` and `m3u8` playlists
- Loop and shuffle options

## Web Setup

Open this from a phone or computer on the same network:

```text
http://tatertube.local:24024/setup
```

Use Web Setup for module logins, API keys, HDHomeRun setup, Tater Tube Server pairing, RetroNAS paths, Sunshine pairing, Bluetooth/gamepad settings, local commercial uploads, and custom TV Mode channels.

Commercials are local files uploaded into categories. Video on Demand, Public Access TV Mode, and The Tube Local TV Mode can all use the selected commercial categories without relying on YouTube playlists.

If `MP240_API_TOKEN` is set, Web Setup and API calls require `Authorization: Bearer <token>` or `X-240MP-Token: <token>`.

## Local API

Tater Tube includes a small HTTP API for companion apps and voice-assistant bridges. It runs on port `24024` in the Pi image.

```bash
curl http://tatertube.local:24024/api/v1/status
```

Useful endpoints:

```text
GET  /api/v1/status
POST /api/v1/player/play-pause
POST /api/v1/player/pause
POST /api/v1/player/resume
POST /api/v1/player/stop
POST /api/v1/player/seek          {"position_ms": 60000} or {"offset_ms": 30000}
POST /api/v1/player/skip-forward  {"offset_ms": 30000}
POST /api/v1/player/skip-back     {"offset_ms": -10000}
POST /api/v1/player/volume-up
POST /api/v1/player/volume-down
POST /api/v1/player/mute
POST /api/v1/player/key           {"key": "LEFT", "repeat": 1}
POST /api/v1/library/search       {"query": "batman", "types": ["movie", "show", "game"], "limit": 10}
POST /api/v1/library/launch       {"id": "vod:movie:ITEM_ID"}
```

Search results return launch IDs such as `vod:movie:...`, `vod:show:...`, and `game:nes:...`.

## Install

- [Flash the ready-to-flash Raspberry Pi image](INSTALL.md#flash-the-ready-to-flash-image)
- [Update an existing Tater Tube image](INSTALL.md#update-an-existing-tater-tube-image)
- [Build a custom image](INSTALL.md#build-a-custom-image)
- [Development builds](BUILDING.md)

Download the latest `.img.xz` for your display from the GitHub release page, flash it with Raspberry Pi Imager or Balena Etcher, and boot the Pi.

Release builds reuse a checksum-pinned ARM64 runtime bundle for Moonlight and
the native Game Center ports. This keeps the project open source while avoiding
four identical multi-hour engine rebuilds for every application tag; bundle
sources and rebuild commands are documented in [BUILDING.md](BUILDING.md).

## Hardware Notes

- Pi 4 composite images default to analog video and analog audio
- Pi 5 HDMI image uses the display's preferred EDID mode
- Argon IR receiver default is GPIO23, physical pin 16
- Argon ONE fan control supports Auto, Off, and fixed-speed settings
- SSH is enabled for debugging on the ready-to-flash images

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for the full text.

You are free to use, study, and modify this code. If you distribute a modified version, you must also distribute it under GPL-3.0 and make the source available.

## Credits

Tater Tube started as a fork of [anthonycaccese/240-MP](https://github.com/anthonycaccese/240-MP). This fork is focused on appliance-style Pi images, The Tube, Emby/Jellyfin and Plex playback, HDHomeRun OTA, Public Access playlists, Tape Deck, RetroNAS games, PC Link, and Argon IR defaults.
