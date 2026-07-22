#!/bin/bash -e

source /tmp/240mp-image.env
source /tmp/240mp-pi-setup.sh

cd /opt/240mp-src
cmake -B build -DCMAKE_BUILD_TYPE=Release .
cmake --build build --parallel "$(nproc)"
cmake --install build --prefix /opt/240mp
pi240_install_missing_runtime_dependencies

pi240_create_service_user "$PI240_SERVICE_USER" "$PI240_SERVICE_HOME"
pi240_install_tty_rule
pi240_install_launcher /opt/240mp /usr/local/bin/240mp
pi240_install_autostart "$PI240_SERVICE_USER" /usr/local/bin/240mp /etc/systemd/system/240mp.service "$PI240_SERVICE_HOME"
pi240_install_update_helper "$PI240_SERVICE_USER" /usr/local/sbin/240mp-update /opt/240mp/share/240mp/scripts/240mp-update
pi240_install_ssh_control "$PI240_SERVICE_USER" /usr/local/sbin/240mp-ssh-control "${PI240_ENABLE_SSH:-1}"
pi240_install_bluetooth_control "$PI240_SERVICE_USER" /usr/local/sbin/240mp-bluetooth-control "${PI240_ENABLE_BLUETOOTH:-1}"
pi240_install_retro_mount_helper "$PI240_SERVICE_USER" /usr/local/sbin/240mp-retro-mount
pi240_install_retro_core_control "$PI240_SERVICE_USER" /usr/local/sbin/240mp-retro-core-control
pi240_install_argon_fan_control "$PI240_SERVICE_USER" /usr/local/sbin/240mp-argon-fan-control
pi240_install_moonlight_sdl_bundle /opt/240mp
/opt/240mp-src/scripts/build-sm64coopdx-port.sh /opt/240mp/share/240mp/vendor/ports/sm64coopdx
/opt/240mp-src/scripts/build-2ship2harkinian-port.sh /opt/240mp/share/240mp/vendor/ports/2ship2harkinian
/opt/240mp-src/scripts/build-shipwright-port.sh /opt/240mp/share/240mp/vendor/ports/shipwright
SPAGHETTIKART_BUILD_JOBS=3 /opt/240mp-src/scripts/build-spaghettikart-port.sh /opt/240mp/share/240mp/vendor/ports/spaghettikart
STARSHIP_BUILD_JOBS=3 /opt/240mp-src/scripts/build-starship-port.sh /opt/240mp/share/240mp/vendor/ports/starship
DUSKLIGHT_BUILD_JOBS=3 /opt/240mp-src/scripts/build-dusklight-port.sh /opt/240mp/share/240mp/vendor/ports/dusklight
pi240_install_moonlight_control "$PI240_SERVICE_USER" /usr/local/sbin/240mp-moonlight-control
case "${PI240_IMAGE_PROFILE:-}" in
    crt-ntsc)
        pi240_force_composite_video ntsc
        ;;
    crt-pal)
        pi240_force_composite_video pal
        ;;
esac
if [ "${PI240_ENABLE_IR:-1}" = "1" ]; then
    pi240_install_ir_support "${PI240_IR_PROTOCOL:-nec}" /etc/rc_keymaps/240mp.toml "${PI240_IR_GPIO_PIN:-23}"
fi
if [ "${PI240_ENABLE_BOOT_SPLASH:-1}" = "1" ]; then
    pi240_install_boot_splash
fi

# apt-listchanges can spend a long time fetching remote changelogs during
# pi-gen's export finalise step, and transient DNS failures can stall the build.
rm -f /etc/apt/apt.conf.d/20listchanges

rm -rf /opt/240mp-src /tmp/240mp-image.env /tmp/240mp-pi-setup.sh
apt-get clean
rm -rf /var/lib/apt/lists/*
