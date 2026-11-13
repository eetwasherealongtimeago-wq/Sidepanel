#!/usr/bin/env python3
"""Renders SidePanel's app icon and writes Packaging/AppIcon.icns (+ a PNG preview).

The mark: a graphite squircle "screen" with a luminous mint→cyan panel resting on
its right edge. Inside the panel, a prompt chevron; on the screen, a faint orbit.
Requires Pillow. Run from the repository root:  python3 scripts/generate_icon.py
"""
import io
import math
import struct
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 1024          # master size
SS = 2            # supersampling factor
W = S * SS

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def squircle_mask(size, rect, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(rect, radius=radius, fill=255)
    return m

def vertical_gradient(size, top, bottom):
    g = Image.new("RGBA", (1, size))
    for y in range(size):
        g.putpixel((0, y), lerp(top, bottom, y / (size - 1)))
    return g.resize((size, size))

def diagonal_gradient(w, h, c1, c2):
    g = Image.new("RGBA", (w, h))
    px = g.load()
    for y in range(h):
        for x in range(w):
            t = (x / w * 0.35 + y / h * 0.65)
            px[x, y] = lerp(c1, c2, t)
    return g

def render():
    canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))

    # Body: macOS icon grid leaves ~10% margin around the squircle.
    m = int(W * 0.098)
    body_rect = (m, m, W - m, W - m)
    radius = int((W - 2 * m) * 0.225)

    # Drop shadow
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((m, m + int(W * 0.018), W - m, W - m + int(W * 0.018)),
                                             radius=radius, fill=(0, 0, 0, 150))
    shadow = shadow.filter(ImageFilter.GaussianBlur(W * 0.022))
    canvas.alpha_composite(shadow)

    body = vertical_gradient(W, (34, 38, 49, 255), (11, 12, 16, 255))
    canvas.paste(body, (0, 0), squircle_mask(W, body_rect, radius))

    # Faint orbit on the "screen" area (the browser half of the idea).
    orbit = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    od = ImageDraw.Draw(orbit)
    cx, cy = int(W * 0.37), int(W * 0.50)
    r = int(W * 0.13)
    od.ellipse((cx - r, cy - r, cx + r, cy + r), outline=(154, 140, 255, 150), width=int(W * 0.014))
    ring = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse((cx - int(r * 2.0), cy - int(r * 0.55), cx + int(r * 2.0), cy + int(r * 0.55)),
                                 outline=(154, 140, 255, 110), width=int(W * 0.011))
    ring = ring.rotate(18, center=(cx, cy), resample=Image.BICUBIC)
    orbit.alpha_composite(ring)
    canvas.alpha_composite(orbit)

    # The panel: a tall luminous slab against the right edge.
    px0, py0 = int(W * 0.585), int(W * 0.215)
    px1, py1 = int(W * 0.805), int(W * 0.785)
    prad = int(W * 0.062)
    glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle((px0, py0, px1, py1), radius=prad, fill=(110, 242, 194, 170))
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.045))
    canvas.alpha_composite(glow)

    slab = diagonal_gradient(px1 - px0, py1 - py0, (124, 247, 204, 255), (78, 196, 240, 255))
    slab_mask = Image.new("L", slab.size, 0)
    ImageDraw.Draw(slab_mask).rounded_rectangle((0, 0, slab.size[0] - 1, slab.size[1] - 1), radius=prad, fill=255)
    canvas.paste(slab, (px0, py0), slab_mask)

    # Prompt glyph on the panel.
    gd = ImageDraw.Draw(canvas)
    lw = int(W * 0.03)
    ink = (10, 22, 26, 235)
    gx, gy = int(W * 0.645), int(W * 0.445)
    ch = int(W * 0.055)
    gd.line([(gx, gy - ch), (gx + int(ch * 0.95), gy), (gx, gy + ch)], fill=ink, width=lw, joint="curve")
    for (x, y) in [(gx, gy - ch), (gx + int(ch * 0.95), gy), (gx, gy + ch)]:
        gd.ellipse((x - lw // 2, y - lw // 2, x + lw // 2, y + lw // 2), fill=ink)
    ux0, uy = int(W * 0.64), int(W * 0.60)
    gd.rounded_rectangle((ux0, uy - lw // 2, ux0 + int(W * 0.11), uy + lw // 2), radius=lw // 2, fill=ink)

    # Top highlight on the body.
    hl = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(hl).rounded_rectangle(body_rect, radius=radius, outline=(255, 255, 255, 46), width=int(W * 0.004))
    fade = vertical_gradient(W, (255, 255, 255, 255), (255, 255, 255, 0))
    hl.putalpha(ImageChops.multiply(hl.getchannel("A"), fade.getchannel("A")))
    canvas.alpha_composite(hl)

    return canvas.resize((S, S), Image.LANCZOS)

def png_bytes(img, size):
    buf = io.BytesIO()
    img.resize((size, size), Image.LANCZOS).save(buf, format="PNG", optimize=True)
    return buf.getvalue()

def write_icns(img, path):
    # PNG-encoded ICNS entries (supported since macOS 10.7).
    entries = [
        (b"icp4", 16), (b"icp5", 32), (b"icp6", 64),
        (b"ic07", 128), (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024),
        (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
    ]
    chunks = b""
    for tag, size in entries:
        data = png_bytes(img, size)
        chunks += tag + struct.pack(">I", len(data) + 8) + data
    path.write_bytes(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)

if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    icon = render()
    out = root / "Packaging"
    out.mkdir(exist_ok=True)
    icon.save(out / "AppIcon-1024.png")
    write_icns(icon, out / "AppIcon.icns")
    print("wrote", out / "AppIcon.icns")
