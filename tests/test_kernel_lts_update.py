import unittest

from ci.update_kernel_lts import (
    checksum_for,
    latest_lts_release,
    update_pins,
    version_key,
)


class KernelLtsUpdateTests(unittest.TestCase):
    def test_selects_latest_active_lts_not_newest_stable(self):
        releases = [
            {"moniker": "stable", "version": "7.3.3", "iseol": False},
            {"moniker": "longterm", "version": "6.12.116", "iseol": False},
            {"moniker": "longterm", "version": "6.18.62", "iseol": False},
            {"moniker": "longterm", "version": "6.19.2", "iseol": True},
        ]
        self.assertEqual(latest_lts_release(releases), "6.18.62")

    def test_version_order_is_numeric(self):
        self.assertGreater(version_key("6.18.10"), version_key("6.18.9"))

    def test_finds_exact_checksum_entry(self):
        checksum = "a" * 64
        sums = f"{checksum}  linux-6.18.62.tar.xz\n"
        self.assertEqual(checksum_for(sums, "linux-6.18.62.tar.xz"), checksum)
        with self.assertRaisesRegex(ValueError, "found 0"):
            checksum_for(sums, "linux-6.18.63.tar.xz")

    def test_updates_only_kernel_version_and_checksum_pins(self):
        old = "b" * 64
        new = "c" * 64
        script = f"KVER=6.18.56\nKURL=https://cdn.kernel.org/linux-$KVER.tar.xz\nKSHA256={old}\n"
        updated, current, changed = update_pins(script, "6.18.62", new)
        self.assertEqual(current, "6.18.56")
        self.assertTrue(changed)
        self.assertIn("KVER=6.18.62", updated)
        self.assertIn(f"KSHA256={new}", updated)
        self.assertIn("linux-$KVER.tar.xz", updated)

    def test_does_not_downgrade_or_rewrite_same_version(self):
        checksum = "b" * 64
        script = f"KVER=6.18.62\nKSHA256={checksum}\n"
        updated, current, changed = update_pins(script, "6.18.61", "c" * 64)
        self.assertEqual(updated, script)
        self.assertEqual(current, "6.18.62")
        self.assertFalse(changed)


if __name__ == "__main__":
    unittest.main()
