# 模型选择指南

## 一、只认 GGUF

| 格式 | 能否在驼峰里跑 | 说明 |
|---|---|---|
| **GGUF** | ✅ | 唯一支持的格式 |
| safetensors / `.bin` | ❌ | 原始权重，需要用 `convert_hf_to_gguf.py` 转换，手机算不动 |
| GPTQ / AWQ / EXL2 | ❌ | GPU 推理格式 |
| ONNX | ❌ | 不同生态 |
| `.ms` / `.om` | ⬜ | MindSpore Lite / CANN 格式，规划中 |

在 HuggingFace 或 ModelScope 上选模型时，认准仓库名带 `-GGUF` 后缀的那个，文件名通常是 `xxx-Q4_K_M.gguf`。

## 二、量化档位怎么选

以 7B 模型为例，不同量化的体积与质量：

| 量化 | 相对体积 | 质量损失 | 建议 |
|---|---|---|---|
| Q8_0 | ~100% | 几乎无损 | 手机不考虑，太大 |
| Q6_K | ~80% | 极小 | 内存充裕时可用 |
| **Q5_K_M** | ~70% | 很小 | 平衡之选 |
| **Q4_K_M** | ~58% | 小，可接受 | **默认推荐** |
| Q3_K_M | ~48% | 明显 | 只在内存紧张时用 |
| Q2_K | ~35% | 严重，中文尤其明显 | 不建议 |

经验值：**Q4_K_M 是质量/体积的拐点**。再往下压，中文输出会开始出现语法错误和词语重复。

## 三、手机上的规模上限

按可用内存倒推（模型体积 + KV cache + 运行时开销 ≈ 需求内存 × 1.3）：

| 设备内存 | 推荐模型 | 可跑上限 |
|---|---|---|
| 6 GB | 0.5B-1.5B Q4_K_M | 1.5B |
| 8 GB | 1.5B Q4_K_M | 3B（勉强） |
| 12 GB+ | 3B Q4_K_M | 4B |

**7B 在手机 CPU 上不是「慢」，是「不可用」**——2-4 tok/s 意味着一句 30 字的回答要等 10 秒以上。不要被「能加载」误导，加载和能用是两回事。

## 四、推荐清单

| 模型 | 体积 | 中文 | 特点 |
|---|---|---|---|
| Qwen2.5-1.5B-Instruct | ~1.06 GB | 好 | 默认首选，中文自然，指令遵循稳 |
| Qwen2.5-0.5B-Instruct | ~400 MB | 一般 | 老机型兜底，速度快但深度弱 |
| Qwen2.5-3B-Instruct | ~1.98 GB | 很好 | 质量明显提升，速度降到 7-12 tok/s |
| Gemma-2-2B-it | ~1.7 GB | 中 | 英文强，中文一般 |
| Llama-3.2-1B-Instruct | ~800 MB | 弱 | 英文场景，中文不推荐 |
| MiniCPM-2B | ~1.5 GB | 好 | 中文优化，适合对话 |

## 五、怎么判断一个 GGUF 靠不靠谱

导入前先看三个地方：

**1. 仓库里的文件是不是分片**

如果看到 `model-00001-of-00003.gguf`，说明是分片文件，需要全部下载后合并，驼峰当前不支持。选单个完整文件。

**2. 是不是真的 Q4_K_M**

文件名写 `q4_k_m` 不代表真的。导入后看「模型」页详情里的量化字段——那是从文件头 `general.file_type` 读出来的，不是文件名。

**3. 有没有对话模板**

详情里显示「含对话模板」的模型，会用它自己的模板渲染对话；不显示的会回退到 ChatML。Qwen 系列通常自带，一些手工转换的模型会丢。

模板丢失的表现：你问「你好」，模型接着往下编故事，而不是回答你。

## 六、自己转换

如果目标模型只有 safetensors，在电脑上转（不要在手机上试）：

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
pip install -r requirements.txt

# 转成 GGUF（F16 中间格式）
python convert_hf_to_gguf.py /path/to/model --outfile model-f16.gguf --outtype f16

# 量化到 Q4_K_M
cmake -B build && cmake --build build --config Release -j
./build/bin/llama-quantize model-f16.gguf model-q4km.gguf Q4_K_M
```

转换需要原模型 2 倍以上的内存和几十 GB 磁盘，普通笔记本跑 1.5B 大概几分钟，7B 要十几分钟。

## 七、下载渠道

- **ModelScope**（国内直连）：`modelscope.cn`，搜模型名 + GGUF
- **HuggingFace**：`huggingface.co`，仓库名带 `-GGUF`
- **国内镜像**：`hf-mirror.com`

下载时优先选官方或知名量化者（如 `bartowski`、`Qwen` 官方）的仓库，第三方转换的量化质量参差不齐，常见问题是量化参数写错但文件名正常。
