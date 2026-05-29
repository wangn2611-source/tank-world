#!/usr/bin/env python3
"""
github-push.py - 通过 GitHub API 推送代码 (解决 git HTTPS 连接问题)
用法: python3 github-push.py [提交信息]
"""
import os, sys, json, urllib.request, base64, subprocess, re

def api(url, data=None, method="GET"):
    token = os.environ.get("GH_TOKEN")
    if not token:
        # 从 git remote URL 提取
        try:
            remote = subprocess.run(["git", "remote", "get-url", "origin"],
                                  capture_output=True, text=True, cwd=REPO_DIR).stdout.strip()
            m = re.search(r'https://[^:]+:([^@]+)@github\.com/([^/]+)/([^/]+?)\.git', remote)
            if m:
                token = m.group(1)
                globals()["OWNER"] = m.group(2)
                globals()["REPO"] = m.group(3)
        except: pass
    if not token:
        print("❌ 请设置 GH_TOKEN 环境变量或在 git remote URL 中包含 token")
        sys.exit(1)

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "github-push-script",
    }
    if data is not None:
        headers["Content-Type"] = "application/json"
        req = urllib.request.Request(f"https://api.github.com{url}", json.dumps(data).encode(), headers, method=method)
    else:
        req = urllib.request.Request(f"https://api.github.com{url}", headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode()) if r.readable() else {}
    except urllib.error.HTTPError as e:
        err = e.read().decode()
        print(f"⚠️ API 错误 ({e.code}): {e.url}")
        # 404 时返回 None 表示不存在
        if e.code == 404: return None
        print(err[:200])
        return None
    except Exception as e:
        print(f"⚠️ 请求错误: {e}")
        return None

REPO_DIR = os.getcwd()
OWNER, REPO = "", ""
COMMIT_MSG = sys.argv[1] if len(sys.argv) > 1 else "更新代码"

print(f"📂 仓库目录: {REPO_DIR}")
print(f"📝 提交信息: {COMMIT_MSG}")

# 获取文件列表
result = subprocess.run(["git", "ls-files"], capture_output=True, text=True, cwd=REPO_DIR)
files = [f for f in result.stdout.strip().split("\n") if f and not f.startswith(".git/")]
if not files:
    # fallback: 所有非 git 文件
    for root, dirs, fnames in os.walk(REPO_DIR):
        dirs[:] = [d for d in dirs if d != ".git"]
        for fn in fnames:
            fp = os.path.relpath(os.path.join(root, fn), REPO_DIR)
            if fp != "github-push.py" and fp != "git-api-push.sh":
                files.append(fp)

print(f"📄 共 {len(files)} 个文件")
for f in files:
    print(f"   - {f}")

# 获取当前分支信息
print("🔍 获取仓库信息...")
ref = api(f"/repos/{OWNER}/{REPO}/git/refs/heads/master")
if ref is None:
    print("🆕 空仓库，创建初始提交")

base_tree_sha = None
parent_sha = None
if ref and "object" in ref:
    parent_sha = ref["object"]["sha"]
    commit = api(f"/repos/{OWNER}/{REPO}/git/commits/{parent_sha}")
    if commit and "tree" in commit:
        base_tree_sha = commit["tree"]["sha"]

# 为每个文件创建 blob
tree_entries = []
for f in files:
    fpath = os.path.join(REPO_DIR, f)
    if not os.path.isfile(fpath):
        continue
    with open(fpath, "rb") as fh:
        content = fh.read()
    b64 = base64.b64encode(content).decode()

    print(f"  ⏳ 上传: {f}")
    blob = api(f"/repos/{OWNER}/{REPO}/git/blobs", {"content": b64, "encoding": "base64"}, "POST")
    if blob and "sha" in blob:
        tree_entries.append({"path": f, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    else:
        print(f"  ⚠️  跳过 {f} (blob 创建失败)")

if not tree_entries:
    print("❌ 没有文件成功上传")
    sys.exit(1)

# 创建新树
print("🌳 创建树对象...")
tree_data = {"tree": tree_entries}
if base_tree_sha:
    tree_data["base_tree"] = base_tree_sha
new_tree = api(f"/repos/{OWNER}/{REPO}/git/trees", tree_data, "POST")
if not new_tree or "sha" not in new_tree:
    print("❌ 创建树失败")
    sys.exit(1)
print(f"  ✅ 树 SHA: {new_tree['sha']}")

# 创建 commit
print("💾 创建提交...")
commit_data = {
    "message": COMMIT_MSG,
    "tree": new_tree["sha"],
    "parents": [parent_sha] if parent_sha else [],
}
new_commit = api(f"/repos/{OWNER}/{REPO}/git/commits", commit_data, "POST")
if not new_commit or "sha" not in new_commit:
    print("❌ 创建提交失败")
    sys.exit(1)
print(f"  ✅ Commit SHA: {new_commit['sha']}")

# 更新分支
print("📤 推送到 master...")
result = api(f"/repos/{OWNER}/{REPO}/git/refs/heads/master",
             {"sha": new_commit["sha"], "force": True}, "PATCH")
if result and "object" in result and result["object"]["sha"] == new_commit["sha"]:
    print()
    print("✅✅✅ 推送成功！ ✅✅✅")
    print(f"   https://github.com/{OWNER}/{REPO}")
    # 更新本地 git 引用
    subprocess.run(["git", "update-ref", "refs/heads/master", new_commit["sha"]],
                   capture_output=True, cwd=REPO_DIR)
else:
    print("⚠️ 推送可能失败:")
    print(json.dumps(result, indent=2)[:200])
    sys.exit(1)
