import unittest

import dsp_slot


class DspSlotTests(unittest.TestCase):
    def test_empty_slot_round_trip(self):
        slot = dsp_slot.make_slot()
        self.assertEqual(len(slot), dsp_slot.SLOT_SIZE)
        self.assertEqual(dsp_slot.parse_slot(slot), b"")

    def test_data_slot_round_trip(self):
        data = bytes(range(64))
        self.assertEqual(dsp_slot.parse_slot(dsp_slot.make_slot(data)), data)

    def test_rejects_odd_or_oversized_data(self):
        with self.assertRaises(ValueError):
            dsp_slot.make_slot(b"x")
        with self.assertRaises(ValueError):
            dsp_slot.make_slot(bytes(dsp_slot.MAX_DATA + 2))

    def test_rejects_corrupted_hash_and_padding(self):
        slot = bytearray(dsp_slot.make_slot(b"ab"))
        slot[12] ^= 1
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            dsp_slot.parse_slot(slot)
        slot = bytearray(dsp_slot.make_slot(b"ab"))
        slot[-1] = 1
        with self.assertRaisesRegex(ValueError, "padding"):
            dsp_slot.parse_slot(slot)

    def test_finds_only_one_complete_slot(self):
        slot = dsp_slot.make_slot()
        self.assertEqual(dsp_slot.find_slot(b"prefix" + slot + b"suffix"), (6, slot))
        with self.assertRaisesRegex(ValueError, "exactly once"):
            dsp_slot.find_slot(slot + slot)
        with self.assertRaisesRegex(ValueError, "past the end"):
            dsp_slot.find_slot(dsp_slot.MAGIC)


if __name__ == "__main__":
    unittest.main()
