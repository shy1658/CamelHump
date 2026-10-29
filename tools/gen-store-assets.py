#!/usr/bin/env python3
"""
生成华为应用市场上架所需的素材包。

规格依据（华为官方《素材规范》HarmonyOS 应用 · 手机/平板）：
  · 应用图标：216×216 或 1024×1024 px，PNG ≤3MB，非动图，正方形
  · 应用介绍截图：3–10 张
      横向 16:9 1920×1080  /  竖向 9:16 1080×1920，PNG/JPG ≤5MB
  · 应用介绍视频（可选）：横向 1280×720 / 竖向 720×1280，15 秒–2 分钟

注意：450×800 与 800×450 是**路由器应用**的规格，手机应用不适用。

产物位于 docs/store-assets/：
  icon-216.png         上架用图标
  icon-512.png         上架用图标
  screenshot-01..03.png 竖版截图（450×800）
  screenshot-wide.png   横版截图（800×450）
  README.md            素材清单与提交说明

用法:
  python3 tools/gen-store-assets.py
"""
import argparse
import asyncio
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_SRC = 'AppScope/resources/base/media/app_icon.png'
PREVIEW_HTML = 'docs/copyright/界面预览.html'

# 截图顺序对应三个主页面
SCREENS = [
    ('对话', 'screen-chat.png'),
    ('模型', 'screen-models.png'),
    ('设置', 'screen-settings.png'),
]


def gen_icons(out_dir):
    """从 1024×1024 源图缩放出上架需要的两种尺寸。"""
    from PIL import Image
    src = os.path.join(ROOT, ICON_SRC)
    if not os.path.exists(src):
        print(f'找不到图标源文件: {src}', file=sys.stderr)
        return []

    im = Image.open(src).convert('RGBA')
    results = []
    for size in (216, 1024):
        # 用 LANCZOS 保证缩小后的边缘质量
        out = im.resize((size, size), Image.LANCZOS)
        path = os.path.join(out_dir, f'icon-{size}.png')
        out.save(path, 'PNG', optimize=True)
        kb = os.path.getsize(path) / 1024
        print(f'  icon-{size}.png  {size}×{size}  {kb:.0f} KB')
        if kb > 2048:
            print(f'    ⚠️ 超过 2MB 上限，需要压缩')
        results.append(path)
    return results


async def gen_screenshots(out_dir):
    """重新渲染预览 HTML，按 450×800 竖版与 800×450 横版输出。"""
    from playwright.async_api import async_playwright
    from PIL import Image

    html = os.path.join(ROOT, PREVIEW_HTML)
    if not os.path.exists(html):
        print(f'找不到预览 HTML: {html}', file=sys.stderr)
        return []

    results = []
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=['--no-sandbox', '--font-render-hinting=none'])
        page = await browser.new_page(viewport={'width': 1400, 'height': 1000},
                                      device_scale_factor=2)
        await page.goto(f'file://{os.path.abspath(html)}')
        await page.wait_for_timeout(1200)

        phones = await page.query_selector_all('.phone')
        for idx, (title, _) in enumerate(SCREENS):
            if idx >= len(phones):
                break
            # 先截手机外壳，再按上架规格缩放
            tmp = os.path.join(out_dir, f'_tmp-{idx}.png')
            await phones[idx].screenshot(path=tmp)

            im = Image.open(tmp).convert('RGB')
            # 竖版 1080×1920（9:16）：等比缩放后居中放置，背景与应用底色一致
            bg = (11, 14, 20)
            canvas = Image.new('RGB', (1080, 1920), bg)
            ratio = min(1080 / im.width, 1920 / im.height)
            resized = im.resize((int(im.width * ratio), int(im.height * ratio)), Image.LANCZOS)
            canvas.paste(resized, ((1080 - resized.width) // 2, (1920 - resized.height) // 2))
            out = os.path.join(out_dir, f'screenshot-{idx+1:02d}.png')
            canvas.save(out, 'PNG', optimize=True)
            kb = os.path.getsize(out) / 1024
            print(f'  screenshot-{idx+1:02d}.png  1080×1920  {kb:.0f}KB  {title}页')

            # 第一屏额外出一张横版
            if idx == 0:
                wide = Image.new('RGB', (1920, 1080), bg)
                r2 = min(1920 / im.width, 1080 / im.height)
                r2im = im.resize((int(im.width * r2), int(im.height * r2)), Image.LANCZOS)
                wide.paste(r2im, ((1920 - r2im.width) // 2, (1080 - r2im.height) // 2))
                wout = os.path.join(out_dir, 'screenshot-wide.png')
                wide.save(wout, 'PNG', optimize=True)
                print(f'  screenshot-wide.png  1920×1080  横版备用')

            os.remove(tmp)
            results.append(out)

        await browser.close()
    return results


README_TPL = """# 上架素材包

华为应用市场素材规格与本目录产物的对应关系。

## 应用图标

| 文件 | 尺寸 | 格式 | 说明 |
|---|---|---|---|
| `icon-216.png` | 216×216 | PNG | 首选上传尺寸 |
| `icon-512.png` | 512×512 | PNG | 备选 |

约束：PNG 格式、非动图、≤2MB。图标为全出血方形，四角无透明区域。

> ⚠️ 提交图标必须与应用安装后在桌面显示的图标、任务管理器「最近任务」中的图标
> **完全一致**。三者都用同一张源图生成，不会出现不一致。

## 应用截图

| 文件 | 尺寸 | 内容 |
|---|---|---|
| `screenshot-01.png` | 450×800 | 对话页 —— 流式输出、AI 生成标识、生成速度 |
| `screenshot-02.png` | 450×800 | 模型页 —— 模型列表、容量统计、导入入口 |
| `screenshot-03.png` | 450×800 | 设置页 —— 参数调节、系统提示词、关于区 |
| `screenshot-wide.png` | 800×450 | 横版备用（若需横屏展示） |

要求：3–8 张，当前提供 3 张竖版 + 1 张横版。截图不得包含其他应用市场标识。

> ⚠️ 华为审核会核对截图与实际功能的一致性。当前截图由界面预览文件渲染，
> **上架前建议用真机截图替换**，以确保与实际运行效果完全一致。
> 重新渲染：`python3 tools/gen-store-assets.py`

## 其他素材

- **隐私政策 URL**：<https://shy1658.github.io/CamelHump/privacy.html>（已上线，可直接填）
- **AI 生成内容显式标识截图**：`screenshot-01.png` 中已包含「AI 生成」标签，
  但审核要求的是**单独的截图**，建议单独截一张标识特写
- **应用名称**：驼峰
- **分类**：工具 → 效率
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(ROOT, 'docs', 'store-assets'))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    print('生成图标：')
    gen_icons(args.out)

    print('生成截图：')
    asyncio.run(gen_screenshots(args.out))

    with open(os.path.join(args.out, 'README.md'), 'w', encoding='utf-8') as f:
        f.write(README_TPL)

    print(f'\n素材包已生成：{args.out}')
    for f in sorted(os.listdir(args.out)):
        p = os.path.join(args.out, f)
        if os.path.isfile(p):
            print(f'  {f}  {os.path.getsize(p)/1024:.0f} KB')


if __name__ == '__main__':
    sys.exit(main())
