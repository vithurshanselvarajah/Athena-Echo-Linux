#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

SYSTEM=${1:?usage: ci/test-image.sh system.img output-directory}
OUT=${2:?usage: ci/test-image.sh system.img output-directory}

TRIVY_IMAGE=${TRIVY_IMAGE:-}
TRIVY_EXIT_CODE=${TRIVY_EXIT_CODE:-0}
TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/trivy}

grep -q 'linux,code = <KEY_VOLUMEUP>' "$ROOT/dts/mt8183-amazon-athena.dts"
grep -q 'linux,code = <KEY_VOLUMEDOWN>' "$ROOT/dts/mt8183-amazon-athena.dts"
grep -q 'linux,code = <KEY_MICMUTE>' "$ROOT/dts/mt8183-amazon-athena.dts"
grep -q 'linux,code = <SW_CAMERA_LENS_COVER>' "$ROOT/dts/mt8183-amazon-athena.dts"
grep -q 'brightness-levels = <0 1023>' "$ROOT/dts/mt8183-amazon-athena.dts"
grep -A8 'pwm-leds {' "$ROOT/dts/mt8183-amazon-athena.dts" | grep -q 'status = "okay"'
grep -q 'function = LED_FUNCTION_MICMUTE;' "$ROOT/dts/mt8183-amazon-athena.dts"

label=$(blkid -p -s LABEL -o value "$SYSTEM")
[ "$label" = athena-rootfs ] || {
	echo "unexpected root filesystem label: $label" >&2
	exit 1
}

e2fsck -fn "$SYSTEM"

work=$(mktemp -d)
rootfs=$work/root
mkdir -p "$rootfs" "$OUT" "$TRIVY_CACHE_DIR"
OUT=$(cd "$OUT" && pwd)
TRIVY_CACHE_DIR=$(cd "$TRIVY_CACHE_DIR" && pwd)

cleanup() {
	rm -rf "$work"
}
trap cleanup EXIT

debugfs -R "rdump / $rootfs" "$SYSTEM" >/dev/null 2>&1

for script in \
	"$rootfs/init" \
	"$rootfs/usr/local/sbin/athena-set-identity" \
	"$rootfs/usr/local/sbin/athena-root-grow" \
	"$rootfs/usr/local/sbin/athena-power-action" \
	"$rootfs/usr/local/sbin/athena-audio-init" \
	"$rootfs/usr/local/sbin/athena-micmute-led" \
	"$rootfs/usr/local/sbin/athena-volume-key" \
	"$rootfs/usr/local/sbin/athena-micmute-key" \
	"$rootfs/usr/local/sbin/athena-usb-console"; do
	test -x "$script"
	test "$(head -n 1 "$script")" = '#!/bin/sh'
	sh -n "$script"
done
test "$(awk -F: '$1 == "athena" { print $3 ":" $4 }' "$rootfs/etc/passwd")" = 1000:1000
grep -q '^root:![^:]*:' "$rootfs/etc/shadow"
test -x "$rootfs/usr/local/sbin/athena-set-identity"
test -x "$rootfs/usr/local/sbin/athena-root-grow"
test -x "$rootfs/usr/local/sbin/athena-power-action"
test -x "$rootfs/usr/local/sbin/athena-audio-init"
test -f "$rootfs/etc/systemd/system/athena-root-grow.service"
grep -q 'findfs LABEL=athena-rootfs' "$rootfs/usr/local/sbin/athena-root-grow"
grep -q 'resize2fs' "$rootfs/usr/local/sbin/athena-root-grow"
test -f "$rootfs/etc/phosh/phoc.ini"
grep -q '^rotate=270$' "$rootfs/etc/phosh/phoc.ini"
grep -q '^scale=1$' "$rootfs/etc/phosh/phoc.ini"
grep -q '^idle-delay=uint32 300$' "$rootfs/etc/dconf/db/local.d/20-athena"
grep -q '^lock-enabled=false$' "$rootfs/etc/dconf/db/local.d/20-athena"
grep -q '^require-unlock=false$' "$rootfs/etc/dconf/db/local.d/20-athena"
grep -q '^orientation-lock=true$' "$rootfs/etc/dconf/db/local.d/20-athena"
grep -q "^power-button-action='nothing'$" "$rootfs/etc/dconf/db/local.d/20-athena"
grep -q '^app-filter-mode=\[\]$' "$rootfs/etc/dconf/db/local.d/20-athena"
grep -q "^favorites=\['org.gnome.Settings.desktop','foot.desktop'\]$" "$rootfs/etc/dconf/db/local.d/20-athena"
grep -q '^HandlePowerKey=ignore$' "$rootfs/etc/systemd/logind.conf.d/athena.conf"
test -x "$rootfs/usr/bin/chvt"
grep -q '^ExecStartPost=+chvt 7$' "$rootfs/usr/lib/systemd/system/phosh.service"
test -f "$rootfs/usr/share/applications/athena-recovery.desktop"
test -f "$rootfs/usr/share/applications/athena-poweroff.desktop"
test -f "$rootfs/etc/triggerhappy/triggers.d/athena-volume.conf"
grep -q 'ATTRS{name}=="mtk-pmic-keys".*LIBINPUT_IGNORE_DEVICE="1"' "$rootfs/etc/udev/rules.d/70-athena-drm.rules"
grep -q '^KEY_MICMUTE 1 /usr/bin/sudo -n /usr/local/sbin/athena-micmute-key$' "$rootfs/etc/triggerhappy/triggers.d/athena-volume.conf"
test -f "$rootfs/usr/share/alsa/ucm2/conf.d/mt8183_athena/mt8183_athena.conf"
test -f "$rootfs/usr/share/alsa/ucm2/conf.d/mt8183_athena/HiFi.conf"
grep -q 'CapturePCM "hw:${CardId},2"' "$rootfs/usr/share/alsa/ucm2/conf.d/mt8183_athena/HiFi.conf"
grep -qx 'athena ALL=(ALL:ALL) NOPASSWD: ALL' "$rootfs/etc/sudoers.d/athena-admin"
grep -q 'PARTLABEL=misc' "$rootfs/usr/local/sbin/athena-power-action"
test -x "$rootfs/usr/bin/gsettings"
test -e "$rootfs/usr/share/applications/sm.puri.OSK0.desktop"

