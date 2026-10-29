#!/usr/bin/env python3
"""
把界面预览 HTML 渲染成图片，供软著用户手册与上架素材使用。

软著要求「文档中出现的截图须反映软件真实界面」，因此插图必须与
ArkTS 代码里的实际布局一致 —— 预览 HTML 就是按真实配色与布局复刻的。

用法:
  python3 tools/gen-screenshots.py [--html 预览HTML] [--out 输出目录]
"""
import argparse
import asyncio
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 预览 HTML 里每个手机外壳的顺序对应应用三个主页面
SCREENSHOTS = [
    ('screen-chat', '对话界面'),
    ('screen-models', '模型管理界面'),
    ('screen-settings', '设置界面'),
]


async def capture(html_path, out_dir):
    from playwright.async_api import async_playwright

    os.makedirs(out_dir, exist_ok=True)
    html_abs = os.path.abspath(html_path)
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=['--no-sandbox', '--font-render-hinting=none'])
        page = await browser.new_page(viewport={'width': 1400, 'height': 1000},
                                      device_scale_factor=2)
        await page.goto(f'file://{html_abs}')
        await page.wait_for_timeout(1200)

        phones = await page.query_selector_all('.phone')
        print(f'找到 {len(phones)} 个界面')

        results = []
        for idx, (name, title) in enumerate(SCREENSHOTS):
            if idx >= len(phones):
                print(f'跳过 {name}：预览中只有 {len(phones)} 个界面')
                break
            out = os.path.join(out_dir, f'{name}.png')
            await phones[idx].screenshot(path=out)
            results.append((name, title, out))
            print(f'  {name}.png  <- {title}')

        # 整页图（用于文档封面/附录）
        full = os.path.join(out_dir, 'screen-all.png')
        await page.screenshot(path=full, full_page=True)
        print(f'  screen-all.png <- 全部界面')

        await browser.close()
        return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--html', default='/workspace/CamelHump-preview.html')
    ap.add_argument('--out', default=os.path.join(ROOT, 'docs', 'copyright', 'screenshots'))
    args = ap.parse_args()

    if not os.path.exists(args.html):
        print(f'找不到预览 HTML: {args.html}', file=sys.stderr)
        return 1

    asyncio.run(capture(args.html, args.out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
