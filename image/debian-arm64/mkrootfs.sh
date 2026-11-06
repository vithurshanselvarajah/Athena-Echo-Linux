#!/bin/bash
# Create a minimal Debian arm64 root image for Athena hardware bring-up.
set -euo pipefail
say() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

OUT= WORK=/work SIZE=1536M
while [ $# -gt 0 ]; do
	case "$1" in
	-o) OUT=$2; shift 2;;
	-w) WORK=$2; shift 2;;
	-s) SIZE=$2; shift 2;;
	*) echo "mkbringup: unknown argument $1" >&2; exit 1;;
	esac
done
[ -n "$OUT" ] || { echo "usage: mkbringup.sh -o system.img [-w work] [-s 2048M]" >&2; exit 1; }
[ "$(dpkg --print-architecture)" = arm64 ] || { echo "mkbringup: run inside an arm64 container" >&2; exit 1; }
ROOT=/tmp/athena-rootfs
rm -rf "$ROOT" "$WORK/debootstrap.log"
mkdir -p "$ROOT" "$WORK"
export DEBIAN_FRONTEND=noninteractive
say "Refreshing the build container package index"
apt-get update
say "Installing debootstrap and ext4 image tools"
apt-get install -y --no-install-recommends debootstrap e2fsprogs ca-certificates
say "Bootstrapping the Debian trixie arm64 base; package retrieval progress follows"
debootstrap --arch=arm64 --variant=minbase --include=ca-certificates,systemd-sysv trixie "$ROOT" https://deb.debian.org/debian

install -d -m 0755 "$ROOT/etc/dpkg/dpkg.cfg.d"
cat > "$ROOT/etc/dpkg/dpkg.cfg.d/01-athena-slim" <<'DPKG'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/en/*
path-include=/usr/share/locale/en_GB/*
DPKG

cat > "$ROOT/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
exit 101
POLICY
chmod 755 "$ROOT/usr/sbin/policy-rc.d"
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
pkgs=$(sed 's/#.*//' /src/image/debian-arm64/desktop/phosh/packages.txt | xargs)
say "Refreshing package indexes inside the arm64 root"
chroot "$ROOT" apt-get update
say "Installing Phosh, Tauri runtime, hardware and network packages"
chroot "$ROOT" apt-get install -y --no-install-recommends $pkgs
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
echo athena > "$ROOT/etc/hostname"
rm -f "$ROOT/etc/resolv.conf"
ln -s /run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"

install -d -m 0755 "$ROOT/etc/systemd/logind.conf.d"
cat > "$ROOT/etc/systemd/logind.conf.d/athena.conf" <<'LOGIND'
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
LOGIND

install -d -m 0755 "$ROOT/etc/systemd/journald.conf.d"
cat > "$ROOT/etc/systemd/journald.conf.d/athena.conf" <<'JOURNAL'
[Journal]
Storage=volatile
RuntimeMaxUse=24M
RuntimeKeepFree=16M
JOURNAL

say "Writing first-boot init, Phosh display configuration and serial-console setup"
cat > "$ROOT/init" <<'INIT'
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
install -d -m 0755 "$ROOT/etc/phosh" "$ROOT/usr/local/sbin" \
	"$ROOT/usr/share/applications" \
	"$ROOT/etc/udev/rules.d" \
	"$ROOT/etc/triggerhappy/triggers.d" \
	"$ROOT/etc/dconf/profile" "$ROOT/etc/dconf/db/local.d" \
	"$ROOT/etc/systemd/system/athena-root-grow.service.d" \
	"$ROOT/etc/systemd/system/phosh.service.d" \
	"$ROOT/etc/systemd/system/serial-getty@ttyS0.service.d" \
	"$ROOT/etc/systemd/system/serial-getty@ttyGS0.service.d"
cat > "$ROOT/etc/udev/rules.d/70-athena-drm.rules" <<'UDEV'
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", GROUP="video", MODE="0660"
SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", GROUP="render", MODE="0660"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="generic ft5x06 (3e)", ENV{WL_OUTPUT}="DSI-1", ENV{LIBINPUT_CALIBRATION_MATRIX}="0.018601 -1.008491 0.999218 1.012344 0.001388 -0.007528"
UDEV
cat > "$ROOT/etc/phosh/phoc.ini" <<'PHOC'
[core]
xwayland=false

[output:DSI-1]
rotate=270
PHOC

cat > "$ROOT/etc/dconf/profile/user" <<'PROFILE'
user-db:user
system-db:local
PROFILE
cat > "$ROOT/etc/dconf/db/local.d/20-athena" <<'DCONF'
[org/gnome/desktop/session]
idle-delay=uint32 300

[org/gnome/desktop/screensaver]
lock-enabled=false
DCONF

cat > "$ROOT/usr/local/sbin/athena-set-identity" <<'IDENTITY'
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
cat > "$ROOT/etc/systemd/system/athena-set-identity.service" <<'UNIT'
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

cat > "$ROOT/usr/local/sbin/athena-root-grow" <<'GROW'
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
cat > "$ROOT/etc/systemd/system/athena-root-grow.service" <<'UNIT'
[Unit]
Description=Expand Athena ext4 root filesystem on first boot
After=local-fs.target
Before=phosh.service
ConditionPathExists=!/var/lib/athena/root-expanded

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/athena-root-grow
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

cat > "$ROOT/usr/local/sbin/athena-power-action" <<'POWER'
#!/bin/sh
set -eu
case "${1:-}" in
	poweroff) exec systemctl poweroff ;;
	reboot) exec systemctl reboot ;;
	recovery)
		device=$(findfs PARTLABEL=misc 2>/dev/null || findfs LABEL=misc 2>/dev/null || true)
		[ -b "$device" ] || { echo 'misc partition not found' >&2; exit 1; }
		python3 - "$device" <<'PY'
