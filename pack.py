#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

"""Pack the athena boot image: Android boot image header v1, kernel = Image.gz with the DTB

appended, ramdisk = the firmware initramfs (mkfwcpio.py), no second stage.

    pack.py Image.gz athena.dtb ramdisk.cpio.gz OUT.img

The header is built here from the constants below; nothing is copied from another image. The

values are the ones LK on athena expects, as found in the stock boot image's header (load

addresses, page size, and OS version, with the Athena kernel command line.

The ramdisk holds only firmware files (MediaTek's MT7663 firmware, which its license does not allow

to be linked into the kernel) and no /init. LK appends root=PARTUUID=<system> init=/init to the

command line; finding no /init in the initramfs, the kernel mounts the system partition and runs

/init there, as Amazon's kernel does.

"""

import hashlib

import struct

import sys

BOOT_MAGIC = b"ANDROID!"

KERNEL_ADDR = 0x40200000

RAMDISK_ADDR = 0x55000000

SECOND_ADDR = 0x40F00000

TAGS_ADDR = 0x54000000

PAGE_SIZE = 2048

HEADER_VERSION = 1

OS_VERSION = 0x20040134

BOARD_NAME = b""

HEADER_SIZE = 1648

CMDLINE = (
    "bootopt=64S3,32N2,64N2 console=tty0 console=ttyS0,921600 earlycon consoleblank=0 "
    "fbcon=rotate:1 fbcon=nodefer loglevel=8 ignore_loglevel printk.time=1 initcall_debug "
    "systemd.log_level=debug systemd.log_target=console systemd.show_status=1 "
    "fw_devlink.sync_state=timeout "
    "clk_ignore_unused pd_ignore_unused regulator_ignore_unused cpuidle.off=1 "
    "panic=0 sysctl.kernel.panic_on_rcu_stall=1 mem=0x7e150000"
)

EXTRA_CMDLINE = ""

BOOT_PARTITION_SIZE = 16 * 1024 * 1024


def pad(n):

    return (n + PAGE_SIZE - 1) // PAGE_SIZE * PAGE_SIZE


def image_id(kernel, ramdisk=b"", second=b""):
    """The header's id, as mkbootimg computes it for a v1 image without a recovery DTBO: SHA-1

    over kernel, ramdisk and second stage, each followed by its size (le32), then a zero size for

    the recovery DTBO."""

    h = hashlib.sha1()

    for blob in (kernel, ramdisk, second):
        h.update(blob)

        h.update(struct.pack("<I", len(blob)))

    h.update(struct.pack("<I", 0))

    return h.digest()


def header(kernel_size, ramdisk_size, digest):

    hdr = struct.pack(
        "<8s10I16s512s32s1024sIQI",
        BOOT_MAGIC,
        kernel_size,
        KERNEL_ADDR,
        ramdisk_size,
        RAMDISK_ADDR,
        0,
        SECOND_ADDR,
        TAGS_ADDR,
        PAGE_SIZE,
        HEADER_VERSION,
        OS_VERSION,
        BOARD_NAME,
        CMDLINE.encode(),
        digest.ljust(32, b"\0"),
        EXTRA_CMDLINE.encode(),
        0,
        0,
        HEADER_SIZE,
    )

    assert len(hdr) == HEADER_SIZE, len(hdr)

    return hdr.ljust(PAGE_SIZE, b"\0")


def pack(image_gz, dtb, ramdisk):

    kernel = image_gz + dtb

    img = (
        header(len(kernel), len(ramdisk), image_id(kernel, ramdisk))
        + kernel.ljust(pad(len(kernel)), b"\0")
        + ramdisk.ljust(pad(len(ramdisk)), b"\0")
    )

    if len(img) > BOOT_PARTITION_SIZE:
        raise SystemExit(
            "boot image %d bytes, the partition holds %d"
            % (len(img), BOOT_PARTITION_SIZE)
        )

    return img


def main(argv):

    if len(argv) != 5:
        print(
            "usage: pack.py Image.gz athena.dtb ramdisk.cpio.gz OUT.img",
            file=sys.stderr,
        )

        return 2

    assert len(CMDLINE) < 512 and len(EXTRA_CMDLINE) < 1024

    parts = []

    for path in argv[1:4]:
        with open(path, "rb") as f:
            parts.append(f.read())

    image_gz, dtb, ramdisk = parts

    img = pack(image_gz, dtb, ramdisk)

    with open(argv[4], "wb") as f:
        f.write(img)

    print(
        "kernel+dtb %d, ramdisk %d, boot image %d of %d"
        % (len(image_gz) + len(dtb), len(ramdisk), len(img), BOOT_PARTITION_SIZE)
    )

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
