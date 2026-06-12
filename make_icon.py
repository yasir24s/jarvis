#!/usr/bin/env python3
"""Generate a JARVIS arc-reactor app icon and apply it to JARVIS.app (no re-sign)."""
import math, os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))

S = 1024
cx = cy = S / 2
CYAN = (95, 220, 255)
GOLD = (255, 207, 107)

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# Dark rounded-square backdrop
m = 36
d.rounded_rectangle([m, m, S - m, S - m], radius=210, fill=(8, 13, 20, 255))
d.rounded_rectangle([m, m, S - m, S - m], radius=210, outline=(40, 90, 110, 160), width=4)

# Glow layer (drawn separately, then blurred for a soft halo)
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
maxr = 300
for i in range(130):
    t = i / 129.0
    r = maxr * (1 - t)
    a = int(6 + 210 * (t ** 2))
    gd.ellipse([cx - r, cy - r, cx + r, cy + r],
               fill=(int(CYAN[0]), int(CYAN[1]), int(CYAN[2]), min(255, a)))
glow = glow.filter(ImageFilter.GaussianBlur(10))
img.alpha_composite(glow)

# Bright core
for i in range(48):
    t = i / 47.0
    r = 78 * (1 - t)
    a = int(120 + 135 * t)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(int(225 + 30 * t), 255, 255, a))

# Iron-Man style arcs + rings (with gaps)
d.arc([cx - 360, cy - 360, cx + 360, cy + 360], 205, 145, fill=CYAN + (235,), width=12)
d.arc([cx - 300, cy - 300, cx + 300, cy + 300], 25, 300, fill=GOLD + (225,), width=9)
d.ellipse([cx - 250, cy - 250, cx + 250, cy + 250], outline=CYAN + (120,), width=3)

# Tick marks around the outer ring
for deg in range(0, 360, 6):
    a = math.radians(deg)
    r1, r2 = 318, 346
    d.line([cx + r1 * math.cos(a), cy + r1 * math.sin(a),
            cx + r2 * math.cos(a), cy + r2 * math.sin(a)], fill=CYAN + (150,), width=3)

out = os.path.join(HERE, "jarvis_icon.png")
img.save(out)
print("icon png saved:", out)

# Apply to the app bundle via NSWorkspace (writes a custom icon, does NOT touch
# the signed Contents/ → preserves the mic & automation TCC grants).
try:
    from AppKit import NSImage, NSWorkspace
    app = os.path.join(HERE, "dist", "JARVIS.app")
    nsimg = NSImage.alloc().initWithContentsOfFile_(out)
    ok = NSWorkspace.sharedWorkspace().setIcon_forFile_options_(nsimg, app, 0)
    print("icon applied to JARVIS.app:", bool(ok))
except Exception as e:
    print("icon apply failed:", e)
