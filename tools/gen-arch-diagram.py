#!/usr/bin/env python3
"""
生成「零网络请求」架构图，供应用市场审核与算法备案咨询使用。

这张图要回答审核员的一个问题：应用到底在哪里联网？
答案必须一眼可见——图里根本没有网络这一层。

图中刻意画出：
  · 四层调用栈（ArkUI → 核心层 → NAPI → llama.cpp）
  · 左侧贯穿的「无网络」阻断带（虚线红框 + 拒绝标记）
  · 右侧的数据流：只有「用户自带 GGUF 文件」进来，「AI 文本」出去
  · 底部一行状态条：权限列表为空 / 第三方依赖为空 / 网络 API 命中 0

配色与 docs/store-assets/ 下的素材保持一致（暗色系），便于同一批提交。

用法:
  python3 tools/gen-arch-diagram.py
产物:
  docs/store-assets/arch-diagram.png       架构图（1920×1080）
  docs/store-assets/network-proof.png      权限与依赖举证截图（1600×2000）
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, 'docs', 'store-assets')

# 与 app 图标 / 现有素材同一套配色
BG = '#0B0E14'
SURFACE = '#151A23'
SURFACE_ALT = '#1C222D'
BORDER = '#252C39'
ACCENT = '#F2C14E'
TEXT = '#E8EAED'
TEXT_DIM = '#8B93A1'
TEXT_FAINT = '#5A6272'
GREEN = '#5FB878'
RED = '#E05C5C'
BLUE = '#5B9DD9'

FONT_CJK = r'C:\Windows\Fonts\msyh.ttc'
FONT_CJK_BOLD = r'C:\Windows\Fonts\msyhbd.ttc'
FONT_MONO = r'C:\Windows\Fonts\consola.ttf'


def _fonts():
    from PIL import ImageFont
    def f(path, size):
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            return ImageFont.load_default()
    return {
        'h1': f(FONT_CJK_BOLD, 44),
        'h2': f(FONT_CJK_BOLD, 30),
        'h3': f(FONT_CJK_BOLD, 24),
        'body': f(FONT_CJK, 20),
        'small': f(FONT_CJK, 17),
        'tiny': f(FONT_CJK, 15),
        'mono': f(FONT_MONO, 17),
        'mono_s': f(FONT_MONO, 15),
    }


def gen_arch_diagram(out_dir):
    """主架构图：分层调用栈 + 无网络阻断带 + 数据流。"""
    from PIL import Image, ImageDraw

    F = _fonts()
    W, H = 1920, 1080
    img = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(img)

    # ---- 标题 ----
    d.text((80, 56), '驼峰 CamelHump · 端侧推理架构', font=F['h1'], fill=TEXT)
    d.text((80, 116), 'HarmonyOS API 18 · 全部计算在设备 CPU 完成 · 无网络层',
           font=F['body'], fill=TEXT_DIM)
    d.line([(80, 160), (1840, 160)], fill=BORDER, width=2)

    # ---- 左侧「无网络」阻断带 ----
    BX0, BX1 = 80, 300
    d.rounded_rectangle([BX0, 196, BX1, 900], radius=14,
                        fill='#1A1214', outline=RED, width=3)
    # 斜纹填充带，强化「禁止」语义
    for i in range(0, 200, 22):
        d.line([(BX0 + i, 900), (BX0 + i + 60, 196)], fill='#3A1E22', width=2)
    d.rounded_rectangle([BX0, 196, BX1, 900], radius=14,
                        outline=RED, width=3)

    # 禁止标记
    cx, cy, r = (BX0 + BX1) // 2, 300, 42
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=RED, width=6)
    d.line([cx - r * 0.62, cy + r * 0.62, cx + r * 0.62, cy - r * 0.62],
           fill=RED, width=8)

    d.text((cx, 372), '无网络层', font=F['h3'], fill=RED, anchor='ma')
    for i, line in enumerate([
        '无 HTTP 客户端',
        '无 Socket 调用',
        '无第三方 SDK',
        '无 DNS 解析',
    ]):
        d.text((cx, 424 + i * 40), line, font=F['body'], fill=TEXT_DIM, anchor='ma')

    d.text((cx, 610), '操作系统层面', font=F['small'], fill=TEXT_FAINT, anchor='ma')
    d.text((cx, 638), '无法连接任何服务器', font=F['small'], fill=TEXT_FAINT, anchor='ma')
    d.text((cx, 700), '权限列表', font=F['small'], fill=TEXT_FAINT, anchor='ma')
    d.text((cx, 726), '（空）', font=F['h2'], fill=GREEN, anchor='ma')

    # ---- 右侧四层架构 ----
    LX0, LX1 = 348, 1840
    layers = [
        ('表现层  ArkTS / ArkUI',
         '对话页 · 模型管理页 · 设置页 · 首次运行隐私授权弹窗',
         'ChatView  ModelsView  SettingsView  PrivacyConsent', BLUE, 'mono'),
        ('核心层  ArkTS',
         'InferenceEngine（会话生命周期）  ModelRepository（导入·校验·清单·配额）',
         'AppStore  Config  ContextHolder  Logger  Theme', ACCENT, 'mono'),
        ('桥接层  NAPI',
         'napi_async_work 后台线程 + threadsafe function 回流',
         'libcamelhump.so  ->  llama_bridge.cpp', ACCENT, 'mono'),
        ('推理层  llama.cpp（MIT，静态链接）',
         'CPU 分块 prefill · KV cache Q8_0 · Flash Attention · 大核亲和线程池',
         'GgufInspector · 头部解析 · 完整性校验', GREEN, 'cjk'),
    ]
    top = 196
    lh = 168
    gap = 12
    for i, (title, desc, detail, color, dfont) in enumerate(layers):
        y0 = top + i * (lh + gap)
        y1 = y0 + lh
        d.rounded_rectangle([LX0, y0, LX1, y1], radius=12,
                            fill=SURFACE, outline=BORDER, width=2)
        # 左侧色条
        d.rounded_rectangle([LX0, y0, LX0 + 8, y1], radius=4, fill=color)

        d.text((LX0 + 34, y0 + 26), title, font=F['h2'], fill=TEXT)
        d.text((LX0 + 34, y0 + 78), desc, font=F['body'], fill=TEXT_DIM)
        # Consolas 无中文字形，含中文的细项行改用雅黑
        d.text((LX0 + 34, y0 + 118), detail,
               font=F['mono'] if dfont == 'mono' else F['small'],
               fill=TEXT_FAINT)

        # 层间箭头
        if i < len(layers) - 1:
            ax = (LX0 + LX1) // 2
            ay0 = y1 + 1
            ay1 = y1 + gap - 1
            d.line([(ax, ay0), (ax, ay1)], fill=TEXT_FAINT, width=2)
            d.polygon([(ax - 6, ay1 - 6), (ax + 6, ay1 - 6), (ax, ay1)], fill=TEXT_FAINT)

    # 右侧竖向数据流标注
    d.rounded_rectangle([LX0, 920, LX1, 986], radius=10,
                        fill=SURFACE_ALT, outline=BORDER, width=2)
    d.text((LX0 + 30, 940), '数据流：', font=F['small'], fill=TEXT_FAINT)
    d.text((LX0 + 110, 938), '用户自备 GGUF 文件', font=F['body'], fill=ACCENT)
    d.text((LX0 + 300, 938), '→', font=F['body'], fill=TEXT_FAINT)
    d.text((LX0 + 340, 938), '设备本地推理', font=F['body'], fill=TEXT)
    d.text((LX0 + 520, 938), '→', font=F['body'], fill=TEXT_FAINT)
    d.text((LX0 + 560, 938), 'AI 文本（仅显示在本机界面）', font=F['body'], fill=GREEN)

    # ---- 底部状态条 ----
    d.rounded_rectangle([80, 1000, 1840, 1046], radius=8, fill=SURFACE_ALT)
    stats = [
        ('权限声明', '0 条', GREEN),
        ('网络 API 命中', '0 处', GREEN),
        ('第三方依赖', '0 个', GREEN),
        ('离线可用', '是', GREEN),
    ]
    x = 110
    for label, val, color in stats:
        d.text((x, 1011), label, font=F['small'], fill=TEXT_FAINT)
        d.text((x + 110, 1006), val, font=F['h3'], fill=color)
        x += 430

    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, 'arch-diagram.png')
    img.save(path, 'PNG', optimize=True)
    print(f'  arch-diagram.png  {W}×{H}  {os.path.getsize(path) / 1024:.0f} KB')
    return path


def gen_network_proof(out_dir):
    """举证截图：module.json5 全文 + 权限/依赖核查结论。"""
    from PIL import Image, ImageDraw

    F = _fonts()
    W, H = 1600, 2180
    img = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(img)

    d.text((70, 52), '举证材料 · 应用无任何网络请求能力', font=F['h1'], fill=TEXT)
    d.text((70, 116), 'CamelHump v1.1.1 · 包名 com.camelhump.app · HarmonyOS API 18',
           font=F['body'], fill=TEXT_DIM)
    d.line([(70, 162), (W - 70, 162)], fill=BORDER, width=2)

    # ---- 代码块：module.json5 全文 ----
    CODE = [
        ('{', TEXT_DIM),
        ('  "module": {', TEXT),
        ('    "name": "entry",', TEXT),
        ('    "type": "entry",', TEXT),
        ('    "description": "$string:module_desc",', TEXT),
        ('    "mainElement": "EntryAbility",', TEXT),
        ('    "deviceTypes": ["phone", "tablet", "2in1"],', TEXT),
        ('    "deliveryWithInstall": true,', TEXT),
        ('    "installationFree": false,', TEXT),
        ('    "pages": "$profile:main_pages",', TEXT),
        ('    "abilities": [{', TEXT),
        ('      "name": "EntryAbility",', TEXT),
        ('      "srcEntry": "./ets/entryability/EntryAbility.ets",', TEXT),
        ('      "description": "$string:EntryAbility_desc",', TEXT),
        ('      "icon": "$media:app_icon",', TEXT),
        ('      "label": "$string:EntryAbility_label",', TEXT),
        ('      "startWindowIcon": "$media:startIcon",', TEXT),
        ('      "startWindowBackground": "$color:start_window_background",', TEXT),
        ('      "exported": true,', TEXT),
        ('      "launchType": "singleton",', TEXT),
        ('      "skills": [{', TEXT),
        ('        "entities": ["entity.system.home"],', TEXT),
        ('        "actions": ["action.system.home"]', TEXT),
        ('      }]', TEXT),
        ('    }]', TEXT),
        ('  }', TEXT),
        ('}', TEXT_DIM),
    ]

    d.text((70, 196), 'entry/src/main/module.json5（全文）', font=F['h3'], fill=TEXT)
    bx0, by0 = 70, 244
    # 代码块底
    d.rounded_rectangle([bx0, by0, W - 70, by0 + 40 + len(CODE) * 33],
                        radius=10, fill='#0D1017', outline=BORDER, width=2)
    y = by0 + 22
    for line, color in CODE:
        d.text((bx0 + 26, y), line, font=F['mono'], fill=color)
        y += 33

    # 高亮注释：本文件不含 requestPermissions
    hy = by0 + 22 + len(CODE) * 33 + 18
    d.rounded_rectangle([bx0, hy, W - 70, hy + 108], radius=10,
                        fill='#141A20', outline=GREEN, width=2)
    # 雅黑缺少 ✓ 字形，用矢量勾画，避免渲染成方框
    gx, gy = bx0 + 40, hy + 38
    d.line([(gx - 9, gy), (gx - 2, gy + 8), (gx + 11, gy - 9)],
           fill=GREEN, width=5, joint='curve')
    d.text((bx0 + 68, hy + 20), '本文件不含 requestPermissions 字段',
           font=F['h3'], fill=GREEN)
    d.text((bx0 + 26, hy + 62),
           '未申请 ohos.permission.INTERNET，未申请 ohos.permission.GET_NETWORK_INFO，'
           '未申请任何其他系统权限。', font=F['small'], fill=TEXT_DIM)

    # ---- 核查结论表 ----
    ty = hy + 140
    d.text((70, ty), '全仓库静态核查结论', font=F['h3'], fill=TEXT)
    ty += 46

    rows = [
        ('核查项', '核查方法 / 范围', '结论', True),
        ('网络 API 调用',
         '全仓检索 HTTP / Socket / WebSocket / fetch / XMLHttpRequest',
         '0 处命中', False),
        ('网络 Kit 引用',
         '全仓 import 清单：ArkData、AbilityKit、ArkUI、CoreFileKit 等 6 个系统 Kit',
         '未引入 NetworkKit', False),
        ('第三方依赖',
         'oh-package.json5 → dependencies: {}',
         '0 个', False),
        ('原生层网络代码',
         'entry/src/main/cpp 检索 socket / curl / http / getaddrinfo',
         '0 处命中', False),
        ('权限声明',
         '全仓 *.json5 / *.json 检索 ohos.permission',
         '0 条声明', False),
        ('文件导出能力',
         '全仓检索导出 / 分享 / 下载接口',
         '不提供，无对外产出文件', False),
    ]

    cols = [90, 350, 1150]
    for i, (c1, c2, c3, header) in enumerate(rows):
        rh = 76 if i else 48
        y0 = ty
        bg = SURFACE_ALT if header else (SURFACE if i % 2 else '#101419')
        d.rectangle([70, y0, W - 70, y0 + rh], fill=bg)
        d.text((cols[0], y0 + 12), c1, font=F['h3'] if header else F['body'],
               fill=TEXT if header else TEXT)
        d.text((cols[1], y0 + 12), c2, font=F['h3'] if header else F['small'],
               fill=TEXT if header else TEXT_DIM)
        d.text((cols[2], y0 + 12), c3, font=F['h3'] if header else F['body'],
               fill=GREEN)
        d.line([(70, y0 + rh), (W - 70, y0 + rh)], fill=BORDER, width=1)
        ty += rh
    d.rectangle([70, ty - 76 - 48 + 76, W - 70, ty], outline=BORDER, width=1)

    # ---- 结论 ----
    cy = ty + 40
    d.rounded_rectangle([70, cy, W - 70, cy + 150], radius=10,
                        fill='#131A16', outline=GREEN, width=2)
    d.text((98, cy + 24), '结论', font=F['h3'], fill=GREEN)
    for i, line in enumerate([
        '应用在操作系统层面不具备联网能力：无网络权限、无网络 API、无网络依赖。',
        '全部推理计算由设备 CPU 本地完成；用户输入与模型输出不出设备、无服务端。',
        '因此本应用不属于「向境内公众提供生成式人工智能服务」，不涉及算法备案。',
    ]):
        d.text((98, cy + 64 + i * 32), line, font=F['body'], fill=TEXT)

    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, 'network-proof.png')
    img.save(path, 'PNG', optimize=True)
    print(f'  network-proof.png  {W}×{H}  {os.path.getsize(path) / 1024:.0f} KB')
    return path


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print('生成架构图与举证截图...')
    gen_arch_diagram(OUT_DIR)
    gen_network_proof(OUT_DIR)
    print('完成。')


if __name__ == '__main__':
    sys.exit(main())
