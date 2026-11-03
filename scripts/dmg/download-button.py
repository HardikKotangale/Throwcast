"""Draws the README's Download for macOS button, for GitHub's light and dark themes. Needs Pillow."""
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 2                        # drawn at 2x for Retina
W, H, PAD = 300, 72, 18      # button size in points, plus room for its shadow
R = 16


def font(size, weight):
    f = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', size * S)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def button(fill, title, detail, shadow, highlight, out):
    full = (W + PAD * 2) * S, (H + PAD * 2) * S
    im = Image.new('RGBA', full, (0, 0, 0, 0))
    box = (PAD * S, PAD * S, (PAD + W) * S, (PAD + H) * S)
    # A soft shadow lifts it off the page; a hard outline would just box it in.
    blur = Image.new('RGBA', full, (0, 0, 0, 0))
    ImageDraw.Draw(blur).rounded_rectangle((box[0], box[1] + 4 * S, box[2], box[3] + 4 * S), R * S, fill=shadow)
    im.alpha_composite(blur.filter(ImageFilter.GaussianBlur(9 * S)))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle(box, R * S, fill=fill)
    # Light catching the top edge, fading out as it goes down, so it reads as a surface, not a sticker.
    if highlight[3]:
        edge = Image.new('RGBA', full, (0, 0, 0, 0))
        ImageDraw.Draw(edge).rounded_rectangle(box, R * S, outline=highlight, width=S)
        fade = Image.linear_gradient('L').resize(full).point(lambda v: 255 - v)
        fade = fade.point(lambda v: max(0, (v - 200) * 255 // 55))
        edge.putalpha(Image.composite(edge.getchannel('A'), Image.new('L', full, 0), fade))
        im.alpha_composite(edge)
    icon = Image.open('docs/assets/icon.png').convert('RGBA').resize((48 * S, 48 * S), Image.LANCZOS)
    im.alpha_composite(icon, ((PAD + 14) * S, (PAD + 12) * S))
    d.text(((PAD + 72) * S, (PAD + 28) * S), 'Download for macOS', font=font(18, 'Semibold'), fill=title, anchor='lm')
    d.text(((PAD + 72) * S, (PAD + 49) * S), 'Apple silicon · macOS 15 or later', font=font(12, 'Regular'), fill=detail, anchor='lm')
    im.save(out, optimize=True)


button((14, 14, 16, 255), (255, 255, 255), (255, 255, 255, 150), (0, 0, 0, 70), (255, 255, 255, 40), 'docs/assets/download-macos.png')
button((255, 255, 255, 255), (29, 29, 31), (110, 110, 115), (0, 0, 0, 140), (255, 255, 255, 0), 'docs/assets/download-macos-dark.png')
