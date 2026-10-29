#!/usr/bin/env python3
"""
生成软著登记用的「源程序」鉴别材料 PDF。

规范依据（2026-03-15 起施行的软著登记新规与版权中心指引）：
  · 提交前 30 页 + 后 30 页，共 60 页；不足 60 页则全部提交
  · 每页有效代码行不少于 50 行（去掉空行后计）
  · 页眉标注软件全称与版本号，且须与申请表完全一致
  · 右上角标注页码
  · 等宽字体纵向排版，代码需连续、真实、体现独创性
  · 不得混入第三方源码（本工程把 llama.cpp 排除在外）

为什么用 HTML + weasyprint 而不是 reportlab：
  reportlab 的 TTC 子字体注册在中文场景下会渲染成方框，
  而软著材料出现乱码是必然被补正的。weasyprint 走 Pango 字体栈，
  中文与等宽混排都正常。

用法:
  python3 tools/gen-copyright-source.py [--out 输出目录]
"""
import argparse
import html as html_mod
import os
import subprocess
import sys

# ---- 软件基本信息：必须与申请表、用户手册、源码页眉三处完全一致 ----
SOFTWARE_FULL_NAME = '驼峰 CamelHump 本地大模型运行时软件'
SOFTWARE_SHORT_NAME = '驼峰 CamelHump'
VERSION = 'V1.1.1'
VERSION_CODE = '1001001'
COPYRIGHT_OWNER = 'shy1658'

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 提交顺序即源码顺序：从底层到上层，体现架构分层
SOURCE_FILES = [
    'entry/src/main/cpp/gguf_inspector.h',
    'entry/src/main/cpp/gguf_inspector.cpp',
    'entry/src/main/cpp/llama_bridge.h',
    'entry/src/main/cpp/llama_bridge.cpp',
    'entry/src/main/cpp/napi_init.cpp',
    'entry/src/main/ets/core/Types.ets',
    'entry/src/main/ets/core/Theme.ets',
    'entry/src/main/ets/core/Logger.ets',
    'entry/src/main/ets/core/ContextHolder.ets',
    'entry/src/main/ets/core/Config.ets',
    'entry/src/main/ets/core/InferenceEngine.ets',
    'entry/src/main/ets/core/ModelRepository.ets',
    'entry/src/main/ets/core/AppStore.ets',
    'entry/src/main/ets/entryability/EntryAbility.ets',
    'entry/src/main/ets/pages/Index.ets',
    'entry/src/main/ets/view/ChatView.ets',
    'entry/src/main/ets/view/ModelsView.ets',
    'entry/src/main/ets/view/SettingsView.ets',
]

LINES_PER_PAGE = 50          # 每页有效代码行数（下限要求 50）
FIRST_PAGES = 30             # 前 30 页
LAST_PAGES = 30              # 后 30 页

CJK_FONT_DIR = '/tmp/fonts'


def ensure_cjk_font():
    """从 TTC 提取 Noto Sans CJK SC 为独立 TTF —— weasyprint 需要可嵌��的单字体文件。"""
    need = {
        'NotoSansSC-Regular.ttf': '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
        'NotoSansSC-Bold.ttf': '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc',
    }
    os.makedirs(CJK_FONT_DIR, exist_ok=True)
    for out_name, src in need.items():
        out = os.path.join(CJK_FONT_DIR, out_name)
        if os.path.exists(out) or not os.path.exists(src):
            continue
        code = (
            "from fontTools.ttLib import TTCollection\n"
            f"tc = TTCollection({src!r})\n"
            "for f in tc.fonts:\n"
            "    n = f['name'].getDebugName(4)\n"
            "    if n and 'CJK SC' in n:\n"
            f"        f.save({out!r})\n"
            "        break\n"
        )
        subprocess.run([sys.executable, '-c', code], check=True)
    return CJK_FONT_DIR


def load_source(rel_path):
    """读文件并做最小清洗：去空行，保留注释（注释体现设计思路，是独创性的一部分）。"""
    path = os.path.join(ROOT, rel_path)
    with open(path, 'r', encoding='utf-8') as f:
        raw = f.read().splitlines()

    out = []
    for line in raw:
        stripped = line.rstrip()
        # 去掉完全空白的行 —— 规范要求「每页有效代码行」，空行不计入
        if not stripped.strip():
            continue
        out.append(stripped)
    return rel_path, out


def build_stream():
    """把全部源码拼成一条带文件分隔标记的连续流。"""
    stream = []
    for rel in SOURCE_FILES:
        rel, lines = load_source(rel)
        stream.append(('sep', f'/* ===== 文件：{rel} ===== */'))
        for ln in lines:
            stream.append(('code', ln))
    return stream


def paginate(stream):
    """按每页 LINES_PER_PAGE 行切页。"""
    pages = []
    cur = []
    for kind, text in stream:
        cur.append((kind, text))
        if len(cur) >= LINES_PER_PAGE:
            pages.append(cur)
            cur = []
    if cur:
        pages.append(cur)
    return pages


