#!/bin/bash

set -euo pipefail

say() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

OUT= WORK=/work SIZE=1536M

while [ $# -gt 0 ]; do

	case "$1" in

		-o)
			OUT=$2
			shift 2
			;;

		-w)
			WORK=$2
			shift 2
			;;

		-s)
			SIZE=$2
			shift 2
			;;

		*)
			echo "mkrootfs: unknown argument $1" >&2
			exit 1
			;;

	esac

done

[ -n "$OUT" ] || {
	echo "usage: mkrootfs.sh -o system.img [-w work] [-s 2048M]" >&2
	exit 1
}

[ "$(dpkg --print-architecture)" = arm64 ] || {
	echo "mkrootfs: run inside an arm64 container" >&2
	exit 1
}

ROOT=/tmp/athena-rootfs

CACHE=/cache

DESKTOP=phosh

DESKTOP_DIR=/src/image/debian-arm64/desktop/$DESKTOP

DESKTOP_SERVICE=$DESKTOP.service

rm -rf "$ROOT" "$WORK/debootstrap.log"

mkdir -p "$ROOT" "$WORK" "$CACHE/debootstrap" "$CACHE/apt/archives"

export DEBIAN_FRONTEND=noninteractive

say "Bootstrapping the Debian trixie arm64 base; package retrieval progress follows"

debootstrap --cache-dir="$CACHE/debootstrap" --arch=arm64 --variant=minbase --include=ca-certificates,systemd-sysv trixie "$ROOT" https://deb.debian.org/debian

cat >"$ROOT/etc/apt/sources.list" <<'APT'
deb https://deb.debian.org/debian trixie main
deb https://deb.debian.org/debian trixie-updates main
deb https://security.debian.org/debian-security trixie-security main
APT

install -d -m 0755 "$ROOT/etc/dpkg/dpkg.cfg.d"

cat >"$ROOT/etc/dpkg/dpkg.cfg.d/01-athena-slim" <<'DPKG'

path-exclude=/usr/share/doc/*

path-include=/usr/share/doc/*/copyright

path-exclude=/usr/share/man/*

path-exclude=/usr/share/info/*

path-exclude=/usr/share/locale/*

path-include=/usr/share/locale/en/*

path-include=/usr/share/locale/en_GB/*

DPKG

cat >"$ROOT/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh

exit 101

POLICY

chmod 755 "$ROOT/usr/sbin/policy-rc.d"

cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

pkgs=$(sed 's/#.*//' "$DESKTOP_DIR/packages.txt" | xargs)

say "Refreshing package indexes inside the arm64 root"

chroot "$ROOT" apt-get update

find "$CACHE/apt/archives" -type f -name '*.deb' -exec cp -n '{}' "$ROOT/var/cache/apt/archives/" \;

say "Applying available Debian security and stable updates to the base system"

chroot "$ROOT" apt-get upgrade -y --no-install-recommends

find "$ROOT/var/cache/apt/archives" -type f -name '*.deb' -exec cp -n '{}' "$CACHE/apt/archives/" \;

say "Installing Phosh, Tauri runtime, hardware and network packages"

chroot "$ROOT" apt-get install -y --no-install-recommends $pkgs

find "$ROOT/var/cache/apt/archives" -type f -name '*.deb' -exec cp -n '{}' "$CACHE/apt/archives/" \;

say "Removing package download caches to keep the image small"

rm -f "$ROOT/usr/sbin/policy-rc.d"

