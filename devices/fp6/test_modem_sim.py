"""Card discovery must not mix an application's AID with another slot."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("modem_sim", Path(__file__).with_name("modem-sim.py"))
modem = importlib.util.module_from_spec(spec)
spec.loader.exec_module(modem)

EMPTY = """Primary GW:   session doesn't exist
Slot [1]:
  Card state: 'absent'
"""
SECOND = EMPTY + """Slot [2]:
  Card state: 'present'
  Application [1]:
    Application type:  'isim (5)'
    Application ID:
      A0:01:01
  Application [2]:
    Application type:  'usim (2)'
    Application ID:
      A0:02:02
"""


class CardSelection(unittest.TestCase):
    def test_empty_slots(self):
        self.assertIsNone(modem.select_application(EMPTY))

    def test_second_slot_usim(self):
        self.assertEqual(modem.select_application(SECOND), (2, "A0:02:02"))

    def test_existing_session_is_preserved(self):
        self.assertIsNone(modem.select_application(
            SECOND.replace("session doesn't exist", "slot '2', application '2'")))

    def test_missing_aid_is_not_guessed(self):
        self.assertIsNone(modem.select_application(SECOND.replace("A0:02:02", "")))


if __name__ == "__main__":
    unittest.main()
