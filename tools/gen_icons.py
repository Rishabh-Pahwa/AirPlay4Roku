#!/usr/bin/env python3
"""Render the channel artwork into app/images/ (original design: a phone
sending to a TV; deliberately not Apple's AirPlay or Apple TV marks).

  channel_hd.png   290x218   manifest mm_icon_focus_hd  (home-screen grid, HD)
  channel_sd.png   246x140   manifest mm_icon_focus_sd  (home-screen grid, SD)
  splash_hd.png   1280x720   manifest splash_screen_hd

Drawn at 4x and downsampled for anti-aliasing.
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "app", "images")
FONT = "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf"
SS = 4

TOP = (38, 40, 44)
BOTTOM = (6, 6, 8)
WHITE = (245, 245, 247)
ACCENT = (160, 164, 172)


def gradient(w, h):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = min(1.0, max(0.0, 0.65 * y / h + 0.35 * x / w))
            px[x, y] = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    return img


def glyph(d, cx, cy, s):
    """Phone on the left, TV on the right, signal arcs between them.
    (cx, cy) is the centre, s the overall width in pixels."""
    lw = max(2, int(s * 0.035))
    # TV
    tw, th = s * 0.56, s * 0.36
    tx0, ty0 = cx - s * 0.5 + s * 0.44, cy - th * 0.62
    d.rounded_rectangle([tx0, ty0, tx0 + tw, ty0 + th], radius=s * 0.04, outline=WHITE, width=lw)
    d.rounded_rectangle([tx0 + tw * 0.38, ty0 + th + lw * 0.6, tx0 + tw * 0.62, ty0 + th + lw * 0.6 + s * 0.035],
                        radius=s * 0.012, fill=WHITE)
    d.rounded_rectangle([tx0 + tw * 0.26, ty0 + th + s * 0.055, tx0 + tw * 0.74, ty0 + th + s * 0.075],
                        radius=s * 0.01, fill=WHITE)
    # picture on the TV: a small play triangle in the accent colour
    pcx, pcy, pr = tx0 + tw / 2, ty0 + th / 2, th * 0.2
    d.polygon([(pcx - pr * 0.7, pcy - pr), (pcx - pr * 0.7, pcy + pr), (pcx + pr * 0.95, pcy)], fill=ACCENT)
    # phone
    pw, ph = s * 0.17, s * 0.3
    px0, py0 = cx - s * 0.5, cy - ph * 0.42
    d.rounded_rectangle([px0, py0, px0 + pw, py0 + ph], radius=s * 0.03, fill=WHITE)
    d.rounded_rectangle([px0 + lw * 0.9, py0 + lw * 1.6, px0 + pw - lw * 0.9, py0 + ph - lw * 1.6],
                        radius=s * 0.012, fill=ACCENT)
    # signal arcs from the phone towards the TV
    ax, ay = px0 + pw + s * 0.015, py0 + ph * 0.45
    for k, r in enumerate((0.07, 0.12, 0.17)):
        rr = s * r
        d.arc([ax - rr, ay - rr, ax + rr, ay + rr], start=-50, end=50, fill=WHITE if k < 2 else ACCENT, width=lw)


def render(w, h, glyph_w, glyph_cy, text, text_size, text_cy):
    W, H = w * SS, h * SS
    img = gradient(W, H)
    # soft glow behind the glyph
    glow = Image.new("L", (W, H), 0)
    gd = ImageDraw.Draw(glow)
    gw = glyph_w * SS
    gd.ellipse([W / 2 - gw * 0.55, glyph_cy * SS - gw * 0.38, W / 2 + gw * 0.55, glyph_cy * SS + gw * 0.38], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(gw * 0.12))
    img = Image.composite(Image.new("RGB", (W, H), ACCENT), img, glow)
    d = ImageDraw.Draw(img)
    glyph(d, W / 2, glyph_cy * SS, gw)
    if text:
        f = ImageFont.truetype(FONT, int(text_size * SS))
        tw = d.textlength(text, font=f)
        d.text(((W - tw) / 2, text_cy * SS), text, font=f, fill=WHITE, anchor="la")
    return img.resize((w, h), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    render(290, 218, 200, 88, "AirPlay4Roku", 24, 160).save(os.path.join(OUT, "channel_hd.png"))
    render(246, 140, 150, 56, "AirPlay4Roku", 18, 102).save(os.path.join(OUT, "channel_sd.png"))
    render(1280, 720, 560, 300, "AirPlay4Roku", 64, 520).save(os.path.join(OUT, "splash_hd.png"))
    for f in sorted(os.listdir(OUT)):
        im = Image.open(os.path.join(OUT, f))
        print(f, im.size)


if __name__ == "__main__":
    main()
