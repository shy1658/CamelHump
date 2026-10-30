# 网络行为说明 · 本应用无任何网络请求

> **用途**：
> 1. AGC 上架信息「APP 核准（备案）」勾选**「您的 APP 为单机 APP」**的支撑材料；
> 2. 审核备注栏「单机应用说明」段落的底稿；
> 3. 算法备案适用性咨询的附件（见 `AGC-ALGO-FILING-CONSULT.md`）。
>
> **应用**：驼峰 CamelHump · `com.camelhump.app` · v1.1.1
> **文档版本**：1.0 · 2026-10-30

---

## 一、声明

**本应用在运行时不含任何网络通信代码，不发起任何网络请求。**

本声明可由三条独立证据交叉验证：操作系统权限层（无网络权限）、
应用代码层（无网络 API、无网络依赖）、架构层（无网络层）。
任何一方单独成立即可阻断联网可能，三者同时成立则构成完整闭环。

---

## 二、证据一：操作系统权限层 —— 权限列表为空

### 2.1 事实

`entry/src/main/module.json5` **不含 `requestPermissions` 字段**。
应用向操作系统申报的权限数量为 **0**，其中不包含：

- ❌ `ohos.permission.INTERNET`（网络访问）
- ❌ `ohos.permission.GET_NETWORK_INFO`（获取网络状态）
- ❌ `ohos.permission.READ_MEDIA` / `WRITE_MEDIA`（媒体读写）
- ❌ `ohos.permission.ACCESS_TOKEN`（令牌获取）
- ❌ 任何其他系统权限

### 2.2 为什么这一条是决定性的

在 HarmonyOS 中，**没有 `ohos.permission.INTERNET` 授权的应用在操作系统层面
无法建立任何网络连接**——包括 TCP/UDP socket、HTTP 请求、DNS 解析。

这不是"应用选择不联网"，而是"操作系统不允许它联网"。
即使代码中存在网络调用，也会在运行时直接失败。

> 这一点与"有权限无功能"恰好相反。后者（声明了 INTERNET 却不用）是审核
> 驳回高频项；前者（连权限都不申请）是**单机应用最有力、最可验证的证据**。

### 2.3 可视化举证

`docs/store-assets/network-proof.png` —— 该图上半部分为 `module.json5` 全文，
可直接看到无 `requestPermissions` 字段；下半部分为全仓核查结论表。

---

## 三、证据二：应用代码层 —— 无网络 API、无网络依赖

### 3.1 网络 API 检索：0 处命中

全仓（`*.ets` / `*.cpp` / `*.h` / `*.json5`）检索以下模式，**全部无命中**：

```
@ohos.net.http        @kit.NetworkKit      http.createHttp
@ohos.net.socket      WebSocket            requestInStream
fetch(                XMLHttpRequest       axios
```

### 3.2 系统 Kit 引用清单：未引入 NetworkKit

全仓 `import` 语句的**完整**去重结果（仅 6 个系统 Kit，**无一个与网络相关**）：

| Kit | 用途 | 是否涉及网络 |
| --- | --- | --- |
| `@kit.ArkUI` | UI 框架、`window`、`promptAction` | 否 |
| `@kit.AbilityKit` | UIAbility 生命周期、`common` 上下文 | 否 |
| `@kit.CoreFileKit` | `fileIo`、`picker`（系统文件选择器）、`statfs` | 否 |
| `@kit.ArkData` | `preferences`（本地键值存储） | 否 |
| `@kit.PerformanceAnalysisKit` | `hilog`（本地日志） | 否 |
| `@kit.BasicServicesKit` | `pasteboard`（剪贴板）、`BusinessError` | 否 |

### 3.3 第三方依赖：0 个

```json5
// oh-package.json5（根）
{ "dependencies": {} }
// entry/oh-package.json5
{ "dependencies": {} }
```

**没有引入任何第三方 SDK**——没有埋点统计、没有崩溃上报、没有推送、
没有广告 SDK、没有云服务 SDK、没有第三方网络库。

应用内唯一的第三方代码是**以源码形式静态链接**的 `llama.cpp`（MIT），
它是一个纯计算库，不含任何网络实现。

### 3.4 原生层（C++）检索：0 处命中

`entry/src/main/cpp/` 下检索 `socket` / `curl` / `http` / `getaddrinfo` / `connect(`，
**全部无命中**。原生层只有两个源文件：

| 文件 | 职责 |
| --- | --- |
| `llama_bridge.cpp` | llama.cpp 的 NAPI 封装：加载模型、推理、流式 detokenize |
| `gguf_inspector.cpp` | GGUF 文件头解析与完整性校验 |

### 3.5 唯一的 `openLink` 调用：由系统浏览器发起，不经应用进程

应用内有 2 处打开外部链接：

| 位置 | 链接 | 行为 |
| --- | --- | --- |
| `PrivacyConsent.ets:30` | 隐私政策 URL | 首次运行授权弹窗内点击 |
| `SettingsView.ets:82` | GitHub 项目地址 / 隐私政策 | 设置页「关于」区 |

两者均调用 `ContextHolder.get().openLink(url)`，由 **HarmonyOS 系统浏览器进程**
发起网络请求，**不经过应用进程**，且不影响应用自身的"无网络"属性。

这属于华为对单机应用的官方豁免情形之一：**「仅隐私协议托管联网型」**。

> 补充：模型页的「复制下载链接」用的是 `pasteboard`（本地剪贴板），
> 只是把 URL 字符串放进剪贴板，由**用户**用浏览器自行下载——
> 应用同样不发起任何网络请求。

---

## 四、证据三：架构层 —— 图上没有网络层

