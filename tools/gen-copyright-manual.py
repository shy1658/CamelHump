#!/usr/bin/env python3
"""
生成软著登记用的「用户手册」PDF。

规范要点：
  · 用户手册 / 操作手册 / 设计说明书 任选一种
  · ≥15 页，每页 ≥30 行，图文结合
  · 含封面、目录、功能说明、界面截图、操作流程
  · 页眉标注软件名称与版本号，须与申请表、源代码页眉完全一致
  · 截图须反映软件真实界面

用法:
  python3 tools/gen-copyright-manual.py [--out 输出目录]
"""
import argparse
import base64
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SOFTWARE_FULL_NAME = '驼峰 CamelHump 本地大模型运行时软件'
VERSION = 'V1.1.1'
COPYRIGHT_OWNER = 'shy1658'
DEV_DATE = '2026 年 10 月 26 日'
FIRST_PUBLISH = '2026 年 10 月 26 日'


def img_b64(rel_path):
    """把截图转成 base64 data URI，直接内联进 HTML —— 避免 PDF 打包时的路径问题。"""
    path = os.path.join(ROOT, rel_path)
    if not os.path.exists(path):
        return None
    with open(path, 'rb') as f:
        return 'data:image/png;base64,' + base64.b64encode(f.read()).decode()


CSS = """
@page {
  size: A4;
  margin: 20mm 18mm 18mm 18mm;

  @top-left {
    content: "驼峰 CamelHump 本地大模型运行时软件  V1.1.1";
    font-family: "Noto Sans CJK SC", sans-serif;
    font-size: 8.5pt; font-weight: bold;
    border-bottom: 0.4pt solid #999; padding-bottom: 3pt; width: 100%;
  }
  @top-right {
    content: counter(page);
    font-family: "DejaVu Sans Mono", monospace;
    font-size: 8.5pt; font-weight: bold; text-align: right; padding-bottom: 3pt;
  }
  @bottom-center {
    content: "著作权人：shy1658        软件版本：V1.1.1";
    font-family: "Noto Sans CJK SC", sans-serif;
    font-size: 7.5pt; color: #555;
    border-top: 0.3pt solid #bbb; padding-top: 3pt; width: 100%;
  }
}
@page cover { margin: 0; @top-left { content: ""; } @top-right { content: ""; }
  @bottom-center { content: ""; } }

* { box-sizing: border-box; }
body { margin: 0; font-family: "Noto Sans CJK SC", sans-serif; font-size: 10.5pt;
       line-height: 1.85; color: #1a1a1a; }

h1 { font-size: 19pt; margin: 0 0 16pt; }
h2 { font-size: 14pt; margin: 22pt 0 9pt; padding-left: 9pt;
     border-left: 3.5pt solid #F2C14E; page-break-after: avoid; }
h3 { font-size: 11.5pt; margin: 14pt 0 6pt; color: #333; page-break-after: avoid; }
p { margin: 0 0 9pt; text-align: justify; orphans: 2; widows: 2; }
ul, ol { margin: 0 0 11pt; padding-left: 22pt; }
li { margin-bottom: 5pt; page-break-inside: avoid; }

.cover { page: cover; height: 297mm; display: flex; flex-direction: column;
         align-items: center; justify-content: center; text-align: center;
         background: #0B0E14; color: #E8EAED; page-break-after: always; }
.cover .mark { width: 62mm; height: 62mm; border-radius: 14mm;
               margin-bottom: 22mm; overflow: hidden; }
.cover .mark img { width: 100%; height: 100%; object-fit: cover;
                   display: block; }
.cover h1 { font-size: 30pt; color: #E8EAED; margin-bottom: 8pt; border: none; padding: 0; }
.cover .en { font-size: 14pt; color: #F2C14E; letter-spacing: 3pt; margin-bottom: 26mm; }
.cover .meta { font-size: 11pt; line-height: 2.4; color: #8B93A1; }
.cover .meta b { color: #E8EAED; font-weight: normal; }
.cover .ver { margin-top: 20mm; font-size: 12pt; color: #F2C14E; }

.toc { page-break-after: always; }
.toc ol { list-style: none; padding-left: 0; }
.toc li { padding: 5pt 0; border-bottom: 0.4pt dotted #ccc;
          display: flex; justify-content: space-between; }
.toc .num { color: #F2C14E; font-weight: bold; margin-right: 9pt;
            font-family: "DejaVu Sans Mono", monospace; }
.toc li { position: relative; }
.toc a { text-decoration: none; color: #1a1a1a; }
.toc a::after {
  content: target-counter(attr(href), page);
  position: absolute; right: 0; top: 0;
  font-family: "DejaVu Sans Mono", monospace; font-size: 10pt;
}

figure { margin: 13pt 0; text-align: center; page-break-inside: avoid; }
figure img { max-width: 108mm; border: 0.6pt solid #d5d5d5; border-radius: 3pt; }
figcaption { font-size: 9pt; color: #666; margin-top: 6pt; }

table { width: 100%; border-collapse: collapse; margin: 11pt 0 15pt; font-size: 9.5pt;
        page-break-inside: avoid; break-inside: avoid; }
th, td { border: 0.5pt solid #bbb; padding: 5pt 8pt; text-align: left; vertical-align: top; }
th { background: #f2f2f2; font-weight: bold; }
td code { background: #f4f4f4; padding: 0 3pt; font-size: 9pt;
          font-family: "DejaVu Sans Mono", monospace; }

.note { background: #fbf7ec; border-left: 3.5pt solid #F2C14E;
        padding: 9pt 13pt; margin: 12pt 0; font-size: 10pt; }
.note p:last-child { margin-bottom: 0; }
.code-block { background: #f6f6f6; border: 0.4pt solid #ddd; padding: 9pt 12pt;
              margin: 10pt 0; font-family: "DejaVu Sans Mono", monospace;
              font-size: 8.8pt; line-height: 1.55; white-space: pre-wrap; }
.pagebreak { page-break-before: always; }
"""


