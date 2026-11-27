"""One-off refactor: replace hard-coded surface/ink colours in lib/ with theme tokens (context.pal.*).
After this runs, `flutter analyze` reports const errors; _fix_const.py removes the offending `const` keywords."""
import glob
import os
import re

os.chdir(r"D:\NhanSam\MoneyManage\moma\apps\android\lib")
SKIP = {
    "app/theme/palette.dart",
    "app/theme/moma_theme.dart",
    "core/ui/brand.dart",  # owned by the logo agent
}
HEX = {
    "0xFFF3F7F5": "surfaceAlt",
    "0xFFF1F4F3": "surfaceAlt",
    "0xFFEEF2F0": "lineSoft",
    "0xFFDDE6E2": "line",
    "0xFFD9E3DE": "line",
    "0xFFE3F5EC": "bubble",
    "0xFFEAF7F0": "tintSoft",
    "0xFFF1FAF5": "tintSoft",
    "0xFFD7F0E1": "tint",
    "0xFFDDF3E6": "tint",
}
changed = 0
for p in glob.glob("**/*.dart", recursive=True):
    p = p.replace("\\", "/")
    if p in SKIP:
        continue
    s = open(p, encoding="utf8", newline="").read()
    t = s
    # text colours
    t = t.replace("MomaColors.muted", "context.pal.muted")
    t = t.replace("MomaColors.ink", "context.pal.ink")
    t = t.replace("MomaColors.cloud", "context.pal.bg")
    # background hex tints
    for hx, tok in HEX.items():
        t = re.sub(r"(?:const )?Color\(" + hx + r"\)", f"context.pal.{tok}", t)
    # card / sheet / dialog backgrounds that were plain white
    t = re.sub(r"(BoxDecoration\(\s*(?:\n\s*)?color:) Colors\.white,", r"\1 context.pal.surface,", t)
    t = re.sub(r"(Material\(\s*(?:\n\s*)?color:) Colors\.white,", r"\1 context.pal.surface,", t)
    t = re.sub(r"(Container\(\s*(?:\n\s*)?color:) Colors\.white,", r"\1 context.pal.surface,", t)
    t = re.sub(r"(ColoredBox\(\s*(?:\n\s*)?color:) Colors\.white,", r"\1 context.pal.surface,", t)
    t = re.sub(r"(backgroundColor:) Colors\.white,", r"\1 context.pal.surface,", t)
    t = re.sub(r"(fillColor:) Colors\.white,", r"\1 context.pal.surface,", t)
    t = t.replace("color: context.pal.surface,\n          boxShadow", "color: context.pal.surface,\n          boxShadow")
    if t != s:
        if "palette.dart" not in t:
            depth = p.count("/")
            rel = "../" * depth + "app/theme/palette.dart"
            # insert after the last existing import line
            lines = t.split("\n")
            idx = max(i for i, l in enumerate(lines) if l.startswith("import "))
            lines.insert(idx + 1, f"import '{rel}';")
            t = "\n".join(lines)
        open(p, "w", encoding="utf8", newline="").write(t)
        changed += 1
print("files changed:", changed)