dpkg-query --admindir="$rootfs/var/lib/dpkg" -W -f='${db:Status-Status}\n' phosh | grep -qx installed
dpkg-query --admindir="$rootfs/var/lib/dpkg" -W -f='${db:Status-Status}\n' gnome-control-center | grep -qx installed
if dpkg-query --admindir="$rootfs/var/lib/dpkg" -W -f='${db:Status-Status}\n' phosh-mobile-settings 2>/dev/null | grep -qx installed; then
	exit 1
fi
dpkg-query --admindir="$rootfs/var/lib/dpkg" -W -f='${db:Status-Status}\n' squeekboard | grep -qx installed
dpkg-query --admindir="$rootfs/var/lib/dpkg" -W -f='${db:Status-Status}\n' kbd | grep -qx installed
dpkg-query --admindir="$rootfs/var/lib/dpkg" -W -f='${db:Status-Status}\n' gnome-settings-daemon | grep -qx installed
dpkg-query --admindir="$rootfs/var/lib/dpkg" -W -f='${db:Status-Status}\n' alsa-ucm-conf | grep -qx installed
dpkg-query --admindir="$rootfs/var/lib/dpkg" -W -f='${db:Status-Status}\n' libglib2.0-bin | grep -qx installed
dpkg-query --admindir="$rootfs/var/lib/dpkg" -W -f='${db:Status-Status}\n' polkitd | grep -qx installed
dpkg-query --admindir="$rootfs/var/lib/dpkg" -W -f='${db:Status-Status}\n' librsvg2-common | grep -qx installed
dpkg-query --admindir="$rootfs/var/lib/dpkg" -W -f='${Architecture}\n' libc6 | grep -qx arm64

if [ -n "$TRIVY_IMAGE" ]; then
	docker run --rm \
		-v "$rootfs:/rootfs:ro" \
		-v "$OUT:/out" \
		-v "$TRIVY_CACHE_DIR:/cache" \
		-e TRIVY_CACHE_DIR=/cache \
		"$TRIVY_IMAGE" rootfs --scanners vuln --severity HIGH,CRITICAL --exit-code 0 \
		--format json --output /out/system-vulnerabilities.json /rootfs

	docker run --rm \
		-v "$rootfs:/rootfs:ro" \
		-v "$OUT:/out" \
		-v "$TRIVY_CACHE_DIR:/cache" \
		-e TRIVY_CACHE_DIR=/cache \
		"$TRIVY_IMAGE" rootfs --scanners vuln --format cyclonedx \
		--output /out/system.sbom.cdx.json /rootfs

	if [ "$TRIVY_EXIT_CODE" = 1 ]; then
		docker run --rm \
			-v "$rootfs:/rootfs:ro" \
			-v "$TRIVY_CACHE_DIR:/cache" \
			-e TRIVY_CACHE_DIR=/cache \
			"$TRIVY_IMAGE" rootfs --scanners vuln --ignore-unfixed --severity HIGH,CRITICAL \
			--exit-code 1 /rootfs
	fi
fi