def build_html(shots, icon):
    def fig(key, caption):
        data = shots.get(key)
        if not data:
            return ''
        return (f'<figure><img src="{data}" alt="{caption}"/>'
                f'<figcaption>图 {caption}</figcaption></figure>')

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="UTF-8"><title>{SOFTWARE_FULL_NAME} 用户手册</title>
<style>{CSS}</style></head>
<body>

<!-- ============ 封面 ============ -->
<div class="cover">
  <div class="mark"><img src="{icon}" alt="应用图标"/></div>
  <h1>驼峰 CamelHump</h1>
  <div class="en">本地大模型运行时软件</div>
  <div class="meta">
    软件全称：<b>{SOFTWARE_FULL_NAME}</b><br/>
    版本号：<b>{VERSION}</b><br/>
    著作权人：<b>{COPYRIGHT_OWNER}</b><br/>
    开发完成日期：<b>{DEV_DATE}</b><br/>
    首次发表日期：<b>{FIRST_PUBLISH}</b><br/>
    开发语言：<b>ArkTS、C++</b><br/>
    运行平台：<b>HarmonyOS API 18 及以上</b>
  </div>
  <div class="ver">版本 {VERSION}</div>
</div>

<!-- ============ 目录 ============ -->
<div class="toc">
<h1>目　录</h1>
<ol>
  <li><a href="#sec-1"><span class="num">1.</span>软件概述</a></li>
  <li><a href="#sec-2"><span class="num">2.</span>运行环境与安装</a></li>
  <li><a href="#sec-3"><span class="num">3.</span>软件架构与功能模块</a></li>
  <li><a href="#sec-4"><span class="num">4.</span>模型管理功能说明</a></li>
  <li><a href="#sec-5"><span class="num">5.</span>对话功能说明</a></li>
  <li><a href="#sec-6"><span class="num">6.</span>参数设置功能说明</a></li>
  <li><a href="#sec-7"><span class="num">7.</span>隐私与数据保护</a></li>
  <li><a href="#sec-8"><span class="num">8.</span>技术实现要点</a></li>
  <li><a href="#sec-9"><span class="num">9.</span>常见问题与故障排除</a></li>
  <li><a href="#sec-10"><span class="num">10.</span>软件著作权与开源许可</a></li>
