#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fake_pwa 换图标重打包工具（侧载场景下真实更换桌面图标的通道）。

原理：桌面图标来自包内编译资源，运行时无法改（鸿蒙公开 API 仅 AGC 动态图标），
但侧载用户可以在「安装前」替换资源重新打包——安装后桌面图标即为目标样式。

用法（在仓库根目录执行）:
  # 内置样式: blue(收藏蓝) black(曜石黑) green(翡翠绿) orange(珊瑚橙) purple(星紫)
  python tools/set_app_icon.py --variant black

  # 任意图片（如目标网站 logo）：自动裁切 1024px 圆角安全区、生成全部图标资源
  python tools/set_app_icon.py --image "D:/icons/bilibili.png"

  # 替换后直接编译出 hap
  python tools/set_app_icon.py --variant green --build

产物: entry/build/default/outputs/default/entry-default-unsigned.hap
恢复默认: python tools/set_app_icon.py --variant blue
"""
import argparse
import os
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw

try:
    BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
except NameError:
    BASE = os.getcwd()

APP_ICON = os.path.join(BASE, 'AppScope/resources/base/media/app_icon.png')
START_ICON = os.path.join(BASE, 'entry/src/main/resources/base/media/startIcon.png')
FOREGROUND = os.path.join(BASE, 'entry/src/main/resources/base/media/foreground.png')
BACKGROUND = os.path.join(BASE, 'entry/src/main/resources/base/media/background.png')

ASSETS_DIR = os.path.join(BASE, 'assets/icons')

# 内置样式：白色网络地球 + 不同底色渐变（上浅下深）
VARIANTS = {
    'blue':   ('#589EF6', '#2D5AEE', '收藏蓝'),
    'black':  ('#3A3D45', '#12141A', '曜石黑'),
    'green':  ('#3DDC97', '#0FA36B', '翡翠绿'),
    'orange': ('#FFA940', '#F2643C', '珊瑚橙'),
    'purple': ('#B37FEB', '#7B3FF2', '星紫'),
}


def hex2rgb(h: str):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def make_gradient(size: int, top, bot) -> Image.Image:
    img = Image.new('RGBA', (size, size))
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        c = (int(top[0] + (bot[0] - top[0]) * t),
             int(top[1] + (bot[1] - top[1]) * t),
             int(top[2] + (bot[2] - top[2]) * t), 255)
        for x in range(size):
            px[x, y] = c
    return img


def make_globe(size: int) -> Image.Image:
    """白色网络地球前景（与应用默认样式一致）。"""
    w = 4
    big = Image.new('RGBA', (size * w, size * w), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    cx = cy = size * w // 2
    r = int(size * w * 0.30)
    sw = int(size * w * 0.032)
    white = (255, 255, 255, 255)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=white, width=sw)
    for rx in (int(r * 0.55), int(r * 0.22)):
        d.ellipse([cx - rx, cy - r, cx + rx, cy + r], outline=white, width=sw)
    ry = int(r * 0.55)
    d.ellipse([cx - r, cy - ry, cx + r, cy + ry], outline=white, width=sw)
    d.line([cx, cy - r, cx, cy + r], fill=white, width=sw)
    return big.resize((size, size), Image.LANCZOS)


def cover_crop(src: Image.Image, size: int) -> Image.Image:
    """居中裁切成正方形 cover 填充。"""
    src = src.convert('RGBA')
    w, h = src.size
    side = min(w, h)
    left, top0 = (w - side) // 2, (h - side) // 2
    return src.crop((left, top0, left + side, top0 + side)).resize((size, size), Image.LANCZOS)


def write_resources(app_icon: Image.Image, background: Image.Image, foreground: Image.Image):
    app_icon.save(APP_ICON)
    background.save(BACKGROUND)
    foreground.save(FOREGROUND)
    app_icon.resize((216, 216), Image.LANCZOS).save(START_ICON)
    print('已写入图标资源：app_icon(1024) / background(1024) / foreground(1024) / startIcon(216)')


def apply_variant(name: str):
    top, bot, label = hex2rgb(VARIANTS[name][0]), hex2rgb(VARIANTS[name][1]), VARIANTS[name][2]
    bg = make_gradient(1024, top, bot)
    fg = make_globe(1024)
    write_resources(Image.alpha_composite(bg, fg), bg, fg)
    print(f'样式: {label} ({VARIANTS[name][0]} -> {VARIANTS[name][1]})')


def apply_image(path: str):
    if not os.path.isfile(path):
        sys.exit(f'图片不存在: {path}')
    src = Image.open(path)
    img = cover_crop(src, 1024)
    transparent = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    write_resources(img, img, transparent)
    print(f'自定义图标: {path}（分层前景置空，整图作背景，保证系统圆角裁切后完整显示）')


def run_build():
    """maxCount 临时改 5 编译，编完恢复（本地 hvigor schema 限制）。"""
    app_json5 = os.path.join(BASE, 'AppScope/app.json5')
    with open(app_json5, encoding='utf-8') as f:
        raw = f.read()
    modified = raw.replace('"maxCount": 10', '"maxCount": 5')
    with open(app_json5, 'w', encoding='utf-8', newline='\n') as f:
        f.write(modified)
    try:
        env = dict(os.environ)
        env['DEVECO_SDK_HOME'] = r'C://Program Files//Huawei//DevEco Studio//sdk'
        node = r'C:/Program Files/Huawei/DevEco Studio/tools/node/node.exe'
        hv = r'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js'
        jbr = r'C:/Program Files/Huawei/DevEco Studio/jbr/bin'
        env['PATH'] = env.get('PATH', '') + os.pathsep + jbr
        print('开始编译 assembleHap ...')
        r = subprocess.run([node, hv, '--mode', 'module', '-p', 'product=default',
                            'assembleHap', '--no-daemon'], cwd=BASE, env=env,
                           capture_output=True, text=True)
        out = (r.stdout or '') + (r.stderr or '')
        ok = 'BUILD SUCCESSFUL' in out
        print('BUILD SUCCESSFUL' if ok else 'BUILD FAILED（详见上方提示，可手动执行 hvigorw 查看日志）')
        if not ok:
            tail = [l for l in out.splitlines() if 'ERROR' in l or 'FAILED' in l][:10]
            print('\n'.join(tail))
    finally:
        with open(app_json5, 'w', encoding='utf-8', newline='\n') as f:
            f.write(raw)
    hap = os.path.join(BASE, 'entry/build/default/outputs/default/entry-default-unsigned.hap')
    if os.path.isfile(hap):
        print(f'hap 产物: {hap}')


def main():
    ap = argparse.ArgumentParser(description='fake_pwa 换图标重打包工具')
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--variant', choices=sorted(VARIANTS), help='内置图标样式')
    g.add_argument('--image', help='任意图片路径（网站 logo 等，自动裁切为 1024px）')
    ap.add_argument('--build', action='store_true', help='替换后立即编译 hap')
    args = ap.parse_args()

    if args.variant:
        apply_variant(args.variant)
    else:
        apply_image(args.image)
    if args.build:
        run_build()


if __name__ == '__main__':
    main()
