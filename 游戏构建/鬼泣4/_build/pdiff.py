#!/usr/bin/env python3
# pdiff.py <a.png> <b.png> [x y w h] —— 计算两张截图的平均像素差（0~255）
# 不指定区域则整图比较；指定区域则只比较该矩形（用于聚焦人物动作区）
import sys
from PIL import Image, ImageChops, ImageStat

a, b = Image.open(sys.argv[1]).convert("L"), Image.open(sys.argv[2]).convert("L")
if len(sys.argv) >= 7:
    x, y, w, h = (int(v) for v in sys.argv[3:7])
    box = (x, y, x + w, y + h)
    a, b = a.crop(box), b.crop(box)
d = ImageChops.difference(a, b)
st = ImageStat.Stat(d)
print("mean=%.2f max=%d" % (st.mean[0], d.getextrema()[1]))