</ol>
</div>

<!-- ============ 1 软件概述 ============ -->
<h1 id="sec-1">一、软件概述</h1>

<h2>1.1 编写目的</h2>
<p>本手册是《{SOFTWARE_FULL_NAME}》（以下简称"本软件"）的用户操作说明书，
用于说明本软件的运行环境、安装方法、功能构成、界面操作方式以及技术实现要点。
阅读本手册后，用户应能独立完成模型导入、参数配置与本地对话的全部操作。</p>

<h2>1.2 软件简介</h2>
<p>本软件是一款运行于 HarmonyOS 终端的本地大模型推理运行时工具。
与常见的云端 AI 助手不同，本软件采用纯端侧离线架构：用户自行导入 GGUF 格式的
模型权重文件后，全部推理计算由设备 CPU 现场完成。软件运行期间不发起任何网络请求，
不申请网络访问权限，不注册账号体系，用户输入的对话内容与导入的模型文件始终保留在
终端本地的应用私有沙箱目录内。</p>
<p>软件内置了基于 llama.cpp 的推理引擎，支持 GGUF 格式的多种量化变体，
并针对移动设备的内存与功耗约束实现了 KV 缓存量化、Flash Attention、
大核亲和性线程池与提示词前缀复用四项优化。软件同时遵循
《人工智能生成合成内容标识办法》的要求，对模型生成的回复内容进行显式标识。</p>

<h2>1.3 术语约定</h2>
<table>
  <tr><th>术语</th><th>说明</th></tr>
  <tr><td>GGUF</td><td>大语言模型权重的文件格式，本软件仅支持该格式</td></tr>
  <tr><td>量化</td><td>将模型权重压缩为低精度表示以降低内存占用的技术</td></tr>
  <tr><td>KV 缓存</td><td>推理过程中缓存键值张量的结构，其占用随上下文长度线性增长</td></tr>
  <tr><td>prefill</td><td>将提示词一次性送入模型并计算首个词元的过程</td></tr>
  <tr><td>decode</td><td>自回归逐词元生成回复的过程</td></tr>
  <tr><td>Flash Attention</td><td>减少注意力中间量显存往返的优化技术</td></tr>
</table>

<!-- ============ 2 运行环境 ============ -->
<h1 id="sec-2" class="pagebreak">二、运行环境与安装</h1>

<h2>2.1 硬件与系统要求</h2>
<table>
  <tr><th>项目</th><th>最低要求</th><th>推荐配置</th></tr>
  <tr><td>操作系统</td><td>HarmonyOS API 18</td><td>HarmonyOS 5.0 及以上</td></tr>
  <tr><td>内存</td><td>6 GB</td><td>8 GB 及以上</td></tr>
  <tr><td>存储</td><td>预留 2 GB（取决于模型大小）</td><td>预留 8 GB</td></tr>
  <tr><td>处理器</td><td>支持 64 位指令集的 ARM 处理器</td><td>支持 NEON 向量扩展</td></tr>
</table>
<p>关于内存规格的说明：运行 0.5B 量化模型约需 1.5 GB 内存，
运行 1.5B 量化模型约需 3 GB 内存，运行时长还取决于所设置的上下文长度与最大输出长度。</p>

<h2>2.2 安装步骤</h2>
<ol>
  <li>获取安装包文件 <code>CamelHump-1.1.1.hap</code>。</li>
  <li>将文件传输至终端，可通过数据线、网盘或即时通讯工具的文件传输功能。</li>
  <li>打开终端自带的「文件管理」应用，在下载目录中点击该文件。</li>
  <li>首次安装时，系统提示需允许「安装未知来源应用」，按提示进入设置并授权。</li>
  <li>安装完成后，桌面出现名为「驼峰」的应用图标，点击启动。</li>
