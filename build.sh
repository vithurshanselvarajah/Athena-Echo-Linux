#!/bin/bash

# SPDX-License-Identifier: MIT

set -euo pipefail

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

HERE=$(cd "$(dirname "$0")" && pwd)

WORK=${WORK:-$HOME/athena-kbuild}

OUT=${OUT:-$WORK/out}

JOBS=${JOBS:-$(nproc)}

KVER=6.18.62

KURL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz

KSHA256=490a7aedf1b355c565d3a6c05333ccccb5da82064eca46b590448a7099d7d651

FW_TAG=20260916

FW_URL=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain

FW_FILES="

5e1a65036ccf9f53a6f69d9d8f75a07f546f9a7cec83ca89f24907925c54f079 mediatek/mt7663_n9_rebb.bin

d8b8488f37f65e41ded9a911950afb000d236b36e5aa94ad9650ad0c3a86fd45 mediatek/mt7663_n9_v3.bin

534f2152f9b0f48dfcec9c1727b0bab9a3727a655d76d5ec818cc39a55602336 mediatek/mt7663pr2h.bin

e812442fd631ecbea7d2898c3168cb5780377378a0eed74c14fe8d8057fe547c mediatek/mt7663pr2h_rebb.bin

a90d3f66704d85889945fec5525ea77622549da83aced1aac99828383f8f1805 LICENSES/LICENCE.mediatek

"

RAMDISK_FILES="LICENCE.mediatek mediatek/mt7663_n9_rebb.bin mediatek/mt7663_n9_v3.bin mediatek/mt7663pr2h.bin mediatek/mt7663pr2h_rebb.bin"

if [ -z "${CROSS_COMPILE:-}" ]; then
	if [ "$(dpkg --print-architecture)" = arm64 ]; then
		CROSS_COMPILE=
	else
		CROSS_COMPILE=aarch64-linux-gnu-
	fi
fi

export ARCH=arm64 CROSS_COMPILE

export KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=athena-build

export KBUILD_BUILD_TIMESTAMP="2026-10-26 18:00:00 UTC" KBUILD_BUILD_VERSION=1

export LC_ALL=C TZ=UTC

mkdir -p "$WORK/cache" "$OUT"

WORK=$(cd "$WORK" && pwd) OUT=$(cd "$OUT" && pwd)

CACHE=$WORK/cache

KBUILD_OUT=$WORK/kbuild/linux-$KVER

mkdir -p "$WORK/kbuild" "$KBUILD_OUT"

fetch() {

	if [ ! -f "$2" ] || ! echo "$3  $2" | sha256sum -c --quiet - 2>/dev/null; then

		mkdir -p "$(dirname "$2")"

		log "Downloading $(basename "$2")"

		curl --fail --location --progress-bar -o "$2.part" "$1"

		mv "$2.part" "$2"

	else

		log "Using cached $(basename "$2")"

	fi

	echo "$3  $2" | sha256sum -c --quiet - || {
		echo "sha256 mismatch: $2" >&2
		exit 1
	}

	log "SHA256 verified: $(basename "$2")"

}

log "[1/7] Preparing Linux $KVER source"

source_inputs_hash() {

	(

		cd "$HERE"

		find dts src patches -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d ' ' -f 1

	)

}

SOURCE_HASH=$(printf '%s\n%s\n' "$KSHA256" "$(source_inputs_hash)" | sha256sum | cut -d ' ' -f 1)

MANAGED_TREE=1

if [ -n "${KTREE:-}" ]; then

	MANAGED_TREE=0

	KTREE=$(cd "$KTREE" && pwd)

	grep -q "^SUBLEVEL = ${KVER##*.}$" "$KTREE/Makefile" || {
		echo "$KTREE is not linux-$KVER" >&2
		exit 1
	}

else

	fetch "$KURL" "$CACHE/linux-$KVER.tar.xz" "$KSHA256"

	KTREE=$WORK/linux-$KVER

	SOURCE_STAMP=$CACHE/linux-$KVER-athena-source.sha256

	if [ ! -f "$KTREE/Makefile" ] || [ "$(cat "$SOURCE_STAMP" 2>/dev/null || true)" != "$SOURCE_HASH" ]; then

		rm -rf "$KTREE"

		log "Extracting Linux source into $WORK"

		tar -C "$WORK" -xJf "$CACHE/linux-$KVER.tar.xz"

	fi

