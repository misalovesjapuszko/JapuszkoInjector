"""Draws the placeholder app icon (replace with scripts/set-icon.sh yours.png)."""
import sys
from PIL import Image, ImageDraw

S = 1024
img = Image.new("RGB", (S, S), (9, 11, 10))
d = ImageDraw.Draw(img)
for i in range(0, S, 64):
    c = (22, 27, 24) if i % 320 else (34, 41, 37)
    d.line([(i, 0), (i, S)], fill=c, width=2)
    d.line([(0, i), (S, i)], fill=c, width=2)

acid = (182, 255, 59)
# syringe, drawn horizontally on its own layer then rotated
L = Image.new("RGBA", (S, S), (0, 0, 0, 0))
g = ImageDraw.Draw(L)
cy = S // 2
g.rectangle([300, cy - 70, 760, cy + 70], outline=(230, 236, 231), width=14)      # barrel
g.rectangle([470, cy - 52, 742, cy + 52], fill=acid)                                # dose
for k in range(8):
    x = 330 + k * 55
    g.line([(x, cy - 70), (x, cy - 70 + (40 if k % 4 == 0 else 24))], fill=(230, 236, 231), width=8)
g.rectangle([284, cy - 120, 300, cy + 120], fill=(120, 136, 129))                  # flange
g.rectangle([180, cy - 14, 470, cy + 14], fill=(120, 136, 129))                    # rod
g.rectangle([450, cy - 56, 470, cy + 56], fill=(230, 236, 231))                    # stopper
g.rectangle([150, cy - 95, 180, cy + 95], fill=(230, 236, 231))                    # thumb rest
g.polygon([(760, cy - 16), (900, cy - 4), (930, cy), (900, cy + 4), (760, cy + 16)], fill=(120, 136, 129))
g.ellipse([918, cy - 14, 946, cy + 14], fill=acid)
L = L.rotate(35, resample=Image.BICUBIC, center=(S // 2, S // 2))
img.paste(L, (0, 0), L)
img.save(sys.argv[1])
