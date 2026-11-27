"""Frames the raw screenshots from marketing_test.dart for the README and the website.

    cd apps/android
    MOMA_SCREENSHOTS=1 flutter test test/screenshots
    python test/screenshots/frame.py

Reads build/screenshots/*.png and writes:
  docs/images/<name>.png         phone-framed PNG for the README (< 400 KB each)
  docs/images/logo.png           app icon with rounded corners
  website/assets/<name>.webp     phone-framed WebP for the landing page
  website/assets/preview.webp    animated preview (light theme screens)
  website/assets/logo.png, website/assets/favicon.png

Needs Pillow (pip install pillow). Fonts: Be Vietnam Pro from test/screenshots/fonts.
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
APP = HERE.parents[1]  # apps/android
ROOT = APP.parents[1]  # repo root
RAW = APP / "build" / "screenshots"
DOCS = ROOT / "docs" / "images"
WEB = ROOT / "website" / "assets"
FONT = HERE / "fonts" / "BeVietnamPro-SemiBold.ttf"
ICON = ROOT / "design" / "brand" / "moma-icon-1024.png"

DPR = 2.625
STATUS = round(28 * DPR)  # status bar height reserved by the test (px)
README_WIDTH = 520
WEB_WIDTH = 560


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    # Draw at 4x and scale down for smooth corners.
    w, h = size
    big = Image.new("L", (w * 4, h * 4), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, w * 4 - 1, h * 4 - 1), radius * 4, fill=255)
    return big.resize(size, Image.LANCZOS)


def luminance(rgb: tuple[int, int, int]) -> float:
    r, g, b = rgb[:3]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def draw_status_bar(img: Image.Image) -> None:
    """Android-style status bar: time on the left, signal / Wi-Fi / battery on the right."""
    w = img.width
    sample = img.crop((0, 0, w, STATUS)).resize((1, 1), Image.BOX).getpixel((0, 0))
    ink = (20, 30, 26) if luminance(sample) > 150 else (240, 248, 244)
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(str(FONT), round(13.5 * DPR))
    cy = STATUS // 2 + round(1 * DPR)
    d.text((round(22 * DPR), cy), "9:41", font=font, fill=ink, anchor="lm")
    u = DPR
    x = w - round(20 * u)
    # battery
    bw, bh = round(22 * u), round(11 * u)
    d.rounded_rectangle((x - bw, cy - bh // 2, x, cy + bh // 2), round(3 * u), outline=ink, width=max(2, round(1.3 * u)))
    d.rounded_rectangle((x - bw + round(2.5 * u), cy - bh // 2 + round(2.5 * u), x - round(6 * u), cy + bh // 2 - round(2.5 * u)), round(1.5 * u), fill=ink)
    d.rectangle((x + round(1 * u), cy - round(2.5 * u), x + round(2.6 * u), cy + round(2.5 * u)), fill=ink)
    x -= bw + round(10 * u)
    # wifi (three arcs + dot)
    r = round(9 * u)
    for k, rr in enumerate((r, round(r * 0.66), round(r * 0.33))):
        box = (x - r - rr, cy + round(4 * u) - rr, x - r + rr, cy + round(4 * u) + rr)
        if k < 2:
            d.arc(box, 225, 315, fill=ink, width=max(2, round(1.8 * u)))
        else:
            d.pieslice(box, 225, 315, fill=ink)
    x -= 2 * r + round(8 * u)
    # cellular signal (4 bars)
    bar = round(3 * u)
    gap = round(1.6 * u)
    for i in range(4):
        hgt = round((4 + i * 2.6) * u)
        x0 = x - (4 - i) * (bar + gap)
        d.rounded_rectangle((x0, cy + round(5 * u) - hgt, x0 + bar, cy + round(5 * u)), round(1 * u), fill=ink)


def phone(screen: Image.Image) -> Image.Image:
    """Screen inside a slim dark bezel with rounded corners, a punch-hole camera and a soft shadow."""
    screen = screen.convert("RGBA")
    draw_status_bar(screen)
    sw, sh = screen.size
    bezel = round(9 * DPR)
    radius = round(34 * DPR)
    body_w, body_h = sw + 2 * bezel, sh + 2 * bezel
    pad = round(18 * DPR)  # room for the shadow
    canvas = Image.new("RGBA", (body_w + 2 * pad, body_h + 2 * pad), (0, 0, 0, 0))

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (pad, pad + round(6 * DPR), pad + body_w, pad + body_h + round(6 * DPR)),
        radius + bezel,
        fill=(4, 30, 24, 90),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(round(10 * DPR)))
    canvas.alpha_composite(shadow)

    body = Image.new("RGBA", (body_w, body_h), (0, 0, 0, 0))
    bd = ImageDraw.Draw(body)
    bd.rounded_rectangle((0, 0, body_w - 1, body_h - 1), radius + bezel, fill=(17, 24, 22, 255))
    bd.rounded_rectangle((2, 2, body_w - 3, body_h - 3), radius + bezel - 2, outline=(62, 76, 71, 255), width=2)
    masked = Image.new("RGBA", screen.size, (0, 0, 0, 0))
    masked.paste(screen, (0, 0), rounded_mask(screen.size, radius))
    body.alpha_composite(masked, (bezel, bezel))
    # punch-hole camera
    cx, cy, cr = body_w // 2, bezel + STATUS // 2, round(5 * DPR)
    bd = ImageDraw.Draw(body)
    bd.ellipse((cx - cr, cy - cr, cx + cr, cy + cr), fill=(8, 10, 10, 255))
    canvas.alpha_composite(body, (pad, pad))
    return canvas


def fit(img: Image.Image, width: int) -> Image.Image:
    return img.resize((width, round(img.height * width / img.width)), Image.LANCZOS)


def save_png(img: Image.Image, path: pathlib.Path, limit: int = 400_000) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)
    if path.stat().st_size > limit:
        # Palette with alpha keeps the look and cuts the size for photo-like gradients.
        q = img.quantize(colors=256, method=Image.FASTOCTREE, dither=Image.FLOYDSTEINBERG)
        q.save(path, optimize=True)
    print(f"{path.relative_to(ROOT)}  {path.stat().st_size // 1024} KB")


def save_webp(img: Image.Image, path: pathlib.Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "WEBP", quality=86, method=6)
    print(f"{path.relative_to(ROOT)}  {path.stat().st_size // 1024} KB")


def logo(size: int) -> Image.Image:
    icon = Image.open(ICON).convert("RGBA").resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(icon, (0, 0), rounded_mask((size, size), round(size * 0.225)))
    return out


def main() -> None:
    shots = sorted(RAW.glob("*.png"))
    if not shots:
        raise SystemExit(f"No screenshots in {RAW}. Run: MOMA_SCREENSHOTS=1 flutter test test/screenshots")
    framed: dict[str, Image.Image] = {}
    for p in shots:
        framed[p.stem] = phone(Image.open(p))
        save_png(fit(framed[p.stem], README_WIDTH), DOCS / f"{p.stem}.png")
        save_webp(fit(framed[p.stem], WEB_WIDTH), WEB / f"{p.stem}.webp")

    # Animated preview for the website (cross-fade between light screens).
    order = [n for n in ("home-light", "assistant-light", "reports-light", "receive-light", "goals-light") if n in framed]
    if order:
        frames: list[Image.Image] = []
        durations: list[int] = []
        imgs = [fit(framed[n], 360) for n in order]
        for i, a in enumerate(imgs):
            b = imgs[(i + 1) % len(imgs)]
            frames.append(a)
            durations.append(2200)
            for t in (0.33, 0.66):
                frames.append(Image.blend(a, b, t))
                durations.append(90)
        WEB.mkdir(parents=True, exist_ok=True)
        frames[0].save(
            WEB / "preview.webp", "WEBP", save_all=True, append_images=frames[1:],
            duration=durations, loop=0, quality=70, method=6,
        )
        print(f"website/assets/preview.webp  {(WEB / 'preview.webp').stat().st_size // 1024} KB")

    save_png(logo(256), DOCS / "logo.png")
    save_png(logo(192), WEB / "logo.png")
    save_png(logo(64), WEB / "favicon.png")


if __name__ == "__main__":
    main()