fi

log "Linux source is ready"

log "[2/7] Fetching and verifying Wi-Fi/Bluetooth firmware"

FWDIR=$CACHE/linux-firmware-$FW_TAG

echo "$FW_FILES" | while read -r sha path; do

	if [ -n "$path" ]; then fetch "$FW_URL/$path?h=$FW_TAG" "$FWDIR/$path" "$sha"; fi

done

STAGE=$WORK/ramdisk-firmware

rm -rf "$STAGE"

install -D -m 644 "$FWDIR/LICENSES/LICENCE.mediatek" "$STAGE/LICENCE.mediatek"

for f in $RAMDISK_FILES; do

	[ "$f" = LICENCE.mediatek ] || install -D -m 644 "$FWDIR/$f" "$STAGE/$f"

done

log "[3/7] Applying Athena device files and kernel patches"

DTSDIR=$KTREE/arch/arm64/boot/dts/mediatek

copy_if_changed() {

	if [ ! -f "$2" ] || ! cmp -s "$1" "$2"; then

		install -D -m 0644 "$1" "$2"

	fi

}

copy_if_changed "$HERE/dts/mt8183-amazon-athena.dts" "$DTSDIR/mt8183-amazon-athena.dts"

SLOT_TMP=$CACHE/mt8183-amazon-athena-dsp-slot.bin

python3 "$HERE/dsp_slot.py" empty "$SLOT_TMP"

copy_if_changed "$SLOT_TMP" "$DTSDIR/mt8183-amazon-athena-dsp-slot.bin"

copy_if_changed "$HERE/src/mt8183-athena.c" "$KTREE/sound/soc/mediatek/mt8183/mt8183-athena.c"

P=$HERE/patches

if ! grep -q "leave cache-only mode before the clocks are enabled" \
	"$KTREE/sound/soc/mediatek/mt8183/mt8183-afe-pcm.c"; then

	patch -d "$KTREE" -p1 -N -s --no-backup-if-mismatch \
		-i "$P/0001-mt8183-afe-leave-cache-only-before-enabling-clocks.patch"

fi

python3 "$P/patch-kbuild.py" "$KTREE"

python3 "$P/patch-afe-di2.py" "$KTREE"

python3 "$P/patch-afe-awb-dl1.py" "$KTREE"

python3 "$P/patch-usb-force-vbus.py" "$KTREE"

python3 "$P/patch-tcs3400.py" "$KTREE"

python3 "$P/patch-btmtksdio-bdaddr.py" "$KTREE"

python3 "$P/patch-btmtksdio-p192.py" "$KTREE"

python3 "$P/patch-btmtksdio-late-register.py" "$KTREE"

python3 "$P/patch-mt7663s-firmware-hold.py" "$KTREE"

python3 "$P/patch-display.py" "$KTREE"

python3 "$P/patch-tas5805m-dsp-slot.py" "$KTREE"

python3 "$P/patch-cci-sram.py" "$KTREE"

python3 "$P/patch-thermal-devinfo.py" "$KTREE"

python3 "$P/patch-camera.py" "$KTREE"

python3 "$P/patch-jpeg-enc-stall.py" "$KTREE"

if [ "$MANAGED_TREE" -eq 1 ]; then printf '%s\n' "$SOURCE_HASH" >"$CACHE/linux-$KVER-athena-source.sha256"; fi

log "[4/7] Configuring the arm64 kernel"

export KCFLAGS="-fdebug-prefix-map=$KTREE=." KAFLAGS="-fdebug-prefix-map=$KTREE=."

copy_if_changed "$HERE/athena_defconfig" "$KBUILD_OUT/.config"

make -C "$KTREE" O="$KBUILD_OUT" olddefconfig

