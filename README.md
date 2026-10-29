# 驼峰 · CamelHump

> 手机鸿蒙上的本地大模型运行时。自带模型，离线推演，对话不出设备。

[![Release](https://img.shields.io/github/v/release/shy1658/CamelHump?style=flat-square)](https://github.com/shy1658/CamelHump/releases)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue?style=flat-square)](LICENSE)
[![API](https://img.shields.io/badge/HarmonyOS-API%2018-0aa?style=flat-square)](https://developer.huawei.com/consumer/cn/)
[![爱发电](https://img.shields.io/badge/%E7%88%B1%E5%8F%91%E7%94%B5-%E6%94%AF%E6%8C%81%E5%BC%80%E5%8F%91-946ce6?style=flat-square)](https://afdian.com/a/shy1658?utm_source=copylink&utm_medium=link)

Ollama 在桌面上很好用，但它依赖三样手机上没有的东西：systemd 常驻守护进程、无限期后台权限、包管理器。驼峰把这三样换掉，保留真正有价值的部分——**一条路径加载模型、一份清单描述模型、一个稳定接口对接上层**。

作者 [@shy1658](https://github.com/shy1658) · 下载见 [Releases](https://github.com/shy1658/CamelHump/releases) · 支持开发 → [爱发电](https://afdian.com/a/shy1658?utm_source=copylink&utm_medium=link)

```
┌──────────────────────────────────────────────┐
│  ArkTS / ArkUI                               │
│  对话 · 模型管理 · 参数面板                    │
├──────────────────────────────────────────────┤
│  InferenceEngine    ModelRepository          │
│  会话生命周期        导入 · 校验 · 清单 · 配额  │
├──────────────────────────────────────────────┤
│  NAPI  napi_async_work + threadsafe function │
├──────────────────────────────────────────────┤
│  llama.cpp (CPU)      GgufInspector          │
│  分块 prefill         头部解析 · 完整性校验    │
│  流式 detokenizer                             │
└──────────────────────────────────────────────┘
```

---

## 现在能做什么

| 能力 | 状态 |
|---|---|
| 导入用户自己下载的 GGUF 文件 | ✅ |
| 解析 GGUF 头部，识别架构 / 量化 / 上下文 | ✅ |
| 完整性校验（张量表 vs 实际文件大小） | ✅ |
| 本地推理（llama.cpp 已编进包里） | ✅ 1.0.2 起 |
| 流式输出，中文不出现乱码 | ✅ |
| 中途停止生成 | ✅ |
| 多模型管理、切换、删除、容量统计 | ✅ |
| 一键停止使用模型（卸载内存占用、保留文件） | ✅ 1.0.3 起 |
| 采样参数与上下文调节 | ✅ |
| 应用内直连下载 | ❌ 见「已知限制」 |

**不支持**：safetensors / PyTorch `.bin` 原版权重、GPTQ、AWQ、EXL2、ONNX。这些格式 llama.cpp 不认，手机也没有算力做转换。**只认 GGUF。**

---

## 快速开始

### 1. 环境

- DevEco Studio 5.0（API 12）或更高
- HarmonyOS 真机（模拟器可跑界面，但推理速度没有参考价值）
- 至少 8 GB 内存的设备跑 1.5B，6 GB 跑 0.5B

#### API 版本

| 项 | 值 |
| --- | --- |
| compileSdkVersion | 5.1.0.125（OpenHarmony 5.1 Release） |
| targetAPIVersion | 50100018 → **API 18** |
| minAPIVersion | 50100018 → **API 18** |
| compileSdkType | HarmonyOS（不是 OpenHarmony） |

**当前只支持 API 18 及以上。** `build-profile.json5` 里 `compatibleSdkVersion`
与 `minAPIVersion` 都锁在 `5.1.0(18)`，装到 API 12/13/14 的机器上会被系统
直接拒绝安装。

要向下兼容到 API 12，需要做三件事：把 `compatibleSdkVersion` 降到 `5.0.0(12)`、
用 API 12 的 SDK 重新编译、并把所有 API 14+ 才有的调用降级替换
（`@kit.*` 的部分模块在 API 12 上还没有）。这一档暂时没做——本项目没有
后台常驻需求，API 18 覆盖了目前所有在用机型。

### 2. 拉取推理引擎

工程不带 llama.cpp 源码，用脚本拉（脚本会顺手打上 OHOS 需要的补丁）：

```bash
./tools/fetch-llama.sh
```

也可以手动拉：

```bash
cd entry/src/main/cpp
git clone --depth 1 https://github.com/ggml-org/llama.cpp third_party/llama.cpp
```

> 版本要求：2025-10 之后的提交，`include/llama.h` 里要有 `llama_memory_clear` 与
> `llama_get_memory`。旧版本用的是 `llama_kv_cache_clear`，编译时加
> `-DCAMELHUMP_LEGACY_KV_API=ON` 兼容。
>
> 新版把 `use_mmap` / `use_mlock` 合并成了 `load_mode` 枚举，`llama_sampler_init_penalties`
> 也多了一个 `n_vocab` 首参。细节和补丁位置见 [`docs/LLAMA-INTEGRATION.md`](docs/LLAMA-INTEGRATION.md)。

**不拉也能编译。** 1.0.1 之前的包就是这样出来的：界面完整可用，但每次加载模型都会提示「本次构建未包含推理引擎」。1.0.2 起分发包里已经带引擎，源码仓库仍然按需拉取——llama.cpp 有 180 MB，不适合进 git。

### 3. 编译

DevEco Studio 打开工程根目录，配置签名，Run。

命令行：

```bash
hvigorw assembleHap --mode module -p product=default
```

#### 3.1 纯命令行构建（无 DevEco Studio）

鸿蒙构建链的三个组件（hvigor / ohpm / SDK）只随 **Command Line Tools** 分发，不在公开的 OpenHarmony SDK 里：

```bash
# 1) 安装 CLT（内含 hvigorw / ohpm / Node / SDK）
unzip commandline-tools-linux-x64-5.1.0.840.zip -d /root/ohos-clt

# 2) 搭出版本化 SDK 布局（hvigor 要求 SDK 路径带版本号子目录）
mkdir -p /root/ohos/sdk
ln -s /root/ohos-clt/command-line-tools/sdk/default/openharmony /root/ohos/sdk/18
echo "sdk.dir=/root/ohos/sdk" > local.properties

# 3) 构建
export PATH=/root/ohos-clt/command-line-tools/bin:$PATH
export OHOS_BASE_SDK_HOME=/root/ohos/sdk
hvigorw assembleHap --no-daemon --no-incremental
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

#### 3.2 签名

签名材料由 `keystore/gen-signing.sh` 一键生成（根 CA → 应用 CA / profile CA → 叶子证书）：

```bash
cd keystore && ./gen-signing.sh
```

脚本里固化了几个必须遵守的约束：

| 约束 | 原因 |
| --- | --- |
| `generate-profile-cert` 只接受 ECC 密钥 | 内部只支持 `SHA256withECDSA` |
| 证书链顺序必须是 根 → 中间 → 叶子 | `generate-*-cert -outForm certChain` 输出的是叶子优先，要反转 |
| `development-certificate` 必须以 `\n` 结尾 | 少了结尾换行，base64 解码报 `Illegal base64 character 20` |
| 密码长度 ≥ 32 且为偶数 | hvigor `SignHap` 的密码规则 |

签名（绕开 hvigor 内置签名，因为它的加密材料目录只有 DevEco Studio 才会生成）：

```bash
java -jar $SDK/toolchains/lib/hap-sign-tool.jar sign-app -mode localSign \
  -keyAlias camelhump-app-v1 -keyPwd "$KEY_PWD" \
  -appCertFile keystore/app-cert.cer -profileFile keystore/camelhump.p7b \
  -inFile entry/build/default/outputs/default/entry-default-unsigned.hap \
  -signAlg SHA256withECDSA -keystoreFile keystore/camelhump.p12 -keystorePwd "$STORE_PWD" \
  -outFile CamelHump-1.0.1.hap -compatibleVersion 18 -signCode "1"
```

验签：

```bash
java -jar $SDK/toolchains/lib/hap-sign-tool.jar verify-app \
  -inFile CamelHump-1.0.1.hap -outCertChain chain.cer -outProfile profile.p7b
# -> Digest verify result: true / verify-app success
```

> 仓库里的 `keystore/` 是**调试用自签证书**，仅供本地安装体验。真机发布请换成华为开发者联盟下发的正式证书。

### 4. 装模型

1. 电脑上下载一个 GGUF，例如 `Qwen2.5-1.5B-Instruct-Q4_K_M.gguf`（约 1.06 GB）
2. 传到手机（数据线 / 网盘 / 微信文件传输均可）
3. 打开驼峰 → 「模型」页 → 右上角「导入 GGUF」→ 选中文件
4. 复制并校验完成后自动加载，跳到对话页

---

## 三个关键取舍

### 一、不做常驻服务

Ollama 是 `ollama serve` 常驻 + 客户端连 11434。手机上这条路走不通：

- 应用退后台 6-12 秒后进入管控，无合规任务即挂起
- 短时任务配额 3 分钟/次、10 分钟/天
- 长时任务只认 audioPlayback / location / dataTransfer 等固定类型，**「算力」不是合法后台类型**
- 后台 CPU 连续 10 分钟不得高于 10%（8 核累计）

所以驼峰是**可恢复**而非**不死**：模型加载在用户可见的前台完成，生成过程中随时可停，不做跨后台的长任务承接。

### 二、默认关闭 mmap

这是本项目最重要的一个默认值。

公开实测（[arXiv 2410.3613](https://arxiv.org/html/2410.3613v1)）显示：华为设备冷启动加载模型的准备时间异常长，麒麟 SoC 更严重，最差超过 40 秒。定位到 `mmap` 调用本身——MatePad 12.6 Pro 上 mmap 耗时可达 40 秒，热启动后降到 0.2 秒；**关闭文件映射后平均准备时间降到 2.6 秒**。

不是存储慢，是鸿蒙上的 mmap 行为问题。所以 `llama_model_params.use_mmap = false` 是默认值，设置页里给了开关但标注了不建议打开。

### 三、线程数默认 4，不拉满

`n_threads = 8` 在短时基准里更快，但会把大核拉满，三分钟对话就能让机身从 28℃ 升到 41℃、掉电 8%。用户看到的不是「快」，是「烫」和「费电」。

4 线程绑定小核集群是续航与速度的平衡点。`n_threads_batch = 2` 进一步压低 prefill 阶段的峰值功耗。

---

## 四个已经处理掉的问题

这些问题不处理，表现出来都是「模型有 bug」，实际是工程问题。

| 现象 | 真实原因 | 处理 |
|---|---|---|
| 中文输出乱码、出现替换字符 | 一个 token 可能只包含半个 UTF-8 字符 | `Utf8CompleteLen()` 只输出完整字符边界，残字节留到下一个 token |
| 用户说「模型坏了」，实际是文件不全 | 下载中断的 GGUF 缺最后几 MB，加载不报错但输出乱码 | 解析张量表累加字节数，与文件大小比对；不一致直接拒绝导入 |
| 提示词超长时应用闪退 | `n_batch` 溢出触发 llama.cpp 内部 `ggml_abort` | 真实 tokenize 后先算预算，超限返回可读错误而不是让引擎自杀 |
| 模型把你的指令当续写文本 | GGUF 缺 `tokenizer.chat_template` | 优先用模型自带模板，缺失时回退 ChatML，UI 上标明「未含对话模板」 |

---

## 自测

GGUF 解析器不依赖任何 OHOS 接口，可以在电脑上直接跑：

```bash
cd tools/gguf-selftest && ./run.sh
```

```
well-formed v3            ... 9 checks ok
truncated payload         ... flagged incomplete
wrong file type           ... rejected, reason mentions magic
v2 with 2000-entry array  ... 8 checks ok
ALL PASS
```

第四个用例是重点：它构造了一个带 2000 条 tokenizer 字符串的 v2 文件。数组跳过逻辑只要错一个字节，后面的 `architecture`、`context_length`、`head_count` 会全部读错——而这正是真实 GGUF 里最常见、也最难排查的错位来源。

---

## 目录

```
CamelHump/
├── AppScope/                     应用级配置与图标
├── entry/src/main/
│   ├── ets/
│   │   ├── core/
│   │   │   ├── InferenceEngine.ets    会话生命周期，唯一持有 session 的地方
│   │   │   ├── ModelRepository.ets    导入 / 校验 / 清单 / 删除
│   │   │   ├── AppStore.ets           全局状态，通过 AppStorage 同步到页面
│   │   │   ├── Config.ets             默认参数与推荐模型清单
│   │   │   ├── Types.ets              共享类型
│   │   │   └── Theme.ets              配色与格式化
│   │   ├── view/                      三个主页面
│   │   ├── pages/Index.ets            Tab 容器
│   │   └── entryability/
│   ├── cpp/
│   │   ├── gguf_inspector.cpp         GGUF v2/v3 头部解析（纯 C++，可独立测试）
│   │   ├── llama_bridge.cpp           llama.cpp 封装
│   │   ├── napi_init.cpp              NAPI 绑定
│   │   ├── CMakeLists.txt             引擎开关、指令集、Debug -O3 兜底
│   │   ├── third_party/llama.cpp/     按需拉取（tools/fetch-llama.sh）
│   │   └── types/libcamelhump/
│   └── resources/
├── docs/
│   ├── LLAMA-INTEGRATION.md           引擎接入、上游 API 变更、验证方法
│   ├── GPU-VS-CPU.md                  GPU 与 CPU 推理的定量评估（暂不实现）
│   ├── APP-STORE-GUIDE.md            鸿蒙应用市场上架指引（资质、打包、审核）
│   ├── copyright/                     软著登记材料（源代码 PDF、用户手册 PDF）
│   ├── PERF-NOTES.md                  性能实测方法
│   └── MODEL-GUIDE.md                 模型选择
├── tools/
│   ├── fetch-llama.sh                 拉取 llama.cpp 并打 OHOS 补丁
│   ├── gen-copyright-source.py        生成软著源程序鉴别材料（60 页 PDF）
│   ├── gen-copyright-manual.py        生成软著用户手册（PDF）
│   ├── gen-screenshots.py             渲染界面截图
│   └── gguf-selftest/                 GGUF 解析器离线自测
├── keystore/
│   ├── gen-signing.sh                 调试签名材料一键生成
│   ├── camelhump.p12                  密钥库（根 CA / 应用 CA / profile CA / 叶子）
│   ├── root-ca.cer · app-ca.cer · profile-ca.cer
│   ├── app-cert.cer · profile-cert.cer  证书链（根 → 中间 → 叶子）
│   └── camelhump.p7b                  已签名的 Provision Profile
└── build-profile.json5
```

---

## 下载与安装

**普通用户**：到 [Releases](https://github.com/shy1658/CamelHump/releases) 下载 `CamelHump-x.y.z.hap`，
用手机「文件管理」打开即可安装（首次需在系统设置里允许安装未知来源应用）。

**注意**：安装包使用自签名调试证书，仅用于侧载测试。上架华为应用市场需要企业开发者账号与
正式签名，这一步没有做。

| 产物 | 说明 |
| --- | --- |
| `CamelHump-1.1.1.hap` | 当前版本，6.0 MB，含 llama.cpp 引擎，`verify-app` 通过 |
| `CamelHump-v1.1.0-src.zip` | 源码包（不含 181 MB 的 llama.cpp 本体，`tools/fetch-llama.sh` 按需拉取） |

**开发者**：克隆源码后按「快速开始」操作。llama.cpp 不进 git，用脚本拉取并打补丁。

---

## 1.1.1 增补：上架合规改造

**AI 生成内容标识**

依据《人工智能生成合成内容标识办法》，每条 AI 回复气泡上方新增「AI 生成」标签，
对话页空状态区补充「回复内容由本机模型生成，可能存在错误」的提示。
因为应用不提供生成内容的文件导出功能，不涉及文件元数据，无需隐式标识。

**移除全部权限声明**

原先申请了 `INTERNET` 与 `GET_NETWORK_INFO`（早期下载功能的遗留），
但代码里从未有过任何网络请求。这类「有权限无功能」是应用市场审核的高频驳回项。
现已移除，应用包内权限列表为空。

**隐私政策**

完整隐私政策撰写完毕并部署到
<https://shy1658.github.io/CamelHump/privacy.html>，应用内「设置 → 关于」可直接打开。
内容覆盖零网络请求声明、零信息收集清单、本地存储数据清单、AI 标识措施、
权限说明、第三方组件许可、未成年人保护与联系方式。

**上架指引**

新增 [`docs/APP-STORE-GUIDE.md`](docs/APP-STORE-GUIDE.md)，覆盖资质判定、正式签名、
`.app` 打包、素材规格、审核备注话术与时间线预估。

**软著登记材料**

新增 [`docs/copyright/`](docs/copyright/) 目录，材料已全部生成完毕：

| 文件 | 内容 |
| --- | --- |
| `源代码.pdf` | 60 页鉴别材料（前 30 + 后 30，每页 50 行有效代码，页眉含软件全称与版本号） |
| `用户手册.pdf` | 17 页，含封面、目录、10 个章节与 3 张界面截图 |
| `软件主要功能描述.md` | 申请表「软件主要功能」栏填写正文（1154 字，符合 2026 新规 500–1300 字要求） |
| `软著申请指引.md` | 申请流程、填表速查与上传前自检清单 |

材料由 `tools/gen-copyright-source.py` 与 `tools/gen-copyright-manual.py` 生成，
改代码后可重新产出。

> ⚠️ **2026 年 3 月 15 日新规提示**：软著签章页要求本人手抄承诺
> 「未使用 AI 开发编写代码、撰写文档或生成登记申请材料」，并建立失信惩戒机制。
> 而华为应用市场上架中软著是**非必选资质**，具体取舍见
> [`docs/copyright/软著申请指引.md`](docs/copyright/软著申请指引.md)。

> **合规判定小结**：本应用为纯端侧离线推理，不向不特定公众提供生成式AI服务，
> 依据《互联网信息服务深度合成管理规定》第二条，**无需算法备案与安全评估**。
> 上架的真正瓶颈在账号资质与审核往返，不在开发。

---

## 1.1.0 增补

**关于页**

- 作者 `shy1658`、GitHub 仓库、爱发电入口三项均可直接点击打开
- 软件简介两段：定位（本地推理 / 离线 / 不出设备）与能力边界（llama.cpp 基础、量化格式、KV 缓存复用、自动降级）
- 信息行：版本号、**最低支持系统 HarmonyOS API 18**、推理引擎、开源协议
- 爱发电链接带上 `utm_source` / `utm_medium` 参数，便于统计来源

**发布**

- 首次公开发布到 GitHub，源码 + HAP 同仓库，HAP 作为 Release 资产提供
- Release 说明覆盖下载方式、系统要求、本版更新、已知限制

---

## 版本历史

| 版本 | 更新 |
| --- | --- |
| **1.1.1** | 上架合规改造：AI 生成内容显式标识、移除全部权限、隐私政策上线、上架指引 |
| 1.1.0 | 关于页完善；首次公开发布（GitHub + Release） |
| 1.0.9 | CPU 侧四项优化：KV Q8_0、Flash Attention、大核亲和性、prompt cache 复用 |
| 1.0.8 | 修复流式输出不刷新、模型卸载入口 |
| 1.0.7 | 修复上下文预算溢出导致的 `allows 0 tokens` |
| 1.0.6 | 系统提示词默认留空，上下文上限提至 128k，token 显示改 k |
| 1.0.5 | 单轮输出上限提升至 4k |
| 1.0.4 | 设置页支持删除已导入模型 |
| 1.0.3 | 增加停止使用并卸载模型 |
| 1.0.2 | 推理引擎编入分发包，不再提示「未包含推理引擎」 |
| 1.0.1 | 换用首字母图标，修复构建问题 |

---

## 1.0.9 增补：CPU 侧四项优化

GPU 那条路的结论见 [`docs/GPU-VS-CPU.md`](docs/GPU-VS-CPU.md)：手机 decode 是带宽 bound，
在统一内存架构下 GPU 只能提升利用率，上限 1.5–2×，且麒麟驱动未知。
同样量级的收益这四项就能拿到，不需要新后端。

### 1. KV cache 量化 Q8_0

```cpp
cp.type_k = GGML_TYPE_Q8_0;
cp.type_v = GGML_TYPE_Q8_0;
```

KV 从 f16 降到 8 bit，**缓存内存减半，decode 时 KV 的读写带宽也减半**。
8k 上下文下 1.5B 模型从 224 MB 降到 112 MB。设置页的 KV 估算会同步反映这个减半。

注意 **量化 V 必须搭配 flash attention**，llama.cpp 会直接拒绝 Q8 KV + 无 FA 的组合，
所以这两项是绑在一起做降级阶梯的。

### 2. Flash Attention

```cpp
cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
```

attention 不再物化完整的 N×N 分数矩阵，减少中间量的显存往返。上下文越长收益越明显，
短文问答基本看不出来。

### 3. 线程绑定大核

ggml 自己创建 worker 线程，没有「设置亲和性」的开关，只能构造带 cpumask 的
`ggml_threadpool` 再 `llama_attach_threadpool()` 交过去。

选核不靠猜索引——读每颗核的 `cpuinfo_max_freq`，按频率排序取最快的那批，
且只取到最快核 90% 以内的。big.LITTLE 的切分方式每代 SoC 都不同
（麒麟 9000s 是 0–3 A510 / 4–6 A710 / 7 Taishan），猜索引必然在下一代翻车。
读不到频率时不绑核，行为退回原样。

线程池的构造函数是通过 `ggml_backend_reg_get_proc_address` 取的，不是直接链接——
它是 `GGML_BACKEND_API` 符号，在某些构建形态下不导出。

### 4. prompt cache 复用

多轮对话每轮都把整段历史重新 prefill 一遍。现在保留上次的 token 序列，
和新 prompt 求最长公共前缀，只 prefill 差异部分：

```cpp
while (reuse < cached.size() && reuse < tokens.size() && cached[reuse] == tokens[reuse]) ++reuse;
impl_->TrimKvFrom(reuse);   // llama_memory_seq_rm(mem, 0, reuse, -1)
```

两个容易踩的点：

- **位置必须显式写。** 用 `llama_batch_get_one()` 时位置由运行时按记忆状态自动编号，
  部分填充的缓存下起点容易错位；改成 `llama_batch_init()` 手写 `batch.pos[k] = i + k`。
- **`cached` 要逐块同步。** 一开始是在 prefill 结束后一次性赋值，结果中途取消时
  `cached` 描述的是上一轮的内容，而 KV 里已经混进了新的块，下一轮前缀比对就会错。
  现在每个 chunk 解码成功后立刻 append。

相同 prompt 重试的边界也处理了：完全命中时故意退一个 token，否则没有 logits 可采样。

### 降级阶梯

两项优化都不是所有模型都支持，所以按顺序尝试，失败就退一级，不会让加载整个失败：

| 顺序 | 配置 | 条件 |
| --- | --- | --- |
| 1 | FA + Q8 KV | 首选 |
| 2 | FA + F16 KV | V 量化不被支持时 |
| 3 | 基线 | 模型不支持 FA 时 |

### 现在能看见了

设置页顶部状态卡多一行，显示引擎**实际**启用了什么：

```
FA 开 · KV Q8 · 绑核 6 · ctx 8k
```

两者都有静默降级的可能，没有这行就只剩「感觉有点慢」这种无法排查的反馈。
对话气泡的统计行也加了「复用 3.2k」，直接显示这一轮省掉了多少 prefill。

### 预期收益

| 场景 | 优化前 | 优化后 | 主要来自 |
| --- | --- | --- | --- |
| 短问答首 token | — | — | 收益很小，prefill 本来就短 |
| 多轮对话第二轮起 | 重新 prefill 3k | ~200 ms | prompt cache |
| 长上下文（8k+） | 基准 | +20–40% | FA + KV Q8 |
| 全场景 decode | 基准 | +10–20% | 绑核 + KV 带宽减半 |

实测数据要等真机跑过再补。上述是各项独立收益的保守叠加，不是保证值。

---

## 1.0.8 增补

### 单轮最大输出提到 4k

深度思考类模型（Qwen3、R1-distill 这一类）在吐出第一个字之前，光推理就要吃掉两三千 token。
原来的上限是「上下文的一半」：32k 上下文时那是 16k，很宽裕；但默认 2k 上下文时只有 1k，
思考到一半就被 `max_tokens` 切掉，用户看到的是一个突然断掉的回答。

现在上限取 `min(上下文 - 512, max(4096, 上下文/2))`，保证能设到 4k，同时永远给提问留 512 token。
512 这个余量是给 system 消息和用户输入留的，不留的话会回到「ask 128k 但一个 token 都放不下」的老问题。

| 上下文 | 输出上限 |
| --- | --- |
| 2k | 1.5k |
| 4k | 3.5k |
| 8k | 4k |
| 16k | 8k |
| 32k | 16k |
| 128k | 64k |

上下文不到 8k 时，物理上就是放不下 4k 输出，设置页会直说：

> 当前上下文只有 2k，加上提问后放不下 4k 输出，上限被压到 1.5k。
> 想给深度思考模型留足余量，先把上下文提到 8k 以上。

滑块步长也跟着档位走：≤2k 用 64，≤8k 用 128，再往上 256。

> 引擎侧本来就有动态裁剪（`outputBudget = min(maxTokens, 剩余窗口)`），
> 所以即使值设得比窗口大，也不会报错，只是回答按窗口实际剩余长度结束。

---

## 1.0.7 增补

### 上下文上限提到 128k

滑块上限从 8192 放到 131072，并加了一排快捷档位（4k / 8k / 16k / 32k / 64k / 128k），
不用在一条长轨道上慢慢挪。

但「能设置」和「能跑」是两件事，所以配了两道闸：

**一是夹到模型训练长度。** 加载时读 `llama_model_n_ctx_train()`，要的比训练长度大就按训练长度来。
llama.cpp 本身会照单全收，但没有 RoPE 外推的话多出来的位置是硬凑的——回答不会报错，
只会开始原地重复，这是最难排查的一类故障。Qwen2.5 系列原生 32k，设成 128k 会被压回 32k。

**二是 KV 缓存按 token 线性吃内存。** 这个数现在会直接显示在滑块下面，用的是引擎实测出来的
`kvBytesPerToken = 2 × n_layer × n_head_kv × head_dim × 2`：

| 模型 | 每 token | 8k | 32k | 128k |
| --- | --- | --- | --- | --- |
| Qwen2.5-1.5B（28 层 / 2 KV 头） | 28 KB | 224 MB | 896 MB | 3.5 GB |
| Qwen2.5-3B（36 层 / 2 KV 头） | 36 KB | 288 MB | 1.15 GB | 4.6 GB |

8 GB 的手机，模型权重本身已经占掉 1–2 GB，128k 那 3.5 GB 是压死进程的最后一根稻草。
分配不出来时 `llama_init_from_model` 返回空，现在报错会带上具体数字：

```
failed to create context for n_ctx=131072. The KV cache alone would be 4608 MB
-- lower the context in settings or pick a smaller model.
```

### token 单位换成 k

设置里所有 token 数值都过一层 `Fmt.tokens()`：`8192 → 8k`，`131072 → 128k`，
小于 1024 的保持原样（`512 tok` 比 `0.5k` 好读）。滑块步长也跟着放大，
上下文 ≥32k 时单轮输出按 256 递增，不然拖一下要滑很久。

---

## 1.0.6 增补

### 系统提示词默认留空

原来 `DEFAULT_SETTINGS.systemPrompt` 里写死了一句「你是一个离线运行的本地助手……」。
这有两层问题：一是用户没要求过的话不该替他写；二是小模型对 system 消息的服从度远高于大模型，
一句多余的设定会实打实地改变回答风格。

现在默认是空字符串，`buildMessages()` 本来就有 `trim().length > 0` 的判断，空值不发送 system 消息，
模型的默认行为原样保留。

设置页补了一句说明，并把占位符改成「留空（推荐）。需要固定语气或输出格式时再写。」

### 老设置的一次性迁移

设置是持久化的，已经装过旧版本的机器上，那句默认话还躺在 preferences 里。
`loadSettings()` 读到它时按「未设置」处理，改成空串——**只在加载时做一次**。

不能放进 `normalizeSettings()`：那个函数每次保存都会跑，而「通用助手」预设的第一条正是这句话，
用户主动选中它保存后会被悄悄清掉。迁移和校验分开，各管各的。

---

## 1.0.5 增补

### 设置页可以删除模型了

「设置 → 模型文件」列出现有模型，每行带大小、架构、量化，右侧「删除」按钮，删除前二次确认。
正在运行的那个会标「运行中」，删除时会先卸载再删文件。

这里的删除只清掉应用私有目录里的副本，**用户下载目录里的原始 GGUF 不受影响**——
原来想删模型只能去「模型」页点卡片，藏在详情弹窗里，不好找。

### 跨页刷新

模型页原来只在 `onPageShow` 时刷新列表，而 Tabs 切页不触发 `onPageShow`。
在设置页删掉模型再切回模型页，列表还是旧的。现在模型页 `@StorageLink('modelsVersion')`
加 `@Watch`，store 里的版本号一变就重读。

### 导入文案

原来的 toast 只说「已导入 xxx（架构 量化）」，没说文件去哪了。现在明确三件事：
已复制到应用内、原文件可以删、副本可以在设置里删。

| 位置 | 文案 |
| --- | --- |
| 导入成功 toast | 已导入 xxx（Qwen2 Q4_K_M）。文件已复制到应用内，下载目录里的原文件可以删了。 |
| 模型页分区说明 | 导入时已复制一份到应用私有目录，下载目录里的原文件可以删掉，随时能在这里删除副本。 |
| 设置页分区说明 | 删除只清掉那份副本，你下载目录里的原始 GGUF 不受影响。 |

---

## 1.0.4 修掉的问题

### 「prompt is 21 tokens but this model allows 0」

设置页的「单轮最大输出」滑块范围被写死成 64–2048，而默认上下文正好也是 2048。
拖到头就是上下文 2048 减输出 2048，预算 0——21 个 token 的提问也进不去。

两个错叠在一起：

**原生侧把输出上限当成了 prompt 的门槛。** 原来的校验是

```cpp
const int32_t budget = std::max(0, impl_->nCtx - params.maxTokens);
if (n_tokens > budget) { 报错 }
```

这把两件不同的事混成一个：prompt 装不装得进上下文（硬约束），和回答允许多长（软偏好）。
现在硬约束只看 `n_tokens >= nCtx`，输出预算按剩余空间自动收缩：

```cpp
const int32_t room = impl_->nCtx - n_tokens;
int32_t outputBudget = std::min(params.maxTokens, room);
```

用户要 2048 而窗口只剩 300，那就给 300，回答短一点，但不会再整句话都发不出去。

**设置页允许两者相等。** 输出上限的滑块上界现在跟着上下文走，最多占一半：

| 上下文 | 输出上限上限 |
| --- | --- |
| 2048 | 1024 |
| 4096 | 2048 |
| 8192 | 4096 |

调小上下文时，被顶到天花板之上的输出值会被自动压下来。

### 旧设置会自动纠正

设置是持久化的，老版本存进去的 `2048/2048` 会跟着升级活下来。`normalizeSettings()`
在读取和保存两条路径上都会跑一遍，把这类组合夹回合法区间——不用手动清数据。

---

## 1.0.3 修掉的问题

### 模型有回答，屏幕上一个字都不出

这不是引擎没跑，是**消息气泡从来没有被重绘**。

`ForEach` 的 key 是 `item.id`，而流式输出改的是同一个对象的 `content` 字段——key 没变，
ArkUI 就复用已有的节点，连 `@Builder` 都不会重新执行。于是气泡创建时是空的，之后一直空着，
模型其实一直在吐 token，只是屏幕上什么都看不到。

修法：给 `ChatMsg` 加一个 `rev` 计数器，每次内容变化就 +1，key 变成 `${id}#${rev}`。
key 变了节点才会重建，文本才会跟着更新。

顺带把「还没吐字」的空窗期显示成 `正在生成…`，而不是一个空白气泡——空盒子看起来就是「坏了」。

### 三个会让输出彻底消失的原生端隐患

**阻塞式 token 投递。** `napi_call_threadsafe_function` 用的是 `napi_tsfn_blocking`。队列长度是
0（不限），阻塞本来就不必要；而如果运行时的 async work 恰好跑在 JS 线程上，这个调用会直接死锁，
表现同样是「什么都没有」。改成 `napi_tsfn_nonblocking`，语义不变，风险消失。

**0 token 却报成功。** 模型如果第一个 token 就是 EOG（对话模板不匹配、或上下文已经占满），
原来会返回「成功 + 空字符串」，UI 只能显示一个空格。现在这种情况直接返回错误：
`the model ended the answer immediately (chat template mismatch, or the context window is already full)`。

**decode 中途失败被吞掉。** 生成循环里 `llama_decode` 返回非 0 原来只 `break`，用户拿到的是
一段被无声截断的回答。现在会记下结束原因。

### 生成状态可诊断

`GenStats` 新增 `finish` 字段，取值 `eos` / `max_tokens` / `cancelled` / `decode_error` / `stopped`。
`generate()` 返回的 JSON 里带上它，UI 在「零字」时按原因给不同提示：

| finish | 提示 |
| --- | --- |
| `max_tokens` | 达到长度上限，把「最大输出」调大 |
| `decode_error` | 引擎中途失败，通常是内存不足 |
| `cancelled` | （已停止） |

### 停止使用模型

「模型」页里正在运行的模型，按钮从「使用」变成「停止」，点一下就卸载、释放内存，文件保留在磁盘上。
对话页标题栏也加了「卸载」，不用切页就能腾出内存再换模型。

卸载前会先 `cancel()` 再 `release()`：正在生成的会话由异步任务持着引用，光移除会话表里的条目
不会释放权重，得让生成先停下来。

---

## 1.0.2 修掉的问题

1.0.1 装到机器上点「加载模型」，弹的是：

```
加载失败：engine not compiled in: run 'git submodule update --init' then rebuild
```

这不是 bug，是 1.0.1 的构建里压根没有推理引擎——`third_party/llama.cpp` 是空目录，
CMake 走到 `else()` 分支只打了个 WARNING，`CAMELHUMP_WITH_LLAMA` 恒为 0。
1.0.2 把引擎真正编进去了。

### 引擎接入

**源码获取。** 浅克隆在该网络环境下卡在 `fetch-pack` 阶段反复超时
（`RPC failed; curl 28 Operation too slow`），改走 codeload tarball 通道，38 MB 一分钟下完。
`tools/fetch-llama.sh` 固化了这条路径。

**四处 API 变更。** 上游 master 相比 2025 年中的版本改了不少：

| 位置 | 变化 | 后果 |
| --- | --- | --- |
| `llama_model_params` | `use_mmap` / `use_mlock` 两个 bool → `load_mode` 枚举 | 编译失败 |
| `llama_sampler_init_penalties` | 首参新增 `n_vocab` | 编译失败（否则参数错位） |
| `ggml-cpu.c` | OHOS 的 musl 没有 `pthread_setaffinity_np` | 编译失败 |
| `ggml-cpu.c` | `CPU_ZERO` / `CPU_SET` 需要 `_GNU_SOURCE` | 编译失败 |

后两处属于上游没有适配 OHOS，补丁由 `fetch-llama.sh` 自动打；`_GNU_SOURCE` 只加在
`ggml-cpu` 这一个 CMake 目标上，不污染全局。

### 性能

**Debug 构建跑在 -O0。** hvigor 默认 `buildMode=debug`，`-O0` 下 NEON intrinsic 几乎退化，
矩阵乘慢一个数量级。这在真机上会被直接误判成「手机跑不动大模型」。现在
`CMakeLists.txt` 会把 Debug 的编译选项改写成 `-O3 -g`（`CAMELHUMP_OPTIMIZE_IN_DEBUG`，默认开）。

**指令集。** `GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16` 让编译器生成 `udot/sdot`
（int8 量化点积）和 `fmla`（fp16 融合乘加）。产物里实测 `udot/sdot` 1132 条、`fmla` 2461 条。

**KleidiAI 关掉。** 该选项在 CMake 配置期用 `FetchContent` 从 GitHub Releases 下源码，
交叉编译机上一拉不到整个 configure 就失败。省下的那点 INT8 加速在手机上被内存带宽吃掉大半，
不值得引入构建期网络依赖。

### 验证

| 检查项 | 结果 |
| --- | --- |
| `llvm-strings` 里 `engine not compiled in` | 0 次（stub 分支已被编译掉） |
| `llama_*` / `ggml_*` 导出符号 | 5514 个 |
| `udot` / `sdot` 指令 | 1132 条 |
| `fmla` 指令 | 2461 条 |
| `libcamelhump.so`（strip 后） | 5.2 MB |
| HAP 签名 | `Digest verify result: true` / `verify-app success` |

---

## 1.0.1 修掉的问题

这一版集中处理了代码审查里发现的真实缺陷。

### 会崩的

**推理中切换模型导致 use-after-free。** 会话表原本存 `unique_ptr<Session>`，
而 `release` 会立刻销毁 Session——可此时后台线程可能正在 `Generate()` 里用
它。现在会话表改存 `shared_ptr`，每个异步任务自己持一份引用，Session 活到
最后一个使用者放手为止。

**清空对话后崩溃。** 生成过程中点「清空」，`messages` 变空，代码仍按
`length - 1` 取下标，拿到 `-1`。现在先判空。

### 悄悄出错的

**流式文本不刷新。** `ChatMsg` 原本是普通 interface，ArkUI 观测不到它内部
属性的变化——流式输出时气泡一直显示旧文本，要等整轮结束才一次性跳出来。
改成 `@Observed` class 后实时刷新。

**回答末尾丢字。** promise 原本在异步任务完成回调里结算，而那个回调与
token 队列之间**没有任何顺序保证**，最后几个 token 可能在 promise resolve
之后才送达，此时 UI 已经停了刷新定时器，字就丢了。现在 native 侧在 token
流末尾推一个 EOF 哨兵，promise 改由收到哨兵的回调结算——哨兵是队列最后
一项，收到它就意味着所有 token 都已送达。

**非法 UTF-8 字节让输出永久卡死。** 遇到非法前导字节时旧代码直接返回偏移
但不消费该字节，之后每次都撞上同一个字节，流式输出再也不动了。现在改为
跳过该字节并继续。

**加载失败后状态残留。** 换模型失败时，界面仍显示上一个模型的名字、
`engineReady` 仍为 true。现在失败会复位全部状态。

**负数预算提示。** 用户把输出 token 调到超过上下文长度时，提示会变成
「本模型允许 -2048 tokens」。现在钳制为 0。

**未知 tensor 类型被当成完整文件。** 遇到无法识别的量化类型时旧代码
直接跳过，该 tensor 的字节数没被计入，`complete` 于是误判为 true，
截断文件会被当成完好的模型收下。现在标记为不完整并记录类型码。

### 健壮性

- `napi_create_async_work` / `napi_queue_async_work` 的返回值现在都检查，
  失败时 reject 而不是让 promise 永远悬着
- `onDestroy` 现在真的会释放 session，不再让模型权重在后台任务里占着内存
- `CMakeLists.txt` 里 `CAMELHUMP_LEGACY_KV_API` 补上 `option()` 声明

### 验证

- NDK clang `-fsyntax-only` 检查三个 C++ 文件：通过
- GGUF 解析器自测套件（含 2000 条 tokenizer 数组的 v2 用例）：**ALL PASS**
- ArkTS 编译 + HAP 打包：通过
- `verify-app`：`Digest verify result: true` / `verify-app success`

---

## 已知限制

**应用内直连下载未实现。** 推荐模型列表提供了链接复制，需要用户用浏览器下载后导入。原因：模型分发涉及 CDN、配额、合规审核，属于运营决策而非技术实现；第一版把导入链路做扎实，比接一个不稳定的源更有价值。

**只支持 CPU 推理。** NPU 需要 MindSpore Lite 的 `.ms` 格式或 CANN 的 `.om` 格式，模型得重新转换，且 Transformer 动态 shape 在离线图里表达很别扭。当前手机 CPU 跑 1.5B Q4 约 20 tok/s，已经能交付价值，NPU 留到后续。

**需要 ARMv8.2 + dotprod。** 引擎按 `-march=armv8.2-a+dotprod+fp16` 编译，因为 int8 量化的点积和 fp16 融合乘加决定了推理速度的量级。代价是 ARMv8.0/8.1 的老机器会在加载模型时触发 `SIGILL`。要兼容老机型，把 `CMakeLists.txt` 里的 `GGML_CPU_ARM_ARCH` 改成空串重新编译即可（会退回通用 NEON，速度大约掉三到四成）。2018 年之后的 Kirin / 骁龙基本都支持这两个扩展。

**本工程未在真机编译验证。** 代码按 HarmonyOS API 12 的接口编写，静态检查通过，但 ArkTS 编译器的一些约束（例如特定装饰器组合、Struct 属性传函数）只能在 DevEco 里暴露。首次编译可能需要少量调整，主要集中在 `view/` 目录。

**无法调用系统内置模型。** 手机上盘古模型跑在系统层，接口未向第三方开放。`DataAugmentationKit.localChatModel` 仅支持 PC/2in1 且需要企业开发者资质。所以自带模型是当前唯一路径——但架构上已经把后端抽象出来了，接口开放时接上 `SystemRunner` 即可。

---

## 路线图

- **v1.1** 应用内下载（分片 + 断点续传 + 校验），模型变体（system prompt + 参数打包成可分享的 JSON）
- **v1.2** 会话持久化，导出 Markdown
- **v1.3** NPU 后端：MindSpore Lite 承接 embedding / rerank 这类固定 shape 任务
- **v2.0** 跨端算力借用：手机发起，鸿蒙 PC 推理，流式回传

---

## 支持这个项目

驼峰是业余时间做的，没有商业收入，也不打算加广告或账号体系。如果它帮你省下了几次开会员的钱，
或者你只是想让手机上的本地推理继续变得更好用：

**→ [爱发电 · afdian.com/a/shy1658](https://afdian.com/a/shy1658?utm_source=copylink&utm_medium=link)**

不打赏也完全没关系。**提 issue、反馈一个跑不通的模型、说一句哪里卡手，是同样有价值的支持**——
这个项目里大半的修复都来自具体的使用反馈，而不是我自己的想象。

---

## 许可

本项目代码 Apache-2.0（见 [LICENSE](LICENSE)）。llama.cpp 与 ggml 遵循 MIT，
第三方声明见 [NOTICE](NOTICE)。
