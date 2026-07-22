# Game Center ports

Port manifests describe allowlisted native game engines. Approved engines can
be bundled, but no ROM, disc image, BIOS, user-generated game archive, extracted
game asset, or credential is shipped. Most ports validate a user's ROM by size
and cryptographic hash and copy it into the port's private writable directory.
Disc-aware ports may explicitly delegate revision validation to their engine and
stream the image directly from the configured game library.

The sm64coopdx integration is built from pinned v1.5.1 source and applies the
small patch under
`packaging/ports/sm64coopdx` to add **Exit to Tater Tube** at the bottom of the
pause menu. No ROM or extracted Nintendo game data is included. Place a supported
original ROM under `N64`, `Nintendo64`, or `Nintendo 64` in the configured game
library, then refresh the Game Center list.

Developers can rebuild the engine with `scripts/build-sm64coopdx-port.sh`. The
SteamOS release uses its Ubuntu 22.04 builder, while Raspberry Pi releases build
the same pinned source natively for arm64.

The 2 Ship 2 Harkinian integration is built from pinned 4.0.2 source. Its patch
automatically imports the ROM that Game Center has already validated, avoiding
desktop file-picker dialogs on a controller-only system, and labels the normal
quit command **Exit to Tater Tube**. The generated `mm.o2r` remains in the port's
private user directory and is never part of a release. Developers can rebuild
the engine with `scripts/build-2ship2harkinian-port.sh`.

The Ship of Harkinian integration is built from pinned 9.2.3 source. It accepts
the upstream-supported Ocarina of Time ROM hashes, automatically processes the
ROM already validated by Game Center, and changes the normal quit action to
**Exit to Tater Tube**. The user-generated `oot.o2r` or `oot-mq.o2r` remains in
the port's private user directory. Only the engine and its port-owned `soh.o2r`
are bundled. Developers can rebuild it with `scripts/build-shipwright-port.sh`.

The SpaghettiKart integration is built from pinned 1.0.0 source. It accepts the
upstream-supported Mario Kart 64 (USA) ROM, automatically processes the ROM
already validated by Game Center, enables controller navigation, and provides
**Exit to Tater Tube** in its settings menu. The user-generated `mk64.o2r`
remains in the port's private user directory. Only the engine and its port-owned
`spaghetti.o2r` are bundled. Developers can rebuild it with
`scripts/build-spaghettikart-port.sh`.

The Starship integration is built from pinned 2.0.0 source. It accepts the
upstream-supported Star Fox 64 USA 1.0 and 1.1 ROMs, automatically processes the
ROM already validated by Game Center, enables controller navigation, and labels
the normal quit action **Exit to Tater Tube**. The user-generated `sf64.o2r`
remains in the port's private user directory. Only the CC0 engine and its
port-owned `starship.o2r` are bundled. Developers can rebuild it with
`scripts/build-starship-port.sh`.

The Dusklight integration is built from pinned 1.4.1 CC0 source. It accepts the
upstream-supported GameCube USA and EUR releases in ISO/GCM, CISO, GCZ, NFS,
RVZ, WBFS, WIA, or TGC form. Because compressed disc images do not have stable
whole-file hashes, Dusklight performs the game and supported-region check
itself. Game Center passes the read-only RetroNAS path directly to the engine
instead of copying a multi-gigabyte image into local storage. Its normal quit
menu is labelled **Exit to Tater Tube**. Developers can rebuild it with
`scripts/build-dusklight-port.sh`. Linux requires Vulkan; Raspberry Pi support
therefore depends on a working Mesa V3DV driver and suitable performance.

For development, `TATER_TUBE_SM64COOPDX` may point directly to the executable or
its containing directory.

`TATER_TUBE_2SHIP2HARKINIAN` provides the same override for the 2Ship launcher.

`TATER_TUBE_SHIPWRIGHT` provides the same override for the Shipwright launcher.

`TATER_TUBE_SPAGHETTIKART` provides the same override for the SpaghettiKart
launcher.

`TATER_TUBE_STARSHIP` provides the same override for the Starship launcher.

`TATER_TUBE_DUSKLIGHT` provides the same override for the Dusklight launcher.
