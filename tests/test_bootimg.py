#!/usr/bin/env python3
"""Round-trip tests for tools/bootimg.py against a synthetic boot image.

Built to mirror what was measured on the stick (header v0, page_size 2048, kernel
payload with an appended FDT, separate ramdisk) so the parser is proven before it is
ever pointed at the only copy of a working boot partition.

    python3 -m unittest discover -s tests -v
"""
import json
import re
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools" / "bootimg.py"
PAGE = 2048


def mkdtb(total_len: int = 2048, fill: bytes = b"\x00") -> bytes:
    """A byte string that starts with a valid FDT magic and claims total_len."""
    head = struct.pack(">II", 0xD00DFEED, total_len)
    body = (fill * ((total_len - len(head)) // len(fill) + 1))[:total_len - len(head)]
    return head + body


def build(kernel_payload: bytes, ramdisk: bytes, cmdline: str) -> bytes:
    hdr = bytearray(PAGE)
    hdr[0:8] = b"ANDROID!"
    struct.pack_into("<10I", hdr, 8,
                     len(kernel_payload), 0x80080000,   # kernel size / addr
                     len(ramdisk), 0x82000000,          # ramdisk size / addr
                     0, 0x80f00000,                     # second size / addr
                     0x81e00000, PAGE,                  # tags_addr, page_size
                     0, 0)                              # dtb_size field, os_version
    hdr[48:64] = b"bianyi-tag".ljust(16, b"\x00")
    hdr[64:576] = cmdline.encode().ljust(512, b"\x00")
    pad = lambda b: b.ljust(((len(b) + PAGE - 1) // PAGE) * PAGE, b"\x00")  # noqa: E731
    return bytes(hdr) + pad(kernel_payload) + pad(ramdisk)


class BootimgTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        self.dtb = mkdtb(2048)
        self.kernel_only = b"K" * 9000
        self.ramdisk = b"R" * 500
        self.stock = self.d / "boot-stock.bin"
        self.stock.write_bytes(build(self.kernel_only + self.dtb, self.ramdisk,
                                     "earlycon root=PARTUUID=deadbeef console=ttyMSM0 rw"))

    def run_tool(self, *args, expect_ok=True):
        r = subprocess.run([sys.executable, str(TOOL), *[str(a) for a in args]],
                           capture_output=True, text=True)
        if expect_ok:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def field(self, out, name):
        m = re.search(rf"^{name}\s+(\S.*)$", out, re.M)
        self.assertIsNotNone(m, f"{name} missing from:\n{out}")
        return m.group(1).strip()

    def test_info_reports_the_measured_header(self):
        out = self.run_tool("info", self.stock).stdout
        self.assertEqual(int(self.field(out, "kernel_size")), len(self.kernel_only) + len(self.dtb))
        self.assertEqual(int(self.field(out, "ramdisk_size")), len(self.ramdisk))
        self.assertEqual(int(self.field(out, "page_size")), PAGE)
        self.assertEqual(self.field(out, "name"), "bianyi-tag")
        self.assertIn("root=PARTUUID=deadbeef", self.field(out, "cmdline"))
        self.assertIn("FDT @ kernel+9000", out)

    def test_unpack_splits_the_appended_dtb(self):
        target = self.d / "unpacked"
        out = self.run_tool("unpack", self.stock, target).stdout
        self.assertIn("payload=9000 bytes, dtb=2048 bytes", out)
        self.assertEqual((target / "dtb0.dtb").read_bytes(), self.dtb)
        self.assertEqual((target / "kernel-only.gz").read_bytes(), self.kernel_only)
        self.assertEqual((target / "ramdisk.img").read_bytes(), self.ramdisk)
        self.assertIn("root=PARTUUID=deadbeef", (target / "cmdline.txt").read_text())
        meta = json.loads((target / "header.json").read_text())
        self.assertEqual(meta["kernel_size"], len(self.kernel_only) + len(self.dtb))
        self.assertEqual(meta["ramdisk_size"], len(self.ramdisk))

    def test_repack_swaps_the_dtb_and_fixes_sizes(self):
        new_dtb = mkdtb(2048, b"\x11")
        (self.d / "new.dtb").write_bytes(new_dtb)
        bare = self.d / "Image.gz"
        bare.write_bytes(b"J" * 4000)
        out = self.d / "boot-new.bin"
        self.run_tool("repack", "--template", self.stock, "--kernel", bare,
                      "--dtb", self.d / "new.dtb", "-o", out)
        info = self.run_tool("info", out).stdout
        self.assertEqual(int(self.field(info, "kernel_size")), 4000 + len(new_dtb))
        # cmdline must be inherited verbatim - this is what keeps root=PARTUUID alive
        self.assertIn("root=PARTUUID=deadbeef", self.field(info, "cmdline"))
        self.assertEqual(int(self.field(info, "ramdisk_size")), len(self.ramdisk))
        u2 = self.d / "u2"
        self.run_tool("unpack", out, u2)
        self.assertEqual((u2 / "dtb0.dtb").read_bytes(), new_dtb)
        self.assertEqual((u2 / "kernel-only.gz").read_bytes(), b"J" * 4000)

    def test_repack_drops_a_stale_dtb_before_appending(self):
        # a kernel payload that already has a DTB must not end up with two
        (self.d / "k-with-dtb.gz").write_bytes(self.kernel_only + self.dtb)
        (self.d / "new.dtb").write_bytes(mkdtb(2048, b"\x22"))
        out = self.d / "boot-swap.bin"
        self.run_tool("repack", "--template", self.stock, "--kernel", self.d / "k-with-dtb.gz",
                      "--dtb", self.d / "new.dtb", "-o", out)
        info = self.run_tool("info", out).stdout
        self.assertEqual(int(self.field(info, "kernel_size")), 9000 + 2048)
        self.assertEqual(self.field(info, "cmdline"),
                         self.field(self.run_tool("info", self.stock).stdout, "cmdline"))

    def test_cmdline_override(self):
        bare = self.d / "Image.gz"
        bare.write_bytes(self.kernel_only + self.dtb)
        out = self.d / "boot-cmd.bin"
        self.run_tool("repack", "--template", self.stock, "--kernel", bare,
                      "--cmdline", "root=/dev/mmcblk0p14 console=ttyMSM0,115200", "-o", out)
        self.assertIn("root=/dev/mmcblk0p14",
                      self.field(self.run_tool("info", out).stdout, "cmdline"))

    def test_oversized_image_is_refused(self):
        big = self.d / "huge.gz"
        big.write_bytes(b"Z" * (65 * 1024 * 1024))
        r = self.run_tool("repack", "--template", self.stock, "--kernel", big,
                          "-o", self.d / "x.bin", expect_ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("exceeds the 64 MiB boot partition", r.stderr + r.stdout)

    def test_non_boot_image_is_rejected(self):
        junk = self.d / "junk.bin"
        junk.write_bytes(b"\x00" * 4096)
        r = self.run_tool("info", junk, expect_ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not an Android boot image", r.stderr + r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
