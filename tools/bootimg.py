#!/usr/bin/env python3
"""Read/write the Android boot image ("ANDROID!") layout this stick actually uses.

The UFI103s `boot` partition holds a header-v0 boot image whose kernel blob is
`Image.gz` with the board DTB appended - which matters here because the board's
`handsome,openstick` DT is not in mainline, so the only guaranteed-correct DTB is
the one already in the stock image. This tool can therefore:

  info    dump the header fields and locate the appended FDT
  unpack  write kernel(+dtb), kernel-only, dtb, ramdisk, cmdline to a directory
  repack  rebuild a boot image from a stock template, optionally swapping in a new
          kernel / dtb / ramdisk / cmdline while keeping the vendor header quirks

Pure stdlib on purpose - no mkbootimg/device-tree-compiler needed to inspect.
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

MAGIC = b"ANDROID!"
FDT_MAGIC = 0xD00DFEED
FIELDS = [
    ("kernel_size", 8), ("kernel_addr", 12), ("ramdisk_size", 16), ("ramdisk_addr", 20),
    ("second_size", 24), ("second_addr", 28), ("tags_addr", 32), ("page_size", 36),
    ("dtb_size_or_hdr_ver", 40), ("os_version", 44),
]


def cstr(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("utf-8", "replace")


def parse(data: bytes) -> dict:
    if not data.startswith(MAGIC):
        sys.exit("not an Android boot image (no ANDROID! magic)")
    h = struct.unpack_from("<8I", data, 8)
    info = {name: val for (name, _), val in zip(FIELDS, h)}
    info["name"] = cstr(data[48:64])
    info["cmdline"] = cstr(data[64:576])
    page = info["page_size"] or 2048
    info["page_size"] = page
    info["header_size"] = page  # v0 keeps the first page for the header
    off = page
    info["kernel_offset"] = off
    off += align(info["kernel_size"], page)
    info["ramdisk_offset"] = off
    off += align(info["ramdisk_size"], page)
    info["second_offset"] = off
    off += align(info["second_size"], page)
    info["dtb_partition_offset"] = off if info["dtb_size_or_hdr_ver"] else None
    return info


def align(size: int, page: int) -> int:
    return ((size + page - 1) // page) * page if size else 0


def find_fdt(blob: bytes) -> list[tuple[int, int]]:
    """All plausible appended FDTs: (offset, totalsize)."""
    out = []
    for i in range(0, len(blob) - 8, 4):
        if blob[i:i + 4] == struct.pack(">I", FDT_MAGIC):
            total = struct.unpack(">I", blob[i + 4:i + 8])[0]
            if 1024 <= total <= len(blob) - i + 4096:
                out.append((i, total))
    return out


def cmd_info(a):
    data = Path(a.boot[0]).read_bytes()
    info = parse(data)
    for k, v in info.items():
        print(f"{k:22} {v}")
    kb = data[info["kernel_offset"]:info["kernel_offset"] + info["kernel_size"]]
    fdts = find_fdt(kb)
    if not fdts:
        print("appended FDT       none found inside kernel blob")
    for off, total in fdts:
        head = kb[off:off + total]
        model = compat = b""
        # name/compatible live in the first struct block; just grep the strings.
        strings = b" ".join(w for w in head.split(b"\x00") if 4 < len(w) < 64)
        print(f"FDT @ kernel+{off}   size={total} bytes")
        print(f"  contains: {strings[:240].decode('utf-8','replace')}")
    print(f"kernel blob size     {len(kb)}")
    rd = data[info["ramdisk_offset"]:info["ramdisk_offset"] + info["ramdisk_size"]]
    print(f"ramdisk magic        {rd[:4].hex()} (81 0c = gzip, 02 21 4c 18 = lz4, d0 0d fe ed = raw dtb)")
    print(f"total file           {len(data)} bytes; partition is 64 MiB")


def cmd_unpack(a):
    data = Path(a.boot[0]).read_bytes()
    info = parse(data)
    out = Path(a.outdir)
    out.mkdir(parents=True, exist_ok=True)
    kb = data[info["kernel_offset"]:info["kernel_offset"] + info["kernel_size"]]
    rd = data[info["ramdisk_offset"]:info["ramdisk_offset"] + info["ramdisk_size"]]
    (out / "kernel+zImage.gz").write_bytes(kb)
    (out / "ramdisk.img").write_bytes(rd)
    (out / "cmdline.txt").write_text(info["cmdline"] + "\n")
    (out / "header.json").write_text(json.dumps(info, indent=2) + "\n")
    fdts = find_fdt(kb)
    for n, (off, total) in enumerate(fdts):
        (out / f"dtb{n}.dtb").write_bytes(kb[off:off + total])
        (out / "kernel-only.gz").write_bytes(kb[:off])
        print(f"split kernel blob: payload={off} bytes, dtb={total} bytes -> dtb{n}.dtb")
    if not fdts:
        print("WARNING: no appended DTB in kernel blob - kernel-only not split")
    print(f"wrote {out}")


def cmd_repack(a):
    stock = Path(a.template).read_bytes()
    info = parse(stock)
    page = info["page_size"]
    header = bytearray(stock[:page])

    kernel = Path(a.kernel).read_bytes() if a.kernel else \
        stock[info["kernel_offset"]:info["kernel_offset"] + info["kernel_size"]]
    if a.dtb:
        # drop any DTB already appended to the kernel payload, then append the new one
        fdts = find_fdt(kernel)
        if fdts:
            kernel = kernel[:fdts[0][0]]
        dtb = Path(a.dtb).read_bytes()
        pad = (-len(kernel)) % 4  # dtb must start on a 4-byte boundary
        kernel = kernel + b"\x00" * pad + dtb
    ramdisk = Path(a.ramdisk).read_bytes() if a.ramdisk else \
        stock[info["ramdisk_offset"]:info["ramdisk_offset"] + info["ramdisk_size"]]
    cmdline = a.cmdline if a.cmdline else info["cmdline"]

    struct.pack_into("<I", header, 8, len(kernel))
    struct.pack_into("<I", header, 16, len(ramdisk))
    header[64:576] = cmdline.encode()[:512].ljust(512, b"\x00")

    out = bytearray(header[:page])
    out += kernel.ljust(align(len(kernel), page), b"\x00")
    out += ramdisk.ljust(align(len(ramdisk), page), b"\x00")
    if info["second_size"]:
        out += stock[info["second_offset"]:info["second_offset"] +
                    align(info["second_size"], page)].ljust(0)
    dest = Path(a.output)
    dest.write_bytes(bytes(out))
    print(f"repacked {dest}: kernel={len(kernel)} ramdisk={len(ramdisk)} "
          f"pages={page} size={len(out)} (boot partition limit 67108864)")
    if len(out) > 64 * 1024 * 1024:
        sys.exit("ERROR: image exceeds the 64 MiB boot partition")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("info"); a.add_argument("boot", nargs=1); a.set_defaults(f=cmd_info)
    a = sub.add_parser("unpack"); a.add_argument("boot", nargs=1); a.add_argument("outdir")
    a.set_defaults(f=cmd_unpack)
    a = sub.add_parser("repack")
    a.add_argument("--template", required=True, help="stock boot.bin to inherit header from")
    a.add_argument("--kernel", help="new kernel payload (Image.gz / Image.gz-dtb)")
    a.add_argument("--dtb", help="DTB to append to the kernel payload (replaces the stock one)")
    a.add_argument("--ramdisk", help="new ramdisk")
    a.add_argument("--cmdline", help="new cmdline (kept verbatim if omitted)")
    a.add_argument("-o", "--output", required=True)
    a.set_defaults(f=cmd_repack)
    args = p.parse_args()
    args.f(args)


if __name__ == "__main__":
    main()
