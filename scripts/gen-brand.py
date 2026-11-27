"""Generates MoMa brand assets (launcher icons, adaptive icon layers, splash) from one vector definition.
Run: python scripts/gen-brand.py   (needs Pillow). Outputs are committed; re-run only when the mark changes."""
from PIL import Image, ImageDraw
from pathlib import Path
import math

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "apps/android/android/app/src/main/res"
BRAND = ROOT / "design/brand"
TOP, BOT = (8, 66, 52), (34, 138, 106)   # brand greens
MARK = (183, 232, 196)                    # light mint
S = 4                                     # supersampling

def gradient(size):
    g = Image.new("RGB", (size, size))
    px = g.load()
    for y in range(size):
        t = y / (size - 1)
        c = tuple(round(TOP[i] + (BOT[i] - TOP[i]) * t) for i in range(3))
        for x in range(size):
            px[x, y] = c
    return g

def mark(size, scale=1.0, color=MARK):
    """Two-peak ribbon M on transparent canvas; scale<1 shrinks toward center (adaptive safe zone)."""
    n = size * S
    im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    pts = [(0.18, 0.68), (0.34, 0.31), (0.50, 0.59), (0.66, 0.31), (0.82, 0.68)]
    pts = [(0.5 + (x - 0.5) * scale, 0.5 + (y - 0.51) * scale) for x, y in pts]
    pts = [(x * n, y * n) for x, y in pts]
    w = int(0.115 * n * scale)
    d.line(pts, fill=color + (255,), width=w, joint="curve")
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=color + (255,))
    for x, y in pts[1:-1]:
        d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=color + (255,))
    return im.resize((size, size), Image.LANCZOS)

def rounded(im, radius_frac):
    n = im.size[0]
    m = Image.new("L", (n * S, n * S), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, n * S - 1, n * S - 1], radius=int(radius_frac * n * S), fill=255)
    m = m.resize((n, n), Image.LANCZOS)
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.paste(im.convert("RGBA"), (0, 0), m)
    return out

def circle(im):
    n = im.size[0]
    m = Image.new("L", (n * S, n * S), 0)
    ImageDraw.Draw(m).ellipse([0, 0, n * S - 1, n * S - 1], fill=255)
    m = m.resize((n, n), Image.LANCZOS)
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.paste(im.convert("RGBA"), (0, 0), m)
    return out

def full_icon(size):
    bg = gradient(size).convert("RGBA")
    bg.alpha_composite(mark(size))
    return bg

# densities: legacy launcher px / adaptive layer px (108dp)
DENS = {"mdpi": (48, 108), "hdpi": (72, 162), "xhdpi": (96, 216), "xxhdpi": (144, 324), "xxxhdpi": (192, 432)}

def main():
    BRAND.mkdir(parents=True, exist_ok=True)
    master = full_icon(1024)
    master.save(BRAND / "moma-icon-1024.png")
    rounded(master, 0.22).save(BRAND / "moma-logo-1024.png")
    # Play Store icon (512, square, store applies its own mask)
    master.resize((512, 512), Image.LANCZOS).convert("RGB").save(BRAND / "play-store-icon-512.png")
    for name, (leg, lay) in DENS.items():
        d = RES / f"mipmap-{name}"
        d.mkdir(parents=True, exist_ok=True)
        base = full_icon(leg * 4).resize((leg, leg), Image.LANCZOS)
        rounded(base, 0.22).save(d / "ic_launcher.png")
        circle(base).save(d / "ic_launcher_round.png")
        # adaptive foreground: mark inside the 66/108 safe zone; monochrome for themed icons
        mark(lay, scale=0.62).save(d / "ic_launcher_foreground.png")
        mark(lay, scale=0.62, color=(0, 0, 0)).save(d / "ic_launcher_monochrome.png")
    any_dpi = RES / "mipmap-anydpi-v26"
    any_dpi.mkdir(exist_ok=True)
    (any_dpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@drawable/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
        '</adaptive-icon>\n', encoding="utf-8")
    (any_dpi / "ic_launcher_round.xml").write_text((any_dpi / "ic_launcher.xml").read_text(encoding="utf-8"), encoding="utf-8")
    (RES / "drawable" / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">\n'
        '    <gradient android:angle="270" android:startColor="#084234" android:endColor="#228A6A"/>\n'
        '</shape>\n', encoding="utf-8")
    # Splash: transparent-bg mark (rounded logo) centered on brand gradient
    sp = rounded(master.resize((384, 384), Image.LANCZOS), 0.22)
    sp_dir = RES / "drawable-nodpi"
    sp_dir.mkdir(exist_ok=True)
    sp.save(sp_dir / "splash_logo.png")
    # In-app logo asset
    assets = ROOT / "apps/android/assets/brand"
    assets.mkdir(parents=True, exist_ok=True)
    rounded(master.resize((512, 512), Image.LANCZOS), 0.22).save(assets / "moma_logo.png")
    mark(512).save(assets / "moma_mark.png")
    print("brand assets generated")

main()
