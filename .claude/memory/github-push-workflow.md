---
name: github-push-workflow
description: How to push code to GitHub from this environment (git HTTPS broken, use API script)
metadata:
  type: reference
---

# GitHub Push Workflow

## Problem
This environment (MSYS2/MinGW on Windows) has a broken git HTTPS transport:
- `git push` fails with "Recv failure: Connection was reset"
- `curl` and `node fetch` work fine
- SSH also unavailable (key not added to GitHub)

## Solution
Use `node github-push.js` which uses the GitHub API (via `fetch`) instead of git transport.

## Token
Saved in `.env` file at project root (gitignored, safe from commits):
```
GH_TOKEN="<token>"
```
Load with: `source .env`

## Commands
```bash
# Push with default message
cd "F:/Desktop/新建文件夹 (2)" && source .env && node github-push.js

# Push with custom message
cd "F:/Desktop/新建文件夹 (2)" && source .env && node github-push.js "更新内容说明"
```

Remote URL is clean (no token embedded in git remote).

## Repo
https://github.com/wangn2611-source/tank-world

**Why:** git's HTTPS transport (specifically schannel SSL) has issues with large data transfers to GitHub in this environment. The GitHub REST API via `fetch`/`curl` works reliably.
**How to apply:** Any time the user asks to push to GitHub, use the above commands instead of `git push`.