rm -rf "$ROOT/var/lib/apt/lists" "$ROOT/var/cache/apt/archives"/* "$ROOT/var/cache/debconf"/*

find "$ROOT/usr/share/doc" -mindepth 1 -type f ! -name copyright -delete

find "$ROOT/usr/share/doc" -depth -type d -empty -delete

for group in seat video render input audio; do chroot "$ROOT" groupadd --system "$group" 2>/dev/null || true; done

chroot "$ROOT" useradd --create-home --uid 1000 --shell /bin/bash athena

chroot "$ROOT" usermod -a -G video,render,input,seat,audio athena

chroot "$ROOT" passwd -l athena >/dev/null

chroot "$ROOT" passwd -l root >/dev/null

echo athena >"$ROOT/etc/hostname"

rm -f "$ROOT/etc/resolv.conf"

ln -s /run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"

install -d -m 0755 "$ROOT/etc/systemd/logind.conf.d"

cat >"$ROOT/etc/systemd/logind.conf.d/athena.conf" <<'LOGIND'

[Login]

HandlePowerKey=ignore

HandlePowerKeyLongPress=ignore

LOGIND

install -d -m 0755 "$ROOT/etc/systemd/journald.conf.d"

cat >"$ROOT/etc/systemd/journald.conf.d/athena.conf" <<'JOURNAL'

[Journal]

Storage=volatile

RuntimeMaxUse=24M

RuntimeKeepFree=16M

JOURNAL

say "Writing first-boot init, Phosh display configuration and serial-console setup"

cat >"$ROOT/init" <<'INIT'
#!/bin/sh

mount -o remount,rw / || exec sh

mount -t proc proc /proc

mount -t sysfs sysfs /sys

mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

mount -t devpts devpts /dev/pts 2>/dev/null || true

mount -t tmpfs -o mode=0755 tmpfs /run

exec /sbin/init

INIT

chmod 755 "$ROOT/init"

mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev/pts" "$ROOT/run" "$ROOT/var/log"

install -d -m 0755 "$ROOT/usr/local/sbin" \
	"$ROOT/usr/share/applications" \
	"$ROOT/etc/udev/rules.d" \
	"$ROOT/etc/triggerhappy/triggers.d" \
	"$ROOT/etc/systemd/system/serial-getty@ttyS0.service.d" \
	"$ROOT/etc/systemd/system/serial-getty@ttyGS0.service.d"

cat >"$ROOT/etc/udev/rules.d/70-athena-drm.rules" <<'UDEV'

SUBSYSTEM=="drm", KERNEL=="card[0-9]*", GROUP="video", MODE="0660"

SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", GROUP="render", MODE="0660"

SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="generic ft5x06 (3e)", ENV{WL_OUTPUT}="DSI-1", ENV{LIBINPUT_CALIBRATION_MATRIX}="0.018601 -1.008491 0.999218 1.012344 0.001388 -0.007528"

SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="mtk-pmic-keys", ENV{LIBINPUT_IGNORE_DEVICE}="1"

UDEV

bash "$DESKTOP_DIR/configure.sh" "$ROOT"

cat >"$ROOT/etc/machine-info" <<'MACHINEINFO'
CHASSIS=tablet
MACHINEINFO

cat >"$ROOT/usr/local/sbin/athena-set-identity" <<'IDENTITY'
#!/bin/sh

set -eu

serial=$(sed -n 's/.*androidboot.serialno=\([^ ]*\).*/\1/p' /proc/cmdline | head -n 1)

if [ -z "$serial" ]; then

	serial=$(tr -d '\000' </proc/device-tree/serial-number 2>/dev/null || true)

fi

