#!/usr/bin/env bash
# 拉取并打补丁：把 llama.cpp 源码放到 entry/src/main/cpp/third_party/llama.cpp
#
# 为什么不是 git submodule：
#   llama.cpp 仓库历史很大，浅克隆在部分网络环境下会卡在 fetch-pack 阶段
#   （"RPC failed; curl 28 Operation too slow"）。实测 codeload 的 tarball
#   通道更快也更稳，因此这里用 tarball + 补丁，而不是 submodule。
#   .gitmodules 仍然保留，网络正常的机器照样可以 submodule update。
#
# 用法:
#   ./tools/fetch-llama.sh              # 默认走 gh-proxy 前缀
#   DIRECT=1 ./tools/fetch-llama.sh     # 直连 codeload
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/entry/src/main/cpp/third_party"
SRC="$DEST/llama.cpp"

if [ -f "$SRC/CMakeLists.txt" ]; then
  echo "llama.cpp 已存在: $SRC"
  echo "如需重拉，先删除该目录。"
  exit 0
fi

mkdir -p "$DEST"
cd "$DEST"

URL="https://codeload.github.com/ggml-org/llama.cpp/tar.gz/refs/heads/master"
if [ "${DIRECT:-0}" != "1" ]; then
  URL="https://gh-proxy.com/$URL"
fi

echo "下载 $URL"
curl -L --retry 3 --max-time 900 -o llama.tar.gz "$URL"
gzip -t llama.tar.gz

rm -rf llama.cpp-master
tar xzf llama.tar.gz
mv llama.cpp-master llama.cpp
rm -f llama.tar.gz

echo "打补丁..."
python3 - "$SRC" <<'PY'
import sys, pathlib

root = pathlib.Path(sys.argv[1])

# --- 补丁 1: OHOS 上没有 pthread_setaffinity_np -----------------------------
# OHOS 与 Android 一样用 musl, 只有 sched_setaffinity, 没有 pthread 包装版本。
f = root / 'ggml/src/ggml-cpu/ggml-cpu.c'
s = f.read_text()
old = """#ifdef __ANDROID__
    err = sched_setaffinity(0, sizeof(cpuset), &cpuset);"""
new = """#if defined(__ANDROID__) || defined(__OHOS__)
    // HarmonyOS uses the same musl libc as Android: sched_setaffinity exists,
    // the pthread_setaffinity_np wrapper does not.
    err = sched_setaffinity(0, sizeof(cpuset), &cpuset);"""
if old in s:
    f.write_text(s.replace(old, new, 1))
    print('  patched ggml-cpu.c (sched_setaffinity)')
elif new in s:
    print('  ggml-cpu.c already patched')
else:
    sys.exit('!! ggml-cpu.c: expected hunk not found, upstream changed')
PY

cat <<'EOF'

完成。注意 CMakeLists.txt 里已经代你处理了两件事：
  - 给 ggml-cpu 加 -D_GNU_SOURCE（否则 CPU_ZERO / CPU_SET 未定义）
  - 关闭 GGML_CPU_KLEIDIAI（它会在配置期从 GitHub Releases 现场下载源码）

下一步:
  hvigorw assembleHap --no-daemon --no-incremental
EOF
