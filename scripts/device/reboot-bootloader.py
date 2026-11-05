#!/usr/bin/env python3
"""Reboot into fastboot from Linux, on a board with no adb and no `misc` partition.

    reboot-bootloader.py [reason]        # reason defaults to "bootloader"

Why this exists: once the rootfs is musl there is no adb (the vendor `adbd` is a glibc binary),
and this GPT has no `misc` partition, so the Android "write boot-fastboot into misc" route is
unavailable. The physical EDL button is the only other door, and it needs hands on the board.

What `adb reboot bootloader` actually does is reboot(2) with LINUX_REBOOT_CMD_RESTART2 and the
string "bootloader". The Qualcomm restart handler records that reason and the bootloader
honours it. That this board honours it is measured, not assumed: it is exactly how fastboot was
first entered here, from the vendor Debian running this same 5.15 kernel.

If the reason is NOT honoured the machine simply reboots normally - which makes this the
zero-risk way to try for fastboot, unlike deliberately corrupting the boot partition.
"""
import ctypes
import sys

MAGIC1 = 0xFEE1DEAD
MAGIC2 = 672274793  # LINUX_REBOOT_MAGIC2
LINUX_REBOOT_CMD_RESTART2 = 0xA1B2C3D4
SYS_REBOOT = 142  # arm64 / asm-generic


def main() -> int:
    reason = (sys.argv[1] if len(sys.argv) > 1 else "bootloader").encode() + b"\0"
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    libc.syscall.restype = ctypes.c_long
    libc.syscall.argtypes = [
        ctypes.c_long,
        ctypes.c_uint,
        ctypes.c_uint,
        ctypes.c_uint,
        ctypes.c_char_p,
    ]
    libc.sync()
    rc = libc.syscall(SYS_REBOOT, MAGIC1, MAGIC2, LINUX_REBOOT_CMD_RESTART2, reason)
    if rc != 0:
        err = ctypes.get_errno()
        print(f"reboot(2) RESTART2 failed, errno={err}", file=sys.stderr)
        return 1
    # Unreachable when it works: the kernel does not return from RESTART2.
    print(f"reboot(2) RESTART2 '{reason[:-1].decode()}' returned {rc} - reason not honoured?")
    return 0


if __name__ == "__main__":
    sys.exit(main())