for want in 'CONFIG_SND_SOC_MT8183_ATHENA=y' 'CONFIG_SND_SOC_TAS5805M=y' 'CONFIG_CRYPTO_LIB_SHA256=y' \
	'CONFIG_FRAMEBUFFER_CONSOLE=y' 'CONFIG_FRAMEBUFFER_CONSOLE_ROTATION=y' \
	'CONFIG_VT=y' 'CONFIG_VT_CONSOLE=y' 'CONFIG_QFMT_V2=y' 'CONFIG_TCS3472=y' \
	'CONFIG_BT_MTKSDIO=y' 'CONFIG_MT7663S=y' 'CONFIG_UHID=y' 'CONFIG_DRM_MEDIATEK=y' \
	'CONFIG_DRM_PANEL_ILITEK_ILI9881C=y' 'CONFIG_DRM_PANEL_JADARD_JD9365DA_H3=y' 'CONFIG_MTK_IOMMU=y' 'CONFIG_DRM_FBDEV_EMULATION=y' \
	'CONFIG_EXTRA_FIRMWARE=""' 'CONFIG_BLK_DEV_INITRD=y' 'CONFIG_RD_GZIP=y' \
	'CONFIG_INITRAMFS_SOURCE=""' 'CONFIG_LOCALVERSION="-athena"' \
	'CONFIG_ARM_MEDIATEK_CPUFREQ=y' 'CONFIG_ARM_MEDIATEK_CCI_DEVFREQ=y' 'CONFIG_MTK_SOC_THERMAL=y' \
	'CONFIG_THERMAL_DEFAULT_GOV_POWER_ALLOCATOR=y' 'CONFIG_MEDIA_SUPPORT=y' 'CONFIG_VIDEO_DEV=y' \
	'CONFIG_MTK_SENINF30=y' 'CONFIG_MTK_CAMSV=y' 'CONFIG_PHY_MTK_MIPI_CSI_0_5=y' 'CONFIG_VIDEO_OV13855=y' \
	'CONFIG_DRM_PANFROST=y' 'CONFIG_PM_DEVFREQ=y' 'CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND=y' 'CONFIG_DEVFREQ_THERMAL=y' \
	'CONFIG_VIDEO_MEDIATEK_JPEG=y' 'CONFIG_CGROUPS=y' 'CONFIG_FHANDLE=y' \
	'CONFIG_SECCOMP=y' 'CONFIG_SECCOMP_FILTER=y' 'CONFIG_BACKLIGHT_CLASS_DEVICE=y' \
	'CONFIG_BACKLIGHT_PWM=y'; do

	grep -qxF "$want" "$KBUILD_OUT/.config" || {
		echo "config check failed: $want" >&2
		exit 1
	}

done

for want in 'CONFIG_NETFILTER=y' 'CONFIG_NETFILTER_XTABLES=y' 'CONFIG_NETFILTER_XTABLES_LEGACY=y' \
	'CONFIG_NF_CONNTRACK=y' 'CONFIG_NETFILTER_XT_MATCH_STATE=y' 'CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y' \
	'CONFIG_NETFILTER_XT_MATCH_OWNER=y' 'CONFIG_NETFILTER_XT_MATCH_RECENT=y' 'CONFIG_IP_NF_IPTABLES=y' 'CONFIG_IP_NF_IPTABLES_LEGACY=y' \
	'CONFIG_IP_NF_FILTER=y' 'CONFIG_IP_NF_TARGET_REJECT=y' 'CONFIG_IP6_NF_IPTABLES=y' \
	'CONFIG_IP6_NF_IPTABLES_LEGACY=y' 'CONFIG_IP6_NF_FILTER=y' 'CONFIG_IP6_NF_TARGET_REJECT=y'; do

	grep -qxF "$want" "$KBUILD_OUT/.config" || {
		echo "config check failed: $want" >&2
		exit 1
	}

done

log "[5/7] Compiling Image.gz and the Athena device tree with $JOBS jobs"

make -C "$KTREE" O="$KBUILD_OUT" -j"$JOBS" Image.gz mediatek/mt8183-amazon-athena.dtb

cp "$KBUILD_OUT/arch/arm64/boot/Image.gz" "$OUT/Image.gz"

cp "$KBUILD_OUT/arch/arm64/boot/dts/mediatek/mt8183-amazon-athena.dtb" "$OUT/athena.dtb"

cp "$KBUILD_OUT/.config" "$OUT/kernel.config"

log "Kernel and device tree compilation finished"

log "[6/7] Creating the firmware ramdisk and boot image"

python3 "$HERE/mkfwcpio.py" "$STAGE" "$OUT/ramdisk.cpio.gz" $RAMDISK_FILES

python3 "$HERE/pack.py" "$OUT/Image.gz" "$OUT/athena.dtb" "$OUT/ramdisk.cpio.gz" "$OUT/boot-athena.img"