serial=$(printf '%s' "$serial" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')

if [ -z "$serial" ]; then

	hostname=athena-unknown

else

	hostname="athena-$serial"

fi

printf '%s\n' "$hostname" >/etc/hostname

hostname "$hostname"

IDENTITY

chmod 755 "$ROOT/usr/local/sbin/athena-set-identity"

cat >"$ROOT/etc/systemd/system/athena-set-identity.service" <<'UNIT'

[Unit]

Description=Set Athena hostname from device serial

DefaultDependencies=no

After=local-fs.target

Before=network-pre.target

Wants=network-pre.target

[Service]

Type=oneshot

ExecStart=/usr/local/sbin/athena-set-identity

RemainAfterExit=yes

[Install]

WantedBy=multi-user.target

UNIT

cat >"$ROOT/usr/local/sbin/athena-root-grow" <<'GROW'
#!/bin/sh

set -eu

marker=/var/lib/athena/root-expanded

[ -e "$marker" ] && exit 0

fstype=$(findmnt -n -o FSTYPE /)

[ "$fstype" = ext4 ] || { echo "root filesystem is $fstype, expected ext4" >&2; exit 1; }

device=$(findfs LABEL=athena-rootfs)

[ -b "$device" ] || { echo 'athena-rootfs label did not resolve to a block device' >&2; exit 1; }

resize2fs "$device"

install -D -m 0644 /dev/null "$marker"

GROW

chmod 755 "$ROOT/usr/local/sbin/athena-root-grow"

cat >"$ROOT/etc/systemd/system/athena-root-grow.service" <<UNIT

[Unit]

Description=Expand Athena ext4 root filesystem on first boot

After=local-fs.target

Before=$DESKTOP_SERVICE

ConditionPathExists=!/var/lib/athena/root-expanded

[Service]

Type=oneshot

ExecStart=/usr/local/sbin/athena-root-grow

RemainAfterExit=yes

[Install]

WantedBy=multi-user.target

UNIT

cat >"$ROOT/usr/local/sbin/athena-power-action" <<'POWER'
#!/bin/sh

set -eu

case "${1:-}" in

	poweroff) exec systemctl poweroff ;;

	reboot) exec systemctl reboot ;;

	recovery)

		compatible=$(tr '\000' ' ' </proc/device-tree/compatible 2>/dev/null || true)

		case " $compatible " in *" amzn,athena "*) ;; *) echo 'recovery action is only enabled for Athena' >&2; exit 1 ;; esac

		device=$(findfs PARTLABEL=misc 2>/dev/null || true)

		[ -b "$device" ] || { echo 'misc partition not found' >&2; exit 1; }

		raw_device=$(readlink -f "$device")

		case "$raw_device" in /dev/mmcblk*p6) ;; *) echo "unexpected misc partition: $raw_device" >&2; exit 1 ;; esac

		[ "$(blockdev --getsize64 "$raw_device")" -ge 2048 ] || { echo 'misc partition is too small' >&2; exit 1; }

		tmp=$(mktemp /run/athena-recovery.XXXXXX)

		trap 'rm -f "$tmp"' EXIT

		dd if=/dev/zero of="$tmp" bs=32 count=1 status=none

		printf 'boot-recovery' | dd of="$tmp" bs=1 count=13 conv=notrunc status=none

		dd if="$tmp" of="$raw_device" bs=32 count=1 conv=notrunc,fsync status=none

		cmp -n 32 "$tmp" "$raw_device" || { echo 'recovery request read-back failed' >&2; exit 1; }

	exec systemctl reboot ;;

	*) echo 'usage: athena-power-action poweroff|reboot|recovery' >&2; exit 2 ;;

esac

POWER

chmod 755 "$ROOT/usr/local/sbin/athena-power-action"

cat >"$ROOT/etc/sudoers.d/athena-admin" <<'SUDOERS'

athena ALL=(ALL:ALL) NOPASSWD: ALL

SUDOERS

chmod 440 "$ROOT/etc/sudoers.d/athena-admin"

cat >"$ROOT/usr/share/applications/athena-recovery.desktop" <<'DESKTOP'

[Desktop Entry]

Name=Reboot to TWRP

Exec=sudo -n /usr/local/sbin/athena-power-action recovery

Icon=system-reboot

Terminal=false

Type=Application

Categories=System;

DESKTOP

cat >"$ROOT/usr/share/applications/athena-poweroff.desktop" <<'DESKTOP'

[Desktop Entry]

Name=Power Off

Exec=sudo -n /usr/local/sbin/athena-power-action poweroff

Icon=system-shutdown

Terminal=false

Type=Application

Categories=System;

DESKTOP

chroot "$ROOT" dconf update

cat >"$ROOT/usr/local/sbin/athena-micmute-led" <<'MICMUTELED'
#!/bin/sh

set -eu

case "${1:-}" in
	muted) value=1 ;;
	active) value=0 ;;
	*) exit 2 ;;
esac

for led in /sys/class/leds/*; do
	[ -e "$led/brightness" ] || continue
	function=$(cat "$led/function" 2>/dev/null || true)
	name=${led##*/}
	case "$function:$name" in
		*micmute*|*mic-mute*|*mute*)
			if [ "$value" -eq 1 ]; then
				brightness=$(cat "$led/max_brightness")
			else
				brightness=0
			fi
			printf '%s\n' "$brightness" >"$led/brightness"
			;;
	esac
done

MICMUTELED

chmod 755 "$ROOT/usr/local/sbin/athena-micmute-led"

cat >"$ROOT/usr/local/sbin/athena-audio-init" <<'AUDIOINIT'
#!/bin/sh

set -eu

n=0

while [ ! -e /dev/snd/controlC0 ] && [ "$n" -lt 30 ]; do

	sleep 1

	n=$((n + 1))

done

[ -e /dev/snd/controlC0 ] || { echo 'ALSA card 0 did not appear' >&2; exit 1; }

