#!/usr/bin/env bash
# 一键注册 SSH 公钥到 GitHub 并完成推送。
#
# 前提：本机已存在 ~/.ssh/id_ed25519_github 及其 .pub 文件。
#
# 用法：
#   ./tools/push-via-ssh.sh                 # 用 gh CLI 注册 + 推送
#   ./tools/push-via-ssh.sh --token XXX     # 用 PAT 注册 + 推送
#
# 若 gh CLI 未安装，先执行：
#   winget install --id GitHub.cli
# 或从 https://cli.github.com/ 下载 MSI 安装。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KEY_FILE="$HOME/.ssh/id_ed25519_github"
PUB_FILE="$KEY_FILE.pub"
TITLE="CamelHump-2026 (Windows)"

if [ ! -f "$PUB_FILE" ]; then
  echo "找不到公钥文件：$PUB_FILE" >&2
  echo "先生成：ssh-keygen -t ed25519 -C 'shy1658@CamelHump-2026' -f $KEY_FILE -N ''" >&2
  exit 1
fi

TOKEN_ARG=""
if [ "${1:-}" = "--token" ]; then
  TOKEN_ARG="${2:-}"
  [ -z "$TOKEN_ARG" ] && { echo "缺少 token" >&2; exit 1; }
fi

echo "=== 待注册的公钥 ==="
cat "$PUB_FILE"
echo

# --- 注册公钥 ---
if [ -n "$TOKEN_ARG" ]; then
  echo "=== 通过 PAT 注册公钥 ==="
  GH_TOKEN="$TOKEN_ARG" gh ssh-key add "$PUB_FILE" --title "$TITLE"
elif command -v gh >/dev/null 2>&1; then
  echo "=== 通过 gh CLI 注册公钥 ==="
  gh ssh-key add "$PUB_FILE" --title "$TITLE"
else
  echo "!! 未找到 gh CLI，也未提供 --token。" >&2
  echo >&2
  echo "请二选一：" >&2
  echo "  A) 手动添加（最简单）：" >&2
  echo "     打开 https://github.com/settings/ssh/new" >&2
  echo "     Title 填 '$TITLE'" >&2
  echo "     Key 粘贴下面这行，回车保存：" >&2
  echo >&2
  sed 's/^/     /' "$PUB_FILE" >&2
  echo >&2
  echo "  B) 装 gh CLI 后重跑本脚本：" >&2
  echo "     winget install --id GitHub.cli" >&2
  echo >&2
  echo "  C) 带 PAT 重跑：./tools/push-via-ssh.sh --token ghp_xxx" >&2
  exit 1
fi

echo "✅ 公钥已注册"

# --- 验证认证 ---
echo
echo "=== 验证 SSH 认证 ==="
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -T git@ssh.github.com 2>&1 || true

# --- 推送 ---
echo
echo "=== 推送 main ==="
git push ssh-origin main

echo
echo "✅ 推送完成。"
echo "   若希望以后默认走 SSH："
echo "   git remote set-url origin git@ssh.github.com:shy1658/CamelHump.git"
