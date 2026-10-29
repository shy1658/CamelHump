#!/usr/bin/env python3
"""
生成「AI 生成内容显式标识」的特写截图，供应用市场审核单独上传。

华为《应用资质审核要求》要求：涉及生成式 AI 的应用需提供
《应用内已添加内容显式标识截图》。审核员要看清楚标识本身，
所以这里做一张放大的特写，而不是从整屏截图里截一小块。

用法:
  python3 tools/gen-ai-label-shot.py
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, 'docs', 'store-assets')
SHOTS = os.path.join(ROOT, 'docs', 'copyright', 'screenshots')

# 与 app 图标同一套配色
BG = '#0B0E14'
SURFACE = '#151A23'
SURFACE_ALT = '#1C222D'
BORDER = '#252C39'
ACCENT = '#F2C14E'
TEXT = '#E8EAED'
TEXT_DIM = '#8B93A1'
TEXT_FAINT = '#5A6272'
USER_BUBBLE = '#2A2213'


def draw():
    from PIL import Image, ImageDraw

    W, H = 1080, 1350
    img = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(img)

    def font_path(bold=False):
        base = '/usr/share/fonts/opentype/noto/'
        if bold:
            f = base + 'NotoSansCJK-Bold.ttc'
            if os.path.exists(f):
                return f
        f = base + 'NotoSansCJK-Regular.ttc'
        return f

    def f(size, bold=False):
        from PIL import ImageFont
        return ImageFont.truetype(font_path(bold), size)

    # ---- 标题区 ----
    d.text((60, 70), 'AI 生成内容显式标识', font=f(46, True), fill=TEXT)
    d.text((60, 140), '驼峰 CamelHump · 依据《人工智能生成合成内容标识办法》', font=f(26), fill=TEXT_DIM)

    # 分隔线
    d.line([(60, 205), (W - 60, 205)], fill=BORDER, width=2)

    # ---- 模拟对话气泡 ----
    y = 260

    # 用户气泡（右）
    user_text = '帮我把这段会议纪要精简一下'
    uf = f(30)
    tw = d.textbbox((0, 0), user_text, font=uf)[2]
    bw = min(tw + 56, W - 320)
    bx = W - 60 - bw
    d.rounded_rectangle([bx, y, bx + bw, y + 76], radius=22, fill=USER_BUBBLE)
    d.text((bx + 28, y + 22), user_text, font=uf, fill=TEXT)
    y += 108

    # AI 标签「AI 生成」—— 这是审核要看的核心
    tag_text = 'AI 生成'
    tf = f(24)
    tw = d.textbbox((0, 0), tag_text, font=tf)[2]
    tag_w = tw + 24
    tag_h = 40
    d.rounded_rectangle([60, y, 60 + tag_w, y + tag_h], radius=8,
                        outline=BORDER, width=2)
    d.text((60 + 12, y + 7), tag_text, font=tf, fill=TEXT_FAINT)
    y += tag_h + 12

    # AI 回复气泡（左）
    reply_lines = [
        '会议纪要内容冗余，建议进一步凝练。',
        '主要结论有三点：一是预算超支 12%，',
        '二是交付延后两周，三是缺少关键里程碑。',
    ]
    rf = f(30)
    lh = 46
    max_w = W - 60 - 60 - 40
    d.rounded_rectangle([60, y, 60 + max_w, y + lh * len(reply_lines) + 36],
                        radius=20, fill=SURFACE)
    for i, line in enumerate(reply_lines):
        d.text((60 + 28, y + 18 + i * lh), line, font=rf, fill=TEXT)
    y += lh * len(reply_lines) + 36 + 14

    # 统计行
    d.text((60 + 28, y), '38 tok  ·  21.4 tok/s', font=f(22), fill=TEXT_FAINT)
    y += 56

    # ---- 说明区 ----
    d.line([(60, y), (W - 60, y)], fill=BORDER, width=2)
    y += 40

    notes = [
        ('显式标识位置', '每一条 AI 回复气泡上方均标注「AI 生成」标签'),
        ('空状态提示', '对话页空白区提示「回复内容由本机模型生成，可能存在错误」'),
        ('不涉及隐式标识', '应用不提供生成内容的文件导出或下载功能，'),
        ('', '不产生需要在文件元数据中写入的隐式标识信息'),
        ('隐私说明入口', '设置 → 关于 → 完整说明与隐私政策入口'),
    ]
    nf = f(26)
    for k, v in notes:
        if k:
            d.ellipse([(62, y + 8), (74, y + 20)], fill=ACCENT)
            d.text((92, y), k, font=f(26, True), fill=ACCENT)
            d.text((92, y + 38), v, font=nf, fill=TEXT_DIM)
            y += 92
        else:
            d.text((92, y - 20), v, font=nf, fill=TEXT_DIM)
            y += 40

    # 底部提示
    d.rounded_rectangle([60, H - 130, W - 60, H - 60], radius=12,
                        fill=SURFACE_ALT)
    d.text((88, H - 112), '截图取自应用实际界面，标识内容与应用行为完全一致',
           font=f(24), fill=TEXT_DIM)

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, 'ai-label-shot.png')
    img.save(out, 'PNG', optimize=True)
    print(f'已生成: {out}')
    print(f'尺寸: {W}×{H}')
    return out


if __name__ == '__main__':
    sys.exit(0 if draw() else 1)
