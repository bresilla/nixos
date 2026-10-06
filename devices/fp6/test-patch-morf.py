import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("patch_morf", Path(__file__).with_name("patch-morf.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PatchTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.source = root / "cached"
        self.output = root / "repaired"
        (self.source / "bin").mkdir(parents=True)
        self.before = b"the affected embedded shader"
        self.after = b"corrected shader"
        self.binary = self.source / "bin/.morf-wrapped"
        self.contents = b"\x7fELF\0prefix\0" + self.before + b"\0suffix"
        self.binary.write_bytes(self.contents)
        self.binary.chmod(0o555)
        self.launcher = self.source / "bin/morf"
        self.launcher.write_text(f'#!/bin/sh\nexec "{self.binary}" "$@"\n')
        self.launcher.chmod(0o555)

    def patch(self):
        module.patch_package(self.source, self.output, self.before, self.after)

    def test_layout_source_and_launcher_are_preserved(self):
        self.patch()
        result = (self.output / "bin/.morf-wrapped").read_bytes()
        self.assertEqual(len(result), len(self.contents))
        start = self.contents.index(self.before)
        self.assertEqual(result[:start], self.contents[:start])
        self.assertEqual(result[start + len(self.before):], self.contents[start + len(self.before):])
        self.assertEqual(result[start:start + len(self.before)], self.after.ljust(len(self.before), b" "))
        self.assertEqual(self.binary.read_bytes(), self.contents)
        self.assertEqual(self.binary.stat().st_mode & 0o777, 0o555)
        self.assertIn(str(self.output / "bin/.morf-wrapped"), (self.output / "bin/morf").read_text())
        self.assertIn(str(self.binary), self.launcher.read_text())

    def test_new_cached_binary_passes_through_unchanged(self):
        self.binary.chmod(0o755)
        self.binary.write_bytes(b"\x7fELF\0new renderer")
        self.patch()
        self.assertTrue(self.output.is_symlink())
        self.assertEqual(self.output.resolve(), self.source)

    def test_duplicate_shader_is_rejected_before_copying(self):
        self.binary.chmod(0o755)
        self.binary.write_bytes(self.contents + self.before)
        with self.assertRaises(ValueError):
            self.patch()
        self.assertFalse(self.output.exists())

    def test_unexpected_launcher_is_rejected_before_copying(self):
        self.launcher.chmod(0o755)
        self.launcher.write_text("#!/bin/sh\nexec something-else\n")
        with self.assertRaises(ValueError):
            self.patch()
        self.assertFalse(self.output.exists())

    def test_oversized_replacement_is_rejected(self):
        self.after = b"X" * (len(self.before) + 1)
        with self.assertRaises(ValueError):
            self.patch()
        self.assertFalse(self.output.exists())

    def test_symlink_cannot_modify_an_external_binary(self):
        target = self.source / "external"
        self.binary.rename(target)
        self.binary.symlink_to(target)
        with self.assertRaises(ValueError):
            self.patch()
        self.assertEqual(target.read_bytes(), self.contents)


if __name__ == "__main__":
    unittest.main()
