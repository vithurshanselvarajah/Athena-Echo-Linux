import importlib.util
import os
import pathlib
import struct
import tempfile
import unittest

import dsp_slot


INSTALLER_PATH = pathlib.Path(__file__).parents[1] / "install-athena.py"
INSTALLER_SPEC = importlib.util.spec_from_file_location(
    "install_athena", INSTALLER_PATH
)
installer = importlib.util.module_from_spec(INSTALLER_SPEC)
INSTALLER_SPEC.loader.exec_module(installer)


def make_boot(slot=None):
    page = 2048
    kernel = bytearray(page * 5)

    if slot is not None:
        kernel[128 : 128 + len(slot)] = slot

    image = bytearray(page + len(kernel))
    image[:8] = b"ANDROID!"
    struct.pack_into("<9I", image, 8, len(kernel), 0, 0, 0, 0, 0, 0, page, 0)
    image[page:] = kernel
    image[576:608] = installer.BootImage(bytes(image), "test boot").image_id()

    return bytes(image)


class InstallAmpSlotTests(unittest.TestCase):
    def test_install_targets_accept_legacy_and_merged_system_sizes(self):
        boot_capacity = 16 * 1024 * 1024
        boot_size = boot_capacity
        image_size = 1536 * 1024 * 1024

        for system_capacity in (3_254_779_904, 7_281_294_848):
            with self.subTest(system_capacity=system_capacity):
                installer.validate_install_targets(
                    "boot",
                    boot_capacity,
                    "system",
                    system_capacity,
                    boot_size,
                    image_size,
                )

    def test_install_targets_reject_image_larger_than_legacy_system(self):
        with self.assertRaisesRegex(installer.InstallError, "exceed the target"):
            installer.validate_install_targets(
                "boot", 16 * 1024 * 1024, "system", 3_000_000_000,
                16 * 1024 * 1024, 3_100_000_000
            )

    def test_archives_stale_backup_and_sidecar_without_overwriting(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "p21-system.img")
            with open(path, "wb") as backup:
                backup.write(b"old system image")
            with open(path + ".sha256", "w", encoding="ascii") as sidecar:
                sidecar.write("old checksum")

            with open(path + ".stale-1", "wb") as previous:
                previous.write(b"earlier archive")

            archived = installer.archive_stale_backup(path)

            self.assertEqual(archived, path + ".stale-2")
            self.assertFalse(os.path.exists(path))
            with open(archived, "rb") as backup:
                self.assertEqual(backup.read(), b"old system image")
            with open(archived + ".sha256", encoding="ascii") as sidecar:
                self.assertEqual(sidecar.read(), "old checksum")

    def test_extracts_valid_embedded_tuning(self):
        tuning = b"\x01\x02\x03\x04"
        boot = make_boot(dsp_slot.make_slot(tuning))

        self.assertEqual(
            installer.extract_embedded_amp_tuning(boot, "test boot"), tuning
        )

    def test_returns_none_without_slot(self):
        self.assertIsNone(
            installer.extract_embedded_amp_tuning(make_boot(), "test boot")
        )

    def test_returns_none_for_valid_empty_slot(self):
        boot = make_boot(dsp_slot.make_slot())

        self.assertIsNone(
            installer.extract_embedded_amp_tuning(boot, "test boot")
        )

    def test_rejects_tuning_with_bad_hash(self):
        slot = bytearray(dsp_slot.make_slot(b"\x01\x02"))
        slot[44] ^= 1
        boot = make_boot(slot)

        with self.assertRaisesRegex(installer.InstallError, "SHA-256"):
            installer.extract_embedded_amp_tuning(boot, "test boot")


if __name__ == "__main__":
    unittest.main()