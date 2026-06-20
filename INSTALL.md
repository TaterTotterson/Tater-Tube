# Install 240-MP

## On a Raspberry Pi

The following steps will set up an SD card for your Raspberry Pi with the latest version of 240-MP (and optionally set it up to autostart after boot).  

If you are building from source, you can now skip the manual OS setup and build a ready-to-flash appliance image that has Raspberry Pi OS Lite, 240-MP, dependencies, display config, and the boot service already installed.

### Option 1: Build a ready-to-flash appliance image

The repo includes a [pi-gen](https://github.com/RPi-Distro/pi-gen) wrapper that builds a Raspberry Pi OS Lite (64-bit) image and enables 240-MP on boot.

Requirements on your build machine:

- Docker
- Git
- Enough free disk space for a Raspberry Pi OS image build (plan for tens of GB)

Build the default CRT/composite NTSC image:

```bash
./scripts/build-pi-image.sh
```

Build the default CRT/composite NTSC image and add your SSH public key:

```bash
PI_FIRST_USER_PUBKEY=~/.ssh/id_ed25519.pub \
./scripts/build-pi-image.sh
```

Build an HDMI image:

```bash
PI_IMAGE_PROFILE=hdmi ./scripts/build-pi-image.sh
```

Build without GPIO IR remote support:

```bash
PI_ENABLE_IR=0 ./scripts/build-pi-image.sh
```

Build without the graphical boot splash:

```bash
PI_ENABLE_BOOT_SPLASH=0 ./scripts/build-pi-image.sh
```

The finished `.img.xz` lands in:

```text
.cache/pi-gen-arm64/deploy/
```

Flash that image with Raspberry Pi Imager, Balena Etcher, or `dd`, then boot the Pi. 240-MP starts automatically as a dedicated `mp240` service user. SSH is enabled by default for debugging and can be toggled from Settings. The normal login user is only for SSH, debugging, and the `Exit to Terminal` flow.

The default login is `tater` / `pi`. Override `PI_FIRST_USER_NAME` and `PI_FIRST_USER_PASS` before building if you plan to share the image outside your own network.

Useful image build options:

| Variable | Default | Description |
| --- | --- | --- |
| `PI_IMAGE_PROFILE` | `crt-ntsc` | `hdmi`, `crt-ntsc`, or `none` |
| `PI_IMAGE_ROOT_MARGIN_MB` | `1536` | Extra root partition free-space cushion for export |
| `PI_IMAGE_NAME` | `240mp` | Output image name prefix |
| `PI_IMAGE_RELEASE` | `trixie` | Raspberry Pi OS release used by pi-gen |
| `PI_SERVICE_USER` | `mp240` | Dedicated user that runs the boot service |
| `PI_SERVICE_HOME` | `/var/lib/240mp` | Home directory for the boot service user |
| `PI_FIRST_USER_NAME` | `tater` | Normal login user |
| `PI_FIRST_USER_PASS` | `pi` | Password for the normal login user |
| `PI_FIRST_USER_PUBKEY` | unset | SSH public key string or path to a `.pub` file; enables SSH automatically |
| `PI_ENABLE_SSH` | `1` | Enable SSH in the image; set to `0` to build with SSH off |
| `PI_PUBKEY_ONLY_SSH` | `0` | Disable SSH password auth when set to `1` and `PI_FIRST_USER_PUBKEY` is set |
| `PI_ENABLE_IR` | `1` | Enable GPIO IR receiver support in the image |
| `PI_IR_GPIO_PIN` | `17` | GPIO pin used by the IR receiver data line |
| `PI_IR_PROTOCOL` | `nec` | IR protocol loaded by `ir-keytable` |
| `PI_ENABLE_BOOT_SPLASH` | `1` | Hide boot text behind the 240-MP Plymouth splash |

Set `PI_FIRST_USER_PASS` to a stronger password before building if this image will leave your lab or home network.

### GPIO IR Remote

The ready-to-flash image enables a GPIO IR receiver by default on GPIO17 and loads a starter NEC keymap for the common small 21-key remotes. Wire the receiver data pin to GPIO17, plus 3.3V and ground, then boot the Pi.

If your remote uses different scancodes, log in on the Pi and run:

```bash
sudo 240mp-ir-learn
```

Press the remote buttons, copy the printed scancodes into `/etc/rc_keymaps/240mp.toml`, then reload:

```bash
sudo systemctl restart 240mp-ir-keymap.service
```

### Option 2: Install onto an existing Raspberry Pi OS card

Steps 1-4 are focused on setting up a new card with Raspberry Pi OS Lite (64-Bit) and include options for writing a config.txt that will output to a CRT or modern TV.  

However, if you already have Raspberry Pi OS set up and working on your TV then the specific 240-MP install steps start at step 5.

### Requirements

- A [RaspberryPi 4](https://www.raspberrypi.com/products/raspberry-pi-4-model-b/)
    - The Pi 4 fits in a nice sweet spot of performance + composite out and its the model I use daily so its the model I am most familiar with. It supports 1080p H264/HEVC playback well on both a CRT and over HDMI.
    - AV1 media should be served through Emby/Jellyfin transcoding. 240-MP's Video on Demand module auto-transcodes AV1/AV01 sources to H.264/AAC HLS in `AUTO` quality, and the `Video Quality` setting can force 480p, 720p, or 1080p transcodes.
    - The [Pi 3B and 3B+](https://www.raspberrypi.com/products/raspberry-pi-3-model-b/) work well too with some caveats...  The default configuration for Pi 3 supports smooth 1080p H264 playback at the expense of inconsistent crop functionality during playback (cropping will display a black screen on some videos).  If crop is important for your use case on a Pi 3 then you can change the video decode settings with the caveat that 1080p H264 playback will no longer be smooth (720p and below will still work well). See [BUILDING.md](BUILDING.md#video-decode-tuning-mpv_video_args) for the override.
    - The [Pi 5](https://www.raspberrypi.com/products/raspberry-pi-5/) also works but I've only tested over HDMI to a modern TV. The Pi 5 doesn't have a direct composite output port, one can be added through a mod but I don't have the hardware to test that.
    - If you have a setup that is working for you and would like to help out others, please open a hardware validation issue with the Pi model, display path, OS version, and any config changes.
- SD Card (minimum of 4GB) with RaspberryPi OS already set up
    - Note: 240-MP is only an application, it's not an OS so you will need to make sure you have an OS setup and working with the display you'd like to use. 
    - In the below steps I provide an example using Raspberry Pi OS Lite that you can use to create a fresh SD card along with configs I've tested for CRT and HDMI output.
    - The 240-MP specific steps start at step 5 so you can skip to that if you already have an OS running.
- A keyboard to navigate
- Internet Access (either WiFi or network cable will work)

### Optional

- A CRT TV and a composite cable
    - Composite out is my recommended way to use 240-MP
    - it will also work over HDMI as well so just select the config that works for your setup in step 2 below.
    - This is the composite cable I use if you happen to have a CRT: https://www.adafruit.com/product/2881 (note: I've only tested composite on the Pi 3/4 - the Pi 5 works well over HDMI
- USB remote control
    - Keyboard input works well but if you want that experience of sitting back and playing video on a VCR then a remote will definitely help with that.
    - I use this one: https://www.amazon.com/dp/B01FVUGPE8
- USB game controller 
    - Most controllers (Xbox, PlayStation, 8BitDo, NES-style, etc.) should work out of the box: D-pad/left stick to navigate, A to select, B to go back, Start for play/pause.  
    - Controllers can be plugged in at any time, and the button mapping can be customized — see [BUILDING.md → Gamepad input](BUILDING.md#gamepad-input-inputcfg).
    - If a controller isn't detected, make sure your user is in the `input` group: `sudo usermod -aG input $USER` then reboot.

### Steps

1) Write RaspberryPi OS Lite (64-bit) to an SD Card

    I reccomend using [Raspberry Pi Imager](https://www.raspberrypi.com/software/), it handles everything from OS selection to preconfiguring networking and user set up in nice simple flow

    Here is what you should select for OS if using Raspberry Pi Imager:

    | OS > Raspberry Pi OS (other) | Raspberry Pi OS Lite (64-bit) |
    | --- | --- |
    | <img src="https://github.com/user-attachments/assets/bb9f7a47-12b7-4580-abf4-ec8ad22153ba" /> | <img src="https://github.com/user-attachments/assets/30c39fce-99f8-48c9-9ad0-2b39b52690c1" /> |

    I would also suggest filling out Hostname, User and Wifi in the customization section as it will you save you from having to set them up manually later.

2) After the write is complete, reconnect the card to your PC and update your config.txt to one of the following (please make sure to choose the one that best matches your TV):

    **Option 1: For composite out on a CRT TV (NTSC)...**
    ```
    # --- Global ---
    disable_splash=1
    disable_overscan=1
    dtparam=audio=on

    # Composite
    enable_tvout=1
    dtoverlay=vc4-kms-v3d,composite

    # --- Pi 3B ---
    [pi3]

    # Overclocking
    over_voltage=4
    arm_freq=1300
    core_freq=450
    sdram_freq=500

    # --- Pi 3B+ ---
    [pi3+]

    # Overclocking
    over_voltage=2
    arm_freq=1500
    core_freq=500
    sdram_freq=500

    # --- Pi 4B ---
    [pi4]

    # Drivers & Video
    dtoverlay=rpivid-v4l2

    # Overclocking
    over_voltage=2
    arm_freq=1750
    gpu_freq=600
    
    # --- Global ---
    [all]
    ```

    or **Option 2: for HDMI out on a modern TV...**
    ```
    # --- Global ---
    disable_splash=1
    disable_overscan=1

    # HDMI
    display_auto_detect=1
    hdmi_force_hotplug=1
    dtoverlay=vc4-kms-v3d

    # --- Pi 3B ---
    [pi3]

    # Overclocking
    over_voltage=4
    arm_freq=1300
    core_freq=450
    sdram_freq=500

    # --- Pi 3B+ ---
    [pi3+]

    # Overclocking
    over_voltage=2
    arm_freq=1500
    core_freq=500
    sdram_freq=500

    # --- Pi 4B ---
    [pi4]

    # Drivers & Video
    dtoverlay=rpivid-v4l2

    # Overclocking
    over_voltage=2
    arm_freq=1750
    gpu_freq=600
    
    # --- Global ---
    [all]
    ```

3) Place the SD card in your Raspberry Pi and let it run through its first boot sequence

4) Once complete, SSH in and run `sudo raspi-config`

    - Turn on Auto Login: `System Options > Auto Login > Yes`
    - Expand filesystem: `Advanced Options > Expand Filesystem > Yes`
    - Select Finish and allow the Raspberry Pi to reboot

5) After that completes SSH in again and run the following to install the latest version of 240-MP

    ```bash
    bash <(curl -fsSL https://github.com/TaterTotterson/240-MP-Emby-Jelly/releases/latest/download/install.sh)
    ```

    This will install all of the needed dependencies (note: over WiFi it will take about 20 mins to complete) 

    **Optional** 
    - You will get an option at the end of the install script that asks: `Install systemd autostart service? [y/N]` 
    - If you type `Y` and press enter it will set up 240-MP to autostart when your Raspberry Pi boots which creates a nice appliance experience (basically a dedicated 240-MP device).
    - If you choose that option please make sure to enter your primary user for the pi at the next prompt.  If you don't provide one it will set it up for the `Pi` user.

At this point you can type `240mp` at any time to start up the app.  And if you installed the autostart service then the next time you boot your Pi it will boot directly into 240-MP.

**Exit to Terminal:** 
- If you have the autostart service installed, the Quit dialog gains an `Exit to Terminal` option alongside `Power Off`. Choosing that will drop you to a login shell on the Pi instead of powering off, and leaves autostart intact for subsequent reboots. 
- On the ready-to-flash image, `Ctrl+Alt+F2` opens a recovery login on `tty2` if the app display is black or stuck. Log in with the image credentials and run `journalctl -u 240mp -b` to inspect the app service.
- To get back into 240-MP from that shell you can do one of the following:
    1. (*Recommended*) type `sudo systemctl start 240mp` to start up 240-MP and the autostart service again
    2. type `sudo reboot` to reboot and start up the device from scratch (which will also restart the autostart service)
    3. type `240mp` which will relaunch the app unmanaged in your shell; here the Quit dialog shows the plain Yes/No menu and selecting Yes will just return you to the shell rather than powering off

### Update

To update to the latest release on Raspberry Pi please follow these steps (your settings will be retained):

1) SSH into your Raspberry Pi
2) Re-run the install script
    ```bash
    bash <(curl -fsSL https://github.com/TaterTotterson/240-MP-Emby-Jelly/releases/latest/download/install.sh)
    ```
3) When it asks to "`Install systemd autostart service? [y/N]`"
    - If you already have autostart set up you can press either Y or N, it will keep your current autostart
    - If you don't have autostart installed and want to keep it that way just answer `N`
    - And if you want to turn on autostart please answer `Y`
4) Once that completes just run `sudo reboot` and when your pi restarts you'll be on the latest version

### Uninstall

1) If you'd like to remove 240-MP and continue to use your SD card for other things then you can run the following commands via terminal or over SSH:

    ```bash
    sudo rm -rf /opt/240mp
    sudo rm /usr/local/bin/240mp
    ```

2) If you installed the autostart service and want to remove it then please run the running the following commands:

    ```bash
    sudo systemctl unmask getty@tty1.service autovt@.service
    sudo systemctl disable 240mp.service
    sudo rm -f /etc/systemd/system/240mp.service /etc/systemd/system/240mp-terminal.service /usr/local/bin/240mp-stop
    sudo systemctl daemon-reload
    ```

## macOS

macOS is not a release target for this fork. The macOS build path is kept only for quick local testing while developing the QML/C++ app. See [BUILDING.md](BUILDING.md#macos-arm-local-testing-only).
