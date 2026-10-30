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
# 本脚本还承担第二项职责：**合规前提守护**。
#   上架材料（docs/NETWORK-BEHAVIOR.md 等）全部建立在"应用无网络能力、
#   无权限、模型由用户自导入"这三条前提上。任何一条被破坏，
#   架构图、举证截图、模型来源说明会同时失效，且审核结论会翻转。
#   所以这些检查放在同一个脚本里，每次发版跑一遍 —— 防止前提被静默破坏。
#
# 用法：
#   ./tools/check-repo.sh          # 检查并报告
#   ./tools/check-repo.sh --fix    # 发现仓库设置问题自动修复
set -euo pipefail

REPO="shy1658/CamelHump"
PAGES_BRANCH="gh-pages"
SITE_URL="https://shy1658.github.io/CamelHump/"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

GH_TOKEN="${GH_TOKEN:-$(cat /tmp/.gh_tok 2>/dev/null || true)}"
NEED_TOKEN=0
[ -z "$GH_TOKEN" ] && NEED_TOKEN=1

FIX="${1:-}"
ISSUES=0

api() { gh api "$@"; }

echo "=== 合规前提守护 ==="
echo "    （上架材料的前提条件；任一项失败则单机 APP 论证失效）"

# 1. 权限列表必须为空
PERM=$(grep -rn "ohos.permission" --include="*.json5" --include="*.json" "$ROOT/entry" "$ROOT/AppScope" 2>/dev/null || true)
if [ -z "$PERM" ]; then
  echo "  ✓ 权限声明：0 条"
else
  echo "  ✗ 权限声明：发现网络/其他权限，上架材料已失效"
  echo "$PERM" | sed 's/^/      /'
  ISSUES=$((ISSUES+1))
fi

# 2. 第三方依赖必须为空
if grep -q '"dependencies": *{[^}]' "$ROOT/oh-package.json5" 2>/dev/null; then
  echo "  ✗ 第三方依赖：非空，可能引入联网 SDK"
  ISSUES=$((ISSUES+1))
else
  echo "  ✓ 第三方依赖：0 个"
fi

# 3. 不得引入网络 Kit / 网络 API
NET=$(grep -rniE "@ohos\.net\.|@kit\.NetworkKit|http\.createHttp|WebSocket|XMLHttpRequest|fetch\(" \
  --include="*.ets" --include="*.cpp" --include="*.h" "$ROOT/entry/src/main" 2>/dev/null || true)
if [ -z "$NET" ]; then
  echo "  ✓ 网络 API：0 处命中"
else
  echo "  ✗ 网络 API：发现调用，单机 APP 论证失效"
  echo "$NET" | sed 's/^/      /'
  ISSUES=$((ISSUES+1))
fi

# 4. AI 生成内容不得出现导出/复制能力（否则隐式标识义务触发）
#    注意：不能用裸 "export" 匹配 —— ArkTS 的 `export struct/function/class`
#    是语法关键字，会大量误报。只匹配真正调用外部 API 的形式。
EXP=$(grep -nE "pasteboard|createData|getSystemPasteboard|saveFile|exportFile|shareFile|@kit\.FilePickerKit|fileIo\.copyFile" \
  "$ROOT/entry/src/main/ets/view/ChatView.ets" 2>/dev/null || true)
if [ -z "$EXP" ]; then
  echo "  ✓ AI 内容导出：无（无隐式标识适用对象）"
else
  echo "  ⚠️ AI 内容导出：已出现导出/复制能力，须评估隐式标识义务"
  echo "$EXP" | sed 's/^/      /'
  ISSUES=$((ISSUES+1))
fi

# 5. 文件写入点必须仍为 2 处（模型文件 + meta.json）
WRITES=$(grep -rn "fs.writeSync" --include="*.ets" "$ROOT/entry/src/main/ets" 2>/dev/null | wc -l | tr -d ' ')
if [ "$WRITES" = "2" ]; then
  echo "  ✓ 文件写入点：2 处（均为非 AI 输出）"
else
  echo "  ⚠️ 文件写入点：$WRITES 处（预期 2），须复核是否有生成合成内容文件"
  ISSUES=$((ISSUES+1))
fi

echo
if [ "$NEED_TOKEN" = "1" ]; then
  echo "缺少 GH_TOKEN，跳过仓库可见性 / Pages / 站点可达性检查。"
  echo "  export GH_TOKEN=ghp_xxx" >&2
  echo
else
  export GH_TOKEN
fi

if [ "$NEED_TOKEN" != "1" ]; then
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
fi   # end of GH_TOKEN-gated block

echo
if [ "$ISSUES" = "0" ]; then
  echo "全部正常。"
else
  echo "发现 $ISSUES 个问题。运行 './tools/check-repo.sh --fix' 自动修复。" >&2
  exit 1
fi