python3 "$HERE/check-boot.py" "$OUT/boot-athena.img"

log "[7/7] Preparing and compressing the corresponding kernel source archive (this can take several minutes)"

SRCNAME=linux-$KVER-athena

SRCTAR=$OUT/$SRCNAME-source.tar.xz

SRC_STAMP=$CACHE/linux-$KVER-athena-source-package.sha256

SRC_HASH=$(printf '%s\n%s\n%s\n' "$SOURCE_HASH" "$(sha256sum "$OUT/kernel.config" | cut -d ' ' -f 1)" "$KBUILD_BUILD_TIMESTAMP" | sha256sum | cut -d ' ' -f 1)

if [ "$MANAGED_TREE" -eq 0 ] || [ ! -s "$SRCTAR" ] || [ "$(cat "$SRC_STAMP" 2>/dev/null || true)" != "$SRC_HASH" ]; then

	PKG=$WORK/source-pkg

	rm -rf "$PKG" && mkdir -p "$PKG"

	cp -a "$KTREE" "$PKG/$SRCNAME"

	make -C "$PKG/$SRCNAME" distclean

	rm -f "$PKG/$SRCNAME"/arch/arm64/boot/Image "$PKG/$SRCNAME"/arch/arm64/boot/Image.gz

	cp "$OUT/kernel.config" "$PKG/$SRCNAME/athena.config"

	tar -C "$PKG" --sort=name --mtime="$KBUILD_BUILD_TIMESTAMP" --owner=0 --group=0 --numeric-owner \
		--mode='go-w,a+rX' --format=gnu -cf - "$SRCNAME" | xz -v -T1 -6 >"$SRCTAR.part"

	mv "$SRCTAR.part" "$SRCTAR"

	printf '%s\n' "$SRC_HASH" >"$SRC_STAMP"

else

	log "Using cached corresponding source archive"

fi

VERIFY_STAMP=$CACHE/linux-$KVER-athena-source-verified.sha256

VERIFY_HASH=$(printf '%s\n' \
	"$(sha256sum "$SRCTAR" "$OUT/boot-athena.img" "$OUT/kernel.config" "$HERE/build.sh" "$HERE/check-source.py")" \
	"$WORK" "$KTREE" "$(id -un)" "${USER:-}" "${SUDO_USER:-}" | sha256sum | cut -d ' ' -f 1)

if [ "$(cat "$VERIFY_STAMP" 2>/dev/null || true)" = "$VERIFY_HASH" ]; then

	log "Using cached source and boot verification"

else

	fetch "$KURL" "$CACHE/linux-$KVER.tar.xz" "$KSHA256"

	esc() { printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'; }

	pat="/home/|relbuild|$(esc "$WORK")|$(esc "$KTREE")"

	for n in "$(id -un)" "${USER:-}" "${SUDO_USER:-}"; do

		case "$n" in "" | root | builder) ;; *) pat="$pat|\b$(esc "$n")\b" ;; esac

	done

	count() { grep -aoiE "$pat" | tr 'A-Z' 'a-z' | sort | uniq -c; }

	ours=$(tar -xJOf "$SRCTAR" | count || true)

	theirs=$(tar -xJOf "$CACHE/linux-$KVER.tar.xz" | count || true)

	names=$(tar -tJf "$SRCTAR" | grep -iE "$pat" || true)

	if [ -n "$names" ] || [ "$ours" != "$theirs" ]; then

		echo "$SRCTAR carries something of this computer:" >&2

		echo "  kernel.org's: $theirs" >&2
		echo "  ours: $ours" >&2

		[ -z "$names" ] || echo "  in names: $(echo "$names" | head -5)" >&2

		exit 1

	fi

	python3 "$HERE/check-source.py" --config "$OUT/kernel.config" "$SRCTAR" "$OUT/boot-athena.img"

	printf '%s\n' "$VERIFY_HASH" >"$VERIFY_STAMP"

fi

rm -rf "$WORK/source-pkg"

log "Writing final SHA256SUMS"

cd "$OUT" && sha256sum boot-athena.img Image.gz athena.dtb ramdisk.cpio.gz kernel.config "$SRCNAME-source.tar.xz" >SHA256SUMS && cat SHA256SUMS

log "Build complete: $OUT"
