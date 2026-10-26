# GPU vs CPU：手机端 LLM 推理的真实瓶颈

> 结论先说：**能加 GPU，但不建议现在加**。
> 手机上 decode 阶段的瓶颈是内存带宽，不是算力；GPU 能提升的是「带宽利用效率」，
> 上限约 1.5–2 倍，代价是驱动兼容性、功耗、发热和构建复杂度。
> 同样量级的收益，用 CPU 侧四项优化就能拿到，确定性和兼容性好一个数量级。

---

## 1. 先算账：一个 token 要搬多少字节

LLM 自回归解码时，每生成一个 token 都要把**全部权重过一遍**。

| 模型 | 参数量 | Q4_K_M 体积 | 每 token 读取 | 每 token 计算 |
| --- | --- | --- | --- | --- |
| Qwen2.5-1.5B | 1.54 B | ≈ 1.0 GB | 1.0 GB | ≈ 3.1 GFLOP |
| Qwen2.5-3B | 3.09 B | ≈ 1.9 GB | 1.9 GB | ≈ 6.2 GFLOP |

算术强度 = 6.2 GFLOP / 1.9 GB ≈ **3.3 FLOP/Byte**。

这个数字极低。作为对照，训练时的算术强度在几百到几千 FLOP/Byte 量级。
Roofline 模型下，3.3 远低于任何现代处理器的拐点（CPU 约 10–30，GPU 约 50–100），
所以 **decode 完全落在 memory-bound 区域**：算力再翻倍也不快，带宽决定一切。

## 2. 硬件的真实上限

麒麟 9000s 级 SoC：

| 资源 | 规格 | 在此工作负载下的作用 |
| --- | --- | --- |
| LPDDR5 带宽 | ≈ 44 GB/s 有效 | **唯一的硬上限** |
| CPU（1×大核 + 3×中核 + 4×小核），NEON | ≈ 50–100 GFLOPS（整数点积更高） | 只需 6.2 GFLOP/token，占比 < 15% |
| Maleoon GPU | ≈ 1 TFLOPS 级 | 同上，占比 < 1% |
| NPU（达芬奇） | 10+ TOPS INT8 | 同上，但模型格式不兼容 |

按带宽算 decode 的理论天花板：

```
1.5B: 44 GB/s ÷ 1.0 GB  ≈ 44 tok/s
3B  : 44 GB/s ÷ 1.9 GB  ≈ 23 tok/s
```

实测（CPU，4 线程，Q4_K_M）：

```
1.5B: 15–20 tok/s   → 带宽利用率 35–45%
3B  :  7–12 tok/s   → 带宽利用率 30–50%
```

**中间那 50–70% 的缺口，就是所有优化手段能抢的东西。** GPU 的全部机会也在这块缺口里，
不可能超过 100% 带宽——手机是统一内存架构（UMA），GPU 和 CPU 用的是同一块 LPDDR，
不存在「显存带宽更高」这回事。这一点和桌面独显完全不同。

## 3. 所以 GPU 到底能快多少

把差距拆成三段看：

| 阶段 | 瓶颈 | GPU 相对 CPU | 说明 |
| --- | --- | --- | --- |
| Prefill（处理提问） | 算力 | **3–5×** | 大矩阵乘，算术强度高，GPU 强项 |
| Decode（逐字输出） | 带宽 | **1.2–1.8×** | 只能提高带宽利用率，无法突破 44 GB/s |
| 首 token 延迟 | shader 编译 | **更慢** | 首次运行要编译 pipeline，几十秒 |

实际体感由 decode 决定，因为回答长度远大于提问：

- 短问答（提问 50 token、回答 200 token）：GPU 主要改善的是前 0.2 秒，体感差异小
- 长文档摘要（提问 8000 token）：prefill 从 3 秒降到 1 秒，这是 GPU 最有价值的场景
- 长回答（输出 2000 token）：GPU 优势被 1.5 倍系数摊薄，且更容易热降频

社区在 Android 上用 llama.cpp Vulkan 后端跑 1–3B 模型的公开数据，也基本落在 1.2–1.8×，
部分小模型反而更慢——batch 太小，GPU 的调度和同步开销占比过高。

## 4. HarmonyOS 上的具体约束

在本机 OHOS SDK（API 18 / 5.1.0.125）里实测确认：

```
include/vulkan/vulkan.h            ✅ 存在
include/vulkan/vulkan_ohos.h       ✅ 存在（仅 surface / native_buffer / external_memory 三类扩展）
lib/aarch64-linux-ohos/libvulkan.so ✅ 存在
libOpenCL.so                        ❌ 不存在
libmindspore_lite_ndk.so            ✅ 存在
libneural_network_runtime.so        ✅ 存在（NNRt，NPU 通道）
```

几个推论：

**Vulkan compute 的通道是通的。** 头文件和 loader 都在，标准 Vulkan 自带 compute queue，
`vkCreateComputePipelines` 不依赖 OHOS 私有扩展。这是好消息。

**但 `VK_OHOS_*` 全是显示相关。** 三个扩展分别是 surface、native buffer、external memory，
说明华为把 Vulkan 定位成渲染合成通道，没有为通用计算做额外承诺。
compute 能不能跑、跑多快，完全取决于厂商 ICD 驱动的实现质量。

