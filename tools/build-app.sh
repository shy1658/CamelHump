#!/usr/bin/env bash
# 构建华为应用市场上架用的 .app 包（发布证书签名）。
#
# 完整流程（每一步都是踩过坑才定下来的）：
#
#   1. hvigor 的 storePassword/keyPassword 只认 DevEco Studio 加密过的 hex 密文，
#      明文过不了。解密需要 keystore/material 下的加密材料
#      （fd / ac / ce 三个目录）。
#      → 从命令行工具链复制：hvigor-ohos-plugin/res/material
#      → 密码用 tools/encrypt-signing-pwd.js 加密
#
#   2. assembleApp 必须用 --mode project，不是 --mode module。
#      --mode module 是给 assembleHap 用的，用错会报
#      "Task [ 'assembleApp' ] was not found in the project"。
#
#   3. .app 内嵌的 HAP 是 unsigned 的 —— 这是 hvigor 的正常行为。
#      PackageApp 收集的是 getModuleTargetOutputFileName(name, false)
#      （false → unsigned 文件名），签名由 SignApp 打在 .app 这一层。
#      验签要对 .app 做，不是对内嵌 HAP 做。
#
# 用法:
#   ./tools/build-app.sh              # 构建 .app
#   ./tools/build-app.sh --refresh    # 先重新生成加密密码再构建
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KS_DIR="$ROOT/keystore"
CERT="$KS_DIR/release.cer"
PROFILE="$KS_DIR/release.p7b"
P12="$KS_DIR/release.p12"
MATERIAL="$KS_DIR/material"

STORE_PWD="MjkwZjBlZTUxMjY1Y2FhMjgzNTA3N2QyNjNk"
KEY_PWD="ZDg4Y2I0ZTM5ZDdmOTJkZDA4NmNhYmQ5YzIx"
KEY_ALIAS="camelhump-release-v1"

TOOLCHAIN="${TOOLCHAIN:-/root/ohos/sdk/18/toolchains}"
HVIGOR_PLUGIN="${HVIGOR_PLUGIN:-/root/ohos-clt/command-line-tools/hvigor/hvigor-ohos-plugin}"

# ---- 前置检查 ----
missing=0
for f in "$CERT" "$PROFILE" "$P12"; do
  if [ ! -f "$f" ]; then
    echo "缺少文件: $f" >&2
    missing=1
  fi
done
if [ "$missing" = "1" ]; then
  echo >&2
  echo "请先完成发布证书申请：" >&2
  echo "  1. ./tools/gen-release-csr.sh   生成密钥与 CSR" >&2
  echo "  2. 上传 keystore/release.csr 到 AGC，下载 .cer 与 .p7b 放到 keystore/" >&2
  exit 1
fi

# ---- 环境 ----
export PATH="/root/ohos-clt/command-line-tools/bin:$PATH"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/root/ohos-clt/command-line-tools/sdk}"
export DEVECO_NODE_HOME="${DEVECO_NODE_HOME:-/root/ohos-clt/command-line-tools/tool/node}"
export OHOS_SDK_NATIVE="$DEVECO_SDK_HOME/default/openharmony/native"
export PATH="$DEVECO_NODE_HOME/bin:$DEVECO_SDK_HOME/default/openharmony/toolchains:$PATH"

run_hvigor() {
  hvigorw "$@" --no-daemon 2>&1 | tr '\r' '\n' \
    | grep -oE "Error Message:.*|Failed :[a-zA-Z:]+|BUILD (FAILED|SUCCESS).*|Finished :[a-zA-Z:@]+" || true
}

# ============================================================
# 准备 material 与加密密码
# ============================================================
if [ ! -d "$MATERIAL" ]; then
  echo "==> 复制 hvigor 加密材料"
  cp -r "$HVIGOR_PLUGIN/res/material" "$MATERIAL"
  echo "    $MATERIAL"
fi

if [ "${1:-}" = "--refresh" ]; then
  echo "==> 重新加密签名密码"
  STORE_ENC="$(node tools/encrypt-signing-pwd.js "$STORE_PWD")"
  KEY_ENC="$(node tools/encrypt-signing-pwd.js "$KEY_PWD")"
  python3 - "$STORE_ENC" "$KEY_ENC" <<'PY'
import re, sys
store, key = sys.argv[1], sys.argv[2]
p = 'build-profile.json5'
s = open(p).read()
s = re.sub(r'"storePassword": "[0-9a-f]{100,}"', f'"storePassword": "{store}"', s)
s = re.sub(r'"keyPassword": "[0-9a-f]{100,}"', f'"keyPassword": "{key}"', s)
open(p, 'w').write(s)
print('    build-profile.json5 已更新')
PY
fi

# ============================================================
# 构建
# ============================================================
echo
echo "==> [1/2] 构建 .app（project 模式，release 签名）"
run_hvigor assembleApp --mode project -p product=default -p buildMode=release

OUT="$ROOT/CamelHump-release.app"
rm -f "$OUT"

APP_SRC=""
for cand in "$ROOT"/build/outputs/default/*-signed.app; do
  if [ -f "$cand" ]; then APP_SRC="$cand"; break; fi
done

if [ -z "$APP_SRC" ]; then
  echo "未找到签名后的 .app 产物，请检查上面的构建日志" >&2
  exit 1
fi
cp "$APP_SRC" "$OUT"

# ============================================================
# 验签
# ============================================================
echo
echo "==> [2/2] 验签"
java -jar "$TOOLCHAIN/lib/hap-sign-tool.jar" verify-app \
  -inFile "$OUT" -outCertChain /tmp/app-chain.cer -outProfile /tmp/app-profile.p7b 2>&1 | tail -3

echo
echo "构建完成: $OUT"
ls -la "$OUT"
echo
echo "包内容："
unzip -l "$OUT" | head -8
echo
echo "下一步：AGC → 应用 → 版本信息 → 上传软件包，选择这个 .app 文件"