amixer -q -c 0 cset name='I2S1_CH1 DL1_CH1' 1

amixer -q -c 0 cset name='I2S1_CH2 DL1_CH2' 1

amixer -q -c 0 cset name='Master Playback Volume' 110

amixer -q -c 0 cset name='I2S2_HD_Mux' 1

amixer -q -c 0 cset name='UL1_CH1 I2S2_CH1' 1

amixer -q -c 0 cset name='UL1_CH2 I2S2_CH2' 1

amixer -q -c 0 cset name='UL1_CH3 I2S2_CH3' 1

amixer -q -c 0 cset name='UL1_CH4 I2S2_CH4' 1

amixer -q -c 0 cset name='CH1_ASI_EN Switch' 1

amixer -q -c 0 cset name='CH2_ASI_EN Switch' 1

amixer -q -c 0 cset name='CH3_ASI_EN Switch' 1

amixer -q -c 0 cset name='CH4_ASI_EN Switch' 1

amixer -q -c 0 cset name='Digital CH1 Out Volume' 201

amixer -q -c 0 cset name='Digital CH2 Out Volume' 201

amixer -q -c 0 cset name='Digital CH3 Out Volume' 201

amixer -q -c 0 cset name='Digital CH4 Out Volume' 201

/usr/local/sbin/athena-micmute-led active

AUDIOINIT

chmod 755 "$ROOT/usr/local/sbin/athena-audio-init"

cat >"$ROOT/etc/systemd/system/athena-audio-init.service" <<'UNIT'

[Unit]

Description=Configure Athena speaker and four-channel microphone audio

After=systemd-udev-trigger.service sound.target

Before=triggerhappy.service

[Service]

Type=oneshot

ExecStart=/usr/local/sbin/athena-audio-init

RemainAfterExit=yes

[Install]

WantedBy=multi-user.target

UNIT

cat >"$ROOT/usr/local/sbin/athena-volume-key" <<'VOLUMEKEY'
#!/bin/sh

set -eu

case "${1:-}" in

	up) delta=5%+ ;;

	down) delta=5%- ;;

	*) echo 'usage: athena-volume-key up|down' >&2; exit 2 ;;

esac

if /usr/sbin/runuser -u athena -- env XDG_RUNTIME_DIR=/run/user/1000 wpctl set-volume --limit 1.0 @DEFAULT_AUDIO_SINK@ "$delta"; then
	exit 0
fi

case "$1" in

	up) delta=8 ;;

	down) delta=-8 ;;

esac

control='Master Playback Volume'

value=$(amixer -c 0 cget name="$control" | sed -n 's/^[[:space:]]*: values=\([-0-9][0-9]*\).*/\1/p' | head -n 1)

case "$value" in ''|*[!0-9-]*) echo "could not read $control" >&2; exit 1 ;; esac

value=$((value + delta))

[ "$value" -ge 0 ] || value=0

[ "$value" -le 116 ] || value=116

amixer -q -c 0 cset name="$control" "$value,$value"

VOLUMEKEY

chmod 755 "$ROOT/usr/local/sbin/athena-volume-key"

cat >"$ROOT/usr/local/sbin/athena-micmute-key" <<'MICMUTE'
#!/bin/sh

set -eu

/usr/sbin/runuser -u athena -- env XDG_RUNTIME_DIR=/run/user/1000 wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle

if /usr/sbin/runuser -u athena -- env XDG_RUNTIME_DIR=/run/user/1000 wpctl get-volume @DEFAULT_AUDIO_SOURCE@ | grep -q '\[MUTED\]'; then
	/usr/local/sbin/athena-micmute-led muted
else
	/usr/local/sbin/athena-micmute-led active
fi

MICMUTE

chmod 755 "$ROOT/usr/local/sbin/athena-micmute-key"

install -d -m 0755 "$ROOT/etc/sudoers.d"

cat >"$ROOT/etc/sudoers.d/athena-volume-key" <<'SUDOERS'

nobody ALL=(root) NOPASSWD: /usr/local/sbin/athena-volume-key up, /usr/local/sbin/athena-volume-key down, /usr/local/sbin/athena-micmute-key

SUDOERS

chmod 440 "$ROOT/etc/sudoers.d/athena-volume-key"

