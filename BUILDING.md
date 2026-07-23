# Building Tater Tube

Most users should use the ready-to-flash Raspberry Pi image for their display from the latest GitHub release.

This fork is built around appliance targets: Raspberry Pi 4 composite video to a CRT, and Raspberry Pi 5 HDMI auto-resolution.

Use this page when you want to customize the image, change the app, or do local development.

## macOS Local Testing

The macOS build is only for quick UI and backend checks while developing. It is not a release target.

### Prerequisites

```bash
brew install cmake mpv sdl2 qt@6
```

If Qt is installed somewhere custom, pass that path through `CMAKE_PREFIX_PATH`.

### Build

```bash
cmake -B build-macos-test -DCMAKE_PREFIX_PATH="$(brew --prefix qt@6)" .
cmake --build build-macos-test --parallel
```

### Run

```bash
APP_ROOT=$(pwd) ./build-macos-test/240mp.app/Contents/MacOS/240mp
```

macOS settings are stored in:

```text
~/Library/Application Support/240-MP/
```

## Raspberry Pi 4 Development Build

The release image is the normal install path. Build directly on a Pi only when you are debugging or developing.

Install dependencies on Raspberry Pi OS Trixie arm64:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake \
  qt6-base-dev qt6-declarative-dev \
  qml6-module-qtquick qml6-module-qtquick-controls \
  qml6-module-qtquick-window \
  libqt6svg6 qt6-svg-dev qt6-svg-plugins \
  libdrm-dev libxkbcommon-dev \
  libsdl2-dev \
  mpv
```

Build:

```bash
cmake -B build
cmake --build build --parallel
```

Run on Raspberry Pi OS Lite/EGLFS:

```bash
APP_ROOT=$(pwd) QT_QPA_PLATFORM=eglfs ./build/240mp
```

Pi settings are stored in:

```text
~/.local/share/240-MP/
```

## Build A Custom Pi Image

The image builder wraps Raspberry Pi's `pi-gen` arm64 branch, builds Tater Tube inside the rootfs, installs it under `/opt/240mp`, enables `240mp.service`, enables the boot screen, and applies the selected display profile plus Bluetooth controller and Argon IR defaults.

Requirements on your build machine:

- Docker
- Git
- Enough free disk space for a Raspberry Pi OS image build

Build the default Raspberry Pi 4 composite/Argon IR image:

```bash
./scripts/fetch-pi-runtime-bundle.sh out/pi-runtime
PI_RUNTIME_BUNDLE_DIR="$PWD/out/pi-runtime" ./scripts/build-pi-image.sh
```

Build a PAL composite image:

```bash
PI_IMAGE_PROFILE=crt-pal PI_IMAGE_NAME=tater-tube-pal ./scripts/build-pi-image.sh
```

Build a Pi 5 HDMI auto-resolution image:

```bash
PI_IMAGE_PROFILE=pi5-hdmi-auto PI_IMAGE_NAME=tater-tube-pi5-hdmi-auto ./scripts/build-pi-image.sh
```

Build with a stronger login password:

```bash
PI_FIRST_USER_PASS='change-this-password' ./scripts/build-pi-image.sh
```

Build with your SSH public key:

```bash
PI_FIRST_USER_PUBKEY=~/.ssh/id_ed25519.pub ./scripts/build-pi-image.sh
```

Output images are written to:

```text
.cache/pi-gen-arm64/deploy/
```

Tagged releases use the immutable ARM64 archive and SHA-256 pinned in
`packaging/pi/runtime-bundle.lock`. Build a new bundle only when a port engine,
Moonlight, its patch set, toolchain, or ABI changes:

```bash
./scripts/build-pi-runtimes.sh out/pi-runtime
./scripts/package-pi-runtime-bundle.sh
```

Publish the archive as a new, never-overwritten GitHub Release asset, then
update the lock file. Application-only releases reuse the pinned bundle across
the update tarball and all three image profiles.

## Playback Tuning

The release images default to Pi 4 composite playback. The NTSC image forces `720x480i`; the PAL image forces `720x576i`. The app launches `mpv` as a subprocess and chooses Pi 4-safe video and audio flags automatically.

If you need to override mpv video output for debugging, add `mpv_video_args` under `"app"` in `config.json`:

```json
{
  "app": {
    "mpv_video_args": "--vo=drm --hwdec=v4l2m2m-copy"
  }
}
```

For custom audio setups, `mpv_audio_args` can be added beside it. The default composite image uses the Pi analog `Headphones` ALSA card when present.

## Debugging

### Service Logs

The ready-to-flash image runs Tater Tube through `240mp.service`.

```bash
journalctl -u 240mp -b
journalctl -u 240mp -f
```

### Recovery Console

The image leaves `tty2` available as a recovery console. Press `Ctrl+Alt+F2`, log in, and inspect logs from there.

To return to the app:

```bash
sudo systemctl start 240mp
```

### Run By Hand

For debugging without the service:

```bash
sudo systemctl stop 240mp
240mp
```

### mpv Logs

During playback, mpv writes its own log beside the IPC socket:

```text
/tmp/240mp-mpv.log
/tmp/240mp-mpv.sock
```

### Qt / QML Debugging

```bash
QT_LOGGING_RULES="qt.qml.*=true"
QML_IMPORT_TRACE=1
QT_QPA_EGLFS_DEBUG=1
```

## GitHub Actions Releases

Releases are built from version tags:

```bash
git tag v2026.06.20.22
git push origin v2026.06.20.22
```

The release workflow builds and publishes:

- Linux arm64 app update tarball
- Ready-to-flash Raspberry Pi images for NTSC composite, PAL composite, and Pi 5 HDMI auto-resolution
- Image checksum
- Installer script

The ready-to-flash images are the primary release artifacts.
