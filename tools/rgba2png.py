"""Converts a raw RGBA dump (from an example's --dump) into a PNG, using only the standard library.

Usage: python3 -I tools/rgba2png.py <in.rgba> <out.png> [x y w h zoom]
The .rgba file starts with two little-endian u32s (width, height), followed by RGBA8 rows.
With a crop rectangle, only that region is written, scaled up `zoom` times (nearest neighbor) so
single pixels are easy to inspect.
"""

import struct
import sys
import zlib

data = open(sys.argv[1], "rb").read()
w, h = struct.unpack("<II", data[:8])
pixels = data[8:]
if len(sys.argv) > 3:
    cx, cy, cw, ch, zoom = (int(v) for v in sys.argv[3:8])
    out = bytearray()
    for y in range(ch * zoom):
        sy = cy + y // zoom
        for x in range(cw * zoom):
            sx = cx + x // zoom
            out += pixels[(sy * w + sx) * 4:(sy * w + sx) * 4 + 4]
    pixels, w, h = bytes(out), cw * zoom, ch * zoom
rows = b"".join(b"\x00" + pixels[y * w * 4:(y + 1) * w * 4] for y in range(h))

def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(rows, 9))
png += chunk(b"IEND", b"")
open(sys.argv[2], "wb").write(png)