cat >"$ROOT/etc/triggerhappy/triggers.d/athena-volume.conf" <<'TRIGGERS'
KEY_VOLUMEUP 1 /usr/bin/sudo -n /usr/local/sbin/athena-volume-key up
KEY_VOLUMEDOWN 1 /usr/bin/sudo -n /usr/local/sbin/athena-volume-key down
KEY_MICMUTE 1 /usr/bin/sudo -n /usr/local/sbin/athena-micmute-key
TRIGGERS

cat >"$ROOT/usr/local/sbin/athena-usb-console" <<'USB'
#!/bin/sh

set -eu

G=/sys/kernel/config/usb_gadget/athena

mkdir -p "$G" "$G/strings/0x409" "$G/configs/c.1/strings/0x409" "$G/functions/acm.usb0"

printf '0x1d6b' > "$G/idVendor"

printf '0x0104' > "$G/idProduct"

printf '0x0100' > "$G/bcdDevice"

printf '0x0200' > "$G/bcdUSB"

printf 'Athena' > "$G/strings/0x409/manufacturer"

printf 'Athena Debian USB console' > "$G/strings/0x409/product"

printf 'ATHENA-USB-CONSOLE' > "$G/strings/0x409/serialnumber"

printf 'USB serial console' > "$G/configs/c.1/strings/0x409/configuration"

printf '100' > "$G/configs/c.1/MaxPower"

[ -L "$G/configs/c.1/acm.usb0" ] || ln -s "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0"

if [ -z "$(cat "$G/UDC")" ]; then

	for udc in /sys/class/udc/*; do

		[ -e "$udc" ] || continue

		basename "$udc" > "$G/UDC"

		exit 0

	done

	echo 'No USB device controller is available for the ACM console' >&2

	exit 1

fi

USB

chmod 755 "$ROOT/usr/local/sbin/athena-usb-console"

cat >"$ROOT/etc/systemd/system/sys-kernel-config.mount" <<'MOUNT'

[Unit]

Description=USB gadget configuration filesystem

Before=athena-usb-console.service

[Mount]

What=configfs

Where=/sys/kernel/config

Type=configfs

Options=nosuid,nodev,noexec

[Install]

WantedBy=multi-user.target

MOUNT

cat >"$ROOT/etc/systemd/system/athena-usb-console.service" <<'UNIT'

[Unit]

Description=Athena USB CDC ACM console gadget

Requires=sys-kernel-config.mount

After=sys-kernel-config.mount

[Service]

Type=oneshot

ExecStart=/usr/local/sbin/athena-usb-console

RemainAfterExit=yes

[Install]

WantedBy=multi-user.target

UNIT

cat >"$ROOT/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<'GETTY'

[Service]

ExecStart=

ExecStart=-/sbin/agetty --autologin athena --keep-baud 921600 ttyS0 vt100

GETTY

cat >"$ROOT/etc/systemd/system/serial-getty@ttyGS0.service.d/usb-console.conf" <<'GETTY'

[Unit]

Requires=athena-usb-console.service

After=athena-usb-console.service

[Service]

ExecStart=

ExecStart=-/sbin/agetty --autologin athena --keep-baud 115200 ttyGS0 vt100

GETTY

chroot "$ROOT" systemctl --no-reload --root=/ enable graphical.target "$DESKTOP_SERVICE" seatd.service systemd-resolved.service systemd-timesyncd.service NetworkManager.service bluetooth.service athena-audio-init.service triggerhappy.service athena-usb-console.service sys-kernel-config.mount serial-getty@ttyS0.service serial-getty@ttyGS0.service athena-set-identity.service athena-root-grow.service

chroot "$ROOT" systemctl --no-reload --root=/ disable getty@tty1.service

chroot "$ROOT" systemctl --no-reload --root=/ set-default graphical.target

rm -f "$ROOT/etc/machine-id"

touch "$ROOT/etc/machine-id"

rm -f "$OUT"

mkdir -p "$(dirname "$OUT")"

say "Creating ext4 image ($SIZE); this final filesystem-population step can take a while"

mke2fs -F -t ext4 -L athena-rootfs -m 0 -E root_owner=0:0,lazy_itable_init=0 \
	-d "$ROOT" "$OUT" "$SIZE"

say "Created Debian arm64 Athena system image: $OUT ($(du -h "$OUT" | cut -f1))"
