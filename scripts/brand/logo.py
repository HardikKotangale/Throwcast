"""Draws the Throwcast mark: a T whose bar is a TV screen and whose stem is its stand.
Writes every size the Mac app, the TV app, the extension and the docs use. Needs Pillow.

    python3 scripts/brand/logo.py
"""
from PIL import Image, ImageDraw, ImageFilter

N = 1024
WHITE = (255, 255, 255, 255)
# The screen: 16:9, centered so the whole T sits in the middle of the icon.
SCREEN = (232, 262, 792, 577)
STEM_W, BASE_W = 84, 300


def mark(d, screen_fill):
    x1, y1, x2, y2 = SCREEN
    cx = (x1 + x2) // 2
    d.rounded_rectangle(SCREEN, 58, fill=WHITE)
    inner = (x1 + 40, y1 + 40, x2 - 40, y2 - 40)
    d.rounded_rectangle(inner, 30, fill=screen_fill)
    d.rounded_rectangle((cx - STEM_W // 2, y2 - 20, cx + STEM_W // 2, 760), 30, fill=WHITE)
    d.rounded_rectangle((cx - BASE_W // 2, 734, cx + BASE_W // 2, 782), 24, fill=WHITE)
    # The play mark sits on the screen's optical center, nudged right as triangles need.
    my = (y1 + y2) // 2
    d.polygon([(cx - 44, my - 66), (cx - 44, my + 66), (cx + 70, my)], fill=WHITE)


def icon():
    im = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    grad = Image.new('RGBA', (N, N))
    g = ImageDraw.Draw(grad)
    for y in range(N):
        t = y / N
        g.line((0, y, N, y), fill=(round(36 - 28 * t), round(140 - 82 * t), round(255 - 79 * t), 255))
    shape = Image.new('L', (N, N), 0)
    ImageDraw.Draw(shape).rounded_rectangle((100, 100, 924, 924), 186, fill=255)
    shadow = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((100, 114, 924, 938), 186, fill=(0, 0, 0, 80))
    im.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(16)))
    im.paste(grad, (0, 0), shape)
    # A screen that glows a little lighter than the tile, so it reads as lit.
    layer = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    mark(ImageDraw.Draw(layer), (60, 150, 255, 255))
    im.alpha_composite(layer)
    return im


def white_mark(w, h):
    """The TV's home row style: white on transparency, outline screen so the play mark shows."""
    im = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    mark(ImageDraw.Draw(im), (0, 0, 0, 0))
    crop = im.crop((200, 230, 824, 800))
    out = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    scale = min(w * 0.62 / crop.width, h * 0.62 / crop.height)
    crop = crop.resize((round(crop.width * scale), round(crop.height * scale)), Image.LANCZOS)
    out.alpha_composite(crop, ((w - crop.width) // 2, (h - crop.height) // 2))
    return out


big = icon()
mac = 'app/macos/Runner/Assets.xcassets/AppIcon.appiconset'
for size in (16, 32, 64, 128, 256, 512, 1024):
    big.resize((size, size), Image.LANCZOS).save(f'{mac}/app_icon_{size}.png')
for size in (16, 32, 48, 128):
    big.resize((size, size), Image.LANCZOS).save(f'extension/icons/icon{size}.png')
big.resize((256, 256), Image.LANCZOS).save('docs/icon.png')
big.resize((256, 256), Image.LANCZOS).save('tv/app/logo.png')
white_mark(512, 423).save('tv/app/icon.png')
print('done')
