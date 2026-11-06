#!/usr/bin/env python3
"""Guard tests for the flash pack installers (config/flashpack/*.sh).

Assembles a synthetic pack in a tmpdir - fake images, real manifest - and proves the
behaviour that protects a board: dry runs plan without writing, the destructive rungs
refuse until the consent word is given, and a corrupt pack is stopped at the manifest.
Nothing here touches a device; `fastboot` is a stub binary.

    python3 -m unittest discover -s tests -v
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FLASH = ROOT / "config" / "flashpack" / "flash.sh"
RESTORE = ROOT / "config" / "flashpack" / "restore.sh"
TEMPLATE = ROOT / "config" / "flashpack" / "INSTALL.md.in"
BUILDER = ROOT / "scripts" / "80-build-flashpack.sh"

PACK_ENV = """\
PACK_NAME="testpack"
PACK_BOARD_TAG="UFI001C"
PACK_KERNEL="6.12.1-msm8916"
PACK_ALPINE="3.24"
PACK_DEFAULT_DTB="dtbs/ufi001c.dtb"
PACK_ROOT_PARTUUID="a7ab80e8-e9d1-e8cd-f157-93f69b1d141e"
PACK_BUILT="2026-11-06T00:00:00Z"
PACK_BUILT_BY="test"
PACK_HAS_RESTORE="yes"
PACK_SERIAL=""
"""

IMAGES = [
    "rootfs/alpine-rootfs.img",
    "bootloader/aboot.mbn",
    "bootloader/hyp.mbn",
    "boot/boot-mainline.img",
    "adbd-payload/adbd",
    "restore/part-aboot.bin",
    "restore/part-hyp.bin",
    "restore/part-sbl1.bin",
    "restore/part-rpm.bin",
    "restore/part-tz.bin",
    "restore/boot-stock.bin",
]


class FlashPackTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.pack = Path(self._tmp.name)
        for rel in IMAGES:
            p = self.pack / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b"synthetic-" + rel.encode())
        for name, src in (("flash.sh", FLASH), ("restore.sh", RESTORE)):
            (self.pack / name).write_bytes(src.read_bytes())
            os.chmod(self.pack / name, 0o755)
        (self.pack / "pack.env").write_text(PACK_ENV)
        # `devices` printing nothing is the honest stub: any test that reaches the
        # device is expected to fail there, not silently flash nothing.
        stub = Path(self._tmp.name) / "fastboot"
        stub.write_text("#!/bin/sh\nexit 0\n")
        os.chmod(stub, 0o755)
        self.stub = stub
        self._manifest()

    def tearDown(self):
        self._tmp.cleanup()

    def _manifest(self):
        files = sorted(
            p for p in self.pack.rglob("*")
            if p.is_file() and p.name not in ("MANIFEST.sha256", "pack.env", "fastboot")
        )
        out = subprocess.run(
            ["sha256sum"] + [str(p) for p in files],
            capture_output=True, text=True, check=True, cwd=self.pack,
        )
        # sha256sum prints absolute paths when given them; the manifest is relative.
        (self.pack / "MANIFEST.sha256").write_text(
            out.stdout.replace(str(self.pack) + "/", "")
        )

    def run_sh(self, script, env=None, extra_env=None):
        e = dict(os.environ, FASTBOOT=str(self.stub))
        if extra_env:
            e.update(extra_env)
        e.pop("COMMIT", None)
        e.pop("I_WIPE_ROOTFS", None)
        e.pop("I_RESTORE_FACTORY", None)
        e.pop("SERIAL", None)
        e.update(env or {})
        return subprocess.run([str(self.pack / script)], capture_output=True,
                              text=True, cwd=self.pack, env=e, timeout=60)

    # ------------------------------------------------------------------ flash.sh
    def test_flash_dry_run(self):
        r = self.run_sh("flash.sh")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("DRY RUN", r.stdout)
        for token in ("rootfs", "aboot", "boot", "MANIFEST.sha256"):
            self.assertIn(token, r.stdout)

    def test_flash_commit_without_consent_refuses_before_device(self):
        r = self.run_sh("flash.sh", env={"COMMIT": "1"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("I_WIPE_ROOTFS", r.stderr + r.stdout)
        # The guard must fire with NO board present: "no board in fastboot" means the
        # consent check ran after the device probe, which is the ordering this fixes.
        self.assertNotIn("no board in fastboot", r.stderr + r.stdout)

    def test_flash_only_boot_without_consent_is_allowed_past_guard(self):
        # --only boot skips the rootfs rung, so no I_WIPE_ROOTFS is needed; it should
        # get all the way to the (stubbed, empty) fastboot device probe instead.
        r2 = subprocess.run(
            [str(self.pack / "flash.sh"), "--only", "boot"],
            capture_output=True, text=True, cwd=self.pack, timeout=60,
            env=dict(os.environ, FASTBOOT=str(self.stub), COMMIT="1"),
        )
        self.assertNotEqual(r2.returncode, 0)
        self.assertIn("no board in fastboot", r2.stderr + r2.stdout)

    def test_flash_refuses_corrupt_pack(self):
        (self.pack / "boot" / "boot-mainline.img").write_bytes(b"tampered")
        r = self.run_sh("flash.sh")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("manifest verification FAILED", r.stderr + r.stdout)

    def test_flash_refuses_missing_manifest(self):
        (self.pack / "MANIFEST.sha256").unlink()
        r = self.run_sh("flash.sh")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("MANIFEST", r.stderr + r.stdout)

    def test_flash_rejects_bad_argument(self):
        r = subprocess.run(
            [str(self.pack / "flash.sh"), "--wipe-all"],
            capture_output=True, text=True, cwd=self.pack, timeout=60,
            env=dict(os.environ, FASTBOOT=str(self.stub)),
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("unknown argument", r.stderr + r.stdout)

    # ---------------------------------------------------------------- restore.sh
    def test_restore_dry_run_lists_six_partitions(self):
        r = self.run_sh("restore.sh")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("DRY RUN", r.stdout)
        for part in ("aboot", "hyp", "sbl1", "rpm", "tz", "boot"):
            self.assertIn(f"fastboot flash {part}", r.stdout)

    def test_restore_refuses_incomplete_restore_dir(self):
        (self.pack / "restore" / "part-tz.bin").unlink()
        r = self.run_sh("restore.sh")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("restore/ is incomplete", r.stderr + r.stdout)
        self.assertIn("MISSING", r.stdout)

    def test_restore_commit_without_consent_refuses(self):
        r = self.run_sh("restore.sh", env={"COMMIT": "1"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("I_RESTORE_FACTORY", r.stderr + r.stdout)

    # -------------------------------------------------------------- templates
    def test_install_template_tokens_all_substituted(self):
        import re
        tokens = set(re.findall(r"@([A-Z_]+)@", TEMPLATE.read_text()))
        sed = BUILDER.read_text()
        missing = [t for t in tokens if f"|@{t}@|" not in sed]
        self.assertEqual(missing, [], f"INSTALL.md.in tokens with no sed rule in 80: {missing}")

    # ------------------------------------------------------- nat-share picks the interface
    def test_nat_share_masquerades_the_interface_not_the_gateway(self):
        """`default via X dev Y` - Y is the outgoing interface, X is not.

        iptables happily accepts `-o 192.168.24.1`. The rule is installed, the counters stay
        at zero and the client just has no internet - measured on a MacBook behind a UFI001C,
        where the first version of uplink() returned field 3 of `ip -4 route show default`.
        """
        import shutil
        tmp = Path(self._tmp.name) / "nat"
        bindir = tmp / "bin"
        bindir.mkdir(parents=True)
        (tmp / "sys").mkdir()
        (tmp / "sys" / "usb0").mkdir()
        stubs = {
            "ip": '#!/bin/sh\n'
                  'case "$*" in\n'
                  '  *route*) echo "default via 192.168.24.1 dev wlan0 proto dhcp src 192.168.24.162 metric 600";;\n'
                  '  *) echo "3: usb0    inet 192.168.5.1/24 scope global usb0";;\n'
                  'esac\n',
            "iptables": '#!/bin/sh\nif [ "$1" = "-t" ]; then echo "$@" >> "$IPTLOG"; fi\nexit 0\n',
            "sysctl": '#!/bin/sh\nexit 0\n',
            "pidof": '#!/bin/sh\nexit 1\n',
        }
        for name, body in stubs.items():
            p = bindir / name
            p.write_text(body)
            os.chmod(p, 0o755)
        log = tmp / "iptables.log"
        env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", IPTLOG=str(log),
                   DNS_DIR=str(tmp / "dns"), LOG=str(tmp / "nat.log"),
                   GADGET_NET="192.168.5.0/24", GADGET_GW="192.168.5.1")
        # /sys/class/net is read by gadget_iface(), which a test cannot create; the name
        # fallback (usb0/ncm0/ecm0) is what this stub exercises, and it is the same one the
        # vendor-kernel and mainline paths differ across.
        r = subprocess.run(["sh", str(ROOT / "config" / "alpine-gadget" / "nat-share.sh"), "apply"],
                           capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        rules = log.read_text() if log.exists() else ""
        self.assertIn("-o wlan0", rules, f"MASQUERADE did not use the interface:\n{rules}")
        self.assertNotIn("-o 192.168.24.1", rules, "NAT rule was keyed on the GATEWAY - matches nothing")

    def test_pack_scripts_parse(self):
        for f in (FLASH, RESTORE, BUILDER):
            r = subprocess.run(["bash", "-n", str(f)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, f"{f}: {r.stderr}")

    # ------------------------------------------------------- timeout cannot exec a function
    def test_no_timeout_wrapping_a_shell_function(self):
        """`timeout N name ...` where name is a shell function is a silent no-op.

        timeout execs a real program, so this fails ("No such file or directory") on stderr,
        and in a `| grep -E 'OKAY|FAILED'` pipeline - with no pipefail, as these scripts are -
        the failure is invisible and the exit status is grep's 0. Two scripts in this repo did
        that to every fastboot call, so a rung that wrote 896 MB reported doing nothing at all
        and a board was rebooted believing it had been flashed. The fix is an argv array
        (`FB_CMD=( ... )`), which is also what scripts/lib.sh's `fb`/`FB` does.
        """
        import re
        files = sorted({p for g in ("scripts/*.sh", "scripts/device/*.sh", "config/*.sh",
                                    "config/*/*.sh", "config/*/*/*.sh")
                        for p in ROOT.glob(g)})
        self.assertTrue(files, "the glob found no shell scripts, so this test proves nothing")
        defines = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)', re.M)
        uses = re.compile(r'\btimeout\s+[0-9]+(?:\.[0-9]+)?[a-z]*\s+([A-Za-z_][A-Za-z0-9_]*)\b')
        bad = []
        for f in files:
            text = f.read_text()
            funcs = set(defines.findall(text))
            if not funcs:
                continue
            for no, line in enumerate(text.splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue                      # the fix is documented in comments, in this form
                m = uses.search(line)
                if m and m.group(1) in funcs:
                    bad.append(f"{f.relative_to(ROOT)}:{no}: timeout {m.group(1)} ... "
                               f"({m.group(1)} is a function here)")
        self.assertEqual(bad, [], "timeout cannot exec these shell functions:\n  " +
                         "\n  ".join(bad))


if __name__ == "__main__":
    unittest.main()
