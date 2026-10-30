#!/usr/bin/env bash
# 把本地提交推送到 GitHub。
#
# 两条路径，按可用性自动选择：
#   路径 A（推荐）：SSH —— 密钥已注册时走这条，绕开 HTTPS 代理，稳定性最好
#   路径 B（兜底）：HTTPS + PAT —— 需要带 --token 参数
#
# 用法：
#   ./tools/push-via-ssh.sh                # 优先 SSH，失败自动回退并提示
#   ./tools/push-via-ssh.sh --token ghp_xxx
#
# ⚠️ 关于 PAT 的权限范围：
#   推送（写仓库）只需要 repo scope。
#   但「通过 API 注册 SSH 公钥」需要额外的 admin:public_key scope，
#   普通 fine-grained PAT 不含该权限，调用 /user/keys 会返回 404
#   （不是 403 —— 该缺失的特征就是 404，容易误判为路径写错）。
#   所以若公钥尚未注册，用 PAT 推送是可行的，但没法用 PAT 自动注册公钥，
#   此时请手动到 https://github.com/settings/ssh/new 添加一次。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KEY_FILE="$HOME/.ssh/id_ed25519_github"
PUB_FILE="$KEY_FILE.pub"
TITLE="CamelHump-2026 (Windows)"

TOKEN_ARG=""
if [ "${1:-}" = "--token" ]; then
  TOKEN_ARG="${2:-}"
  [ -z "$TOKEN_ARG" ] && { echo "缺少 token" >&2; exit 1; }
fi

if [ ! -f "$PUB_FILE" ]; then
  echo "找不到公钥文件：$PUB_FILE" >&2
  echo "先生成：ssh-keygen -t ed25519 -C '$TITLE' -f $KEY_FILE -N ''" >&2
  exit 1
fi

# ---------------------------------------------------------------- 路径 A: SSH
echo "=== 尝试 SSH 推送 ==="
echo "    远端：git@ssh.github.com:shy1658/CamelHump.git（443 端口）"
echo

if git push ssh-origin main 2>/tmp/push-ssh.err; then
  echo
  echo "✅ 推送完成（SSH）"
  exit 0
fi

echo "⚠️  SSH 推送失败："
sed 's/^/      /' /tmp/push-ssh.err | head -5
echo
echo "    最常见原因：公钥尚未添加到 GitHub。"
echo "    打开 https://github.com/settings/ssh/new"
echo "    Title 填 '$TITLE'，Key 粘贴："
sed 's/^/      /' "$PUB_FILE"
echo
rm -f /tmp/push-ssh.err

# ---------------------------------------------------------------- 路径 B: HTTPS
if [ -z "$TOKEN_ARG" ]; then
  echo "需要用 PAT 走 HTTPS 推送时，请带上 token 参数：" >&2
  echo "  ./tools/push-via-ssh.sh --token ghp_xxx" >&2
  exit 1
fi

echo "=== 回退到 HTTPS + PAT 推送 ==="
git -c credential.helper="!f() { echo username=x-access-token; echo password=$TOKEN_ARG; }; f" \
    push origin main

echo
echo "✅ 推送完成（HTTPS + PAT）"
echo
echo "提示：本次 token 只经命令行传入，未落盘保存。"
echo "     如需免重复传，在 GitHub 账号设置里给该 PAT 补上 admin:public_key"
echo "     scope 后重跑本脚本，即可自动注册公钥并永久走 SSH。"
