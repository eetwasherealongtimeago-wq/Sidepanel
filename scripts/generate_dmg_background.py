#!/usr/bin/env python3
"""Renders the installer window background for the DMG (1x and 2x PNGs).

Layout (660x440 points): the app icon sits at (170, 170), the Applications
shortcut at (490, 170) — scripts/make_dmg.sh places them there.
Requires Pillow and the Inter font (falls back to DejaVu Sans).
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 660, 440
APP_X, LINK_X, ICON_Y = 170, 490, 170

FONT_DIRS = ["/usr/share/fonts/opentype/inter", "/Library/Fonts", str(Path.home() / "Library/Fonts")]

def font(weight, size):
    names = {"bold": ["Inter-Bold.otf", "Inter-SemiBold.otf"], "medium": ["Inter-Medium.otf"], "regular": ["Inter-Regular.otf"]}[weight]
    for d in FONT_DIRS:
        for n in names:
            p = Path(d) / n
            if p.exists():
                return ImageFont.truetype(str(p), size)
    fallback = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if weight == "bold" else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    return ImageFont.truetype(fallback, size)

def render(scale):
    w, h = W * scale, H * scale
    s = lambda v: int(v * scale)
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / h
        for x in range(w):
            u = x / w
            r = int(20 - 8 * t + 4 * u)
            g = int(23 - 9 * t + 3 * u)
            b = int(31 - 11 * t + 6 * u)
            px[x, y] = (r, g, b)

    # Soft accent glows.
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((s(-120), s(-160), s(300), s(200)), fill=(110, 242, 194, 34))
    gd.ellipse((s(420), s(260), s(820), s(600)), fill=(154, 140, 255, 30))
    glow = glow.filter(ImageFilter.GaussianBlur(s(60)))
    img = Image.alpha_composite(img.convert("RGBA"), glow)
    d = ImageDraw.Draw(img)

    # Title
    d.text((w // 2, s(46)), "Install SidePanel", font=font("bold", s(22)), fill=(233, 235, 241), anchor="mm")
    d.text((w // 2, s(72)), "Drag the app onto the Applications folder", font=font("regular", s(13)), fill=(144, 151, 168), anchor="mm")

    # Arrow between the two icon slots.
    ax0, ax1, ay = s(APP_X + 78), s(LINK_X - 78), s(ICON_Y)
    for i in range(ax0, ax1 - s(14), s(12)):
        d.rounded_rectangle((i, ay - s(2), i + s(6), ay + s(2)), radius=s(2), fill=(110, 242, 194))
    d.polygon([(ax1, ay), (ax1 - s(16), ay - s(10)), (ax1 - s(16), ay + s(10))], fill=(110, 242, 194))

    # First-launch steps card.
    card = (s(36), s(276), w - s(36), h - s(24))
    d.rounded_rectangle(card, radius=s(14), fill=(10, 11, 15, 255), outline=(44, 48, 60), width=max(1, s(1)))
    d.text((card[0] + s(18), card[1] + s(16)), "FIRST LAUNCH", font=font("bold", s(10)), fill=(93, 100, 118))
    steps = [
        ("1", "Open SidePanel from Applications. If macOS says it can’t verify it, click Done."),
        ("2", "Open System Settings  ›  Privacy & Security, scroll down, click Open Anyway."),
        ("3", "Press  ⌥ Space  any time to show or hide the panel."),
    ]
    y = card[1] + s(40)
    for num, text in steps:
        cx, cy = card[0] + s(28), y + s(9)
        d.ellipse((cx - s(10), cy - s(10), cx + s(10), cy + s(10)), fill=(110, 242, 194))
        d.text((cx, cy), num, font=font("bold", s(11)), fill=(10, 22, 26), anchor="mm")
        d.text((card[0] + s(48), y + s(1)), text, font=font("medium", s(12)), fill=(214, 218, 228))
        y += s(30)
    return img.convert("RGB")

if __name__ == "__main__":
    out = Path(__file__).resolve().parent.parent / "Packaging"
    render(1).save(out / "dmg-background.png")
    render(2).save(out / "dmg-background@2x.png")
    print("wrote", out / "dmg-background.png")
