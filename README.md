<img src="https://github.com/user-attachments/assets/73c3e46f-a74a-4d96-9c4f-ae30f28378be" />

# 240-MP

240-MP is a retro VCR-style media frontend for Raspberry Pi, preferably hooked up to a CRT TV over composite video.

Playback experiences are handled via modules so new integrations can be added without reshaping the shell. This fork includes Local Files, Video on Demand for local Emby/Jellyfin servers, and Ambient Mode for looping video/audio ambience.

It launches [mpv](https://mpv.io/) as the playback engine. The ready-to-flash image and Raspberry Pi installer install the required runtime dependencies for you.

## Video Overview

Watch on YouTube: https://youtu.be/r-gylGDoELY

## Photos

| Module Selection | Item Detail |
| --- | --- |
| <img src="https://github.com/user-attachments/assets/9472d55a-4617-4a7f-80c4-32aa28494048" /> | <img src="https://github.com/user-attachments/assets/4f7d8230-860a-4ace-9370-9f59f43289c0" /> |

| Resume Option | Playback | Settings |
| --- | --- | --- | 
| <img src="https://github.com/user-attachments/assets/490e9ebd-fab2-4fd1-9959-35ebb619eff0" /> | <img src="https://github.com/user-attachments/assets/a3c768c7-6ede-4cdf-9d03-90aee7b8cdfb" /> | <img src="https://github.com/user-attachments/assets/0fd48977-8776-4334-b34e-d12256f23b97" /> |

## Current Features

### Local Files Module
- Supported file types: `"mp4", "mkv", "avi", "mov", "m4v", "webm", "wmv", "flv", "f4v", "mpg", "mpeg", "vob"`
- Playlist support using `m3u` and `m3u8` files
- Folder browsing
- Loop playback
- Shuffle playback
- Playback history
- Switch audio/subtitle tracks during playback

### Video on Demand Module
- Designed for CRT navigation (simple, fast, list browsing)
- Supported library types: `Movies, TV Shows, Other Videos`
- Local-only server sign in with a manually entered LAN URL
- Select specific libraries to display
- Continue Watching and Resume
- Autoplay next episode in a season (optional, off by default)
- Playlist and Collection support
- Select preferred audio/subtitle track before playback and switch tracks during playback
- Full library browsing by letter
- Show/Season browsing
- Video quality selection: Auto direct play with AV1-to-H.264 fallback, plus forced transcode options

### Ambient Mode Module
- Supported video file types: `"mp4", "mkv", "avi", "mov", "m4v", "webm", "wmv", "flv", "f4v", "mpg", "mpeg", "vob"`
- Playlist support for audio tracks using `m3u` and `m3u8` files
- Mix video with a different audio track
- Loops forever until you stop it

### Global
- Color schemes, including the Off Air CRT/static theme
- Keyboard, USB remote, and controller input support
- Settings toggle for SSH access on ready-to-flash Pi images
- Media Keys during video playback (volume +/-, mute, play/pause, stop, seek, next chapter, previous chapter)

## Install 
- [Ready-to-flash Raspberry Pi image](INSTALL.md#option-1-build-a-ready-to-flash-appliance-image)
- [On a Raspberry Pi](INSTALL.md#on-a-raspberry-pi)
- [Build from source / local macOS testing](BUILDING.md)

## Hardware Testing
- Primary target: Raspberry Pi 4 with composite output to a CRT
- Also expected to work on Raspberry Pi OS Lite arm64 over HDMI
- Raspberry Pi 3/3B+ can work with lower playback headroom; see [BUILDING.md](BUILDING.md#video-decode-tuning-mpv_video_args)
- Raspberry Pi 5 is best treated as HDMI-first unless your composite hardware path is known-good

## FAQs

- Why didn't you use Kodi/LibreELEC/OSMC?
    - I've used all of those distros and they are all excellent but I also like making things and wanted something simpler without as many options.  Something that felt like a VCR from my youth.
- Should I use 240-MP instead of Kodi/LibreELEC/OSMC?
    - No.
    - All of those distros are amazing, feature rich, work across a ton of devices and have awesome supportive teams behind them.
    - I on the other hand am just one person making nostalgic things for my own niche use cases.  If those use cases match with what you're looking for, then 240-MP is a bunch of fun and I'd be happy for you to try it.  Otherwise, the well known distros are spectacular and you should likely open those doors instead.
- Will this work on other Raspberry Pi models? (like the 5, 2 zero, etc...)
    - Sorry, I can't say for sure as I've only tested on the 4b, 3b+ and 3b and don't have plans to test on other devices at this time.
- Where does the name "240-MP" come from?
    - 240 has a double meaning referring to the longest [VHS tape length](https://en.wikipedia.org/wiki/VHS#Tape_lengths) and my primary display target for it of [CRT TVs](https://consolemods.org/wiki/CRT:What_is_240p%3F).
    - MP also has a double meaning of "Media Player" and a play on the "SP/LP/EP/SLP" terminology that was used to refer to the recording quality for VHS recordings.
- Does the 240 in the name mean that it outputs at 240p resolution?
    - The output resolution for the menu and video playback when using it on a CRT is 480i/576i (depending on your config).
- Does 240-MP work over HDMI on a modern television too?
    - Yes! The UI was built to scale on modern televisions over HDMI as well.
    - Please make sure you use the config.txt I provide for HDMI and it will output at the proper resolution for a modern tv.

## Credits & Acknowledgments 

- The `VCR OSD Mono` font was created by Riciery Santos Leal (a.k.a. mrmanet) https://www.dafont.com/vcr-osd-mono.font
- Because this is a hobby project (and a fairly niche use case), I am using [Claude Code](https://www.anthropic.com/product/claude-code) to build a large part of the backend C++ code and structure the modules.  If you have concerns with that, I am glad to talk through it.  Also, please feel free to fork this repo, update any aspects and tailor things to your own use case; that's why the source is fully open and available.
- Thank you to Emby and Jellyfin for local media-server APIs that make custom clients possible
- Thank you to [the MPV team](https://mpv.io/) for a simple, extensible and cross platform media player
- And thank you to the [Raspberry Pi Foundation](https://www.raspberrypi.org/) for helping me fill a drawer with SBCs to tinker with and inspire fun ideas like this project.

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for the full text.

You are free to use, study, and modify this code. If you distribute a modified version, you must also distribute it under GPL-3.0 and make the source available.
