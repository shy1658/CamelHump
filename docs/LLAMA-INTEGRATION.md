# 推理引擎接入说明

这份文档记录 llama.cpp 是怎么进到 HAP 里的、踩了哪些坑、以及怎么验证它真的在里面。
1.0.1 的 HAP 之所以一加载模型就报 `engine not compiled in`，就是因为下面这套流程当时没走完。

## 1. 选型与版本

| 项目 | 值 |
| --- | --- |
| 上游仓库 | `github.com/ggml-org/llama.cpp` |
| 分支 | `master`（快照） |
| 上游自报版本 | `0.7.0`（`LLAMA_VERSION_MAJOR/MINOR/PATCH`） |
| 源码包 sha256 | `16fcc704a0237b5ebe79ae803a073d05191db82bffe2f7024f570d6d2876a5f0`（codeload 的 ETag 即内容 sha256） |
| 目标 ABI | `arm64-v8a`，`--target=aarch64-linux-ohos`，OHOS NDK clang |
| 链接方式 | 静态链入 `libcamelhump.so`，不额外产出 `.so` |

选 master 快照而不是某个 release tag，是因为 `llama_memory_clear()` 这套新 KV API 在 2025 年才稳定下来，release 分支上的一部分 tag 还停留在 `llama_kv_cache_clear()`。
如果要换版本，先确认 `include/llama.h` 里有 `llama_memory_clear` 与 `llama_get_memory` 两个符号；没有的话编译时加 `-DCAMELHUMP_LEGACY_KV_API=ON`。

## 2. 获取源码

```bash
./tools/fetch-llama.sh          # 走 gh-proxy 前缀
DIRECT=1 ./tools/fetch-llama.sh # 网络好时直连 codeload
```

不走 `git submodule` 的原因：浅克隆在部分网络环境下会卡死。

```
error: RPC failed; curl 28 Operation too slow. Less than 1000 bytes/sec transferred the last 120 seconds
fatal: fetch-pack: invalid index-pack output
```

而 codeload 的 tarball 通道同一条线路能跑满，38 MB 一分钟内下完。
`.gitmodules` 仍然保留，网络正常的机器照样可以 `git submodule update --init`。

## 3. 上游 API 变更（这次要改的四处）

升级到 2026-10 的 master 之后，本工程原来按 2025 年中 API 写的代码有四处对不上：

| 位置 | 旧写法 | 新写法 | 后果 |
| --- | --- | --- | --- |
| `llama_bridge.cpp` | `mp.use_mmap = ...; mp.use_mlock = ...` | `mp.load_mode = LLAMA_LOAD_MODE_MMAP / _MLOCK / _MMAP_MLOCK / _NONE` | 编译报 `no member named 'use_mmap'` |
| `llama_bridge.cpp` | `llama_sampler_init_penalties(64, rp, 0, 0)` | 首参多了 `n_vocab`：`(n_vocab, 64, rp, 0, 0)` | 参数错位，惩罚对象全错 |
| `ggml-cpu.c` | `pthread_setaffinity_np(...)` | musl 只有 `sched_setaffinity(...)` | 编译报 undeclared |
| `ggml-cpu.c` | `CPU_ZERO` / `CPU_SET` 直接用 | 必须先有 `_GNU_SOURCE` | 报 `undeclared identifier 'cpuset'` |

前两处改在本工程自己的代码里，后两处改在 `third_party/llama.cpp` 里。
`fetch-llama.sh` 会自动打下 `ggml-cpu.c` 那一处补丁；`_GNU_SOURCE` 则由 `CMakeLists.txt` 用
`target_compile_definitions(ggml-cpu PRIVATE _GNU_SOURCE)` 补上，不改上游文件。

> 为什么不能全局加 `_GNU_SOURCE`：它会把 glibc/musl 里一批非标准符号一起放出来，
> 和 OHOS 自己的 `hilog` / `napi` 头文件容易撞。只给 ggml-cpu 这一个目标加最稳。

## 4. 编译选项

```cmake
set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16")
set(GGML_CPU_KLEIDIAI OFF)
set(GGML_NATIVE       OFF)
set(GGML_LTO          OFF)
set(GGML_OPENMP       OFF)
```

- `GGML_CPU_ARM_ARCH` 只有在 `GGML_NATIVE=OFF` 时才会被采纳（两者互斥，同时开直接 FATAL_ERROR）。
  这里显式写死 `armv8.2-a+dotprod+fp16`，让编译器生成 `sdot/udot` 与 `fmla` 两组指令，
  Kirin 9000 系列都支持。`GGML_NATIVE=ON` 会去探测**构建机**的 CPU，交叉编译下毫无意义。
- `GGML_CPU_KLEIDIAI=OFF`：这个选项会在 CMake 配置阶段用 `FetchContent` 从
  GitHub Releases 现下 KleidiAI 源码。交叉编译机上一旦拉不到，整个 configure 就失败，
  报错还埋在 FetchContent 里很难看。收益（INT8 matmul 加速）在手机上被内存带宽吃掉大半，
  不值得引入这个构建期网络依赖。
- `GGML_LTO=OFF`：LTO 会让链接阶段的内存占用翻几倍，对一个 5 MB 的目标收益有限。
- `GGML_OPENMP=OFF`：OHOS 没有 libgomp，只能关。

另外 `CMakeLists.txt` 里有一段「Debug 强制 -O3」的保护：

```cmake
elseif(CAMELHUMP_OPTIMIZE_IN_DEBUG)
  set(CMAKE_CXX_FLAGS_DEBUG "-O3 -g" CACHE STRING "" FORCE)
```

hvigor 默认 `buildMode=debug`，传到 CMake 就是 `CMAKE_BUILD_TYPE=Debug`，也就是 `-O0`。
矩阵乘在 `-O0` 下 NEON intrinsic 几乎退化干净，1.5B 模型会慢到一个数量级，
非常容易被误判成「手机跑不动大模型」。所以这里直接把 Debug 的编译选项改写掉。

## 5. 验证引擎确实在包里

```bash
SO=entry/build/default/intermediates/stripped_native_libs/default/arm64-v8a/libcamelhump.so

# 1. stub 的提示串必须消失
llvm-strings "$SO" | grep -c "engine not compiled in"   # 期望 0

# 2. llama / ggml 符号必须存在
llvm-nm -D --defined-only "$SO" | grep -c "llama_\|ggml_"   # 期望 5000+

# 3. dotprod / fp16 指令确实生成了
llvm-objdump -d "$SO" | grep -c "udot\|sdot"   # 期望 > 0
llvm-objdump -d "$SO" | grep -c "fmla"         # 期望 > 0
```

本次 1.0.2 的实测值：

| 检查项 | 结果 |
| --- | --- |
| `engine not compiled in` 出现次数 | 0 |
| llama + ggml 导出符号 | 5514 |
| `udot` / `sdot` 指令 | 1132 |
| `fmla` 指令 | 2461 |
| `libcamelhump.so`（strip 后） | 5.2 MB |
| HAP | 6.9 MB |

## 6. 构建耗时参考

| 阶段 | 冷编译 | 增量 |
| --- | --- | --- |
| llama.cpp + ggml（85 个编译单元） | ~50 s | 0 |
| 本工程 3 个 cpp | ~3 s | ~3 s |
| ArkTS | ~18 s | ~4 s |

llama.cpp 用的是 unity build，`src/` 下十几个文件被合成 10 个 `unity_*_cxx.cxx`，
所以编译单元只有 85 个而不是两百多个。