</ol>

<div class="note">
<p><strong>提示：</strong>本软件不要求任何系统权限。安装与运行过程中若出现权限申请提示，
均非本软件发起，可直接拒绝。</p>
</div>

<h2>2.3 模型文件准备</h2>
<p>本软件不提供模型下载功能。用户需自行获取 GGUF 格式的模型文件，
建议从模型发布方的官方渠道下载，并确认其许可协议允许所计划的使用方式。
将模型文件传输至终端后，通过应用内的文件选择器导入即可。</p>
<p>推荐的入门模型规格如下表所示：</p>
<table>
  <tr><th>模型规格</th><th>文件大小</th><th>内存占用</th><th>适用场景</th></tr>
  <tr><td>0.5B · Q4_K_M</td><td>约 400 MB</td><td>约 1.5 GB</td><td>6 GB 内存设备的基础问答</td></tr>
  <tr><td>1.5B · Q4_K_M</td><td>约 1.1 GB</td><td>约 3 GB</td><td>日常对话、摘要与改写</td></tr>
  <tr><td>1.5B · Q8_0</td><td>约 1.9 GB</td><td>约 3.5 GB</td><td>对输出质量有要求的场景</td></tr>
</table>

<!-- ============ 3 架构 ============ -->
<h1 id="sec-3" class="pagebreak">三、软件架构与功能模块</h1>

<h2>3.1 总体架构</h2>
<p>本软件采用分层架构，自上而下依次为表现层、逻辑层、接口层与执行层，
各层之间通过明确定义的接口通信，层内模块不直接依赖其他层的内部实现。</p>
<div class="code-block">┌──────────────────────────────────────────────┐
│  ArkTS / ArkUI 表现层                │
│  对话页　　模型页　　设置页                     │
├──────────────────────────────────────────────┤
│  逻辑层                                        │
│  会话生命周期　模型仓库　全局状态　参数配置        │
├──────────────────────────────────────────────┤
│  接口层                                        │
│  NAPI 异步任务　线程安全函数                     │
├──────────────────────────────────────────────┤
│  执行层                                        │
│  llama.cpp 推理引擎　GGUF 头部解析器              │
│  分块预填充　流式反分词                          │
└──────────────────────────────────────────────┘</div>

<h2>3.2 功能模块划分</h2>
<table>
  <tr><th>模块</th><th>主要职责</th></tr>
  <tr><td>推理引擎封装</td><td>模型加载、上下文管理、逐词元生成、流式输出、中止控制</td></tr>
  <tr><td>GGUF 解析器</td><td>解析模型头部，识别架构、量化格式、上下文长度，校验文件完整性</td></tr>
  <tr><td>模型仓库</td><td>模型导入、复制校验、清单维护、容量统计、删除</td></tr>
  <tr><td>会话管理</td><td>多轮对话上下文构建、提示词模板选择、KV 缓存复用</td></tr>
  <tr><td>参数配置</td><td>上下文长度、线程数、采样参数、系统提示词等</td></tr>
  <tr><td>表现层</td><td>三个主页面、状态同步、错误提示、AI 生成内容标识</td></tr>
</table>

<h2>3.3 与桌面端工具的差异</h2>
<p>本软件在设计时移除了桌面端同类工具依赖的三项前提条件，
用可恢复的前台运行模型替代常驻守护进程。</p>
<table>
  <tr><th>桌面端依赖</th><th>本软件的替代方案</th></tr>
  <tr><td>常驻后台服务</td><td>模型在用户可见的前台完成加载，生成过程中可随时中止</td></tr>
  <tr><td>长期后台运行权限</td><td>不申请后台长时任务权限，符合终端管控策略</td></tr>
  <tr><td>包管理器与依赖安装</td><td>推理引擎已编译进安装包，用户无需额外安装</td></tr>