**OpenCL 缺失，直接排除了 MindSpore Lite 的 GPU delegate。** 那条路本来还能省掉自己写后端，
现在不通了。

**NNRt 是 NPU 通道**，但要求模型是编译后的格式，GGUF 用不了。

## 5. 如果真要做 GPU，需要跨过四道门槛

不是「加个开关」的量级。按顺序：

### 门槛一：设备侧 Vulkan 可用性

`libvulkan.so` 在 SDK 里存在，不代表设备上能加载成功。要先在真机上跑通探测：

```cpp
vkCreateInstance → vkEnumeratePhysicalDevices → vkGetPhysicalDeviceProperties
```

拿不到 physical device 就直接结束，后面都不用谈。

### 门槛二：驱动扩展

`ggml-vulkan` 的量化内核依赖这几个扩展：

| 扩展 | 用途 | 缺失后果 |
| --- | --- | --- |
| `VK_KHR_shader_float16_int8` | fp16/int8 存储与运算 | 量化模型无法上 GPU |
| `VK_KHR_16bit_storage` | 半精度 buffer | 同上 |
| `VK_KHR_cooperative_matrix`（可选） | 矩阵乘加速 | 性能打折，但能跑 |
| `VK_KHR_8bit_storage` | int8 权重 | Q4/Q8 需要 |

麒麟 Maleoon 驱动的支持情况**未知**，必须用 `vkEnumerateDeviceExtensionProperties` 实测。
这是整个方案最大的不确定性。

### 门槛三：构建链

`GGML_VULKAN=ON` 需要：

- `glslc`（shaderc）在**宿主机**上编译 shader 到 SPIR-V
- 交叉编译 vulkan-headers（NDK 里已有，可直接用）
- HAP 体积 +2–4 MB，首启还要生成 pipeline cache

### 门槛四：运行时行为

| 问题 | 表现 | 缓解 |
| --- | --- | --- |
| shader 编译 | 首次推理卡住几十秒 | 预编译 + 落盘 pipeline cache |
| 热降频 | 3–5 分钟后掉到 60% | 无法缓解，是物理限制 |
| 功耗 | GPU 满载 4–6 W，比 CPU 高 | 同上 |
| 前后台切换 | Vulkan device lost | 需要重建 device，复杂度高 |

## 6. 更划算的路线：先把 CPU 榨干

同样想抢那 50–70% 的带宽缺口，下面四件事都是在现有代码上改几十行，
不需要新后端、不增加包体、不引入驱动风险。

| 优化 | 原理 | 预期收益 | 改动量 |
| --- | --- | --- | --- |
| **KV cache 量化 Q8_0** | KV 读写带宽减半 | 长上下文 +15–30% | 3 行 |
| **Flash Attention** | 减少 attention 中间量往返 | 长上下文 +20–40% | 2 行 |
| **线程绑定大核** | 避免任务被调度到 A510 | +10–20% | 20 行 |
| **prompt cache 复用** | 多轮对话不重复 prefill | 首 token 从秒级降到百毫秒 | 100 行 |

前两项在 `llama_context_params` 上就是两个字段：

```cpp
cp.type_k = GGML_TYPE_Q8_0;   // KV cache 量化
cp.type_v = GGML_TYPE_Q8_0;
cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
```

注意 KV 量化需要模型架构支持 flash attention（Qwen2/2.5 支持），
且 `flash_attn` 与部分量化类型组合有额外约束，要在真机验证。

保守估计这四项叠加能把 3B 模型从 7–12 tok/s 提到 **12–18 tok/s**，
与 GPU 的期望收益（1.5×）基本重叠，但确定性高得多。

## 7. 建议

| 方案 | 收益 | 风险 | 工作量 | 建议 |
| --- | --- | --- | --- | --- |
| CPU 优化（KV 量化 + FA + 绑核） | 1.5–2× | 低 | 1–2 天 | **先做** |
| Vulkan 后端 | 1.2–1.8× decode，3–5× prefill | 高（驱动未知） | 1–2 周 | 验证后再定 |
| NPU（NNRt） | 2–4× 理论 | 极高（需转换模型） | 月级 | 不做 |

**分阶段路线：**

1. 先做 CPU 四项，拿到确定收益，同时把 `n_ctx` 8k + 输出 4k 的默认组合调稳
2. 写一个 30 行的 Vulkan 探测页（不进主流程），在真机上打印
   `vkEnumeratePhysicalDevices` 和扩展列表——这一步只需要半天，就能判断 GPU 路线是否彻底关闭
3. 如果第 2 步显示 `VK_KHR_shader_float16_int8` + `VK_KHR_8bit_storage` 都在，再评估接 `ggml-vulkan`
4. 如果扩展缺失，这条路就到此为止，把精力放到长上下文与多轮对话体验上

## 8. 一句话总结

> 手机 GPU 跑 LLM 不是「更快」，是「同样受带宽限制，但能少浪费一点」。
> 在 UMA 架构 + 未知驱动 + 手机散热这三重约束下，先把 CPU 侧的带宽利用率从 40% 拉到 70%，
> 比赌一个 1.5 倍的 GPU 后端要划算得多。
