"""Generates ALL MoMa brand assets from one geometry definition (the ribbon "M" below).
Run: python scripts/gen-brand.py      (needs Pillow only; deterministic)

Outputs: design/brand/*.svg (master vectors), play-store icon, Android launcher mipmaps / adaptive layers /
monochrome / splash, in-app images. The same geometry is mirrored in apps/android/lib/core/ui/brand.dart
(MomaMark) - keep both in sync when changing MARK_* constants.

Lockup text: SVG uses font-family "Be Vietnam Pro" (brand typeface, see brand sheet) with sans-serif
fallbacks; install the font (Google Fonts, free) before exporting the lockups to PNG/PDF."""
from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "apps/android/android/app/src/main/res"
BRAND = ROOT / "design/brand"
ASSETS = ROOT / "apps/android/assets/brand"
S = 4  # supersampling

# ---------------------------------------------------------------- geometry (mark space 96 x 64)
VB_W, VB_H = 96.0, 64.0
STROKE = 13.5
# Ribbon A (left, light): foot -> left peak -> valley.  Ribbon B (right, deep): valley -> right peak -> foot.
# Each ribbon is a chain of cubic Beziers (p0, c1, c2, p1), stroked with round caps / joins.
RIB_A = [((9, 53), (14, 40), (18, 11), (29, 11)),
         ((29, 11), (40, 11), (44, 33), (48, 42))]
RIB_B = [((48, 42), (52, 33), (56, 11), (67, 11)),
         ((67, 11), (78, 11), (82, 40), (87, 53))]
SHADOW_SEG = [((48, 42), (50.2, 37), (52, 28), (56.5, 20))]  # B near the fold, drops onto A
SHADOW_OFF = (0.0, 1.6)   # mark units
SHADOW_SIGMA = 2.4
SHADOW_ALPHA = 0.36

# palettes: (A_left, A_right, B_left, B_right); x gradient in mark space (A: 0..52, B: 46..96)
PAL_DARK = ("#C9F7D6", "#6FE3B2", "#52DBA6", "#25B98B")   # on Forest/Emerald backgrounds
PAL_LIGHT = ("#7BE0B4", "#34BE92", "#27A67F", "#0C6A54")  # on white / light backgrounds
GRAD_A = (0.0, 52.0)
GRAD_B = (46.0, 96.0)
FOREST, EMERALD = "#073D33", "#21896E"
CENTER = (VB_W / 2, VB_H / 2)


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def bez(seg, t):
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = seg
    u = 1 - t
    return (u**3 * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t**3 * x3,
            u**3 * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t**3 * y3)


def flatten(segs, tf, step_px):
    """Dense polyline of the chain in pixel space (tf maps mark units -> px)."""
    pts = []
    for seg in segs:
        n = 400
        prev = None
        for i in range(n + 1):
            p = tf(bez(seg, i / n))
            if prev is None or ((p[0] - prev[0]) ** 2 + (p[1] - prev[1]) ** 2) ** .5 >= step_px or i == n:
                pts.append(p)
                prev = p
    return pts


