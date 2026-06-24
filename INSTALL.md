# Install CRT Station

CRT Station is meant to be used as a ready-to-flash Raspberry Pi 4 appliance image for a CRT over composite video.

The release images are built for:

- Raspberry Pi 4
- Composite video output to a CRT, with separate NTSC and PAL image assets
- Emby/Jellyfin or Plex media libraries
- HDHomeRun OTA tuners
- YouTube playlists
- RetroNAS/MiSTer ROM shares
- Sunshine/Moonlight PC Link hosts
- Bluetooth controllers
- Argon IR remote support
- GPIO IR receiver on GPIO23, physical pin 16
- Boot screen and automatic launch straight into CRT Station
- SSH debugging

## Flash the ready-to-flash image

1. Open the [latest release](https://github.com/TaterTotterson/CRT-Station/releases/latest).
2. Download the `image_...crt-ntsc...img.xz` asset for an NTSC CRT, or the `image_...crt-pal...img.xz` asset for a PAL CRT.
3. Flash it to an SD card with Raspberry Pi Imager, Balena Etcher, or `dd`.
4. Put the SD card in a Raspberry Pi 4.
5. Connect the Pi to the CRT using composite video.
6. Boot the Pi.

The image boots directly into CRT Station. The default login is `tater` / `pi` for SSH and recovery access.

If this image will leave your own network, build a custom image with a stronger password first.

## Default Hardware Setup

### Composite Video

The release page has separate ready-to-flash images for NTSC and PAL composite output through the Raspberry Pi 4 3.5mm AV jack. Pick the image that matches your CRT video standard.

Custom local image builds default to `PI_IMAGE_PROFILE=crt-ntsc`. Use `PI_IMAGE_PROFILE=crt-pal` for PAL.

Use a known-good Raspberry Pi compatible composite cable. The 3.5mm AV cable pinout matters; some camcorder-style cables swap video and audio.

### Argon IR Remote

The image enables GPIO IR support by default for the Argon IR Remote for Argon Raspberry Pi cases.

Default IR receiver wiring:

| IR receiver | Raspberry Pi |
| --- | --- |
| Data | GPIO23, physical pin 16 |
| VCC | 3.3V |
| GND | Ground |

The built-in keymap includes Argon remote scancodes. If your remote uses different scancodes, SSH into the Pi and run:

```bash
sudo 240mp-ir-learn
```

Then copy the printed scancodes into `/etc/rc_keymaps/240mp.toml` and reload:

```bash
sudo systemctl restart 240mp-ir-keymap.service
```

### Bluetooth Controllers

The Pi image includes BlueZ and a Settings screen helper for Bluetooth controller pairing.

1. Put the controller in pairing mode.
2. Open Settings.
3. Turn Bluetooth on if needed.
4. Select Scan Controllers.
5. Select the controller to pair, trust, and connect it.

After pairing, the controller appears as a normal Linux input device. CRT Station uses SDL for menu navigation, and Game Center launches RetroArch so the same controller can be mapped or auto-detected there.

CRT Station seeds a default controller layout from the first connected gamepad. Use Settings, then Map Controller, only when you want to override the default buttons. The mapper writes CRT Station navigation bindings and RetroArch player-one RetroPad bindings. RetroArch cores share that global layout.

Paired and trusted Bluetooth controllers are retried automatically after boot and while the system is running. If a controller powers off, turn it back on normally; it should reconnect without forgetting and pairing again.

### Boot And Recovery

The image shows the CRT Station boot screen and starts the app automatically.

SSH is enabled by default. The Settings screen can toggle SSH on or off.

If the display is black or stuck, press `Ctrl+Alt+F2` to open the recovery console on `tty2`, log in, and inspect the service logs:

```bash
journalctl -u 240mp -b
```

To return to the app:

```bash
sudo systemctl start 240mp
```

## Video On Demand Setup

### Emby/Jellyfin

1. Boot into CRT Station.
2. Open Settings, then Video on Demand.
3. Set Provider to `EMBY/JELLYFIN`.
4. Open the Video on Demand module.
5. Enter your local Emby or Jellyfin server URL.
6. Sign in.
7. Choose the libraries you want shown on the CRT UI.

### Plex

1. Boot into CRT Station.
2. Open Settings, then Video on Demand.
3. Set Provider to `PLEX`.
4. Open the Video on Demand module.
5. On another device, open `https://plex.tv/link`.
6. Enter the code shown on the CRT.
7. Select your Plex server if more than one is available.

The Mixtapes module uses the same selected media provider as Video on Demand.

## Over The Air Setup

1. Connect the HDHomeRun tuner to the same network as the Raspberry Pi.
2. Open Settings, then Over The Air.
3. Enter the HDHomeRun IP address.
4. Open the Over The Air module.

The OTA module connects directly to the HDHomeRun and opens into TV playback without a guide screen. Up/down changes channels while video is playing.

## Public Access Setup

1. Open the Public Access module.
2. Add a public YouTube playlist URL or just the playlist `list` code.
3. Pick a saved playlist.
4. Pick a video from the VHS-style list.

Saved playlists load automatically on later launches. The Pi image installs `yt-dlp` so mpv can stream YouTube videos directly. Public Access defaults to 360p for reliable CRT/Pi playback; change Quality in Settings if needed.

## Game Center Setup

1. Set up RetroNAS with the MiSTer share enabled.
2. Put ROMs in the MiSTer `games` folder layout, for example `games/NES`, `games/Genesis`, or `games/PSX`.
3. Open the Game Center module.
4. Enter the RetroNAS host, share, and path. Defaults are `retronas.local`, `mister`, and `games`.
5. Enter a username and password if the share is not guest-accessible.

The Pi image installs RetroArch and tries to install the supported libretro cores automatically. The module only shows systems that have both a ROM folder and an installed core. Games launch directly into RetroArch; press Home on the remote to stop the game and return to the CRT Station menu.

Bluetooth pairing only connects the controller. Button layout is handled by the global controller mapper/RetroArch input mapping layer.

## PC Link Setup

1. Install and configure Sunshine on the PC or Mac you want to stream from.
2. Add Steam, games, or desktop apps in the Sunshine web UI.
3. In CRT Station, open Settings, then PC Link.
4. Enter the Sunshine host IP address or hostname.
5. Pick a stream resolution. The default is `640x480`.
6. Open PC Link and choose Enter PIN if the host is not paired yet.
7. Enter the PIN in the Sunshine web UI.
8. Launch Steam or another Sunshine app from the CRT Station list.

CRT Station controls the Moonlight stream request. The default PC Link profile asks Sunshine for `640x480`, `15 FPS`, `1000 Kbps`, H.264 video. This keeps the stream itself CRT-friendly and 4:3.

The host still controls the desktop or game resolution. For the cleanest CRT image, set the Sunshine app, host display, virtual display, or game launch options to a matching 4:3 resolution such as `640x480` or `800x600`. If the host keeps running widescreen, Sunshine may scale or letterbox that widescreen image inside the 4:3 stream.

Controller support depends on the Sunshine host. Windows Sunshine requires ViGEmBus for virtual gamepads; install it from Sunshine's Troubleshooting tab and reboot if controllers do not work. Sunshine on macOS currently streams video/audio and keyboard-style input, but does not currently support gamepads.

## Update An Existing CRT Station Image

Use Settings, System, then Check For Updates for normal appliance updates. The built-in updater switches to a CRT Station firmware screen, shows a VHS-style progress bar, writes detailed logs to `/var/log/240mp-update.log`, and refreshes the app, runtime packages, helpers, controller support, RetroArch cores, Moonlight, boot splash, IR, fan, SSH, Bluetooth, and composite setup without reflashing the SD card.

From SSH:

```bash
bash <(curl -fsSL https://github.com/TaterTotterson/CRT-Station/releases/latest/download/install.sh)
```

Then reboot:

```bash
sudo reboot
```

Settings and media-provider sign-in data are kept during app updates.

## Build A Custom Image

Use this when you want a different login password, SSH key, or image name.

Requirements on your build machine:

- Docker
- Git
- Enough free disk space for a Raspberry Pi OS image build

Build the default Raspberry Pi 4 composite/Argon IR image:

```bash
./scripts/build-pi-image.sh
```

Build a PAL composite image:

```bash
PI_IMAGE_PROFILE=crt-pal PI_IMAGE_NAME=240mp-pal ./scripts/build-pi-image.sh
```

Build with a stronger login password:

```bash
PI_FIRST_USER_PASS='change-this-password' ./scripts/build-pi-image.sh
```

Build with your SSH public key:

```bash
PI_FIRST_USER_PUBKEY=~/.ssh/id_ed25519.pub ./scripts/build-pi-image.sh
```

Useful image build options:

| Variable | Default | Description |
| --- | --- | --- |
| `PI_IMAGE_PROFILE` | `crt-ntsc` | Composite CRT profile. Use `crt-ntsc` or `crt-pal`; `hdmi` and `none` are developer options |
| `PI_IMAGE_NAME` | `240mp` | Output image name prefix |
| `PI_FIRST_USER_NAME` | `tater` | Normal login user |
| `PI_FIRST_USER_PASS` | `pi` | Password for the normal login user |
| `PI_FIRST_USER_PUBKEY` | unset | SSH public key string or path to a `.pub` file |
| `PI_ENABLE_SSH` | `1` | Enable SSH in the image |
| `PI_ENABLE_BLUETOOTH` | `1` | Enable Bluetooth controller support in the image |
| `PI_ENABLE_IR` | `1` | Enable GPIO IR receiver support |
| `PI_IR_GPIO_PIN` | `23` | GPIO pin used by the IR receiver data line |
| `PI_IR_PROTOCOL` | `nec` | IR protocol loaded by `ir-keytable` |
| `PI_ENABLE_BOOT_SPLASH` | `1` | Show the CRT Station boot screen |

The finished `.img.xz` lands in:

```text
.cache/pi-gen-arm64/deploy/
```

## Local Control API

CRT Station starts a small HTTP playback-control API with the app. By default it listens on all network interfaces at port `24024`:

```bash
curl http://240mp.local:24024/api/v1/status
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
POST /api/v1/library/search       {"query": "mario", "types": ["game"], "limit": 5}
POST /api/v1/library/launch       {"id": "game:nes:ROM_PATH"}
```

`/api/v1/library/search` can search Video on Demand and Game Center. `types` may include `movie`, `show`, `episode`, `video`, and `game`. Each result includes an `id`; pass that exact `id` to `/api/v1/library/launch`.

Example:

```bash
curl -sS http://240mp.local:24024/api/v1/library/search \
  -H 'Content-Type: application/json' \
  -d '{"query":"star wars","types":["movie","show"],"limit":5}'
```

Optional runtime environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `MP240_API_ENABLED` | `1` | Set to `0` to disable the API |
| `MP240_API_HOST` | `0.0.0.0` | Bind address; use `127.0.0.1` for local-only |
| `MP240_API_PORT` | `24024` | HTTP port |
| `MP240_API_TOKEN` | unset | If set, callers must send `Authorization: Bearer <token>` or `X-240MP-Token: <token>` |