</table>

<!-- ============ 4 模型管理 ============ -->
<h1 id="sec-4">四、模型管理功能说明</h1>

<h2>4.1 功能概述</h2>
<p>模型管理页用于导入、维护与切换本地模型。所有模型文件保存在应用私有沙箱目录内，
卸载应用即一并清除。页面顶部状态卡显示当前模型与加载状态，
并列出引擎实际生效的优化配置。</p>

{fig('models', '模型管理界面')}

<h2>4.2 导入模型</h2>
<ol>
  <li>进入模型管理页，点击右上角的「导入 GGUF」。</li>
  <li>在系统文件选择器中定位并选中目标 GGUF 文件。</li>
  <li>软件随即复制文件至私有沙箱目录，复制过程中显示进度。</li>
  <li>复制完成后进入文件完整性校验：解析模型头部，累加张量表声明的字节数，
      与文件实际大小比对。若中途下载不完整导致文件缺失，此处会拒绝导入并提示原因。</li>
  <li>校验通过后自动加载模型，加载成功后跳转至对话页。</li>
</ol>
<div class="note">
<p><strong>关于完整性校验：</strong>公开实测显示，从镜像站下载的 GGUF 文件有时会因
下载中断而缺失末尾数据。此类文件能够通过常规加载流程且不报错，但推理输出会出现乱码。
本软件在导入环节主动比对张量表与文件实际大小，可拦截此类损坏文件。</p>
</div>

<h2>4.3 模型列表</h2>
<p>模型列表按导入时间倒序排列，每项显示模型名称、量化格式、参数规模、
文件大小与当前状态。状态包括：已导入、已加载、加载中、加载失败。</p>
<p>点击列表项可选中该模型；选中已加载的模型时可选择「停止使用」，
软件随即卸载内存中的权重与缓存，保留文件以便下次快速启用。</p>

<h2>4.4 删除模型</h2>
<p>在设置页的「已导入模型」区域，向目标模型条目右侧滑动或点击删除图标即可移除。
删除后模型文件从沙箱目录移除，列表与容量统计同步刷新。</p>

<!-- ============ 5 对话 ============ -->
<h1 id="sec-5">五、对话功能说明</h1>

<h2>5.1 功能概述</h2>
<p>对话页提供多轮文本交互能力。顶部显示当前模型名称与运行指标，
包括实时生成速度与首字响应时间。右侧「卸载」按钮用于释放模型占用的内存，
「清空」按钮用于清除当前会话的全部消息记录。</p>

{fig('chat', '对话界面')}

<h2>5.2 AI 生成内容标识</h2>
<p>依据《人工智能生成合成内容标识办法》，本软件对模型生成的回复内容实施显式标识：
每一条模型回复的气泡上方均标注「AI 生成」标签，对话页空白区域亦提示
「回复内容由本机模型生成，可能存在错误，请勿直接作为事实依据」。</p>
<p>由于本软件不提供生成内容的文件导出与下载功能，因此不涉及在文件元数据中
写入隐式标识信息的情形。</p>

<h2>5.3 流式输出与中止</h2>
<p>模型生成过程中，回复内容以词元为单位逐段追加至气泡，界面保持约每秒 25 帧的刷新率，
避免因高频重绘造成掉帧。点击输入框右侧的「停止」按钮可随时中止当前轮次的生成。</p>
<p>当模型未能产生可见输出时，软件会给出具体原因提示，例如已达到长度上限、
引擎中途失败或模型本身未输出内容，避免用户面对空白气泡无从判断。</p>

<h2>5.4 多轮对话与上下文复用</h2>
<p>软件在每轮对话中将历史消息与本轮输入拼接后送入模型。为降低重复计算开销，
软件保留上一轮的词元序列，与本轮提示词求最长公共前缀，
仅对差异部分执行预填充，其余部分直接复用既有的键值缓存。</p>
<p>每轮回复的统计行会显示「复用」字样及复用的词元数量，用户可直接观测到该优化的实际效果。</p>

