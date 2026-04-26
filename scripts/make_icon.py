#!/usr/bin/env python3
"""Generate a 1024x1024 PNG icon for Simple Video: film strip + play button.
Pure stdlib — writes a valid PNG with no external dependencies.
"""
import math, struct, zlib, array, sys

W = H = 1024
RADIUS = 200
BG_TOP = (88, 86, 214)
BG_BOT = (255, 45, 85)
WHITE  = (255, 255, 255)
DARK   = (28, 28, 30)

def rounded_alpha(x, y):
    r = RADIUS
    cx = max(r, min(W - r, x))
    cy = max(r, min(H - r, y))
    d = math.hypot(x - cx, y - cy)
    if d <= r - 1: return 255
    if d >= r + 1: return 0
    return int(round(255 * (r + 1 - d) / 2))

def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))

def blend(base, over, alpha):
    a = alpha / 255.0
    return tuple(int(round(base[i] * (1 - a) + over[i] * a)) for i in range(3))

def in_circle(x, y, cx, cy, r):
    d = math.hypot(x - cx, y - cy)
    if d <= r - 1: return 255
    if d >= r + 1: return 0
    return int(round(255 * (r + 1 - d) / 2))

def in_triangle(x, y, cx, cy, size):
    h = size
    p1 = (cx - h * 0.45, cy - h * 0.55)
    p2 = (cx - h * 0.45, cy + h * 0.55)
    p3 = (cx + h * 0.65, cy)
    def sign(a, b, c):
        return (a[0] - c[0]) * (b[1] - c[1]) - (b[0] - c[0]) * (a[1] - c[1])
    d1 = sign((x, y), p1, p2)
    d2 = sign((x, y), p2, p3)
    d3 = sign((x, y), p3, p1)
    has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return 255 if not (has_neg and has_pos) else 0

def film_strip_alpha(x, y):
    strip_h = 150
    in_top_strip = y < strip_h
    in_bot_strip = y > H - strip_h
    if not (in_top_strip or in_bot_strip):
        return 0
    spacing = 145
    start = 90
    cy = strip_h // 2 if in_top_strip else H - strip_h // 2
    col = round((x - start) / spacing)
    cx = start + col * spacing
    if cx < 60 or cx > W - 60: return 0
    return in_circle(x, y, cx, cy, 38)

print("Rendering 1024x1024 icon (this takes ~10s)...", file=sys.stderr)
px = array.array('B', [0] * (W * H * 4))
play_cx, play_cy = W // 2 + 30, H // 2
play_size = 280
play_bg_r = 290

for y in range(H):
    for x in range(W):
        t = y / H
        bg = lerp(BG_TOP, BG_BOT, t)
        color = bg
        circ_a = in_circle(x, y, play_cx, play_cy, play_bg_r)
        if circ_a:
            color = blend(color, WHITE, circ_a)
        tri_a = in_triangle(x, y, play_cx, play_cy, play_size)
        if tri_a:
            inside = in_circle(x, y, play_cx, play_cy, play_bg_r - 10)
            if inside:
                color = blend(color, DARK, min(tri_a, inside))
        strip_h = 150
        in_strip = (y < strip_h) or (y > H - strip_h)
        if in_strip:
            color = blend(color, DARK, 230)
            hole_a = film_strip_alpha(x, y)
            if hole_a:
                color = blend(color, bg, hole_a)
        ra = rounded_alpha(x, y)
        i = (y * W + x) * 4
        px[i]   = color[0]
        px[i+1] = color[1]
        px[i+2] = color[2]
        px[i+3] = ra

def png_chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)

sig = b'\x89PNG\r\n\x1a\n'
ihdr = struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0)
raw = b''
for y in range(H):
    raw += b'\x00' + px[y*W*4:(y+1)*W*4].tobytes()
idat = zlib.compress(raw, 9)
out = sig + png_chunk(b'IHDR', ihdr) + png_chunk(b'IDAT', idat) + png_chunk(b'IEND', b'')

out_path = sys.argv[1] if len(sys.argv) > 1 else "icon.png"
open(out_path, 'wb').write(out)
print(f"✓ Wrote {out_path} ({len(out):,} bytes)", file=sys.stderr)
