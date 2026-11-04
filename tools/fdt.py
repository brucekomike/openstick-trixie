#!/usr/bin/env python3
"""Minimal Flattened Device Tree reader: dump a .dtb as a node/property listing.

No device-tree-compiler needed, because this host has no `dtc`. Used to compare the stock
DTB extracted from the stick's boot partition against the community .dts files, so a claim
like "UFI001C is supported by thwc-ufi001c.dtb" can be checked against this board instead of
assumed from a table.

    python3 tools/fdt.py dump out/bootimg/dtb0.dtb [compat,status,model]
    python3 tools/fdt.py prop out/bootimg/dtb0.dtb /__aliases__
    python3 tools/fdt.py find out/bootimg/dtb0.dtb sdhc
"""
from __future__ import annotations

import struct
import sys

FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9
MAGIC = 0xD00DFEED


class Fdt:
    def __init__(self, blob: bytes):
        if len(blob) < 40:
            sys.exit("blob too small to be an FDT")
        magic, totalsize, off_struct, off_strings, _rsv, version, _last, size_strings, nameoff = \
            struct.unpack_from(">9I", blob, 0)
        if magic != MAGIC:
            sys.exit(f"not an FDT (magic {magic:#x})")
        if version < 16:
            print(f"# warning: FDT version {version} < 16", file=sys.stderr)
        if totalsize > len(blob):
            print(f"# warning: totalsize {totalsize} > blob {len(blob)} (truncated?)",
                  file=sys.stderr)
        self.struct = blob[off_struct:off_strings]
        self.strings = blob[off_strings:off_strings + size_strings]
        self.nameoff = nameoff

    def str(self, off: int) -> str:
        end = self.strings.find(b"\x00", off)
        if end < 0:
            end = len(self.strings)
        return self.strings[off:end].decode("utf-8", "replace")

    def walk(self):
        """Linear pass: yield (depth, node_name, props) for every node."""
        data = self.struct
        p = 0
        stack: list[tuple[str, dict]] = []
        n = len(data)
        while p + 4 <= n:
            token = struct.unpack_from(">I", data, p)[0]
            p += 4
            if token == FDT_NOP:
                continue
            if token == FDT_END:
                break
            if token == FDT_BEGIN_NODE:
                end = data.find(b"\x00", p)
                if end < 0:
                    sys.exit(f"unterminated node name at {p}")
                name = data[p:end].decode("utf-8", "replace")
                p = (end + 1 + 3) & ~3
                stack.append((name, {}))
            elif token == FDT_END_NODE:
                if not stack:
                    sys.exit(f"END_NODE with empty stack at {p-4}")
                name, props = stack.pop()
                yield (len(stack), name, props)
            elif token == FDT_PROP:
                if p + 8 > n:
                    sys.exit("truncated property header")
                length, nameoff = struct.unpack_from(">II", data, p)
                p += 8
                val = data[p:p + length]
                p = (p + length + 3) & ~3
                if stack:
                    stack[-1][1][self.str(nameoff)] = val
            else:
                sys.exit(f"unknown FDT token {token:#x} at offset {p-4}")
        if stack:
            print(f"# warning: {len(stack)} node(s) left unclosed", file=sys.stderr)


def fmt(val: bytes) -> str:
    if val == b"":
        return "true"
    # NUL-separated string lists (compatible, linux,procivcid, etc.) are the common case
    if b"\x00" in val:
        parts = [p.decode("utf-8", "replace") for p in val.split(b"\x00") if p]
        if parts and all(all(32 <= ord(c) < 127 for c in p) for p in parts):
            return '"' + '", "'.join(parts) + '"'
    text = val.decode("utf-8", "replace").strip("\x00")
    if text and all(32 <= ord(c) < 127 or c == "\t" for c in text):
        return '"' + text + '"'
    if len(val) % 4 == 0:
        ints = struct.unpack(f">{len(val) // 4}I", val)
        if len(ints) <= 8:
            return " ".join(f"0x{x:x}" for x in ints)
    return f"[{len(val)} bytes] " + val[:24].hex()


def lines(f: Fdt):
    for depth, name, props in f.walk():
        yield depth, name, props


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, path = sys.argv[1], sys.argv[2]
    f = Fdt(open(path, "rb").read())
    if cmd == "prop":
        want = sys.argv[3].strip("/")
        for depth, name, props in lines(f):
            if name == want or name.split("@")[0] == want:
                for k, v in props.items():
                    print(f"{k} = {fmt(v)}")
                return
        sys.exit(f"node not found: {want}")
    if cmd == "find":
        needle = sys.argv[3].lower()
        hits = 0
        for depth, name, props in lines(f):
            hay = [name, *props.keys()]
            for k in ("compatible", "model", "status", "phy-type", "label"):
                if k in props:
                    hay.append(fmt(props[k]))
            text = " ".join(hay).lower()
            if needle in text:
                hits += 1
                show = " ".join(f"{k}={fmt(props[k])}" for k in
                                ("compatible", "status", "reg") if k in props)
                print(f"{'  ' * depth}{name}  {show}")
        print(f"# {hits} match(es) for '{needle}'", file=sys.stderr)
        return
    if cmd == "nodes":
        out = list(lines(f))
        print(f"# {len(out)} nodes, max depth {max(d for d, _, _ in out)}")
        for depth, name, props in out:
            print(f"{'  ' * depth}{name}")
        return
    # dump
    show = sys.argv[3].split(",") if len(sys.argv) > 3 else ["compatible", "status", "model"]
    for depth, name, props in lines(f):
        bits = " ".join(f"{k}={fmt(props[k])}" for k in show if k in props)
        print(f"{'  ' * depth}{name}{'  ' + bits if bits else ''}")


if __name__ == "__main__":
    main()