`docs/store-assets/arch-diagram.png` 呈现完整调用栈：

```
┌──────────────────────────────────────────────┐
│  表现层  ArkTS / ArkUI                        │  对话 · 模型管理 · 设置 · 隐私授权
├──────────────────────────────────────────────┤
│  核心层  ArkTS                               │  InferenceEngine · ModelRepository
├──────────────────────────────────────────────┤
│  桥接层  NAPI                                │  napi_async_work · threadsafe function
├──────────────────────────────────────────────┤
│  推理层  llama.cpp（MIT，静态链接）           │  CPU prefill · KV cache · Flash Attention
└──────────────────────────────────────────────┘
   ↑ 左侧竖带：❌ 无网络层
```

**四层之间没有任何一条涉及网络的边。** 数据流向只有：

```
用户自备 GGUF 文件  →  设备本地推理  →  AI 文本（仅显示在本机界面）
```

---

## 五、飞行模式实测（提交前必做）

华为官方对单机应用有明确提醒：

> 勾选「单机 APP」提交版本审核后，若识别到该应用存在非以上特定联网场景，
> 将无法通过审核，会影响您的版本发布进度，请谨慎选择！

官方定义的四种单机场景中，本应用属于**「完全离线型：断网后，APP 内所有功能和
链接均可正常访问」**。

### 实测清单（请逐项打勾）

| # | 操作 | 预期结果 | ⬜ |
| --- | --- | --- | --- |
| 1 | 开飞行模式 → 打开应用 | 正常启动，界面完整 | ⬜ |
| 2 | 飞行模式下导入 GGUF 模型 | 导入成功、校验通过 | ⬜ |
| 3 | 飞行模式下加载模型 | 加载成功（首载耗时较长属正常） | ⬜ |
| 4 | 飞行模式下对话 | 正常流式输出，中文不乱码 | ⬜ |
| 5 | 飞行模式下停止生成 | 立即停止 | ⬜ |
| 6 | 飞行模式下切换模型 / 删除模型 | 正常 | ⬜ |
| 7 | 飞行模式下修改参数并保存 | 正常，重启后仍生效 | ⬜ |
| 8 | 飞行模式下首次运行隐私弹窗 | 正常弹出，可同意 / 不同意 | ⬜ |

> **务必录屏**。审核员实测是标准动作，一段 30–60 秒的飞行模式演示视频
> 能省掉大量来回问答。

---

## 六、填入 AGC「APP 核准（备案）」栏

| 字段 | 填写内容 |
| --- | --- |
| APP 核准（备案） | **您的 APP 为单机 APP** |

对应说明（供备注栏引用）：

> 本应用属于完全离线型单机应用：不含任何网络通信代码，不申请任何系统权限
> （含 `ohos.permission.INTERNET`），不引入任何联网 SDK，第三方依赖数为 0。
> 断网后模型导入、加载、对话全部功能正常。
> 唯一需要联网的地方是隐私政策链接，由系统浏览器打开，不经应用进程，
> 属于官方豁免情形中的「仅隐私协议托管联网型」。

---

## 七、可复核的核查命令

审核方或第三方可用以下命令自行复核本说明的全部事实主张：

```bash
# 1. 无权限声明（应无输出）
grep -rn "requestPermissions\|ohos.permission" --include="*.json5" --include="*.json" .

# 2. 无网络 API（应无输出）
grep -rniE "@ohos\.net\.http|@kit\.NetworkKit|http\.createHttp|WebSocket|fetch\(|XMLHttpRequest" \
  --include="*.ets" --include="*.cpp" --include="*.h" entry/src/main/

# 3. 系统 Kit 引用清单（应无 NetworkKit）
grep -rhoE "from '@[^']+'" --include="*.ets" entry/src/main/ets/ | sort -u

# 4. 无第三方依赖
cat oh-package.json5 | grep -A2 dependencies

# 5. 原生层无网络代码（应无输出）
grep -rniE "socket|curl|winhttp|getaddrinfo" entry/src/main/cpp/*.cpp entry/src/main/cpp/*.h

# 6. 全部文件写入点（应仅 2 处，且均非 AI 输出）
grep -rn "fs.writeSync" --include="*.ets" entry/src/main/ets/

# 7. 唯一的外部链接调用
grep -rn "openLink" --include="*.ets" entry/src/main/ets/
```

---

## 八、⚠️ 前提守护

本说明的结论**完全建立在"应用无网络能力"这一前提上**。
若后续版本引入网络能力（例如恢复应用内模型下载），本说明、架构图、
举证截图、模型来源说明**全部同时失效**。

建议在 `tools/check-repo.sh` 中固化以下检查项，使合规前提无法被静默破坏：

| 检查 | 判据 |
| --- | --- |
| 权限列表仍为空 | `module.json5` 不含 `requestPermissions` |
| 依赖列表仍为空 | `oh-package.json5` 的 `dependencies` 仍为 `{}` |
| 未引入网络 Kit | import 清单中不出现 `NetworkKit` / `@ohos.net.*` |
| 未引入网络 API | 无 `http.` / `WebSocket` / `fetch(` 调用 |
| 写盘点未增加 | `fs.writeSync` 仍为 2 处（若增加，须评估隐式标识义务） |
| 未新增导出功能 | `ChatView.ets` 中不出现 `pasteboard` / 导出 / 分享调用 |

---

*文档版本 1.0 · 2026-10-30 · 适用于 CamelHump v1.1.1 上架审核*
*配套材料：`MODEL-PROVENANCE.md`（模型来源）、`AI-LABELING.md`（标识措施）、`AGC-ALGO-FILING-CONSULT.md`（算法备案咨询）*
