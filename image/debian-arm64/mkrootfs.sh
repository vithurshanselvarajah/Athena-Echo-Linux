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
ROOT=/tmp/athena-bringup-rootfs
rm -rf "$ROOT" "$WORK/debootstrap.log"
mkdir -p "$ROOT" "$WORK"
export DEBIAN_FRONTEND=noninteractive
say "Refreshing the build container package index"
apt-get update
say "Installing debootstrap and ext4 image tools"
apt-get install -y --no-install-recommends debootstrap e2fsprogs ca-certificates
say "Bootstrapping the Debian trixie arm64 base; package retrieval progress follows"
debootstrap --arch=arm64 --variant=minbase --include=ca-certificates,systemd-sysv trixie "$ROOT" https://deb.debian.org/debian

cat > "$ROOT/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
exit 101
POLICY
chmod 755 "$ROOT/usr/sbin/policy-rc.d"
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
pkgs=$(sed 's/#.*//' /src/image/debian-arm64/packages.txt | xargs)
say "Refreshing package indexes inside the arm64 root"
chroot "$ROOT" apt-get update
say "Installing desktop, Electron runtime, touch, audio and network packages"
chroot "$ROOT" apt-get install -y --no-install-recommends $pkgs
say "Removing package download caches to keep the image small"
rm -f "$ROOT/usr/sbin/policy-rc.d"
rm -rf "$ROOT/var/lib/apt/lists" "$ROOT/var/cache/apt/archives"/* "$ROOT/var/cache/debconf"/*

# One unprivileged desktop account, with passwordless sudo for the serial bring-up console.
for group in seat video render input audio; do chroot "$ROOT" groupadd --system "$group" 2>/dev/null || true; done
chroot "$ROOT" useradd --create-home --uid 1000 --shell /bin/bash bringup
chroot "$ROOT" usermod -a -G video,render,input,seat,audio bringup
printf 'bringup ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$ROOT/etc/sudoers.d/bringup"
chmod 440 "$ROOT/etc/sudoers.d/bringup"
chroot "$ROOT" passwd -l bringup >/dev/null
chroot "$ROOT" passwd -l root >/dev/null
echo athena-bringup > "$ROOT/etc/hostname"
rm -f "$ROOT/etc/resolv.conf"
ln -s /run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"

# LK passes init=/init. Mount the early virtual filesystems, then hand PID 1 to Debian systemd.
say "Writing first-boot init, Weston desktop and serial-console configuration"
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
install -d -m 0755 "$ROOT/etc/xdg/weston" "$ROOT/usr/local/sbin" \
	"$ROOT/etc/udev/rules.d" \
	"$ROOT/etc/triggerhappy/triggers.d" \
	"$ROOT/etc/systemd/system/serial-getty@ttyS0.service.d" \
	"$ROOT/etc/systemd/system/serial-getty@ttyGS0.service.d"
cat > "$ROOT/etc/udev/rules.d/70-athena-drm.rules" <<'UDEV'
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", GROUP="video", MODE="0660"
SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", GROUP="render", MODE="0660"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="generic ft5x06 (3e)", ENV{WL_OUTPUT}="DSI-1", ENV{LIBINPUT_CALIBRATION_MATRIX}="0.018601 -1.008491 0.999218 1.012344 0.001388 -0.007528"
UDEV
cat > "$ROOT/etc/xdg/weston/weston.ini" <<'WESTON'
[core]
backend=drm-backend.so
shell=desktop-shell.so
idle-time=0
xwayland=true

[shell]
background-color=0xff18202b

[output]
name=DSI-1
transform=rotate-270
WESTON

cat > "$ROOT/usr/local/sbin/athena-desktop-session" <<'SESSION'
#!/bin/sh
set -eu
export XDG_RUNTIME_DIR=/run/weston
export LIBSEAT_BACKEND=seatd
unset WAYLAND_DISPLAY
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
WESTON_LOG="$XDG_RUNTIME_DIR/weston.log"
weston --socket=wayland-0 --config=/etc/xdg/weston/weston.ini --log="$WESTON_LOG" &
weston_pid=$!
trap 'kill "$weston_pid" 2>/dev/null || true' EXIT INT TERM
export WAYLAND_DISPLAY=wayland-0
n=0
while [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && kill -0 "$weston_pid" 2>/dev/null && [ "$n" -lt 30 ]; do
	sleep 1; n=$((n+1))
done
[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] || { echo "Weston did not start; inspect $WESTON_LOG" >&2; exit 1; }
DISPLAY=$(sed -n 's/.*xserver listening on display :\([0-9][0-9]*\).*/:\1/p' "$WESTON_LOG" | tail -1)
export DISPLAY
exec foot
SESSION
chmod 755 "$ROOT/usr/local/sbin/athena-desktop-session"

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
value=$(amixer -c 0 cget name="$control" | sed -n 's/.*values=\([-0-9][0-9]*\).*/\1/p' | head -n 1)
case "$value" in ''|*[!0-9-]*) echo "could not read $control" >&2; exit 1 ;; esac
value=$((value + delta))
[ "$value" -ge 0 ] || value=0
# 110 is 0 dB; cap at +6 dB.
[ "$value" -le 116 ] || value=116
amixer -q -c 0 cset name="$control" "$value,$value"
VOLUMEKEY
chmod 755 "$ROOT/usr/local/sbin/athena-volume-key"
cat > "$ROOT/etc/triggerhappy/triggers.d/athena-volume.conf" <<'TRIGGERS'
KEY_VOLUMEUP 1 /usr/local/sbin/athena-volume-key up
KEY_VOLUMEDOWN 1 /usr/local/sbin/athena-volume-key down
TRIGGERS

cat > "$ROOT/etc/systemd/system/athena-desktop.service" <<'UNIT'
[Unit]
Description=Athena Weston desktop and terminal
After=systemd-udev-trigger.service seatd.service systemd-user-sessions.service
Requires=seatd.service

[Service]
Type=simple
User=bringup
SupplementaryGroups=video render input seat audio
RuntimeDirectory=weston
RuntimeDirectoryMode=0700
Environment=LIBSEAT_BACKEND=seatd
ExecStart=/usr/local/sbin/athena-desktop-session
Restart=always
RestartSec=2

[Install]
WantedBy=graphical.target
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
ExecStart=-/sbin/agetty --autologin bringup --keep-baud 921600 ttyS0 vt100
GETTY
cat > "$ROOT/etc/systemd/system/serial-getty@ttyGS0.service.d/usb-console.conf" <<'GETTY'
[Unit]
Requires=athena-usb-console.service
After=athena-usb-console.service

[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin bringup --keep-baud 115200 ttyGS0 vt100
GETTY
chroot "$ROOT" systemctl --no-reload --root=/ enable graphical.target seatd.service systemd-resolved.service systemd-timesyncd.service NetworkManager.service athena-desktop.service athena-audio-init.service triggerhappy.service athena-usb-console.service sys-kernel-config.mount serial-getty@ttyS0.service serial-getty@ttyGS0.service
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
