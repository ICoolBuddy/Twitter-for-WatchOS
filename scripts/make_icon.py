#!/usr/bin/env python3
"""Draws Perch's app icon (a round bird on a branch) as a 1024x1024 RGB PNG, stdlib only."""
import math, struct, sys, zlib

N = 1024
def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
TOP, BOT = (29, 155, 240), (10, 60, 140)
BIRD, BELLY, BEAK, EYE, BRANCH = (255, 255, 255), (220, 236, 250), (255, 176, 32), (15, 20, 30), (90, 62, 40)

def pixel(x, y):
    c = lerp(TOP, BOT, y / N)
    # branch
    if abs((y - 760) - (x - 512) * 0.12) < 26 and 120 < x < 920: c = BRANCH
    # body
    dx, dy = x - 500, y - 560
    if dx * dx / (250 ** 2) + dy * dy / (215 ** 2) <= 1:
        c = BIRD
        if (x - 540) ** 2 / 150 ** 2 + (y - 620) ** 2 / 120 ** 2 <= 1: c = BELLY
    # head
    if (x - 640) ** 2 + (y - 380) ** 2 <= 135 ** 2: c = BIRD
    # eye
    if (x - 680) ** 2 + (y - 360) ** 2 <= 22 ** 2: c = EYE
    # beak (triangle)
    if 760 <= x <= 860 and abs(y - 395) <= (860 - x) * 0.35: c = BEAK
    # tail
    if 210 <= x <= 300 and abs(y - 520 + (300 - x) * 0.9) < 45: c = BIRD
    # feet
    for fx in (470, 560):
        if abs(x - fx) < 10 and 760 <= y <= 800: c = BEAK
    return c

rows = []
for y in range(N):
    row = bytearray([0])
    for x in range(N): row += bytes(pixel(x, y))
    rows.append(bytes(row))
raw = b"".join(rows)
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
for path in sys.argv[1:]:
    open(path, "wb").write(png)