def stroke_mask(size, segs, tf, width_px):
    """Round-cap/round-join stroke of a Bezier chain as 'L' mask (circle stamping, sub-pixel dense)."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    r = width_px / 2
    for x, y in flatten(segs, tf, max(0.5, r / 10)):
        d.ellipse([x - r, y - r, x + r, y + r], fill=255)
    return m


def hgrad(size, x0, x1, c0, c1):
    """size x size image with horizontal gradient c0@x0 -> c1@x1 (pixel x)."""
    g = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(g)
    a, b = hexrgb(c0), hexrgb(c1)
    for x in range(size):
        t = min(1, max(0, (x + 0.5 - x0) / (x1 - x0)))
        d.line([(x, 0), (x, size)], fill=tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3)))
    return g


def mark_layer(size, k, ox, oy, pal=PAL_DARK, solid=None, shadow=True):
    """RGBA size x size with the mark. k = px per mark unit, (ox,oy) = px position of mark origin."""
    n = size * S
    kk = k * S
    tf = lambda p: (ox * S + p[0] * kk, oy * S + p[1] * kk)
    wpx = STROKE * kk
    ma = stroke_mask(n, RIB_A, tf, wpx)
    mb = stroke_mask(n, RIB_B, tf, wpx)
    big = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    if solid:
        union = Image.new("L", (n, n), 0)
        union.paste(255, (0, 0), ma)
        union.paste(255, (0, 0), mb)
        big.paste(Image.new("RGBA", (n, n), hexrgb(solid) + (255,)), (0, 0), union)
    else:
        gx = lambda u: ox * S + u * kk
        ga = hgrad(n, gx(GRAD_A[0]), gx(GRAD_A[1]), pal[0], pal[1])
        gb = hgrad(n, gx(GRAD_B[0]), gx(GRAD_B[1]), pal[2], pal[3])
        big.paste(ga.convert("RGBA"), (0, 0), ma)
        if shadow:
            tfs = lambda p: tf((p[0] + SHADOW_OFF[0], p[1] + SHADOW_OFF[1]))
            sm = stroke_mask(n, SHADOW_SEG, tfs, wpx).filter(ImageFilter.GaussianBlur(SHADOW_SIGMA * kk))
            sm = sm.point(lambda v: int(v * SHADOW_ALPHA))
            sh = Image.new("RGBA", (n, n), (3, 38, 30, 255))
            layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))
            layer.paste(sh, (0, 0), sm)
            big.alpha_composite(layer)
        top = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        top.paste(gb.convert("RGBA"), (0, 0), mb)
        big.alpha_composite(top)
    return big.resize((size, size), Image.LANCZOS)


def fit_mark(size, width_frac, cy_frac=0.5, **kw):
    """Mark centred, content width (92 units) = width_frac * size."""
    k = width_frac * size / 92.0
    ox = size / 2 - CENTER[0] * k
    oy = size * cy_frac - CENTER[1] * k
    return mark_layer(size, k, ox, oy, **kw)


def diag_gradient(size, c0=FOREST, c1=EMERALD):
    g = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(g)
    a, b = hexrgb(c0), hexrgb(c1)
    for s in range(2 * size - 1):
        t = s / (2 * size - 2)
        d.line([(s, 0), (0, s)], fill=tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3)), width=2)
    return g


def glow(size):
    """Soft top-left light on the icon background."""
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).ellipse([-0.35 * size, -0.45 * size, 0.75 * size, 0.45 * size], fill=26)
    m = m.filter(ImageFilter.GaussianBlur(size * 0.12))
    out = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    out.putalpha(m)
    return out


ICON_MARK = 0.60  # content width / canvas for the full-bleed icon


def full_icon(size):
    bg = diag_gradient(size).convert("RGBA")
    bg.alpha_composite(glow(size))
    bg.alpha_composite(fit_mark(size, ICON_MARK))
    return bg


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


# ---------------------------------------------------------------- SVG
def f(v):
    return ("%.2f" % v).rstrip("0").rstrip(".")


def chain_d(segs, dx=0.0, dy=0.0):
    s = "M%s %s" % (f(segs[0][0][0] + dx), f(segs[0][0][1] + dy))
    for _, c1, c2, p in segs:
        s += " C%s %s %s %s %s %s" % (f(c1[0] + dx), f(c1[1] + dy), f(c2[0] + dx), f(c2[1] + dy),
                                      f(p[0] + dx), f(p[1] + dy))
    return s


def mark_svg_body(uid, pal=PAL_DARK, solid=None, shadow=True):
    """SVG <defs> + shapes in mark space (0..96 x 0..64)."""
    sw = 'stroke-width="%s" stroke-linecap="round" stroke-linejoin="round" fill="none"' % f(STROKE)
    if solid:
        return ("<g stroke=\"%s\" %s><path d=\"%s\"/><path d=\"%s\"/></g>" %
                (solid, sw, chain_d(RIB_A), chain_d(RIB_B)))
    defs = ('<linearGradient id="%sA" gradientUnits="userSpaceOnUse" x1="%s" y1="0" x2="%s" y2="0">'
            '<stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>'
            '<linearGradient id="%sB" gradientUnits="userSpaceOnUse" x1="%s" y1="0" x2="%s" y2="0">'
            '<stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>'
            % (uid, f(GRAD_A[0]), f(GRAD_A[1]), pal[0], pal[1], uid, f(GRAD_B[0]), f(GRAD_B[1]), pal[2], pal[3]))
    body = '<path d="%s" stroke="url(#%sA)" %s/>' % (chain_d(RIB_A), uid, sw)
    if shadow:
        defs += ('<filter id="%sS" filterUnits="userSpaceOnUse" x="-10" y="-10" width="116" height="84"><feGaussianBlur stdDeviation="%s"/></filter>'
                 % (uid, f(SHADOW_SIGMA)))
        body += ('<path d="%s" stroke="#032620" stroke-opacity="%s" filter="url(#%sS)" %s/>'
                 % (chain_d(SHADOW_SEG, *SHADOW_OFF), f(SHADOW_ALPHA), uid, sw))
    body += '<path d="%s" stroke="url(#%sB)" %s/>' % (chain_d(RIB_B), uid, sw)
    return "<defs>%s</defs>%s" % (defs, body)


FONT = "'Be Vietnam Pro','Inter','Segoe UI',Roboto,Arial,sans-serif"


def svg_mark(pal=PAL_LIGHT, solid=None):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 64" width="96" height="64">'
            '<title>MoMa</title>%s</svg>\n' % mark_svg_body("m", pal, solid))


def svg_icon():
    k = ICON_MARK * 1024 / 92.0
    ox, oy = 512 - CENTER[0] * k, 512 - CENTER[1] * k
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            '<title>MoMa app icon</title><defs>'
            '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="%s"/>'
            '<stop offset="1" stop-color="%s"/></linearGradient>'
            '<radialGradient id="glow" cx="0.18" cy="0.0" r="0.7"><stop offset="0" stop-color="#fff" stop-opacity="0.18"/>'
            '<stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient></defs>'
            '<rect width="1024" height="1024" rx="225" fill="url(#bg)"/>'
            '<rect width="1024" height="1024" rx="225" fill="url(#glow)"/>'
            '<g transform="translate(%s %s) scale(%s)">%s</g></svg>\n'
            % (FOREST, EMERALD, f(ox), f(oy), f(k), mark_svg_body("i", PAL_DARK)))


def svg_lockup(dark_bg):
    pal = PAL_DARK if dark_bg else PAL_LIGHT
    main, sub = ("#FFFFFF", "#B1E5B6") if dark_bg else (FOREST, EMERALD)
    k = 1.55
    bg = '<rect width="560" height="150" rx="20" fill="%s"/>' % FOREST if dark_bg else ""
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 560 150" width="560" height="150">'
            '<title>MoMa MoneyManage</title>%s'
            '<g transform="translate(36 25) scale(%s)">%s</g>'
            '<text x="212" y="84" font-family="%s" font-size="76" font-weight="800" letter-spacing="-1.5" fill="%s">MoMa</text>'
            '<text x="214" y="121" font-family="%s" font-size="29" font-weight="400" letter-spacing="0.4" fill="%s">MoneyManage</text>'
            '</svg>\n' % (bg, f(k), mark_svg_body("l", pal), FONT, main, FONT, sub))


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


# densities: legacy launcher px / adaptive layer px (108dp)
DENS = {"mdpi": (48, 108), "hdpi": (72, 162), "xhdpi": (96, 216), "xxhdpi": (144, 324), "xxxhdpi": (192, 432)}
ADAPTIVE_MARK = 0.48  # content width / 108dp layer; half-diagonal of the mark stays inside the 66dp safe circle


def main():
    BRAND.mkdir(parents=True, exist_ok=True)
    # vectors
    write(BRAND / "moma-mark.svg", svg_mark(PAL_LIGHT))
    write(BRAND / "moma-mark-mono.svg", svg_mark(solid=FOREST))
    write(BRAND / "moma-icon.svg", svg_icon())
    write(BRAND / "moma-lockup-light.svg", svg_lockup(False))
    write(BRAND / "moma-lockup-dark.svg", svg_lockup(True))
    # rasters
    master = full_icon(1024)
    master.save(BRAND / "moma-icon-1024.png")
    rounded(master, 0.225).save(BRAND / "moma-logo-1024.png")
    master.resize((512, 512), Image.LANCZOS).convert("RGB").save(BRAND / "play-store-icon-512.png")
    for name, (leg, lay) in DENS.items():
        d = RES / f"mipmap-{name}"
        d.mkdir(parents=True, exist_ok=True)
        base = full_icon(leg * 4).resize((leg, leg), Image.LANCZOS)
        rounded(base, 0.225).save(d / "ic_launcher.png")
        circle(base).save(d / "ic_launcher_round.png")
        fit_mark(lay, ADAPTIVE_MARK).save(d / "ic_launcher_foreground.png")
        fit_mark(lay, ADAPTIVE_MARK, solid="#000000").save(d / "ic_launcher_monochrome.png")
    any_dpi = RES / "mipmap-anydpi-v26"
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
           '    <background android:drawable="@drawable/ic_launcher_background"/>\n'
           '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
           '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
           '</adaptive-icon>\n')
    write(any_dpi / "ic_launcher.xml", xml)
    write(any_dpi / "ic_launcher_round.xml", xml)
    write(RES / "drawable" / "ic_launcher_background.xml",
          '<?xml version="1.0" encoding="utf-8"?>\n'
          '<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">\n'
          '    <gradient android:angle="315" android:startColor="%s" android:endColor="%s"/>\n'
          '</shape>\n' % (FOREST, EMERALD))
    # splash: rounded logo centred on the brand gradient (launch_background.xml)
    sp_dir = RES / "drawable-nodpi"
    sp_dir.mkdir(exist_ok=True)
    rounded(full_icon(384 * 2).resize((384, 384), Image.LANCZOS), 0.225).save(sp_dir / "splash_logo.png")
    # in-app images
    ASSETS.mkdir(parents=True, exist_ok=True)
    rounded(master.resize((512, 512), Image.LANCZOS), 0.225).save(ASSETS / "moma_logo.png")
    fit_mark(512, 0.94, pal=PAL_LIGHT).crop((0, 96, 512, 416)).save(ASSETS / "moma_mark.png")
    print("brand assets generated")


if __name__ == "__main__":
    main()
