# 性能实测与调优

这份文档记录的是「怎么测」，不是「测试结果」。机型差异极大，别人机器上的数字对你没有参考价值，自己跑一遍才算数。

## 一、先决条件：确认优化真的生效

移动端推理最常见的误判是「Debug 构建跑 -O0，然后认为手机跑不动大模型」。性能差 10 倍，现象和算力不足完全一样。

编译后检查生成的 `build.ninja`：

```bash
grep -m5 "CMAKE_CXX_FLAGS" build/default/intermediates/cmake/default/obj/arm64-v8a/build.ninja
```

必须看到 `-O3 -DNDEBUG`。只有 `-O0` 或什么都没有，说明 `build-profile.json5` 里的 Release 配置没被选中。

`CMakeLists.txt` 里已经对 Release / RelWithDebInfo 强制加了 `-O3 -DNDEBUG -fvectorize`，但工程级的构建模式仍需在 DevEco 里确认为 release。

## 二、基线测试

用命令行跑，避免 UI 层开销干扰：

```bash
hdc file send ./libs/arm64-v8a/llama-cli /data/local/tmp/
hdc shell chmod +x /data/local/tmp/llama-cli
hdc file send ./qwen2.5-1.5b-q4km.gguf /data/local/tmp/

hdc shell /data/local/tmp/llama-cli \
  -m /data/local/tmp/qwen2.5-1.5b-q4km.gguf \
  -p "用一句话解释什么是端侧推理" \
  -n 128 -t 4 --no-mmap --no-warmup
```

记四个数：`load time`（模型加载）、`prompt eval time`（prefill）、`eval time`（decode）、`tokens per second`。

## 三、必须做的三组对照

### 组 1：mmap 开关

```bash
--no-mmap   vs   默认（开启 mmap）
```

冷启动各测三次（每次先重启设备或清空缓存），热启动再测三次。预期看到数量级差异。

如果 `--no-mmap` 没有明显更快，说明你的机型/系统版本上这个已知问题已经修复，可以把默认值改回来省内存。

### 组 2：线程数

```
-t 2 / 4 / 6 / 8
```

不只看 tok/s，同时记录：

```bash
# 采样温度与频率
hdc shell "cat /sys/class/thermal/thermal_zone*/temp"
hdc shell "cat /sys/class/thermal/thermal_zone*/type"
```

跑 3 分钟，每 30 秒记一次温度。如果 8 线程在 90 秒后 tok/s 掉到 4 线程以下，说明已经触发降频，那 8 线程就是负收益。

### 组 3：上下文长度

```
-c 1024 / 2048 / 4096
```

看两件事：decode 速度是否下降，以及峰值内存。1.5B 模型在 4096 上下文下 KV cache 约 250-400 MB（取决于是否量化），这对手机是实打实的压力。

## 四、参考量级

以下数字来自中高端手机（麒麟 9000s / 骁龙 8 Gen 3 级别）的公开实践，仅用于判断「是否明显不对」：

| 模型 | 量化 | 权重体积 | decode 速度 | 峰值内存 |
|---|---|---|---|---|
| 0.5B | Q4_K_M | ~400 MB | 25-40 tok/s | ~0.7 GB |
| 1.5B | Q4_K_M | ~1.06 GB | 15-25 tok/s | ~1.3 GB |
| 3B | Q4_K_M | ~1.98 GB | 7-12 tok/s | ~2.3 GB |
| 7B | Q4_K_M | ~4.4 GB | 2-4 tok/s | ~5 GB |

如果你测得的结果比表里低一半以上，先查 §1 的优化开关，再查是不是跑了非量化的 F16 模型。

## 五、温度与功耗

```bash
# 连续跑 200 token，记录
hdc shell "cat /sys/class/thermal/thermal_zone0/temp"
hdc shell "dumpsys battery | grep -E 'level|temperature'"
```

合格线：3 分钟连续对话，机身温升不超过 8℃，电量下降不超过 5%。

不达标的第一反应不是加散热，是减线程。`n_threads = 4` → `3` 通常能让温升降 2-3℃，速度只掉 10%。

## 六、常见异常与判断

| 现象 | 先查什么 |
|---|---|
| 加载卡 30 秒以上 | mmap 是否关闭 |
| tok/s 只有预期 1/10 | 构建模式是不是 Debug |
| 输出全是重复词 | 采样器链顺序，重复惩罚是否生效 |
| 输出到一半停住 | `maxTokens` 是否太小，或 `n_ctx` 不够 |
| 应用直接消失（无崩溃日志） | 内存超配额被系统回收，降模型规模或上下文 |
| 第二句开始变慢 | KV cache 未复用，当前实现每轮清空重算 |
