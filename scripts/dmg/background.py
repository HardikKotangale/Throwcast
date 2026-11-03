"""Draws the DMG window background, at 1x and 2x. Needs Pillow: python3 -m pip install pillow."""
import sys
from PIL import Image, ImageDraw, ImageFont

# Taller than its content: Finder's path and status bars, if someone has them on, take the bottom.
W, H = 640, 520
APP, APPS = (170, 200), (470, 200)  # icon centers, matching settings.py


def font(size, weight):
    f = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def draw(scale):
    s = lambda v: round(v * scale)
    im = Image.new('RGB', (s(W), s(H)))
    d = ImageDraw.Draw(im)
    # A quiet vertical wash: light enough that the icons and their names stay the focus.
    top, bottom = (250, 250, 252), (231, 237, 248)
    for y in range(s(H)):
        t = y / s(H)
        d.line((0, y, s(W), y), fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    d.text((s(W / 2), s(44)), 'Throwcast', font=font(s(22), 'Semibold'), fill=(29, 29, 31), anchor='mm')
    d.text((s(W / 2), s(70)), 'Drag Throwcast to Applications to install', font=font(s(13), 'Regular'), fill=(110, 110, 115), anchor='mm')
    # The arrow points from the app to where it goes, the one thing to do here.
    y = APP[1] - 10
    x1, x2 = APP[0] + 78, APPS[0] - 78
    blue = (10, 132, 255)
    d.line((s(x1), s(y), s(x2 - 12), s(y)), fill=blue, width=s(5))
    d.polygon([(s(x2), s(y)), (s(x2 - 18), s(y - 11)), (s(x2 - 18), s(y + 11))], fill=blue)
    d.line((s(60), s(282), s(W - 60), s(282)), fill=(214, 220, 232), width=max(1, s(1)))
    d.text((s(W / 2), s(298)), 'ALSO INSIDE', font=font(s(10), 'Semibold'), fill=(140, 140, 150), anchor='mm')
    return im


out = sys.argv[1] if len(sys.argv) > 1 else 'scripts/dmg'
draw(1).save(f'{out}/background.png')
draw(2).save(f'{out}/background@2x.png')
