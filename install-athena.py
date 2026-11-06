#!/usr/bin/env python3

"""Install a locally built arm64 kernel and Debian bring-up image to an unlocked Athena in TWRP.

This is a standalone adb installer. It does not download releases or import code from another repo.

It saves the current boot and system partitions, verifies both local images, checks the partition

names again before writing, streams each image to avoid using TWRP's RAM disk, and verifies flash

read-back hashes before rebooting.

"""

import argparse

import hashlib

import os

import re

import shlex

import struct

import subprocess

import sys

import tempfile

import zlib

class InstallError(Exception):

    pass

def run(args, *, input=None, check=True):

    p = subprocess.run(args, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    if check and p.returncode:

        raise InstallError((p.stderr or p.stdout).decode(errors="replace").strip() or

                           "command failed: " + shlex.join(args))

    return p

def sha256(data):

    return hashlib.sha256(data).hexdigest()

def adb(serial, *args, input=None, check=True):

    return run(["adb", "-s", serial, *args], input=input, check=check)

def shell(serial, command):

    return adb(serial, "shell", command).stdout.decode(errors="replace").replace("\r\n", "\n").strip()

def remote_file(serial, command):

    return adb(serial, "exec-out", command).stdout

def local_hash(path):

    h = hashlib.sha256()

    with open(path, "rb") as f:

        for block in iter(lambda: f.read(1 << 20), b""):

            h.update(block)

    return h.hexdigest()

def read_boot(path):

    data = open(path, "rb").read()

    if len(data) < 2048 or data[:8] != b"ANDROID!":

        raise InstallError(f"{path}: not an Android boot image")

    page = int.from_bytes(data[36:40], "little")

    version = int.from_bytes(data[40:44], "little")

    if page not in (2048, 4096, 8192, 16384) or version > 2:

        raise InstallError(f"{path}: unsupported boot header (page={page}, version={version})")

    return data

SLOT_MAGIC = b"ATHDSPC1"

SLOT_SIZE = 8192

SLOT_HEAD = 44

SLOT_MAX = SLOT_SIZE - SLOT_HEAD

KNOWN_AMP_TABLES = {

    "8c14a75c68e77d071cfc512f2fbeb002351eb2f26b0ee945bd94e87b10c45c49": (0, "table A"),

    "5f3f4ddbcb081b6ac49a361c529ef99fcb010cee0100ae37088d831601ba9248": (1, "table B"),

}

PREBOOT_START = ((0, 0), (0x7f, 0), (3, 2), (0xfe, 2), (1, 0x11))

PREBOOT_END = (2, 2)

MIN_TABLE = 100

class BootImage:

    def __init__(self, data, what):

        if len(data) < 1652 or data[:8] != b"ANDROID!":

            raise InstallError(f"{what}: not an Android boot image")

        (self.kernel_size, _, self.ramdisk_size, _, self.second_size, _, _, self.page,

         self.version) = struct.unpack("<9I", data[8:44])

        if self.page not in (2048, 4096, 8192, 16384) or self.version > 2:

            raise InstallError(f"{what}: unsupported Android boot header")

        self.data = data

        pad = lambda n: (n + self.page - 1) // self.page * self.page

        self.kernel_at = self.page

        self.ramdisk_at = self.kernel_at + pad(self.kernel_size)

        self.second_at = self.ramdisk_at + pad(self.ramdisk_size)

        self.dtbo = self.dtb = b""

        if self.version >= 1:

            size, off = struct.unpack("<IQ", data[1632:1644])

            if size:

                self.dtbo = data[off:off + size]

                if len(self.dtbo) != size:

                    raise InstallError(f"{what}: truncated recovery dtbo")

        if self.version >= 2:

            size = struct.unpack("<I", data[1648:1652])[0]

            at = self.second_at + pad(self.second_size) + pad(len(self.dtbo))

            self.dtb = data[at:at + size]

            if len(self.dtb) != size:

                raise InstallError(f"{what}: truncated device tree")

        if self.second_at + self.second_size > len(data):

            raise InstallError(f"{what}: truncated boot image components")

    def kernel(self):

        return self.data[self.kernel_at:self.kernel_at + self.kernel_size]

    def second(self):

        return self.data[self.second_at:self.second_at + self.second_size]

    def image_id(self):

        h = hashlib.sha1()

        parts = [self.kernel(), self.data[self.ramdisk_at:self.ramdisk_at + self.ramdisk_size], self.second()]

        if self.version >= 1:

            parts.append(self.dtbo)

        if self.version >= 2:

            parts.append(self.dtb)

        for part in parts:

            h.update(part)

            h.update(struct.pack("<I", len(part)))

        return h.digest().ljust(32, b"\0")

def check_empty_slot(data, what):

    img = BootImage(data, what)

    if data[576:608] != img.image_id():

        raise InstallError(f"{what}: boot header SHA1 id does not match its contents")

    if data.count(SLOT_MAGIC) != 1:

        raise InstallError(f"{what}: expected exactly one speaker tuning slot")

    at = data.find(SLOT_MAGIC)

    if at + SLOT_SIZE > len(data) or not (img.kernel_at <= at and at + SLOT_SIZE <= img.second_at + img.second_size):

        raise InstallError(f"{what}: speaker tuning slot is outside the boot image payload")

    if struct.unpack_from("<I", data, at + 8)[0] != 0 or any(data[at + SLOT_HEAD:at + SLOT_SIZE]):

        raise InstallError(f"{what}: speaker tuning slot is not empty; use a freshly built kernel image")

    return img

def _strings(blob):

    return [x.decode("ascii", "replace") for x in blob.split(b"\0") if x]

def _fdt_props(blob):

    magic, total, off_struct, off_strings, _, version = struct.unpack(">6I", blob[:24])

    if magic != 0xd00dfeed or version < 16 or total > len(blob):

        raise ValueError("invalid FDT")

    p, path, props = off_struct, [], []

    while p + 4 <= total:

        token = struct.unpack_from(">I", blob, p)[0]

        p += 4

        if token == 1:

            end = blob.index(b"\0", p)

            path.append(blob[p:end].decode("ascii", "replace"))

            p = (end + 4) & ~3

        elif token == 2:

            if path:

                path.pop()

        elif token == 3:

            size, name_off = struct.unpack_from(">II", blob, p)

            p += 8

            name_at = off_strings + name_off

            name_end = blob.index(b"\0", name_at)

            props.append(("/".join(path) or "/", blob[name_at:name_end].decode("ascii", "replace"),

                          blob[p:p + size]))

            p = (p + size + 3) & ~3

        elif token == 4:

            continue

        elif token == 9:

            return props

        else:

            raise ValueError("unknown FDT token")

    raise ValueError("unterminated FDT")

def _find_dtbs(blob):

    result, at = [], blob.find(b"\xd0\x0d\xfe\xed")

    while at >= 0:

        if at + 40 <= len(blob):

            size = struct.unpack_from(">I", blob, at + 4)[0]

            if 40 < size <= len(blob) - at:

                try:

                    result.append(_fdt_props(blob[at:at + size]))

                except (ValueError, IndexError, struct.error):

                    pass

        at = blob.find(b"\xd0\x0d\xfe\xed", at + 4)

    return result

def _compat(props):

    return next((_strings(v) for path, name, v in props if path == "/" and name == "compatible"), [])

def _speaker_configs(props):

    nodes = {}

    for path, name, value in props:

        nodes.setdefault(path, {})[name] = value

    out = []

    for node in nodes.values():

        if "ti,tas5805m" not in _strings(node.get("compatible", b"")):

            continue

        status = _strings(node.get("status", b"okay"))

        if status and status[0] not in ("okay", "ok"):

            continue

        value = node.get("speaker-config", b"")

        if len(value) == 4:

            out.append(struct.unpack(">I", value)[0])

    return out

def _legacy_lz4(data):

    out, p = bytearray(), 4

    while p + 4 <= len(data):

        size = struct.unpack_from("<I", data, p)[0]

        if size in (0x184c2102, 0) or p + 4 + size > len(data):

            break

        block = data[p + 4:p + 4 + size]

        p += size + 4

        i = 0

        while i < len(block):

            token = block[i]; i += 1

            literals = token >> 4

            if literals == 15:

                while True:

                    b = block[i]; i += 1; literals += b

                    if b != 255: break

            out.extend(block[i:i + literals]); i += literals

            if i >= len(block): break

            offset = block[i] | block[i + 1] << 8; i += 2

            match = token & 15

            if match == 15:

                while True:

                    b = block[i]; i += 1; match += b

                    if b != 255: break

            match += 4

            if not offset or offset > len(out):

                raise ValueError("invalid LZ4 offset")

            for _ in range(match): out.append(out[-offset])

    return bytes(out)

def _decompress_kernel(kernel):

    if kernel[0x38:0x3c] == b"ARMd":

        return kernel

    candidates = []

    for magic in (b"\x1f\x8b\x08", b"\x02\x21\x4c\x18"):

        at = kernel.find(magic)

        while at >= 0 and len(candidates) < 64:

            candidates.append(at); at = kernel.find(magic, at + 1)

    for at in sorted(candidates):

        try:

            raw = (zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(kernel[at:]) if kernel[at] == 0x1f

                   else _legacy_lz4(kernel[at:]))

        except (zlib.error, ValueError, IndexError):

            continue

        if len(raw) >= 1 << 20:

            return raw

    raise InstallError("could not decompress the stock boot kernel to find its amp table")

def _split_amp_run(entries):

    out, start, i = [], 0, 0

    while i < len(entries):

        if tuple(entries[i:i + len(PREBOOT_START)]) == PREBOOT_START:

            if i - start >= MIN_TABLE:

                out.append(entries[start:i])

            j = i + len(PREBOOT_START)

            while j < len(entries) and entries[j] != PREBOOT_END:

                j += 1

            i = start = j + 1

        else:

            i += 1

    if len(entries) - start >= MIN_TABLE:

        out.append(entries[start:])

    return out

def _amp_tables(raw):

    sig = b"".join(struct.pack("<3I", reg, val, 0) for reg, val in PREBOOT_START)

    tables, seen = [], set()

    at = raw.find(sig)

    while at >= 0:

        if at % 4 == 0:

            start = at

            while start >= 12:

                reg, val, zero = struct.unpack_from("<3I", raw, start - 12)

                if zero or reg >= 0x100 or val >= 0x100: break

                start -= 12

            if start not in seen:

                seen.add(start); end = at

                while end + 12 <= len(raw):

                    reg, val, zero = struct.unpack_from("<3I", raw, end)

                    if zero or reg >= 0x100 or val >= 0x100: break

                    end += 12

                entries = [struct.unpack_from("<3I", raw, pos)[:2] for pos in range(start, end, 12)]

                tables.extend(_split_amp_run(entries))

        at = raw.find(sig, at + 1)

    return [bytes(byte for reg, val in entries if reg != 0xfe for byte in (reg, val)) for entries in tables]

def extract_amp_tuning(stock_boot, live_compatible):

    img = BootImage(stock_boot, "saved stock boot partition")

    raw = _decompress_kernel(img.kernel())

    dtbs = _find_dtbs(img.kernel()) + _find_dtbs(img.second()) + _find_dtbs(img.dtb)

    if not dtbs:

        raise InstallError("stock boot image contains no readable device trees")

    matched = [d for d in dtbs if live_compatible and _compat(d) == live_compatible]

    configs = sorted({c for d in matched for c in _speaker_configs(d)})

    source = "matching recovery device tree"

    if len(configs) != 1:

        athena = [d for d in dtbs if "amzn,athena" in _compat(d)]

        configs = sorted({c for d in athena for c in _speaker_configs(d)})

        source = "Athena device trees in stock boot image"

    if len(configs) != 1 or configs[0] not in (0, 1):

        raise InstallError(f"could not unambiguously determine the stock speaker-config ({configs})")

    config = configs[0]

    for table in _amp_tables(raw):

        known = KNOWN_AMP_TABLES.get(sha256(table))

        if known and known[0] == config:

            print(f"Found Fire OS speaker tuning: {known[1]} (speaker-config {config}, {source})")

            return table

    found = ", ".join(sha256(t)[:16] for t in _amp_tables(raw)) or "none"

    raise InstallError(f"Fire OS speaker-config {config} has no recognized amp table (found {found}); "

                       "this firmware needs to be added to the known tuning list")

def fill_amp_slot(boot, table):

    img = check_empty_slot(boot, "locally built kernel image")

    if not table or len(table) > SLOT_MAX or len(table) % 2:

        raise InstallError(f"speaker tuning size {len(table)} is invalid for the reserved slot")

    out = bytearray(boot)

    at = out.find(SLOT_MAGIC)

    out[at + 8:at + 12] = struct.pack("<I", len(table))

    out[at + 12:at + 44] = hashlib.sha256(table).digest()

    out[at + SLOT_HEAD:at + SLOT_HEAD + len(table)] = table

    out[576:608] = BootImage(bytes(out), "tuned kernel image").image_id()

    tuned = bytes(out)

    if tuned.count(SLOT_MAGIC) != 1 or struct.unpack_from("<I", tuned, at + 8)[0] != len(table):

        raise InstallError("speaker tuning slot verification failed")

    if tuned[at + SLOT_HEAD:at + SLOT_HEAD + len(table)] != table:

        raise InstallError("speaker tuning data verification failed")

    if tuned[576:608] != BootImage(tuned, "tuned kernel image").image_id():

        raise InstallError("tuned kernel boot header id verification failed")

    return tuned

def read_ext4(path):

    with open(path, "rb") as f:

        f.seek(1024)

        sb = f.read(136)

    if len(sb) < 136 or sb[56:58] != b"\x53\xef":

        raise InstallError(f"{path}: not an ext4 filesystem image")

    label = sb[120:136].rstrip(b"\0")

    if label != b"athena-rootfs":

        raise InstallError(f"{path}: ext4 label is {label!r}, expected b'athena-rootfs'")

    if os.path.getsize(path) % 4096:

        raise InstallError(f"{path}: image size is not a multiple of 4096")

def adb_devices():

    out = run(["adb", "devices"]).stdout.decode(errors="replace")

    return [line.split()[0] for line in out.splitlines()[1:] if len(line.split()) == 2 and

            line.split()[1] == "recovery"]

def find_emmc(serial):

    for dev in ("mmcblk1", "mmcblk0"):

        if shell(serial, f"sed -n 's/^PARTNAME=//p' /sys/class/block/{dev}p21/uevent 2>/dev/null") == "system":

            return dev

    raise InstallError("could not find an eMMC with partition 21 named system")

def partition_info(serial, mmc, number):

    line = shell(serial, f"d=/sys/class/block/{mmc}p{number}; "

                 "printf '%s %s' \"$(sed -n 's/^PARTNAME=//p' $d/uevent)\" \"$(cat $d/size)\"")

    fields = line.split()

    if len(fields) != 2 or not fields[1].isdigit():

        raise InstallError(f"could not read partition {number} details: {line!r}")

    return fields[0], int(fields[1]) * 512

def ensure_athena(serial):

    props = " ".join(shell(serial, f"getprop {p}") for p in

                    ("ro.product.device", "ro.build.product", "ro.product.vendor.device", "ro.product.board"))

    compatible = shell(serial, "cat /proc/device-tree/compatible 2>/dev/null | tr '\\0' ' '")

    if "athena" not in props.split() and "amzn,athena" not in compatible.split():

        raise InstallError(f"device does not identify as Athena (props={props!r}, compatible={compatible!r})")

    if not shell(serial, "id").startswith("uid=0"):

        raise InstallError("adb shell in recovery is not root")

def mounts(serial, dev):

    return [line.split()[1] for line in shell(serial, "awk '{print $1, $2}' /proc/mounts").splitlines()

            if line.split() and line.split()[0] == dev]

def read_partition(serial, dev, size):

    data = remote_file(serial, f"dd if={dev} bs=1048576 2>/dev/null")

    if len(data) != size:

        raise InstallError(f"read of {dev} returned {len(data)} bytes; expected {size}")

    remote_hash = shell(serial, f"sha256sum {dev}").split()[0]

    if sha256(data) != remote_hash:

        raise InstallError(f"read of {dev} failed SHA256 verification")

    return data

def backup(serial, dev, size, path):

    os.makedirs(os.path.dirname(path), exist_ok=True)

    with open(path + ".partial", "wb") as f:

        p = subprocess.run(["adb", "-s", serial, "exec-out", f"dd if={dev} bs=1048576 2>/dev/null"],

                           stdout=f, stderr=subprocess.PIPE)

    if p.returncode:

        raise InstallError(f"backup of {dev} failed: {p.stderr.decode(errors='replace').strip()}")

    if os.path.getsize(path + ".partial") != size:

        raise InstallError(f"backup of {dev}: read {os.path.getsize(path + '.partial')} bytes, expected {size}")

    remote_hash = shell(serial, f"sha256sum {dev}").split()[0]

    got = local_hash(path + ".partial")

    if got != remote_hash:

        raise InstallError(f"backup of {dev} failed SHA256 read-back check")

    os.replace(path + ".partial", path)

    with open(path + ".sha256", "w") as f:

        f.write(f"{got}  {os.path.basename(path)}\n")

def write_image(serial, mmc, number, name, image):

    dev = f"/dev/block/{mmc}p{number}"

    size = os.path.getsize(image)

    actual_name, capacity = partition_info(serial, mmc, number)

    if actual_name != name or actual_name in ("userdata", "recovery", "vendor", "tee1", "tee1_real", "lk", "lk_real"):

        raise InstallError(f"refusing to write {dev}: partition is named {actual_name!r}, expected {name!r}")

    if size > capacity:

        raise InstallError(f"{image} ({size} bytes) exceeds {dev} capacity ({capacity} bytes)")

    for mount in mounts(serial, dev):

        shell(serial, "umount " + shlex.quote(mount))

    if mounts(serial, dev):

        raise InstallError(f"{dev} remains mounted; unmount it in TWRP and retry")

    block_size = int(shell(serial, f"cat /sys/class/block/{mmc}/queue/logical_block_size"))

    if block_size <= 0:

        raise InstallError(f"could not determine the logical block size for {dev}")

    if size % block_size:

        raise InstallError(f"{image} size is not aligned to the {block_size}-byte logical block size")

    expected = local_hash(image)

    print(f"Streaming {os.path.basename(image)} ({size >> 20} MiB) to {dev}; this can take several minutes...")

    chunk_size = 4 << 20

    if chunk_size % block_size:

        raise InstallError(f"{chunk_size}-byte transfer chunks are not aligned to {block_size}-byte blocks")

    total = (size + chunk_size - 1) // chunk_size

    remote = f"/tmp/athena-install-{os.getpid()}.chunk"

    try:

        with open(image, "rb") as src:

            for index in range(total):

                offset = index * chunk_size

                block = src.read(min(chunk_size, size - offset))

                if not block or len(block) % block_size:

                    raise InstallError(f"could not read an aligned chunk from {image} at byte {offset}")

                chunk_hash = sha256(block)

                with tempfile.NamedTemporaryFile(prefix="athena-install-") as staged:

                    staged.write(block)

                    staged.flush()

                    adb(serial, "push", staged.name, remote)

                remote_hash = shell(serial, f"sha256sum {remote}").split()[0]

                if remote_hash != chunk_hash:

                    raise InstallError(f"adb transfer hash mismatch for {name} chunk {index + 1}/{total}")

                start_block = offset // block_size

                block_count = len(block) // block_size

                shell(serial, f"dd if={remote} of={dev} bs={block_size} seek={start_block} count={block_count} "

                             "2>/dev/null && sync")

                got = shell(serial, f"sync; echo 3 > /proc/sys/vm/drop_caches; "

                                    f"dd if={dev} bs={block_size} skip={start_block} count={block_count} "

                                    f"2>/dev/null | sha256sum").split()[0]

                if got != chunk_hash:

                    raise InstallError(f"{dev} chunk {index + 1}/{total} read-back mismatch; do not reboot")

                if (index + 1) % 16 == 0 or index + 1 == total:

                    print(f"Verified {name} write chunk {index + 1}/{total}")

    finally:

        adb(serial, "shell", f"rm -f {remote}", check=False)

    got = shell(serial, f"sync; echo 3 > /proc/sys/vm/drop_caches; head -c {size} {dev} | sha256sum").split()[0]

    if got != expected:

        raise InstallError(f"{dev} read-back hash mismatch: expected {expected}, got {got}; do not reboot")

    print(f"Verified {dev}: SHA256 {got}")

def main():

    p = argparse.ArgumentParser(description=__doc__)

    p.add_argument("--boot", required=True, help="locally built boot-athena.img")

    p.add_argument("--stock-boot", help="Fire OS boot partition image, if the saved boot backup is not stock")

    p.add_argument("--out-boot", help="where to write the tuned boot image (default: beside the kernel image)")

    p.add_argument("--image", required=True, help="locally built Debian arm64 system.img")

    p.add_argument("--serial", help="adb serial shown by adb devices; auto-select if one recovery device is connected")

    p.add_argument("--backups", default="backups", help="directory for verified boot/system backups (default: ./backups)")

    p.add_argument("--dry-run", action="store_true", help="check device and images without backing up or writing")

    p.add_argument("--yes", action="store_true", help="skip the final write confirmation")

    a = p.parse_args()

    for path in (a.boot, a.image):

        if not os.path.isfile(path):

            raise InstallError(f"file not found: {path}")

    boot = read_boot(a.boot)

    check_empty_slot(boot, a.boot)

    if a.stock_boot and not os.path.isfile(a.stock_boot):

        raise InstallError(f"stock boot image not found: {a.stock_boot}")

    read_ext4(a.image)

    devices = adb_devices()

    serial = a.serial

    if not serial:

        if len(devices) != 1:

            raise InstallError(f"expected one adb recovery device, found {devices}; pass --serial")

        serial = devices[0]

    if serial not in devices:

        raise InstallError(f"{serial} is not listed by `adb devices` in recovery state")

    ensure_athena(serial)

    mmc = find_emmc(serial)

    boot_name, boot_capacity = partition_info(serial, mmc, 20)

    system_name, system_capacity = partition_info(serial, mmc, 21)

    if (boot_name, system_name) != ("boot", "system"):

        raise InstallError(f"unexpected layout: p20={boot_name!r}, p21={system_name!r}; nothing written")

    if os.path.getsize(a.boot) > boot_capacity or os.path.getsize(a.image) > system_capacity:

        raise InstallError("one or both images exceed the target partition size")

    print(f"Athena {serial} in TWRP; targets: boot={mmc}p20 ({boot_capacity >> 20} MiB), "

          f"system={mmc}p21 ({system_capacity >> 20} MiB)")

    print(f"Kernel image: {a.boot} SHA256 {local_hash(a.boot)}")

    print(f"Debian image: {a.image} SHA256 {local_hash(a.image)}")

    if a.dry_run:

        stock_boot = open(a.stock_boot, "rb").read() if a.stock_boot else read_partition(

            serial, f"/dev/block/{mmc}p20", boot_capacity)

        live_compatible = _strings(remote_file(serial, "cat /proc/device-tree/compatible 2>/dev/null"))

        extract_amp_tuning(stock_boot, live_compatible)

        print("Dry run complete; no device data was changed.")

        return

    backup_dir = os.path.join(a.backups, serial)

    if not a.yes:

        answer = input(f"Type INSTALL to back up boot/system, replace both partitions, and reboot {serial}: ")

        if answer != "INSTALL":

            print("Cancelled; no device data was changed.")

            return

    for number, name, size in ((20, "boot", boot_capacity), (21, "system", system_capacity)):

        path = os.path.join(backup_dir, f"p{number}-{name}.img")

        if os.path.exists(path):

            sidecar = path + ".sha256"

            if not os.path.exists(sidecar) or os.path.getsize(path) != size:

                raise InstallError(f"existing backup {path} is incomplete; move it aside before continuing")

            expected = open(sidecar, encoding="ascii").read().split()[0]

            if local_hash(path) != expected:

                raise InstallError(f"existing backup {path} does not match its SHA256 file")

            print(f"Keeping verified backup: {path}")

        else:

            print(f"Backing up {name} partition to {path}...")

            backup(serial, f"/dev/block/{mmc}p{number}", size, path)

    stock_path = a.stock_boot or os.path.join(backup_dir, "p20-boot.img")

    with open(stock_path, "rb") as f:

        stock_boot = f.read()

    live_compatible = _strings(remote_file(serial, "cat /proc/device-tree/compatible 2>/dev/null"))

    table = extract_amp_tuning(stock_boot, live_compatible)

    tuned_boot = fill_amp_slot(boot, table)

    output_boot = os.path.abspath(a.out_boot) if a.out_boot else os.path.join(

        os.path.dirname(os.path.abspath(a.boot)), "boot-athena-tuned.img")

    if output_boot == os.path.abspath(a.boot):

        raise InstallError("--out-boot must differ from --boot so the original build artifact stays untouched")

    os.makedirs(os.path.dirname(output_boot), exist_ok=True)

    with open(output_boot + ".partial", "wb") as f:

        f.write(tuned_boot)

    os.replace(output_boot + ".partial", output_boot)

    print(f"Wrote tuned boot image: {output_boot} (SHA256 {sha256(tuned_boot)})")

    write_image(serial, mmc, 20, "boot", output_boot)

    write_image(serial, mmc, 21, "system", a.image)

    print("Both partitions verified. Rebooting into Debian arm64...")

    adb(serial, "reboot")

if __name__ == "__main__":

    try:

        main()

    except InstallError as e:

        print(f"ERROR: {e}", file=sys.stderr)

        sys.exit(1)
