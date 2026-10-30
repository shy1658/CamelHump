# AGC 上架材料包 · 索引

> **应用**：驼峰 CamelHump · `com.camelhump.app` · v1.1.1
> **包版本**：1.0 · 2026-10-30
> **用途**：华为应用市场（AGC）上架审核的一站式材料包。

---

## 一、这份材料包解决什么问题

上架审核中，本应用最容易被卡住、也最容易被误判的有三件事：

| # | 审核方会问什么 | 本包的回答在 |
| --- | --- | --- |
| 1 | 你的应用联网吗？凭什么说是单机 APP？ | `NETWORK-BEHAVIOR.md` + 2 张举证截图 |
| 2 | 模型哪来的？备案号呢？ | `MODEL-PROVENANCE.md` + `AGC-ALGO-FILING-CONSULT.md` |
| 3 | AI 生成的内容做了标识吗？ | `AI-LABELING.md` + 显式标识截图 |

核心结论：**这是一个不联网、不含模型、无任何第三方 SDK 的纯端侧离线工具**。
三条独立的证据链共同支撑这个结论，任一条被打破，结论即失效。

---

## 二、材料清单

### 2.1 核心文档（4 份）

| 文档 | 内容 | 何时用 |
| --- | --- | --- |
| [`NETWORK-BEHAVIOR.md`](NETWORK-BEHAVIOR.md) | 无任何网络请求的完整论证：权限层 / 代码层 / 架构层三证据链、飞行模式实测清单、可复核命令 | 勾选「您的 APP 为单机 APP」时的支撑材料；备注栏段落底稿 |
| [`MODEL-PROVENANCE.md`](MODEL-PROVENANCE.md) | 模型来源说明：安装包内模型数 0、用户自导入路径、责任划分、许可对照表 | 「AI 功能声明」栏 + 算法备案咨询附件 |
| [`AI-LABELING.md`](AI-LABELING.md) | 显式标识实现与截图要求、隐式标识不适用的法条级论证、说明函底稿 | 「AI 功能声明」栏；审核索取说明函时的底本 |
| [`AGC-ALGO-FILING-CONSULT.md`](AGC-ALGO-FILING-CONSULT.md) | 向 AGC 确认「纯本地、用户自导入模型」能否替代算法备案号的完整提问与论证 | **待你本人提交**（见第四节） |

### 2.2 举证截图（2 张，本包新增）

| 截图 | 尺寸 | 内容 |
| --- | --- | --- |
| [`store-assets/arch-diagram.png`](store-assets/arch-diagram.png) | 1920×1080 | 端侧推理架构图：四层调用栈 + 左侧「无网络层」阻断带 + 数据流向 + 底部四项状态指标 |
| [`store-assets/network-proof.png`](store-assets/network-proof.png) | 1600×2180 | 无网络请求举证：`module.json5` 全文（无 `requestPermissions`）+ 六项全仓核查结论表 + 结论段 |

### 2.3 已有材料（复用）

| 材料 | 位置 | 用途 |
| --- | --- | --- |
| AI 生成内容显式标识特写 | [`store-assets/ai-label-shot.png`](store-assets/ai-label-shot.png) | 《应用内已添加内容显式标识截图》主材料 |
| 对话页完整截图 | [`store-assets/screenshot-01.png`](store-assets/screenshot-01.png) | 辅助材料 |
| 隐私政策 | [`privacy.html`](privacy.html) | 隐私政策网址（必填项） |
| 填写模板 | [`AGC-FILL-TEMPLATE.md`](AGC-FILL-TEMPLATE.md) | AGC 各字段填写内容 |
| 上架指引 | [`APP-STORE-GUIDE.md`](APP-STORE-GUIDE.md) | 账号、打包、签名、提交流程 |

### 2.4 源码佐证

<https://github.com/shy1658/CamelHump> — Apache-2.0 全量开放。
审核方可自行核查全部网络相关代码。仓库提供 `tools/check-repo.sh`，
一条命令复现全部合规前提检查。

---

## 三、材料包要证明的六件事

```
① 权限层   module.json5 无 requestPermissions → 操作系统层面无法联网
              ↓
② 代码层   网络 API 0 命中 / NetworkKit 未引入 / 第三方依赖 0 个
              ↓
③ 架构层   四层调用栈中没有网络层，架构图可见
              ↓
④ 离线可用 飞行模式下导入→加载→对话→停止全部正常
              ↓
⑤ 模型自备 安装包内模型 0 个，用户自行导入，开发者不掌握模型内容
              ↓
⑥ 标识合规 显式标识已实施（每条回复带「AI 生成」标签）
           隐式标识无适用对象（不产生生成合成内容文件）
              ↓
        单机 APP + 无算法备案号 + 无个人信息收集
```

---

## 四、待你完成的两件事

| # | 事项 | 说明 |
| --- | --- | --- |
| 1 | **向 AGC 提交算法备案咨询** | 提问话术已备好在 `AGC-ALGO-FILING-CONSULT.md` 第一节，附件清单在第三节。走 AGC 工单 / 开发者论坛 / 属地网信办任一渠道 |
| 2 | **飞行模式实测并录屏** | 清单在 `NETWORK-BEHAVIOR.md` 第五节（8 项）。审核员会实测，录屏能省掉大量问答 |

---

## 五、提交前的自查顺序

```bash
# 1. 复现全部合规前提检查（需 GH_TOKEN 才能跑仓库/Pages 部分）
./tools/check-repo.sh

# 2. 确认隐私政策链接匿名可访问（审核员不会登录）
curl -sIL -o /dev/null -w "%{http_code}\n" https://shy1658.github.io/CamelHump/privacy.html
#    → 200

# 3. 重新生成举证截图（若代码有变动）
python3 tools/gen-arch-diagram.py
```

补充清单见 `AGC-FILL-TEMPLATE.md` 第十节「上传前最后核对」（12 项）。

---

## 六、材料之间的关系

```
                    ┌─────────────────────────┐
                    │  AGC-ALGO-FILING-CONSULT │  ← 你向 AGC 提问
                    │   （核心提问 + 论证）     │
                    └───────────┬─────────────┘
                                │ 引用
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
┌───────────────┐   ┌────────────────────┐   ┌──────────────────┐
│NETWORK-BEHAVIOR│   │  MODEL-PROVENANCE  │   │   AI-LABELING    │
│ 无网络请求论证  │   │   模型来源说明      │   │  显式/隐式标识   │
└───────┬───────┘   └─────────┬──────────┘   └────────┬─────────┘
        │                     │                        │
        ▼                     ▼                        ▼
 arch-diagram.png      network-proof.png        ai-label-shot.png
```

三份文档 + 三张截图构成完整证据包。**任何一份单独提交都不完整**：
架构图说明"设计上无网络"，举证图证明"实现上无网络"，
模型来源说明证明"不是应用在提供 AI 服务"，标识说明证明"合规义务已履行"。

---

*材料包版本 1.0 · 2026-10-30 · 适用于 CamelHump v1.1.1 上架审核*