<h2>5.5 对话记录管理</h2>
<p>点击顶部「清空」按钮可清除当前会话的全部消息。清除操作会同时终止正在进行的生成任务
并重置提示词缓存状态。消息记录仅保存在设备本地，不会上传至任何服务器。</p>

<!-- ============ 6 设置 ============ -->
<h1 id="sec-6">六、参数设置功能说明</h1>

<h2>6.1 功能概述</h2>
<p>设置页集中管理推理参数、采样参数与系统提示词。顶部状态卡显示当前加载状态，
并列出引擎实际生效的优化配置，便于在优化发生静默降级时排查问题。</p>

{fig('settings', '设置界面')}

<h2>6.2 推理参数</h2>
<table>
  <tr><th>参数</th><th>取值范围</th><th>说明</th></tr>
  <tr><td>上下文长度</td><td>512 至 128k</td><td>决定模型可记忆的历史长度。键值缓存占用随该值线性增长，
      设置过大在低内存设备上可能导致加载失败</td></tr>
  <tr><td>解码线程</td><td>1 至 8</td><td>参与生成计算的线程数量。默认 4 线程，
      通常恰好占满小核集群；提高至 8 线程会唤醒大核，带来短暂提速与明显发热</td></tr>
  <tr><td>最大输出</td><td>依上下文自动计算，上限 4k</td><td>单轮回复的最大词元数</td></tr>
</table>

<h2>6.3 采样参数</h2>
<table>
  <tr><th>参数</th><th>默认值</th><th>说明</th></tr>
  <tr><td>温度</td><td>0.7</td><td>取值越低输出越保守稳定，越高越发散。
      事实类问答建议设为 0.2 至 0.5</td></tr>
  <tr><td>词元概率</td><td>0.9</td><td>候选词元的累计概率阈值，与温度配合控制输出分布</td></tr>
</table>

<h2>6.4 系统提示词</h2>
<p>系统提示词默认为空，由用户自行填写。留空时模型完全按其默认行为响应，
填写后则作为每轮对话的固定前缀参与计算。软件提供通用助手、翻译、润色、摘要、
代码五组预设模板，点击可快速填充，亦可完全自定义。</p>

<h2>6.5 高级选项</h2>
<p>「使用 mmap 加载」开关默认关闭。公开实测表明，在部分终端平台上文件映射调用的
冷启动耗时可达数十秒，关闭该选项后平均加载准备时间降至数秒量级。
软件在设置界面标注了该建议，用户可按自身设备情况选择。</p>

<h2>6.6 关于信息</h2>
<p>设置页底部的关于区域显示软件名称与版本号、最低支持的系统版本、
推理引擎标识、版权协议，以及作者主页、源代码仓库与赞助渠道的入口，
并提供隐私政策的完整内容入口。同时明确标注软件的数据流向为全部本地处理、
不发起网络请求。</p>

<!-- ============ 7 隐私 ============ -->
<h1 id="sec-7">七、隐私与数据保护</h1>

<h2>7.1 设计原则</h2>
<p>本软件在架构层面即确立「数据不出设备」的设计原则。软件运行时代码中
不包含任何网络通信实现，亦不申请包括网络访问在内的任何系统权限。
操作系统层面因此从技术上限制了本软件向外部传输数据的可能。</p>

<h2>7.2 数据处理说明</h2>
<table>
  <tr><th>数据类型</th><th>处理方式</th><th>存储位置</th></tr>
  <tr><td>用户导入的模型文件</td><td>复制后校验完整性</td><td>应用私有沙箱目录</td></tr>
  <tr><td>对话消息</td><td>在设备内存中参与推理计算</td><td>应用私有沙箱目录</td></tr>
  <tr><td>参数偏好设置</td><td>本地持久化</td><td>应用私有沙箱目录</td></tr>
  <tr><td>模型清单与容量统计</td><td>本地维护</td><td>应用私有沙箱目录</td></tr>
