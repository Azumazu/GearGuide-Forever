#!/usr/bin/env python3
"""
Draws the GearGuide logo (original artwork): a copper gear with a compass needle pointing
up-right, on the warm near-black of the addon's skin. Needs Pillow.

Outputs:
  branding/GearGuide-logo-1024.png   master
  branding/GearGuide-logo-400.png    CurseForge project avatar
  GearGuide/Media/icon.tga           64x64 in-game icon (minimap button, addon list)
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SS = 4                      # supersampling factor for smooth edges
SIZE = 1024
S = SIZE * SS
CX = CY = S / 2

BG_TOP, BG_BOTTOM = (34, 28, 23), (10, 9, 8)
COPPER_LIGHT, COPPER, COPPER_DARK = (240, 196, 150), (220, 167, 127), (150, 98, 62)
STEEL_LIGHT, STEEL_DARK = (120, 118, 116), (52, 50, 49)
GOLD = (255, 222, 160)


def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        grad.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return grad.resize((w, h))


def diagonal_gradient(size, a, b):
    """Top-left `a` to bottom-right `b`."""
    w, h = size
    small = Image.new("RGB", (64, 64))
    for y in range(64):
        for x in range(64):
            t = (x + y) / 126
            small.putpixel((x, y), tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3)))
    return small.resize((w, h), Image.BILINEAR)


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


def gear_polygon(cx, cy, r_outer, r_root, teeth, top_frac=0.42, base_frac=0.62, steps=6):
    """Points of a gear outline with trapezoid teeth."""
    pts = []
    pitch = 2 * math.pi / teeth
    for i in range(teeth):
        a = i * pitch - math.pi / 2
        half_base, half_top = pitch * base_frac / 2, pitch * top_frac / 2
        # root arc before the tooth
        start = a - pitch / 2
        for k in range(steps + 1):
            ang = start + (pitch / 2 - half_base) * k / steps
            pts.append((cx + r_root * math.cos(ang), cy + r_root * math.sin(ang)))
        for ang, r in ((a - half_base, r_root), (a - half_top, r_outer), (a + half_top, r_outer), (a + half_base, r_root)):
            pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
        for k in range(steps + 1):
            ang = a + half_base + (pitch / 2 - half_base) * k / steps
            pts.append((cx + r_root * math.cos(ang), cy + r_root * math.sin(ang)))
    return pts


def paste_fill(img, mask, fill_img):
    img.paste(fill_img, (0, 0), mask)


def draw_logo() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Background tile: rounded square, warm vertical gradient, thin copper rim.
    margin, radius = int(S * 0.03), int(S * 0.19)
    tile = rounded_mask((S - 2 * margin, S - 2 * margin), radius)
    bg = vertical_gradient((S - 2 * margin, S - 2 * margin), BG_TOP, BG_BOTTOM).convert("RGBA")
    img.paste(bg, (margin, margin), tile)
    rim = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(rim)
    d.rounded_rectangle((margin, margin, S - margin - 1, S - margin - 1), radius=radius, outline=255, width=int(S * 0.008))
    img.paste(Image.new("RGBA", (S, S), COPPER_DARK + (255,)), (0, 0), rim.point(lambda v: int(v * 0.85)))

    # Soft copper glow behind the emblem.
    glow = Image.new("L", (S, S), 0)
    r = S * 0.36
    ImageDraw.Draw(glow).ellipse((CX - r, CY - r, CX + r, CY + r), fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.07))
    img.paste(Image.new("RGBA", (S, S), COPPER + (255,)), (0, 0), glow)

    # Gear: drop shadow, copper body, dark inner well.
    r_outer, r_root, r_inner = S * 0.335, S * 0.275, S * 0.205
    gear = Image.new("L", (S, S), 0)
    gd = ImageDraw.Draw(gear)
    gd.polygon(gear_polygon(CX, CY, r_outer, r_root, teeth=10), fill=255)
    shadow = gear.filter(ImageFilter.GaussianBlur(S * 0.018))
    shadow_layer = Image.new("RGBA", (S, S), (0, 0, 0, 255))
    img.paste(shadow_layer, (int(S * 0.012), int(S * 0.02)), shadow.point(lambda v: int(v * 0.7)))
    paste_fill(img, gear, diagonal_gradient((S, S), COPPER_LIGHT, COPPER_DARK).convert("RGBA"))
    # bevel: thin highlight ring inside the gear edge
    well = Image.new("L", (S, S), 0)
    ImageDraw.Draw(well).ellipse((CX - r_inner, CY - r_inner, CX + r_inner, CY + r_inner), fill=255)
    paste_fill(img, well, vertical_gradient((S, S), (22, 18, 15), (40, 33, 27)).convert("RGBA"))
    ring = Image.new("L", (S, S), 0)
    ImageDraw.Draw(ring).ellipse((CX - r_inner, CY - r_inner, CX + r_inner, CY + r_inner), outline=255, width=int(S * 0.012))
    img.paste(Image.new("RGBA", (S, S), COPPER_DARK + (255,)), (0, 0), ring)

    # Compass needle pointing up-right (the "guide": toward the next upgrade).
    ang = math.radians(-45)
    length, width = S * 0.25, S * 0.06
    ux, uy = math.cos(ang), math.sin(ang)
    px, py = -uy, ux
    tip = (CX + ux * length, CY + uy * length)
    tail = (CX - ux * length * 0.82, CY - uy * length * 0.82)
    left = (CX + px * width, CY + py * width)
    right = (CX - px * width, CY - py * width)
    nd = ImageDraw.Draw(img)
    nd.polygon([tip, left, (CX, CY)], fill=GOLD)                 # lit facet
    nd.polygon([tip, right, (CX, CY)], fill=COPPER)              # shaded facet
    nd.polygon([tail, left, (CX, CY)], fill=STEEL_LIGHT)
    nd.polygon([tail, right, (CX, CY)], fill=STEEL_DARK)
    rivet = S * 0.028
    nd.ellipse((CX - rivet, CY - rivet, CX + rivet, CY + rivet), fill=COPPER_DARK)
    rivet2 = rivet * 0.55
    nd.ellipse((CX - rivet2, CY - rivet2, CX + rivet2, CY + rivet2), fill=COPPER_LIGHT)

    # Small four-point sparkle at the needle tip.
    sx, sy = tip[0] + ux * S * 0.035, tip[1] + uy * S * 0.035
    a, b = S * 0.045, S * 0.011
    nd.polygon([(sx, sy - a), (sx + b, sy - b), (sx + a, sy), (sx + b, sy + b),
                (sx, sy + a), (sx - b, sy + b), (sx - a, sy), (sx - b, sy - b)], fill=GOLD)

    return img.resize((SIZE, SIZE), Image.LANCZOS)


def main() -> int:
    logo = draw_logo()
    out = ROOT / "branding"
    out.mkdir(exist_ok=True)
    logo.save(out / "GearGuide-logo-1024.png")
    logo.resize((400, 400), Image.LANCZOS).save(out / "GearGuide-logo-400.png")
    media = ROOT / "GearGuide" / "Media"
    media.mkdir(exist_ok=True)
    logo.resize((64, 64), Image.LANCZOS).save(media / "icon.tga", compression=None)  # WoW: 32-bit uncompressed TGA
    logo.resize((256, 256), Image.LANCZOS).save(media / "logo.tga", compression=None)  # sidebar logo / watermark
    print("wrote branding/GearGuide-logo-1024.png, branding/GearGuide-logo-400.png, "
          "GearGuide/Media/icon.tga (64), GearGuide/Media/logo.tga (256)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
