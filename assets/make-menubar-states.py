#!/usr/bin/env python3
"""生成 assets/menubar-states.png —— 菜单栏四种状态（浅色 / 深色菜单栏各一行）。

为什么是脚本：截图是**生成物**，不是手工资产。图里每个图标都由 App 自己的渲染代码
（`FanPilot --render-preview`，与菜单栏走同一个 twoLineImage）导出的模板图合成，
排版一改、跑一次就更新，不会出现「README 里的图和真实菜单栏不一致」。

用法（仓库根目录）：
    make app
    uv run --with pillow python assets/make-menubar-states.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app/.build/release/FanPilotMenu"
OUT = ROOT / "assets/menubar-states.png"

# (状态, 转速, 温度, 标题, 说明) —— 转速在上、温度在下（与 App 一致）
STATES = [
    ("normal", "4547", "57°C", "正常", "上：平均转速 · 下：最高核心温度"),
    ("emergency", "5563", "93°C", "紧急全速", "贴底实心条 · 温度 ≥ 阈值"),
    ("fault", "1247", "63°C", "风扇故障", "贴底虚线条 · 实际不到目标一半"),
    ("firmware", "固件", "45°C", "固件接管", "整体变淡 · 守护已退出"),
]
CELL_W, BAR_H, CAP_H, PAD = 250, 72, 78, 22
LIGHT_BG, DARK_BG = (236, 236, 238), (34, 34, 36)


def font(size: int) -> ImageFont.FreeTypeFont:
    for p in ("/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Medium.ttc"):
        if Path(p).exists():
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def glyph(tmp: Path, st: str, rpm: str, temp: str) -> Image.Image:
    """App 渲染的模板图 ⇒ 透明底的字形遮罩（alpha = 墨迹）。"""
    out = tmp / f"{st}.png"
    # --render-preview 的参数顺序是语义名：先温度、后转速
    r = subprocess.run([str(APP), "--render-preview", str(out), temp, rpm, st],
                       capture_output=True, text=True)
    tmpl = tmp / f"{st}-template.png"
    if r.returncode != 0 or not tmpl.exists():
        sys.exit(f"✗ 渲染失败 {st}: {r.stderr.strip()}")
    # 🩸 模板图背景是**透明**的：转灰度后透明处也是 0，与黑色墨迹分不开（初版整块变成实心矩形）
    #    ⇒ 直接取 alpha 通道当遮罩
    g = Image.open(tmpl).convert("RGBA").getchannel("A")
    if st in ("firmware", "stale"):                           # 模板模拟不含整体变淡，这里补上
        g = g.point(lambda v: int(v * 0.45))
    return g


def main() -> None:
    if not APP.exists():
        sys.exit(f"✗ 找不到 {APP}（先 make app）")
    with tempfile.TemporaryDirectory() as d:
        glyphs = [glyph(Path(d), st, rpm, temp) for st, rpm, temp, *_ in STATES]
    # 🩸 按四张图的**公共**边界裁切：各裁各的会让没有标记条的「正常」被放大，四格比例不一致
    boxes = [g.getbbox() for g in glyphs if g.getbbox()]
    union = (min(b[0] for b in boxes), min(b[1] for b in boxes),
             max(b[2] for b in boxes), max(b[3] for b in boxes))
    glyphs = [g.crop(union) for g in glyphs]

    W = CELL_W * len(STATES)
    H = 40 + BAR_H * 2 + 12 + CAP_H
    img = Image.new("RGB", (W, H), (255, 255, 255))
    dr = ImageDraw.Draw(img)
    dr.text((PAD, 10), "菜单栏实际呈现（由 App 自身渲染代码导出，assets/make-menubar-states.py 生成）",
            fill=(90, 90, 96), font=font(15))
    for row, (bg, ink, tag) in enumerate([(LIGHT_BG, (20, 20, 20), "浅色菜单栏"),
                                          (DARK_BG, (245, 245, 245), "深色菜单栏")]):
        y0 = 40 + row * (BAR_H + 6)
        dr.rectangle([0, y0, W, y0 + BAR_H], fill=bg)
        dr.text((W - 110, y0 + 6), tag, fill=(150, 150, 156), font=font(13))
        for i, g in enumerate(glyphs):
            scale = (BAR_H - 16) / g.height
            gs = g.resize((max(1, int(g.width * scale)), BAR_H - 16), Image.LANCZOS)
            layer = Image.new("RGB", gs.size, ink)
            img.paste(layer, (i * CELL_W + PAD, y0 + 8), gs)
    yc = 40 + BAR_H * 2 + 12
    for i, (_, _, _, title, note) in enumerate(STATES):
        x = i * CELL_W + PAD
        dr.text((x, yc + 6), title, fill=(20, 20, 24), font=font(20))
        dr.text((x, yc + 40), note, fill=(120, 120, 128), font=font(13))
        if i:
            dr.line([(i * CELL_W, 40), (i * CELL_W, H)], fill=(225, 225, 228), width=1)
    img.save(OUT, optimize=True)
    print(f"✅ {OUT.relative_to(ROOT)}  {W}×{H}")


if __name__ == "__main__":
    main()