</table>
<p>卸载应用将一次性清除上述全部数据。软件不采集设备标识、位置信息、
通讯录内容等任何个人信息，亦不包含任何形式的埋点统计与崩溃上报组件。</p>

<h2>7.3 模型权重的来源责任</h2>
<p>本软件不提供模型下载功能。模型权重文件由用户自行获取并导入，
其训练数据、许可协议与输出内容均不在本软件的控制范围内，
亦不由软件开发者承担责任。用户应在导入前确认模型来源合法、
许可协议允许其计划的使用方式。</p>

<!-- ============ 8 技术实现 ============ -->
<h1 id="sec-8">八、技术实现要点</h1>

<h2>8.1 推理执行</h2>
<p>推理引擎以 C++ 编写并通过原生接口层暴露给上层。生成过程以异步任务方式执行，
每个词元的产出通过线程安全函数传递至表现层，避免阻塞界面线程。
调用方持有会话对象的共享所有权，引擎在任务结束前保证对象存活，
消除了异步回调触发的悬垂引用风险。</p>

<h2>8.2 中文输出处理</h2>
<p>单个词元可能仅包含半个多字节字符。若直接按字节追加至界面，
将产生替换字符。本软件在反分词阶段按 UTF-8 字符边界裁剪，
仅输出完整字符，残缺字节保留至下一词元，从而保证中文连续显示不乱码。</p>

<h2>8.3 上下文预算控制</h2>
<p>提示词超出模型容量时，若直接送入引擎将触发内部异常终止。本软件在送入前
先完成真实词元化并计算预算，超限时返回可读的错误提示，
并依据剩余可用空间自动收缩单轮输出上限，避免生成中途被强制截断。</p>

<h2>8.4 面向移动设备的四项优化</h2>
<p>针对移动设备内存紧张、功耗受限的特点，本软件实现了四项推理优化。</p>
<table>
  <tr><th>优化项</th><th>实现方式</th><th>效果</th></tr>
  <tr><td>键值缓存量化</td><td>缓存类型由 16 位降为 8 位</td><td>缓存内存与读写带宽减半</td></tr>
  <tr><td>Flash Attention</td><td>启用注意力计算的融合实现</td><td>长上下文场景收益明显</td></tr>
  <tr><td>大核亲和性线程池</td><td>读取各核心标称频率，动态选取高频核心组建线程池</td><td>解码阶段提速</td></tr>
  <tr><td>提示词前缀复用</td><td>计算新旧提示词最长公共前缀，仅预填充差异部分</td><td>多轮对话显著减少重复计算</td></tr>
</table>
<p>上述优化并非对所有模型均适用，软件按降级阶梯依次尝试，
失败时自动回退至上一级配置，不会导致模型加载整体失败。
设置页的状态卡显示引擎实际启用的配置项，便于用户确认优化是否生效。</p>

<h2>8.5 界面渲染性能</h2>
<p>原生层每生成一个词元即推送一次回调，若每次回调均重建消息列表会造成明显掉帧。
软件将词元累积于缓冲区，按固定时间间隔批量合并后刷新界面，
在保持词元流完整的前提下将界面帧率维持在约每秒 25 帧。
同时，消息列表为每一项维护独立的修订号作为渲染键，
确保内容变更后对应节点被正确重建，避免流式输出不刷新的问题。</p>

<!-- ============ 9 FAQ ============ -->
<h1 id="sec-9">九、常见问题与故障排除</h1>

