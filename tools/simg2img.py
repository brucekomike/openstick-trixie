#!/usr/bin/env python3
"""Convert an Android sparse image to raw, without android-sdk-libsparse-utils.

    tools/simg2img.py IN.simg OUT.raw

Needed because the community OpenStick release ships boot.bin / alpine_rootfs.bin as
sparse images, and inspecting one (debugfs, or comparing it against a partition dump)
requires the raw form. `fastboot` can flash sparse images directly, so this is only
for reading them on the host.

Format: 28-byte file header (magic 0xed26ff3a), then chunks with a 12-byte header:
  0xCAC1 raw, 0xCAC2 fill (one block repeated), 0xCAC3 dontcare (zeros), 0xCAC4 crc32.
"""
import struct
import sys

MAGIC = 0xED26FF3A
RAW, FILL, DONTCARE, CRC32 = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        magic, major, minor, fh_sz, ch_sz, blk_sz, total_blks, total_chunks, _csum = struct.unpack(
            "<IHHHHIIII", fi.read(28)
        )
        if magic != MAGIC:
            print(f"not a sparse image (magic 0x{magic:08x})", file=sys.stderr)
            return 1
        fi.seek(fh_sz)
        print(
            f"v{major}.{minor} blk_sz={blk_sz} total_blks={total_blks} "
            f"({total_blks * blk_sz:,} B) chunks={total_chunks}",
            file=sys.stderr,
        )
        written = 0
        for n in range(total_chunks):
            ctype, _res, chunk_blks, total_sz = struct.unpack("<HHII", fi.read(ch_sz))
            data_sz = total_sz - ch_sz
            if ctype == RAW:
                buf = fi.read(data_sz)
                fo.write(buf)
                written += len(buf)
            elif ctype == FILL:
                fill = fi.read(4)
                block = fill * (blk_sz // len(fill))
                for _ in range(chunk_blks):
                    fo.write(block)
                written += chunk_blks * blk_sz
            elif ctype == DONTCARE:
                if data_sz:
                    fi.read(data_sz)
                fo.write(b"\0" * (chunk_blks * blk_sz))
                written += chunk_blks * blk_sz
            elif ctype == CRC32:
                fi.read(data_sz)
            else:
                print(f"chunk {n}: unknown type 0x{ctype:04x}", file=sys.stderr)
                return 1
        print(f"wrote {written:,} B to {dst}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
