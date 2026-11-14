# SPDX-License-Identifier: GPL-3.0-only
"""Portable tests only. These do NOT test iOS, App Groups, entitlements or display effects."""
import ctypes
import fcntl
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

KIT = Path(__file__).resolve().parents[1]
WORK = KIT / ".test-work"
WORK.mkdir(exist_ok=True)
spec = importlib.util.spec_from_file_location("patch", KIT / "apply_patch.py")
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)
NAME = "com.apple.iokit.IOMobileGraphicsFamily.plist"


class AtomicFileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.library = WORK / "libgxcanvas.so"
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
                        str(KIT / "overlay/GXCanvasAtomic.c"), "-o", str(cls.library)], check=True)
        cls.lib = ctypes.CDLL(str(cls.library))
        cls.lib.gxcl_atomic_replace.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p,
            ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
        cls.lib.gxcl_atomic_replace.restype = ctypes.c_int

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=WORK)
        self.directory = Path(self.temp.name)
        self.path = self.directory / NAME
        self.before = plistlib.dumps({"canvas_width": 1170, "canvas_height": 2532, "unrelated": {"keep": True}}, fmt=plistlib.FMT_BINARY)
        edited = plistlib.loads(self.before)
        edited["canvas_width"], edited["canvas_height"] = 1206, 2622
        self.after = plistlib.dumps(edited, fmt=plistlib.FMT_BINARY)
        self.path.write_bytes(self.before)
        self.path.chmod(0o644)
        self.dirfd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
        self.fd = os.open(self.path, os.O_RDWR)

    def tearDown(self):
        os.close(self.fd)
        os.close(self.dirfd)
        self.temp.cleanup()

    def replace(self, before=None, after=None):
        before = self.before if before is None else before
        after = self.after if after is None else after
        a, b = ctypes.create_string_buffer(before), ctypes.create_string_buffer(after)
        message = ctypes.create_string_buffer(1024)
        result = self.lib.gxcl_atomic_replace(self.dirfd, self.fd, a, len(before), b, len(after), message, len(message))
        return result, message.value.decode()

    def test_replace_and_preserve_unrelated_plist_values(self):
        result, message = self.replace()
        self.assertEqual(result, 0, message)
        self.assertEqual(self.path.read_bytes(), self.after)
        parsed = plistlib.loads(self.path.read_bytes())
        self.assertEqual(parsed["unrelated"], {"keep": True})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o644)
        self.assertEqual(list(self.directory.glob(".gestaltx-canvas-*")), [])

    def test_mismatched_snapshot_leaves_original(self):
        result, _ = self.replace(before=b"wrong snapshot")
        self.assertEqual(result, -1)
        self.assertEqual(self.path.read_bytes(), self.before)

    def test_symlink_refused(self):
        real = self.directory / "real.plist"
        self.path.rename(real)
        self.path.symlink_to(real.name)
        result, _ = self.replace()
        self.assertEqual(result, -1)
        self.assertTrue(self.path.is_symlink())
        self.assertEqual(real.read_bytes(), self.before)

    def test_hardlink_refused(self):
        os.link(self.path, self.directory / "second-link")
        result, _ = self.replace()
        self.assertEqual(result, -1)
        self.assertEqual(self.path.read_bytes(), self.before)

    def test_group_writable_file_refused(self):
        self.path.chmod(0o666)
        result, _ = self.replace()
        self.assertEqual(result, -1)
        self.assertEqual(self.path.read_bytes(), self.before)

    def test_empty_replacement_refused(self):
        self.assertEqual(self.replace(after=b"")[0], -1)
        self.assertEqual(self.path.read_bytes(), self.before)

    def test_oversized_replacement_refused(self):
        self.assertEqual(self.replace(after=b"x" * (4 * 1024 * 1024 + 1))[0], -1)
        self.assertEqual(self.path.read_bytes(), self.before)

    def test_swapped_inode_refused_even_with_same_bytes(self):
        other = self.directory / "replacement"
        other.write_bytes(self.before)
        other.chmod(0o644)
        os.replace(other, self.path)
        self.assertEqual(self.replace()[0], -1)
        self.assertEqual(self.path.read_bytes(), self.before)

    def test_missing_target_is_not_created(self):
        self.path.unlink()
        self.assertEqual(self.replace()[0], -1)
        self.assertFalse(self.path.exists())

    def test_existing_temporary_file_is_not_overwritten(self):
        other = self.directory / f".gestaltx-canvas-{os.getpid()}-0.tmp"
        other.write_bytes(b"do not overwrite")
        self.assertEqual(self.replace()[0], 0)
        self.assertEqual(other.read_bytes(), b"do not overwrite")

    def test_byte_exact_restore_using_same_primitive(self):
        self.assertEqual(self.replace()[0], 0)
        os.close(self.fd)
        self.fd = os.open(self.path, os.O_RDWR)
        result, _ = self.replace(before=self.after, after=self.before)
        self.assertEqual(result, 0)
        self.assertEqual(self.path.read_bytes(), self.before)

    def test_special_permission_bits_refused(self):
        self.path.chmod(0o4644)
        self.assertEqual(self.replace()[0], -1)
        self.assertEqual(self.path.read_bytes(), self.before)

    def test_original_content_changed_after_open_refused(self):
        changed = self.before[:-1] + bytes([self.before[-1] ^ 1])
        self.path.write_bytes(changed)
        self.assertEqual(self.replace()[0], -1)
        self.assertEqual(self.path.read_bytes(), changed)

    def test_all_temporary_names_busy_refused_without_deleting_them(self):
        for index in range(128):
            (self.directory / f".gestaltx-canvas-{os.getpid()}-{index}.tmp").write_bytes(b"keep")
        self.assertEqual(self.replace()[0], -1)
        self.assertEqual(self.path.read_bytes(), self.before)
        self.assertEqual(len(list(self.directory.glob(".gestaltx-canvas-*"))), 128)

    def test_competing_advisory_lock_refused(self):
        other = os.open(self.path, os.O_RDWR)
        try:
            fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.replace()[0], -1)
            self.assertEqual(self.path.read_bytes(), self.before)
        finally:
            fcntl.flock(other, fcntl.LOCK_UN)
            os.close(other)

    def test_null_input_refused(self):
        message = ctypes.create_string_buffer(1024)
        after = ctypes.create_string_buffer(self.after)
        result = self.lib.gxcl_atomic_replace(self.dirfd, self.fd, None, 1, after, len(self.after), message, len(message))
        self.assertEqual(result, -1)
        self.assertEqual(self.path.read_bytes(), self.before)

    def test_non_directory_descriptor_refused(self):
        previous = self.dirfd
        self.dirfd = self.fd
        try:
            self.assertEqual(self.replace()[0], -1)
            self.assertEqual(self.path.read_bytes(), self.before)
        finally:
            self.dirfd = previous


class PatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=WORK)
        self.root = Path(self.temp.name)
        (self.root / "GestaltX").mkdir()
        (self.root / "GestaltX.xcodeproj").mkdir()
        (self.root / "GestaltX/GestaltXApp.swift").write_text(patch.EXPECTED_MAIN)
        (self.root / "GestaltX/GestaltX-Bridging-Header.h").write_text('#include "worse_query.h"\n#import "GXCustomizationAccess.h"\n')
        (self.root / "GestaltX.xcodeproj/project.pbxproj").write_text("PBXFileSystemSynchronizedRootGroup; path = GestaltX;")

    def tearDown(self):
        self.temp.cleanup()

    def test_apply_and_idempotent_repeat(self):
        patch.apply(self.root)
        main = self.root / "GestaltX/GestaltXApp.swift"
        self.assertIn("GXCanvasLabView()", main.read_text())
        self.assertEqual((self.root / ".canvaslab-original/GestaltXApp.swift").read_text(), patch.EXPECTED_MAIN)
        first = main.read_bytes()
        patch.apply(self.root)
        self.assertEqual(first, main.read_bytes())
        for filename in patch.FILES:
            self.assertEqual((self.root / "GestaltX/CanvasLab" / filename).read_bytes(), (KIT / "overlay" / filename).read_bytes())

    def test_dry_run_does_not_modify(self):
        patch.apply(self.root, dry_run=True)
        self.assertFalse((self.root / "GestaltX/CanvasLab").exists())
        self.assertEqual((self.root / "GestaltX/GestaltXApp.swift").read_text(), patch.EXPECTED_MAIN)

    def test_unreviewed_version_refused(self):
        main = self.root / "GestaltX/GestaltXApp.swift"
        main.write_text(main.read_text() + "// different version\n")
        before = main.read_bytes()
        with self.assertRaises(ValueError):
            patch.apply(self.root)
        self.assertEqual(main.read_bytes(), before)
        self.assertFalse((self.root / "GestaltX/CanvasLab").exists())

    def test_existing_destination_refused(self):
        (self.root / "GestaltX/CanvasLab").mkdir()
        with self.assertRaises(ValueError):
            patch.apply(self.root)
        self.assertFalse((self.root / ".canvaslab-original").exists())

    def test_additional_terminal_newline_allowed(self):
        main = self.root / "GestaltX/GestaltXApp.swift"
        main.write_text(patch.EXPECTED_MAIN + "\n")
        patch.apply(self.root)
        self.assertIn("GXCanvasLabView()", main.read_text())

    def test_symlink_entry_point_refused(self):
        main = self.root / "GestaltX/GestaltXApp.swift"
        target = self.root / "original.swift"
        main.rename(target)
        main.symlink_to(target)
        with self.assertRaises(ValueError):
            patch.apply(self.root)
        self.assertEqual(target.read_text(), patch.EXPECTED_MAIN)

    def test_partially_applied_patch_refused(self):
        patch.apply(self.root)
        (self.root / "GestaltX/CanvasLab/GXCanvasLab.m").unlink()
        with self.assertRaises(ValueError):
            patch.apply(self.root)


if __name__ == "__main__":
    unittest.main(verbosity=2)