<table>
  <tr><th>现象</th><th>原因与处理</th></tr>
  <tr><td>提示「本次构建未包含推理引擎」</td><td>安装包为不含引擎的早期版本，
      请重新下载完整安装包。源码编译时需先执行脚本拉取推理引擎源码</td></tr>
  <tr><td>加载模型时提示内存不足</td><td>所选模型规模超过设备可用内存。
      建议改用参数规模更小或量化等级更低的模型，或缩短上下文长度</td></tr>
  <tr><td>导入时提示文件不完整</td><td>模型文件在传输或下载过程中缺失数据。
      重新获取文件后再次导入</td></tr>
  <tr><td>回复内容出现乱码</td><td>当前版本已处理字符边界问题。
      若仍出现，检查模型文件是否完整、量化格式是否为当前引擎支持</td></tr>
  <tr><td>回复内容为空</td><td>软件会给出具体原因提示。
      「达到长度上限」表示需调大最大输出；「引擎中途失败」通常为内存不足</td></tr>
  <tr><td>生成速度过慢</td><td>属于端侧推理的正常现象。
      可尝试减少线程数以降低发热，或改用规模更小的模型</td></tr>
  <tr><td>模型未按提示词格式响应</td><td>部分模型权重未包含对话模板信息，
      软件已回退至通用格式并在界面标注</td></tr>
  <tr><td>设备发热明显</td><td>高线程数与大上下文会提升功耗。
      建议使用默认的 4 线程配置</td></tr>
</table>

<!-- ============ 10 版权 ============ -->
<h1 id="sec-10">十、软件著作权与开源许可</h1>

<h2>10.1 知识产权</h2>
<p>本软件著作权归 {COPYRIGHT_OWNER} 所有。本手册随软件源代码一同公开，
源代码托管于代码托管平台，采用 Apache License 2.0 开源协议发布，
可自由查看、复制、修改与分发，遵循该协议条款即可。</p>

<h2>10.2 第三方组件</h2>
<p>本软件内嵌了开源推理框架 llama.cpp 及其张量运算库 ggml，
二者均采用 MIT 许可证。软件源代码根目录附有许可声明与第三方声明文件，
完整列明了全部依赖组件及其授权条款。</p>
<table>
  <tr><th>组件</th><th>版本</th><th>许可证</th><th>用途</th></tr>
  <tr><td>llama.cpp</td><td>master</td><td>MIT</td><td>本地推理引擎</td></tr>
  <tr><td>ggml</td><td>master</td><td>MIT</td><td>张量运算后端</td></tr>
</table>

<h2>10.3 联系方式</h2>
<p>软件源代码、问题反馈与功能建议，均可通过代码托管平台的项目主页提交。
软件作者亦在设置页提供了源代码仓库与赞助渠道入口。</p>

</body>
</html>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(ROOT, 'docs', 'copyright'))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    shots = {
        'chat': img_b64('docs/copyright/screenshots/screen-chat.png'),
        'models': img_b64('docs/copyright/screenshots/screen-models.png'),
        'settings': img_b64('docs/copyright/screenshots/screen-settings.png'),
    }

    icon = img_b64('AppScope/resources/base/media/app_icon.png')
    if not icon:
        print('警告：未找到应用图标，封面将留空')
        icon = ''

    html = build_html(shots, icon)
    html_path = os.path.join(args.out, '用户手册.html')
    with open(html_path, 'w', encoding='utf-8') as f:
        f.write(html)

    from weasyprint import HTML
    out_pdf = os.path.join(args.out, '用户手册.pdf')
    HTML(filename=html_path, base_url=args.out).write_pdf(out_pdf)

    import subprocess
    info = subprocess.run(['pdfinfo', out_pdf], capture_output=True, text=True).stdout
    pages = 0
    for line in info.splitlines():
        if line.startswith('Pages:'):
            pages = int(line.split()[1])

    size = os.path.getsize(out_pdf)
    print(f'已生成：{out_pdf}')
    print(f'页数：{pages}（要求 ≥15），大小：{size/1024/1024:.2f} MB')
    print(f'软件全称：{SOFTWARE_FULL_NAME}')
    print(f'版本：{VERSION}　著作权人：{COPYRIGHT_OWNER}')
    missing = [k for k, v in shots.items() if not v]
    if missing:
        print(f'警告：缺少截图 {missing}')
    else:
        print('三张界面截图均已内嵌')


if __name__ == '__main__':
    sys.exit(main())
