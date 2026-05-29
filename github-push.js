#!/usr/bin/env node
/**
 * github-push.js - 通过 GitHub API 推送代码
 * 用法: node github-push.js [提交信息]
 *
 * 环境变量: GH_TOKEN 或 git remote URL 中包含 token
 */
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const REPO_DIR = process.cwd();
const COMMIT_MSG = process.argv[2] || '更新代码';

// 获取 Token
function getTokenAndRepo() {
  let token = process.env.GH_TOKEN || '';
  let owner = '', repo = '';

  try {
    const remote = execSync('git remote get-url origin', { cwd: REPO_DIR }).toString().trim();
    const match = remote.match(/https:\/\/([^:]+):([^@]+)@github\.com\/([^/]+)\/([^/]+?)\.git/);
    if (match) {
      token = token || match[2];
      owner = match[3];
      repo = match[4];
    } else {
      const match2 = remote.match(/github\.com\/([^/]+)\/([^/]+?)\.git/);
      if (match2) {
        owner = match2[1];
        repo = match2[2];
      }
    }
  } catch (e) { /* no remote */ }

  if (!token && !process.env.GH_TOKEN) {
    console.error('❌ 请设置 GH_TOKEN 环境变量或 git remote URL 中包含 token');
    console.error('   export GH_TOKEN=ghp_xxx');
    process.exit(1);
  }

  return { token: token || process.env.GH_TOKEN, owner, repo };
}

// GitHub API 调用
async function api(path, data, method = 'GET') {
  const url = `https://api.github.com${path}`;
  const headers = {
    Authorization: `Bearer ${CONFIG.token}`,
    Accept: 'application/vnd.github+json',
    'User-Agent': 'github-push-js',
    'Content-Type': 'application/json',
  };

  const opts = { method, headers };
  if (data !== undefined) opts.body = JSON.stringify(data);

  const resp = await fetch(url, opts);
  if (!resp.ok && resp.status === 404) return null;
  if (!resp.ok) {
    const text = await resp.text();
    console.error(`⚠️ API 错误 ${resp.status}: ${path}`);
    console.error(text.slice(0, 200));
    return null;
  }
  return resp.json();
}

const CONFIG = getTokenAndRepo();
const { owner, repo } = CONFIG;

// 主函数
async function main() {
  console.log(`📂 目录: ${REPO_DIR}`);
  console.log(`📝 提交: ${COMMIT_MSG}`);
  console.log(`📦 仓库: ${owner}/${repo}\n`);

  // 获取文件列表
  let files = [];
  try {
    const out = execSync('git ls-files', { cwd: REPO_DIR }).toString();
    files = out.split('\n').filter(f => f && !f.startsWith('.git/'));
  } catch (e) { /* not a git repo or no files tracked */ }

  if (files.length === 0) {
    // fallback: scan directory
    files = fs.readdirSync(REPO_DIR)
      .filter(f => !f.startsWith('.git') && f !== 'github-push.js' && f !== 'git-api-push.sh')
      .filter(f => fs.statSync(path.join(REPO_DIR, f)).isFile());
  }

  console.log(`📄 共 ${files.length} 个文件`);
  files.forEach(f => console.log(`   - ${f}`));

  // 获取当前分支信息
  console.log('\n🔍 获取仓库信息...');
  const ref = await api(`/repos/${owner}/${repo}/git/refs/heads/master`);
  let parentSha = null;
  let baseTreeSha = null;

  if (ref && ref.object) {
    parentSha = ref.object.sha;
    const commit = await api(`/repos/${owner}/${repo}/git/commits/${parentSha}`);
    if (commit && commit.tree) baseTreeSha = commit.tree.sha;
    console.log(`   父提交: ${parentSha.slice(0, 8)}`);
  } else {
    console.log('   🆕 首次提交');
  }

  // 为每个文件创建 blob
  const treeEntries = [];
  for (const f of files) {
    const fpath = path.join(REPO_DIR, f);
    if (!fs.existsSync(fpath)) continue;

    const content = fs.readFileSync(fpath);
    const b64 = content.toString('base64');

    process.stdout.write(`   ⏳ 上传: ${f}`);
    const blob = await api(`/repos/${owner}/${repo}/git/blobs`, { content: b64, encoding: 'base64' }, 'POST');
    if (blob && blob.sha) {
      treeEntries.push({ path: f, mode: '100644', type: 'blob', sha: blob.sha });
      process.stdout.write(' ✅\n');
    } else {
      process.stdout.write(' ⚠️ 失败\n');
    }
  }

  if (treeEntries.length === 0) {
    console.error('\n❌ 没有文件成功上传');
    process.exit(1);
  }

  // 创建新树
  console.log('\n🌳 创建树对象...');
  const treeData = { tree: treeEntries };
  if (baseTreeSha) treeData.base_tree = baseTreeSha;
  const newTree = await api(`/repos/${owner}/${repo}/git/trees`, treeData, 'POST');
  if (!newTree || !newTree.sha) {
    console.error('❌ 创建树失败');
    process.exit(1);
  }
  console.log(`   ✅ 树 SHA: ${newTree.sha}`);

  // 创建 commit
  console.log('💾 创建提交...');
  const commitData = { message: COMMIT_MSG, tree: newTree.sha, parents: parentSha ? [parentSha] : [] };
  const newCommit = await api(`/repos/${owner}/${repo}/git/commits`, commitData, 'POST');
  if (!newCommit || !newCommit.sha) {
    console.error('❌ 创建提交失败');
    process.exit(1);
  }
  console.log(`   ✅ Commit SHA: ${newCommit.sha}`);

  // 更新分支
  console.log('📤 推送到 master...');
  const result = await api(`/repos/${owner}/${repo}/git/refs/heads/master`,
    { sha: newCommit.sha, force: true }, 'PATCH');

  if (result && result.object && result.object.sha === newCommit.sha) {
    console.log('\n✅✅✅ 推送成功！ ✅✅✅');
    console.log(`   https://github.com/${owner}/${repo}\n`);
    // 更新本地 git 引用
    try {
      execSync(`git update-ref refs/heads/master ${newCommit.sha}`, { cwd: REPO_DIR });
    } catch (e) { /* ignore */ }
  } else {
    console.error('\n⚠️ 推送可能失败');
    if (result) console.error(JSON.stringify(result, null, 2).slice(0, 200));
    process.exit(1);
  }
}

main().catch(e => {
  console.error('❌ 错误:', e.message);
  process.exit(1);
});
