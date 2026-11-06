import struct
import unittest

import pack


class PackTests(unittest.TestCase):
    def test_image_layout_and_header_digest(self):
        kernel = b"kernel-data"
        dtb = b"device-tree"
        ramdisk = b"firmware-ramdisk"
        image = pack.pack(kernel, dtb, ramdisk)

        fields = struct.unpack_from("<8s10I16s512s32s1024sIQI", image)
        self.assertEqual(fields[0], pack.BOOT_MAGIC)
        self.assertEqual(fields[1], len(kernel) + len(dtb))
        self.assertEqual(fields[3], len(ramdisk))
        self.assertEqual(
            image[pack.PAGE_SIZE : pack.PAGE_SIZE + len(kernel) + len(dtb)],
            kernel + dtb,
        )
        self.assertEqual(
            fields[13], pack.image_id(kernel + dtb, ramdisk).ljust(32, b"\0")
        )
        self.assertLessEqual(len(image), pack.BOOT_PARTITION_SIZE)

    def test_page_padding(self):
        self.assertEqual(pack.pad(pack.PAGE_SIZE), pack.PAGE_SIZE)
        self.assertEqual(pack.pad(pack.PAGE_SIZE + 1), pack.PAGE_SIZE * 2)

    def test_rejects_boot_image_larger_than_partition(self):
        with self.assertRaises(SystemExit):
            pack.pack(bytes(pack.BOOT_PARTITION_SIZE), b"", b"")


if __name__ == "__main__":
    unittest.main()