import os
import sys

device = sys.argv[1]
command = b"boot-recovery".ljust(32, b"\0")
with open(device, "r+b", buffering=0) as block:
    block.write(command)
    os.fsync(block.fileno())
with open(device, "rb", buffering=0) as block:
    if block.read(32) != command:
        raise SystemExit("recovery request read-back failed")
PY
	exec systemctl reboot ;;
	*) echo 'usage: athena-power-action poweroff|reboot|recovery' >&2; exit 2 ;;
esac
POWER
chmod 755 "$ROOT/usr/local/sbin/athena-power-action"
cat > "$ROOT/etc/sudoers.d/athena-actions" <<'SUDOERS'
athena ALL=(root) NOPASSWD: /usr/local/sbin/athena-volume-key up, /usr/local/sbin/athena-volume-key down, /usr/local/sbin/athena-power-action poweroff, /usr/local/sbin/athena-power-action reboot, /usr/local/sbin/athena-power-action recovery
SUDOERS
chmod 440 "$ROOT/etc/sudoers.d/athena-actions"
cat > "$ROOT/usr/share/applications/athena-recovery.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Reboot to TWRP
Exec=sudo -n /usr/local/sbin/athena-power-action recovery
Icon=system-reboot
Terminal=false
Type=Application
Categories=System;
DESKTOP
cat > "$ROOT/usr/share/applications/athena-poweroff.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Power Off
Exec=sudo -n /usr/local/sbin/athena-power-action poweroff
Icon=system-shutdown
Terminal=false
Type=Application
Categories=System;
DESKTOP
chroot "$ROOT" dconf update

# Configure Athena speaker playback and the four-channel microphone capture path.
cat > "$ROOT/usr/local/sbin/athena-audio-init" <<'AUDIOINIT'
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
# Enable the four TLV320ADC5140 microphone channels into the AFE capture PCM.
# I2S2 is selected at low jitter in the kernel as well; restating it here
# ensures the capture routes are active after boot.
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
AUDIOINIT
chmod 755 "$ROOT/usr/local/sbin/athena-audio-init"
cat > "$ROOT/etc/systemd/system/athena-audio-init.service" <<'UNIT'
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

# The physical volume buttons emit KEY_VOLUMEUP and KEY_VOLUMEDOWN.
cat > "$ROOT/usr/local/sbin/athena-volume-key" <<'VOLUMEKEY'
#!/bin/sh
set -eu
case "${1:-}" in
	up) delta=1 ;;
	down) delta=-1 ;;
	*) echo 'usage: athena-volume-key up|down' >&2; exit 2 ;;
esac
control='Master Playback Volume'
value=$(amixer -c 0 cget name="$control" | sed -n 's/^[[:space:]]*: values=\([-0-9][0-9]*\).*/\1/p' | head -n 1)
case "$value" in ''|*[!0-9-]*) echo "could not read $control" >&2; exit 1 ;; esac
if [ "$delta" -gt 0 ] && [ "$value" -ge 116 ]; then exit 0; fi
value=$((value + delta))
[ "$value" -ge 0 ] || value=0
amixer -q -c 0 cset name="$control" "$value,$value"
VOLUMEKEY
chmod 755 "$ROOT/usr/local/sbin/athena-volume-key"
install -d -m 0755 "$ROOT/etc/sudoers.d"
cat > "$ROOT/etc/triggerhappy/triggers.d/athena-volume.conf" <<'TRIGGERS'
KEY_VOLUMEUP 1 /usr/bin/sudo -n /usr/local/sbin/athena-volume-key up
KEY_VOLUMEDOWN 1 /usr/bin/sudo -n /usr/local/sbin/athena-volume-key down
TRIGGERS

cat > "$ROOT/etc/systemd/system/phosh.service.d/athena.conf" <<'UNIT'
[Unit]
Requires=seatd.service
After=seatd.service

[Service]
Environment=LIBSEAT_BACKEND=seatd
UNIT
cat > "$ROOT/usr/local/sbin/athena-usb-console" <<'USB'
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
cat > "$ROOT/etc/systemd/system/sys-kernel-config.mount" <<'MOUNT'
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
cat > "$ROOT/etc/systemd/system/athena-usb-console.service" <<'UNIT'
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
cat > "$ROOT/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin athena --keep-baud 921600 ttyS0 vt100
GETTY
cat > "$ROOT/etc/systemd/system/serial-getty@ttyGS0.service.d/usb-console.conf" <<'GETTY'
[Unit]
Requires=athena-usb-console.service
After=athena-usb-console.service

[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin athena --keep-baud 115200 ttyGS0 vt100
GETTY
chroot "$ROOT" systemctl --no-reload --root=/ enable graphical.target phosh.service seatd.service systemd-resolved.service systemd-timesyncd.service NetworkManager.service bluetooth.service athena-audio-init.service triggerhappy.service athena-usb-console.service sys-kernel-config.mount serial-getty@ttyS0.service serial-getty@ttyGS0.service athena-set-identity.service athena-root-grow.service
chroot "$ROOT" systemctl --no-reload --root=/ disable getty@tty1.service
chroot "$ROOT" systemctl --no-reload --root=/ set-default graphical.target
rm -f "$ROOT/etc/machine-id"
touch "$ROOT/etc/machine-id"
rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
say "Creating ext4 image ($SIZE); this final filesystem-population step can take a while"
mke2fs -F -t ext4 -L athena-rootfs -m 0 -E root_owner=0:0,lazy_itable_init=0 \
	-d "$ROOT" "$OUT" "$SIZE"
say "Created Debian arm64 Athena bring-up image: $OUT ($(du -h "$OUT" | cut -f1))"
