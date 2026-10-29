#!/usr/bin/env bash
# 检查 GitHub 仓库的关键设置是否正常 —— 隐私政策等对外资源的可用性依赖它们。
#
# 背景：
#   仓库一旦被切成 private，GitHub 会自动关闭 Pages（免费账号的私有仓库不支持 Pages），
#   隐私政策链接随即 404 —— 而这会直接导致应用商店审核驳回。
#   这个坑很隐蔽：仓库设置页面不会提示，Pages 也不会报错，只是链接悄悄打不开。
#
#   另一个坑：Pages 配置本身可能被删除（gh api .../pages 返回 404），
#   需要重新创建并等待重新构建。
#
# 用法：
#   ./tools/check-repo.sh          # 检查并报告
#   ./tools/check-repo.sh --fix    # 发现问题自动修复（改回 public + 重建 Pages）
set -euo pipefail

REPO="shy1658/CamelHump"
PAGES_BRANCH="gh-pages"
SITE_URL="https://shy1658.github.io/CamelHump/"

GH_TOKEN="${GH_TOKEN:-$(cat /tmp/.gh_tok 2>/dev/null || true)}"
if [ -z "$GH_TOKEN" ]; then
  echo "需要 GH_TOKEN 环境变量" >&2
  echo "  export GH_TOKEN=ghp_xxx" >&2
  exit 1
fi
export GH_TOKEN

FIX="${1:-}"
ISSUES=0

api() { gh api "$@"; }

echo "=== 仓库可见性 ==="
VIS=$(api repos/$REPO --jq '.visibility')
PRIV=$(api repos/$REPO --jq '.private')
echo "  visibility: $VIS   private: $PRIV"

if [ "$PRIV" = "true" ]; then
  echo "  ⚠️ 仓库是私有的！GitHub 会自动关闭 Pages，隐私政策链接会 404"
  ISSUES=$((ISSUES+1))
  if [ "$FIX" = "--fix" ]; then
    echo "  → 改回 public"
    api -X PATCH repos/$REPO -f private=false -f visibility=public --jq '.visibility'
  fi
fi

echo
echo "=== Pages 配置 ==="
PAGES=$(api repos/$REPO/pages 2>/dev/null || echo "")
if [ -z "$PAGES" ]; then
  echo "  ⚠️ Pages 未启用（Pages site 不存在）"
  ISSUES=$((ISSUES+1))
  if [ "$FIX" = "--fix" ]; then
    echo "  → 重新创建 Pages（分支 $PAGES_BRANCH）"
    api repos/$REPO/pages -X POST \
      -f source[branch]="$PAGES_BRANCH" -f source[path]=/ -f build_type=legacy >/dev/null
    echo "  → 等待构建..."
    for i in $(seq 1 12); do
      sleep 5
      S=$(api repos/$REPO/pages --jq '.status')
      echo "     $i: $S"
      [ "$S" = "built" ] && break
    done
  fi
else
  echo "  status : $(echo "$PAGES" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
  echo "  branch : $(echo "$PAGES" | python3 -c 'import sys,json;print(json.load(sys.stdin)["source"]["branch"])')"
  echo "  url    : $(echo "$PAGES" | python3 -c 'import sys,json;print(json.load(sys.stdin)["html_url"])')"
fi

echo
echo "=== 站点可达性 ==="
for path in "" "privacy.html"; do
  URL="$SITE_URL$path"
  CODE=$(curl -sL --max-time 25 -o /dev/null -w "%{http_code}" "$URL" || echo "ERR")
  if [ "$CODE" = "200" ]; then
    echo "  ✓ $URL  ($CODE)"
  else
    echo "  ✗ $URL  ($CODE)"
    ISSUES=$((ISSUES+1))
  fi
done

echo
if [ "$ISSUES" = "0" ]; then
  echo "全部正常。"
else
  echo "发现 $ISSUES 个问题。运行 './tools/check-repo.sh --fix' 自动修复。" >&2
  exit 1
fi
