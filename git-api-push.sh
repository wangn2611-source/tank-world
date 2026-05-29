#!/bin/bash
# git-api-push.sh - 使用 GitHub API 推送代码 (解决 git HTTPS 连接问题)
# 用法: bash git-api-push.sh <仓库目录> <commit消息>

set -euo pipefail

REPO_DIR="${1:-.}"
COMMIT_MSG="${2:-更新代码}"

cd "$REPO_DIR"

# 从 git 远程 URL 中提取 owner/repo
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
if [[ -z "$REMOTE_URL" ]]; then
  echo "❌ 没有找到远程仓库 (git remote)"
  exit 1
fi

# 从 URL 提取 owner/repo 和 token
if [[ "$REMOTE_URL" =~ https://(.+):(.+)@github.com/(.+)/(.+)\.git ]]; then
  TOKEN="${BASH_REMATCH[2]}"
  OWNER="${BASH_REMATCH[3]}"
  REPO="${BASH_REMATCH[4]}"
elif [[ "$REMOTE_URL" =~ github.com/(.+)/(.+)\..* ]]; then
  echo "❌ URL 中没有找到 Token，请先用 git remote set-url 添加 token"
  exit 1
else
  echo "❌ 无法解析远程 URL: $REMOTE_URL"
  exit 1
fi

API="https://api.github.com"
HEADER=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "Content-Type: application/json")

echo "📦 仓库: $OWNER/$REPO"
echo "📝 提交信息: $COMMIT_MSG"

# 1. 获取当前分支的最新 commit SHA
echo "🔍 获取当前分支信息..."
REF=$(curl -s "${HEADER[@]}" "$API/repos/$OWNER/$REPO/git/refs/heads/master" 2>/dev/null || echo "")
CURRENT_SHA=$(echo "$REF" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['object']['sha'])" 2>/dev/null || echo "")

# 如果第一次推送 (空仓库)
if [[ -z "$CURRENT_SHA" ]]; then
  echo "🆕 首次推送，创建初始 commit..."
fi

# 获取当前树的 SHA
if [[ -n "$CURRENT_SHA" ]]; then
  COMMIT=$(curl -s "${HEADER[@]}" "$API/repos/$OWNER/$REPO/git/commits/$CURRENT_SHA")
  BASE_TREE_SHA=$(echo "$COMMIT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['tree']['sha'])" 2>/dev/null || echo "")
else
  BASE_TREE_SHA=""
fi

# 2. 收集要推送的文件
FILES=()
while IFS= read -r -d '' f; do
  # 排除 .git 目录和脚本自身
  if [[ "$f" != .git/* && "$f" != "git-api-push.sh" ]]; then
    FILES+=("$f")
  fi
done < <(git ls-files -z 2>/dev/null || find . -not -path './.git/*' -not -name 'git-api-push.sh' -type f -print0)

echo "📄 共 ${#FILES[@]} 个文件"

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "⚠️ 没有文件需要推送"
  exit 0
fi

# 3. 为每个文件创建 blob，并构建树条目
TREE_ENTRIES=()
for f in "${FILES[@]}"; do
  if [[ ! -f "$f" ]]; then continue; fi
  CONTENT=$(base64 -w0 < "$f" 2>/dev/null || base64 < "$f" 2>/dev/null)
  if [[ -z "$CONTENT" ]]; then
    echo "⚠️  跳过 $f (无法读取)"
    continue
  fi
  echo "  📝 处理: $f"
  BLOB=$(curl -s "${HEADER[@]}" "$API/repos/$OWNER/$REPO/git/blobs" \
    -d "$(python3 -c "
import json
print(json.dumps({'content': '$CONTENT', 'encoding': 'base64'}))
")" 2>/dev/null)

  BLOB_SHA=$(echo "$BLOB" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sha'])" 2>/dev/null || echo "")
  if [[ -z "$BLOB_SHA" ]]; then
    echo "⚠️  跳过 $f (无法创建 blob)"
    continue
  fi
  TREE_ENTRIES+=("{\"path\":\"$f\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"$BLOB_SHA\"}")
done

if [[ ${#TREE_ENTRIES[@]} -eq 0 ]]; then
  echo "❌ 没有成功创建任何文件 blob"
  exit 1
fi

# 4. 创建新树
echo "🌳 创建新树..."
TREE_JSON=$(python3 -c "
import json
entries = [${TREE_ENTRIES[@]}]
tree = {'tree': entries}
if '$BASE_TREE_SHA':
    tree['base_tree'] = '$BASE_TREE_SHA'
print(json.dumps(tree))
")

NEW_TREE=$(curl -s -X POST "${HEADER[@]}" "$API/repos/$OWNER/$REPO/git/trees" -d "$TREE_JSON")
NEW_TREE_SHA=$(echo "$NEW_TREE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sha'])" 2>/dev/null || echo "")

if [[ -z "$NEW_TREE_SHA" ]]; then
  echo "❌ 创建树失败"
  echo "$NEW_TREE" | head -5
  exit 1
fi
echo "  ✅ 树 SHA: $NEW_TREE_SHA"

# 5. 创建 commit
echo "💾 创建 commit..."
COMMIT_JSON=$(python3 -c "
import json
commit = {
    'message': '$COMMIT_MSG',
    'tree': '$NEW_TREE_SHA'
}
if '$CURRENT_SHA':
    commit['parents'] = ['$CURRENT_SHA']
print(json.dumps(commit))
")

NEW_COMMIT=$(curl -s -X POST "${HEADER[@]}" "$API/repos/$OWNER/$REPO/git/commits" -d "$COMMIT_JSON")
NEW_COMMIT_SHA=$(echo "$NEW_COMMIT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sha'])" 2>/dev/null || echo "")

if [[ -z "$NEW_COMMIT_SHA" ]]; then
  echo "❌ 创建 commit 失败"
  echo "$NEW_COMMIT" | head -5
  exit 1
fi
echo "  ✅ Commit SHA: $NEW_COMMIT_SHA"

# 6. 更新分支引用
echo "📤 推送到 master..."
UPDATE=$(curl -s -X PATCH "${HEADER[@]}" "$API/repos/$OWNER/$REPO/git/refs/heads/master" \
  -d "{\"sha\":\"$NEW_COMMIT_SHA\",\"force\":true}")

UPDATE_SHA=$(echo "$UPDATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['object']['sha'])" 2>/dev/null || echo "")
if [[ "$UPDATE_SHA" == "$NEW_COMMIT_SHA" ]]; then
  echo ""
  echo "✅✅✅ 推送成功！✅✅✅"
  echo "   https://github.com/$OWNER/$REPO"
  # 更新本地引用，保持同步
  git update-ref refs/heads/master "$NEW_COMMIT_SHA" 2>/dev/null || true
else
  echo "⚠️  可能失败:"
  echo "$UPDATE" | head -5
  exit 1
fi
