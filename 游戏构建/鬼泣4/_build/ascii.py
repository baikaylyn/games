#!/usr/bin/env python3
# ascii.py <image.png> [cols] [rows] —— 把截图渲染成字符画，便于读出画面上的文字/UI
# 只取亮度通道，用 0-9 九档表示，文字（高亮）会浮出来
import sys
from PIL import Image

path = sys.argv[1]
cols = int(sys.argv[2]) if len(sys.argv) > 2 else 128
rows = int(sys.argv[3]) if len(sys.argv) > 3 else 44

img = Image.open(path).convert("L")
w, h = img.size
img = img.resize((cols, rows))
px = img.load()

# 亮度映射：暗→空格，亮→数字（越大越亮）
ramp = " .:-=+*#%@"[::-1]   # 亮→暗，用 @ 表示最亮
print("size=%dx%d render=%dx%d" % (w, h, cols, rows))
for y in range(rows):
    line = ""
    for x in range(cols):
        v = px[x, y]
        idx = int(v / 255 * (len(ramp) - 1))
        line += ramp[idx]
    print(line)