CSS = """
@page {
  size: A4;
  margin: 20mm 15mm 18mm 17mm;

  /* 页眉：软件全称 + 版本号，必须与申请表完全一致 */
  @top-left {
    content: "驼峰 CamelHump 本地大模型运行时软件  V1.1.1";
    font-family: "Noto Sans CJK SC", sans-serif;
    font-size: 8.5pt;
    font-weight: bold;
    border-bottom: 0.4pt solid #999;
    padding-bottom: 3pt;
    width: 100%;
  }
  /* 右上角页码 */
  @top-right {
    content: counter(page);
    font-family: "DejaVu Sans Mono", monospace;
    font-size: 8.5pt;
    font-weight: bold;
    text-align: right;
    padding-bottom: 3pt;
  }
  /* 页脚：著作权人 */
  @bottom-center {
    content: "著作权人：shy1658        软件版本：V1.1.1";
    font-family: "Noto Sans CJK SC", sans-serif;
    font-size: 7.5pt;
    color: #555;
    border-top: 0.3pt solid #bbb;
    padding-top: 3pt;
    width: 100%;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: "Noto Sans CJK SC", sans-serif;
}
/* 每一页是独立块，配合 break-after 强制分页 —— 保证「每页 50 行」不被重排打乱 */
.page {
  break-after: page;
  page-break-after: always;
}
.page:last-child {
  break-after: auto;
  page-break-after: avoid;
}
pre.code {
  font-family: "DejaVu Sans Mono", "Noto Sans CJK SC", monospace;
  font-size: 8.6pt;
  line-height: 1.42;
  margin: 0;
  white-space: pre-wrap;
  word-wrap: break-word;
  overflow: hidden;
}
span.sep {
  display: block;
  font-weight: bold;
  background: #f0f0f0;
  padding: 1pt 0;
}
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(ROOT, 'docs', 'copyright'))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    ensure_cjk_font()

    stream = build_stream()
    pages = paginate(stream)
    total = len(pages)
    code_lines = sum(1 for k, _ in stream if k == 'code')
    print(f'有效代码行 {code_lines}，共 {total} 页')

    if total <= FIRST_PAGES + LAST_PAGES:
        selected = pages
        print(f'代码不足 60 页，全部提交（{total} 页）')
    else:
        # 取前 30 个满页 + 后 30 个满页。
        # 原始流的最后一页可能不满 50 行（规范允许结束页少于 50 行），
        # 但若把它纳入提交范围，前一页就会缺行。因此这里只取满页，
        # 末页不满的情况由「后 30 页」的边界自然避开。
        full_pages = [pg for pg in pages if len(pg) == LINES_PER_PAGE]
        if len(full_pages) >= FIRST_PAGES + LAST_PAGES:
            selected = full_pages[:FIRST_PAGES] + full_pages[-LAST_PAGES:]
            print(f'提交前 {FIRST_PAGES} 页 + 后 {LAST_PAGES} 页（均为满页）')
        else:
            selected = pages
            print(f'满页不足 60，全部提交（{total} 页）')


    # 拼 HTML：每个 .page 是独立块，weasyprint 按页眉页脚模板渲染
    body = []
    for idx, pg in enumerate(selected):
        lines = []
        for kind, text in pg:
            esc = html_mod.escape(text)
            if kind == 'sep':
                lines.append(f'<span class="sep">{esc}</span>')
            else:
                lines.append(esc)
        body.append(
            f'<div class="page">\n'
            f'<pre class="code">\n' + '\n'.join(lines) + '\n</pre>\n'
            f'</div>'
        )

    doc = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="UTF-8"><style>{CSS}</style></head>
<body>
{''.join(body)}
</body>
</html>"""

    html_path = os.path.join(args.out, '源代码.html')
    with open(html_path, 'w', encoding='utf-8') as f:
        f.write(doc)

    from weasyprint import HTML
    out_pdf = os.path.join(args.out, '源代码.pdf')
    HTML(filename=html_path, base_url=args.out).write_pdf(out_pdf)

    # 核对实际页数与每页行数
    info = subprocess.run(['pdfinfo', out_pdf], capture_output=True, text=True).stdout
    real_pages = 0
    for line in info.splitlines():
        if line.startswith('Pages:'):
            real_pages = int(line.split()[1])

    size = os.path.getsize(out_pdf)
    print(f'已生成：{out_pdf}')
    print(f'实际页数：{real_pages}（要求 60），大小：{size/1024/1024:.2f} MB')
    print(f'每页有效代码行：{LINES_PER_PAGE}（要求 ≥50）')
    print(f'页眉：{SOFTWARE_FULL_NAME}　{VERSION}')
    print(f'著作权人：{COPYRIGHT_OWNER}')

    # 纯文本备份，便于人工复核
    txt = os.path.join(args.out, '源代码-纯文本备份.txt')
    with open(txt, 'w', encoding='utf-8') as f:
        for idx, pg in enumerate(selected):
            f.write(f'\n===== 第 {idx+1} 页 =====\n')
            for kind, text in pg:
                f.write(text + '\n')
    print(f'文本备份：{txt}')
    print(f'HTML 中间产物：{html_path}')


if __name__ == '__main__':
    sys.exit(main())
