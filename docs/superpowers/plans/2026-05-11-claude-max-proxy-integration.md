# Claude Max Subscription Proxy Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 OpenClaude-Portable 主選單新增 `10) Claude (Max Subscription)` 入口，透過 OAuth 訂閱制（不需 API key）使用 Claude，背後走一個本地 `portable-claude-proxy`（OpenAI 相容、in-process Claude Agent SDK）。

**Architecture:** OpenClaude 引擎 → OpenAI-相容 HTTP 呼叫 → `127.0.0.1:3456` 的 `portable-claude-proxy`（git submodule，從 `photofanz/hermes-claude-proxy-v5` 起手新建的 `photofanz/portable-claude-proxy` repo） → 該 proxy in-process 用 `@anthropic-ai/claude-agent-sdk` → 讀 `data/home/.claude/.credentials.json` 的 OAuth token → `api.anthropic.com`。Proxy 由 `start.sh` 在引擎啟動前背景拉起、引擎結束時 kill（跟既有 Ollama 模式一樣）。Portable repo 本身轉為 git 控管並接上 `techjarves/OpenClaude-Portable` upstream。

**Tech Stack:** bash（`start.sh` / `change_provider.sh` / 新增的 `_claude_max_lib.sh` / `preinstall.sh`）、Node.js（vendored proxy `server.js`、`dashboard/server.mjs`）、git submodule、`@anthropic-ai/claude-code` CLI（OAuth 登入用）、`@anthropic-ai/claude-agent-sdk`（proxy runtime）。

**重要前提：**
- 本專案目前**不是 git repo**（root 無 `.git/`）。Task 1 先 `git init`。在那之前的步驟不 commit。
- 涉及三個 repo：(1) `OpenClaude-Portable`（本地，Task 1 轉 git）、(2) `photofanz/portable-claude-proxy`（Task 2 新建）、(3) `photofanz/hermes-claude-proxy-v5`（只讀的衍生來源）。
- 有 `[MANUAL]` 步驟（GitHub 介面建 repo、`claude login` OAuth）— 無法寫成自動化 code block，工人要照指示手動執行。
- bash 腳本本專案沒有測試框架（無 bats），「測試」步驟改成「執行並核對輸出」的手動驗證。
- 專案路徑含中文/空白/括號（`/Users/photofanz/我的雲端硬碟 (d14741006.ntu@gmail.com)/Projects/OpenClaude-Portable`）— 所有 shell 操作的路徑必須加雙引號。

**參考檔案（實作前先讀）：**
- `start.sh:399-418`（既有 `setup_claude` wizard 模式）、`start.sh:244-269`（provider 選單）、`start.sh:825-880`（Ollama 啟停 + 引擎 launch 段）、`start.sh:201-214`（每日更新檢查）
- `tools/local-proxy.js:133-144`（EADDRINUSE handler 範本）
- `tools/change_provider.sh`、`tools/open_dashboard.sh`
- `dashboard/server.mjs:1-20`（imports + 常數）、`dashboard/server.mjs:363-396`（`callAI_OpenAI`）、`dashboard/server.mjs:1081`（`server.listen`）
- `.gitignore`、`.gitattributes`
- spec：`docs/superpowers/specs/2026-05-10-claude-max-proxy-integration-design.md`

---

## File Structure

新增 / 修改的檔案及其職責：

| 檔案 | 動作 | 職責 |
|---|---|---|
| `.git/`、`.gitmodules` | 建立 | git 控管 + submodule 紀錄 |
| `.gitignore` | 修改 | 加 `tools/claude-proxy/node_modules/`、`tools/claude-proxy/.env` |
| `tools/claude-proxy/` | 新增（git submodule → `photofanz/portable-claude-proxy`） | vendored proxy；in-process Claude Agent SDK + OpenAI-相容 endpoint |
| `tools/_claude_max_lib.sh` | 新增 | 共用函式 `setup_claude_max()` + 子函式（OAuth 子 shell 登入、模型三選、token 產生、雙邊 env 寫入、`claude_proxy_ready()`） |
| `tools/preinstall.sh` | 新增 | 主動一次裝完所有依賴（Node + 引擎 + claude CLI + proxy npm i），不啟動引擎 |
| `start.sh` | 修改 | provider 選單加第 10 項；`setup_provider` case 加 `10`；source `_claude_max_lib.sh`；引擎啟動段加 proxy 起停 + trap；每日更新檢查追加 `@anthropic-ai/claude-code` + `--no-claude-cli-update` 旗標 |
| `tools/change_provider.sh` | 修改 | 鏡像第 10 項與 case，source 同一個 lib |
| `dashboard/server.mjs` | 修改 | 啟動初始化區加 self-heal（偵測 `CLAUDE_PROXY_MODE=1` + `OPENAI_BASE_URL` 含 `127.0.0.1:3456` 且 health 失敗時背景起 proxy）；import 加 `spawn` |
| `README.md` | 修改 | features 表、provider 表、project structure、troubleshooting、preinstall 用法、上游 sync workflow |
| `CLAUDE.md` | 修改 | provider 對應規則表後新增 Claude Max 區段、上游同步章節 |

外部（不在本 repo，但 plan 內要做）：
- `photofanz/portable-claude-proxy` GitHub repo — Task 2 新建並推送 3 處微調

---

## Task 1: Portable repo 轉 git 控管 + 接上 upstream

**Files:**
- Create: `.git/`（git init 產生）
- 不修改任何既有檔案內容

- [ ] **Step 1: 確認當前不是 git repo**

Run（在 repo root，即 `/Users/photofanz/我的雲端硬碟 (d14741006.ntu@gmail.com)/Projects/OpenClaude-Portable`）:
```bash
git rev-parse --git-dir 2>&1
```
Expected: `fatal: not a git repository (or any of the parent directories): .git`

- [ ] **Step 2: git init 並設定 upstream remote**

Run:
```bash
git init
git remote add upstream https://github.com/techjarves/OpenClaude-Portable.git
git fetch upstream
```
Expected: `git fetch upstream` 列出抓到的 branch（至少 `upstream/main`）。

- [ ] **Step 3: 把本地檔案 layer 在 upstream/main 之上（避免 unrelated histories）**

Run:
```bash
git reset --soft upstream/main      # HEAD 指到 upstream/main，working tree / index 不動
git add -A
git status --short                  # 看本地檔案相對 upstream/main 的 diff
```
Expected: HEAD 現在 = upstream/main 的 commit；`git status --short` 列出本地與 upstream 有差異的檔案（可能含你之前微調過的 README 等 — 預期）。`git diff --cached --stat` 可看完整差異清單。

- [ ] **Step 4: 建立第一個 commit（本地改動 layer 在 upstream 之上）**

Run:
```bash
git commit -m "Local modifications on top of upstream snapshot

State of this OpenClaude-Portable copy prior to adding the
10) Claude (Max Subscription) provider path. Layered on top of
techjarves/OpenClaude-Portable so future rebase has a common ancestor."
```
Expected: commit 成功，`git log --oneline -3` 顯示這個 commit 在 upstream 的 commit 之上（線性歷史）。

- [ ] **Step 5: 驗證 upstream 可比對**

Run:
```bash
git log --oneline -1
git rev-list --count main..upstream/main
git rev-list --count upstream/main..main
```
Expected: 前者顯示剛建的 commit；後兩個數字代表「upstream 領先幾個 commit」與「本地領先幾個 commit」——只要指令不報錯即可（數字本身僅供參考）。

---

## Task 2: 新建 `photofanz/portable-claude-proxy` repo（從 hermes-v5 起手 + 3 處微調）

**Files:**
- 外部 GitHub repo `photofanz/portable-claude-proxy`（新建）
- 本地工作目錄：`~/portable-claude-proxy`（暫時 clone，不在 OpenClaude-Portable repo 內）

- [ ] **Step 1: [MANUAL] 在 GitHub 介面建立空 repo**

到 https://github.com/new 建立：
- Owner: `photofanz`
- Repository name: `portable-claude-proxy`
- 設為 Public（或 Private，submodule 都能用，但 Public 比較單純）
- **不要**勾「Add a README」「Add .gitignore」「Choose a license」（保持完全空，等下從 hermes clone 過來）

- [ ] **Step 2: 本地 clone hermes-v5 作為起點，重配 remote**

Run（在你的家目錄或任意工作區，**不在** OpenClaude-Portable repo 內）:
```bash
cd ~
git clone https://github.com/photofanz/hermes-claude-proxy-v5.git portable-claude-proxy
cd portable-claude-proxy
git remote rename origin hermes
git remote add origin https://github.com/photofanz/portable-claude-proxy.git
git remote -v
```
Expected: `git remote -v` 顯示 `hermes` 指向 hermes-claude-proxy-v5、`origin` 指向 portable-claude-proxy。

- [ ] **Step 3: 微調 #1 — server.js bind 改 127.0.0.1**

在 `~/portable-claude-proxy/server.js` 找 `app.listen(PORT, '0.0.0.0', () => {`（約第 417 行），改成：
```javascript
const server = app.listen(PORT, '127.0.0.1', () => {
```
（同一行的 callback body 不動。注意：把回傳值存進 `const server` 供下一步用。）

- [ ] **Step 4: 微調 #2 — MIN_REQUEST_INTERVAL_MS 改 0**

在 `~/portable-claude-proxy/server.js` 找 `const MIN_REQUEST_INTERVAL_MS = 3000;`（約第 38 行），改成：
```javascript
const MIN_REQUEST_INTERVAL_MS = parseInt(process.env.MIN_REQUEST_INTERVAL_MS || '0', 10);
```
（保留 env 覆蓋能力；預設 0 = 不節流，適合單使用者 loopback。）

- [ ] **Step 5: 微調 #3 — app.listen 加 EADDRINUSE handler**

緊接 Step 3 改過的 `const server = app.listen(...)` 那行**之後**（callback 結束的 `});` 後面），新增：
```javascript
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.log(`Port ${PORT} already in use — assuming an existing proxy instance, exiting cleanly.`);
    process.exit(0);
  }
  throw err;
});
```
（仿 `tools/local-proxy.js:133-144` 的 reuse-existing-instance 行為。）

- [ ] **Step 6: 微調 #4 — .env.example 加 MAX_RETRIES=2**

在 `~/portable-claude-proxy/.env.example` 找 `MAX_RETRIES=` 那行（如果存在就改值，不存在就新增），設為：
```env
MAX_RETRIES=2
```
並在檔案頂部加一行註解標明衍生來源：
```env
# portable-claude-proxy — derived from photofanz/hermes-claude-proxy-v5,
# specialised for OpenClaude-Portable (loopback bind, no throttle, EADDRINUSE reuse).
```

- [ ] **Step 7: 更新 README 標明衍生關係**

在 `~/portable-claude-proxy/readme.md`（或 `README.md`，看 hermes 用哪個檔名）最上方加一段：
```markdown
> **Derived from [photofanz/hermes-claude-proxy-v5](https://github.com/photofanz/hermes-claude-proxy-v5).**
> This fork is specialised for [OpenClaude-Portable](https://github.com/photofanz/OpenClaude-Portable):
> binds to `127.0.0.1` only, no inter-request throttle, exits cleanly on `EADDRINUSE`
> (so a second launch reuses the existing instance). Pull upstream fixes via
> `git fetch hermes && git cherry-pick <sha>`.
```

- [ ] **Step 8: Commit 並推送到新 repo**

Run（在 `~/portable-claude-proxy`）:
```bash
git add -A
git commit -m "Portable-specific adjustments: loopback bind, no throttle, EADDRINUSE reuse

Derived from hermes-claude-proxy-v5 for use as a git submodule in
OpenClaude-Portable. Changes:
- bind 127.0.0.1 instead of 0.0.0.0
- MIN_REQUEST_INTERVAL_MS defaults to 0 (env-overridable)
- app.listen handles EADDRINUSE by exiting 0 (reuse existing instance)
- .env.example MAX_RETRIES=2"
git push -u origin main
```
Expected: push 成功，GitHub 上 `photofanz/portable-claude-proxy` 出現這些檔案與 commit。

- [ ] **Step 9: 驗證新 proxy 可獨立啟動且 bind 正確**

Run（在 `~/portable-claude-proxy`）:
```bash
npm install
API_KEY=test-key PORT=3456 node server.js &
PROXY_PID=$!
sleep 2
curl -sf http://127.0.0.1:3456/health && echo " <- localhost OK"
# 驗證沒有 bind 到 0.0.0.0：從非 loopback 介面打應該連不上（或用 lsof 確認）
lsof -nP -iTCP:3456 -sTCP:LISTEN | grep -E '127\.0\.0\.1:3456|\*:3456'
kill $PROXY_PID 2>/dev/null
```
Expected: `/health` 回 JSON（含 `"status":"ok"`）；`lsof` 那行顯示 `127.0.0.1:3456` 而**非** `*:3456`。
（注意：此步驟還沒有 OAuth credentials，`/health` 不需要認證所以會成功；實際 chat 要等 Task 7 的 OAuth 登入後才能測。）

---

## Task 3: 把 portable-claude-proxy 加為 submodule + 更新 .gitignore

**Files:**
- Create: `.gitmodules`、`tools/claude-proxy/`（submodule）
- Modify: `.gitignore`

- [ ] **Step 1: 加 submodule**

Run（在 OpenClaude-Portable repo root）:
```bash
git submodule add -b main https://github.com/photofanz/portable-claude-proxy.git tools/claude-proxy
```
Expected: `tools/claude-proxy/` 目錄出現、含 `server.js` 等檔案；`.gitmodules` 被建立並 staged。

- [ ] **Step 2: 確認 submodule 內容正確**

Run:
```bash
cat .gitmodules
ls tools/claude-proxy/
grep -n "127.0.0.1" tools/claude-proxy/server.js
grep -n "MIN_REQUEST_INTERVAL_MS" tools/claude-proxy/server.js
```
Expected: `.gitmodules` 內 `path = tools/claude-proxy`、`url = https://github.com/photofanz/portable-claude-proxy.git`、`branch = main`；`server.js` 含 `'127.0.0.1'` 與 `MIN_REQUEST_INTERVAL_MS || '0'`。

- [ ] **Step 3: 更新 .gitignore**

在 `.gitignore` 的「Personal data」區塊**之後**新增：
```gitignore
# ── Claude Max proxy (submodule) runtime artefacts ────────────────
/tools/claude-proxy/node_modules/
/tools/claude-proxy/.env
```
（submodule 自身的 .gitignore 應已涵蓋這些，但 portable repo 端再加一道保險。）

- [ ] **Step 4: Commit**

Run:
```bash
git add .gitmodules tools/claude-proxy .gitignore
git commit -m "Add portable-claude-proxy as tools/claude-proxy submodule"
```
Expected: commit 成功；`git submodule status` 顯示 `tools/claude-proxy` 在某個 commit SHA 上。

---

## Task 4: 新增 `tools/_claude_max_lib.sh`（共用 wizard 函式庫）

**Files:**
- Create: `tools/_claude_max_lib.sh`

這支腳本被 `start.sh` 與 `tools/change_provider.sh` `source`。它假設呼叫前 caller 已定義：`ROOT_DIR`、`ENGINE_DIR`、`DATA_DIR`、`ENV_FILE`、`NODE_BIN`、`NPM_BIN`、`NPM_CACHE_DIR` 以及顏色變數（`CYAN` `GREEN` `YELLOW` `RED` `DIM` `BOLD` `RESET`）與 `save_env()`。

- [ ] **Step 1: 建立 `tools/_claude_max_lib.sh` 骨架與 `claude_proxy_ready()`**

Create `tools/_claude_max_lib.sh`:
```bash
#!/bin/bash
# =================================================================
#  Claude Max Subscription 共用函式庫
#  被 start.sh 與 tools/change_provider.sh source。
#  依賴 caller 已定義：ROOT_DIR ENGINE_DIR DATA_DIR ENV_FILE
#  NODE_BIN NPM_BIN NPM_CACHE_DIR、顏色變數、save_env()。
# =================================================================

CLAUDE_CLI_BIN="$ENGINE_DIR/node_modules/@anthropic-ai/claude-code/bin/claude"
CLAUDE_PROXY_DIR="$ROOT_DIR/tools/claude-proxy"
CLAUDE_PROXY_PORT=3456

# claude CLI 與 proxy 依賴都裝好了嗎？
claude_proxy_ready() {
    [ -f "$CLAUDE_CLI_BIN" ] && [ -d "$CLAUDE_PROXY_DIR/node_modules/express" ]
}

# OAuth credentials 存在嗎？（HOME 已被 portable 重導到 $DATA_DIR/home）
claude_oauth_present() {
    [ -f "$DATA_DIR/home/.claude/.credentials.json" ]
}
```

- [ ] **Step 2: 加 `install_claude_max()`**

接在 `tools/_claude_max_lib.sh` 後面新增：
```bash
# 安裝 claude CLI 與 proxy 依賴（沿用 start.sh 既有的 npm cache）
install_claude_max() {
    echo -e "  ${YELLOW}[~] Installing Claude CLI and proxy dependencies...${RESET}"
    echo -e "  ${DIM}    First time: downloads ~30-50 MB. Slow USB drives can look idle for a few minutes.${RESET}"
    mkdir -p "$NPM_CACHE_DIR"

    # 1) claude CLI（OAuth 登入用；proxy runtime 不 spawn 它，但 'claude login' 需要它）
    ( cd "$ENGINE_DIR" && NPM_CONFIG_CACHE="$NPM_CACHE_DIR" "$NPM_BIN" install @anthropic-ai/claude-code@latest \
        --no-audit --no-fund --loglevel=warn --no-bin-links --cache "$NPM_CACHE_DIR" )
    if [ ! -f "$CLAUDE_CLI_BIN" ]; then
        echo -e "  ${RED}[ERROR] claude CLI install incomplete (missing $CLAUDE_CLI_BIN).${RESET}"
        return 1
    fi

    # 2) proxy submodule 的依賴
    if [ ! -f "$CLAUDE_PROXY_DIR/package.json" ]; then
        echo -e "  ${RED}[ERROR] tools/claude-proxy submodule not initialised. Run: git submodule update --init${RESET}"
        return 1
    fi
    ( cd "$CLAUDE_PROXY_DIR" && NPM_CONFIG_CACHE="$NPM_CACHE_DIR" "$NPM_BIN" install \
        --no-audit --no-fund --loglevel=warn --cache "$NPM_CACHE_DIR" )
    if [ ! -d "$CLAUDE_PROXY_DIR/node_modules/express" ]; then
        echo -e "  ${RED}[ERROR] proxy dependencies install incomplete.${RESET}"
        return 1
    fi

    echo -e "  ${GREEN}[OK] Claude CLI + proxy installed.${RESET}"
}
```

- [ ] **Step 3: 加 `claude_oauth_login()`（子 shell 自動帶好 HOME 跑 `claude login`）**

接著新增：
```bash
# 用一個子 shell，把 HOME 暫時指到 $DATA_DIR/home，跑 'claude login'
# 完成後 OAuth credentials 落在 $DATA_DIR/home/.claude/.credentials.json
claude_oauth_login() {
    echo ""
    echo -e "  ${CYAN}--- CLAUDE OAUTH LOGIN ---${RESET}"
    echo -e "  ${DIM}A browser window will open. Log in with your Claude Max account.${RESET}"
    echo -e "  ${DIM}Credentials will be saved INSIDE this folder (data/home/.claude/), not your real home.${RESET}"
    echo ""
    read -p "  Press Enter to start login... " _
    mkdir -p "$DATA_DIR/home"
    env HOME="$DATA_DIR/home" \
        PATH="$ENGINE_DIR/node_modules/@anthropic-ai/claude-code/bin:$PATH" \
        bash -c 'claude login'
    echo ""
    if claude_oauth_present; then
        echo -e "  ${GREEN}[OK] OAuth credentials saved.${RESET}"
        return 0
    fi
    echo -e "  ${RED}[ERROR] Login did not produce credentials at data/home/.claude/.credentials.json${RESET}"
    return 1
}

# 驗證現有 OAuth 還活著（5 秒 timeout）
claude_oauth_verify() {
    env HOME="$DATA_DIR/home" \
        PATH="$ENGINE_DIR/node_modules/@anthropic-ai/claude-code/bin:$PATH" \
        bash -c 'timeout 15 claude --print "ping" >/dev/null 2>&1'
}
```

- [ ] **Step 4: 加 `setup_claude_max()`（主 wizard）**

接著新增：
```bash
setup_claude_max() {
    echo ""
    echo -e "  ${CYAN}--- CLAUDE (MAX SUBSCRIPTION) SETUP ---${RESET}"
    echo ""
    echo -e "  ${DIM}This uses your Claude Max ($200/mo) subscription via OAuth — no API key needed.${RESET}"
    echo -e "  ${DIM}OAuth credentials live in data/home/.claude/ (portable). Switching machines/arch may require re-login.${RESET}"
    echo -e "  ${DIM}macOS / Linux only.${RESET}"
    echo ""

    # 1) 依賴
    if ! claude_proxy_ready; then
        install_claude_max || { echo -e "  ${RED}[ERROR] Setup aborted.${RESET}"; return 1; }
    fi

    # 2) OAuth
    if claude_oauth_present && claude_oauth_verify; then
        echo -e "  ${GREEN}[OK] Existing OAuth credentials valid.${RESET}"
    else
        if claude_oauth_present; then
            echo -e "  ${YELLOW}[!] Existing OAuth credentials look stale — re-login needed.${RESET}"
        fi
        claude_oauth_login || { echo -e "  ${RED}[ERROR] Setup aborted (OAuth login failed).${RESET}"; return 1; }
    fi

    # 3) 模型三選一（對齊 portable-claude-proxy server.js resolveModel）
    echo ""
    echo -e "  ${CYAN}Choose default model:${RESET}"
    echo -e "    ${CYAN}1)${RESET} claude-opus-4-7    ${DIM}- strongest (still covered by Max)${RESET}"
    echo -e "    ${CYAN}2)${RESET} claude-sonnet-4-6  ${DIM}- balanced (recommended)${RESET}"
    echo -e "    ${CYAN}3)${RESET} claude-haiku-4-5   ${DIM}- fastest${RESET}"
    read -p "  Select (1-3) [Enter for 2]: " _MSEL
    case "$_MSEL" in
        1) CLAUDE_MAX_MODEL="claude-opus-4-7" ;;
        3) CLAUDE_MAX_MODEL="claude-haiku-4-5" ;;
        *) CLAUDE_MAX_MODEL="claude-sonnet-4-6" ;;
    esac

    # 4) 自動產生 proxy token
    local PROXY_TOKEN
    if command -v openssl >/dev/null 2>&1; then
        PROXY_TOKEN="sk-portable-$(openssl rand -hex 16)"
    else
        PROXY_TOKEN="sk-portable-$(date +%s)$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi

    # 5) 寫 proxy .env
    cat > "$CLAUDE_PROXY_DIR/.env" <<EOF
PORT=$CLAUDE_PROXY_PORT
API_KEY=$PROXY_TOKEN
MAX_CONCURRENT=2
REQUEST_TIMEOUT=300000
MAX_RETRIES=2
PLUGINS_DIR=./plugins
# STATELESS_MODE=1   # 預設 persistent session；除錯時可開
EOF

    # 6) 寫 ai_settings.env
    save_env "# ========================================================
# Portable AI - Master Switchboard (Claude Max via local proxy)
# ========================================================
AI_PROVIDER=openai
CLAUDE_CODE_USE_OPENAI=1
OPENAI_BASE_URL=http://127.0.0.1:$CLAUDE_PROXY_PORT/v1
OPENAI_API_FORMAT=chat_completions
OPENAI_API_KEY=$PROXY_TOKEN
OPENAI_MODEL=$CLAUDE_MAX_MODEL
AI_DISPLAY_MODEL=$CLAUDE_MAX_MODEL
CLAUDE_PROXY_MODE=1"

    echo ""
    echo -e "  ${GREEN}[OK] Claude Max configured (model: $CLAUDE_MAX_MODEL).${RESET}"
}
```

- [ ] **Step 5: 語法檢查**

Run:
```bash
bash -n tools/_claude_max_lib.sh && echo "syntax OK"
```
Expected: `syntax OK`（無語法錯誤）。

- [ ] **Step 6: Commit**

Run:
```bash
git add tools/_claude_max_lib.sh
git commit -m "Add _claude_max_lib.sh: shared Claude Max wizard functions"
```

---

## Task 5: `start.sh` — 接上第 10 個 provider + 引擎啟動段 proxy 起停

**Files:**
- Modify: `start.sh`

- [ ] **Step 1: source `_claude_max_lib.sh`**

在 `start.sh` 中，**在 provider 選單與 `setup_*` 函式定義之前**（例如緊接在 `save_env()` 定義之後、`setup_provider()` 之前），新增：
```bash
# 載入 Claude Max 共用函式（需要 ROOT_DIR ENGINE_DIR DATA_DIR ENV_FILE NODE_BIN NPM_BIN NPM_CACHE_DIR 已定義）
if [ -f "$ROOT_DIR/tools/_claude_max_lib.sh" ]; then
    # shellcheck disable=SC1091
    source "$ROOT_DIR/tools/_claude_max_lib.sh"
fi
```
（確認 `NPM_CACHE_DIR` 在 `start.sh` 已定義 — 第 16 行 `NPM_CACHE_DIR="$DATA_DIR/npm-cache"`，有。確認 `NPM_BIN` 已定義 — 第 45 行，有。）

- [ ] **Step 2: provider 選單加第 10 項**

在 `start.sh:244-252` 的選單字串區塊，`echo -e "  ${CYAN}9)${RESET} ..."` 那行**之後**、`echo ""` 之前，新增：
```bash
    echo -e "  ${CYAN}10)${RESET} ${BOLD}Claude (Max Subscription)${RESET} ${DIM}- \$200/mo, OAuth, no per-token cost (macOS/Linux)${RESET}"
```

- [ ] **Step 3: 擴充 provider 選擇的範圍與 case**

在 `start.sh` 的 `setup_provider()` 內，把 `read -p "  Select your provider (1-9): " PROVIDER_SEL` 改成：
```bash
        read -p "  Select your provider (1-10): " PROVIDER_SEL
```
並在 `case "$PROVIDER_SEL" in` 的 `9) setup_custom_openai; return ;;` **之後**新增：
```bash
            10) setup_claude_max; return ;;
```

- [ ] **Step 4: 引擎啟動段 — 起 proxy（在 Ollama 啟動 block 旁邊）**

在 `start.sh:825-837` 的 Ollama 啟動 block（`if [ "$AI_PROVIDER" = "ollama" ]; then ... fi`）**之後**新增：
```bash
if [ "$CLAUDE_PROXY_MODE" = "1" ]; then
    PROXY_LOG="$DATA_DIR/claude-proxy.log"
    PROXY_DIR="$ROOT_DIR/tools/claude-proxy"
    if [ ! -f "$PROXY_DIR/server.js" ]; then
        echo -e "  ${RED}[ERROR] tools/claude-proxy submodule missing. Run: git submodule update --init${RESET}"
    else
        echo -e "  ${CYAN}[~] Starting Claude Max proxy...${RESET}"
        ( cd "$PROXY_DIR" && "$NODE_BIN" server.js >> "$PROXY_LOG" 2>&1 ) &
        CLAUDE_PROXY_PID=$!
        for _i in 1 2 3 4 5; do
            sleep 1
            if curl -sf "http://127.0.0.1:3456/health" >/dev/null 2>&1; then
                echo -e "  ${GREEN}[OK] Claude Max proxy ready (PID $CLAUDE_PROXY_PID).${RESET}"
                break
            fi
        done
        if ! curl -sf "http://127.0.0.1:3456/health" >/dev/null 2>&1; then
            echo -e "  ${YELLOW}[WARN] Claude Max proxy not responding after 5s — check $PROXY_LOG${RESET}"
        fi
        echo ""
    fi
fi
```

- [ ] **Step 5: 引擎結束後 kill proxy（在既有 Ollama kill 區塊旁）**

在 `start.sh` 檔尾、既有的 Ollama kill 區塊（`if [ -n "$OLLAMA_PID" ]; then ... fi`）**之後**新增：
```bash
if [ -n "$CLAUDE_PROXY_PID" ]; then
    echo ""
    echo -e "  ${CYAN}[~] Stopping Claude Max proxy...${RESET}"
    kill "$CLAUDE_PROXY_PID" 2>/dev/null
    wait "$CLAUDE_PROXY_PID" 2>/dev/null
fi
```

- [ ] **Step 6: 語法檢查**

Run:
```bash
bash -n start.sh && echo "syntax OK"
```
Expected: `syntax OK`。

- [ ] **Step 7: 手動驗證選單出現第 10 項（不完成設定，按 Ctrl+C 中止）**

Run:
```bash
echo "" | timeout 5 bash start.sh 2>&1 | grep -i "Claude (Max Subscription)" || true
```
Expected: 看到 `10) Claude (Max Subscription) - $200/mo, OAuth, ...` 那行（如果 timeout/輸入導致沒走到選單也沒關係，下一步 Task 7 會做完整 end-to-end 驗證）。

- [ ] **Step 8: Commit**

Run:
```bash
git add start.sh
git commit -m "start.sh: add Claude (Max Subscription) provider + proxy lifecycle"
```

---

## Task 6: `start.sh` — 每日更新檢查追加 `@anthropic-ai/claude-code`（D12）

**Files:**
- Modify: `start.sh:201-214`

- [ ] **Step 1: 加 `--no-claude-cli-update` 旗標解析**

在 `start.sh` 既有的旗標解析區塊（`for arg in "$@"; do ... done`，約第 196-199 行），在迴圈內新增：
```bash
    [ "$arg" = "--no-claude-cli-update" ] && SKIP_CLAUDE_CLI_UPDATE=1
```
並在迴圈**之前**初始化：
```bash
SKIP_CLAUDE_CLI_UPDATE=0
```

- [ ] **Step 2: 更新檢查段追加 claude CLI**

在 `start.sh:202-214` 的引擎更新檢查 block 內，`else echo -e "  ${GREEN}[OK] Engine is up to date!${RESET}" fi` **之後**（仍在 `if [ $SKIP_UPDATE -eq 1 ]` 的 else 分支內），新增：
```bash
    # claude CLI 更新檢查（只在 Claude Max 模式且未被旗標跳過時）
    if [ "$CLAUDE_PROXY_MODE" = "1" ] && [ "$SKIP_CLAUDE_CLI_UPDATE" -eq 0 ]; then
        if [ -d "$ENGINE_DIR/node_modules/@anthropic-ai/claude-code" ]; then
            cd "$ENGINE_DIR"
            if "$NPM_BIN" outdated @anthropic-ai/claude-code 2>/dev/null | grep -q claude-code; then
                echo -e "  ${YELLOW}[~] New claude CLI version — upgrading...${RESET}"
                NPM_CONFIG_CACHE="$NPM_CACHE_DIR" "$NPM_BIN" install @anthropic-ai/claude-code@latest \
                    --no-audit --no-fund --loglevel=warn --no-bin-links --cache "$NPM_CACHE_DIR" >/dev/null 2>&1
                echo -e "  ${GREEN}[OK] claude CLI upgraded.${RESET}"
            fi
        fi
    fi
```
（注意：`CLAUDE_PROXY_MODE` 在這個時間點可能還沒從 `ai_settings.env` 載入 —— 確認 `start.sh` 載入 env 的順序：第 217-232 行載入 env 是在更新檢查 *之後*。所以這個 block 要嘛移到 env 載入之後，要嘛改成「`@anthropic-ai/claude-code` 目錄存在就檢查」不依賴 `CLAUDE_PROXY_MODE`。**採後者** —— 把判斷條件改成：）
```bash
    # claude CLI 更新檢查（只要 claude CLI 已安裝且未被旗標跳過）
    if [ "$SKIP_CLAUDE_CLI_UPDATE" -eq 0 ] && [ -d "$ENGINE_DIR/node_modules/@anthropic-ai/claude-code" ]; then
        cd "$ENGINE_DIR"
        if "$NPM_BIN" outdated @anthropic-ai/claude-code 2>/dev/null | grep -q claude-code; then
            echo -e "  ${YELLOW}[~] New claude CLI version — upgrading...${RESET}"
            NPM_CONFIG_CACHE="$NPM_CACHE_DIR" "$NPM_BIN" install @anthropic-ai/claude-code@latest \
                --no-audit --no-fund --loglevel=warn --no-bin-links --cache "$NPM_CACHE_DIR" >/dev/null 2>&1
            echo -e "  ${GREEN}[OK] claude CLI upgraded.${RESET}"
        fi
    fi
```

- [ ] **Step 3: 語法檢查**

Run:
```bash
bash -n start.sh && echo "syntax OK"
```
Expected: `syntax OK`。

- [ ] **Step 4: Commit**

Run:
```bash
git add start.sh
git commit -m "start.sh: auto-check @anthropic-ai/claude-code updates (--no-claude-cli-update to skip)"
```

---

## Task 7: 端到端驗證 — 完成 Claude Max wizard 並對話

**Files:** 無（純驗證 task；如發現 bug 則回到對應 task 修）

- [ ] **Step 1: 確認 submodule 已 init（如果是新 clone）**

Run:
```bash
git submodule update --init tools/claude-proxy
ls tools/claude-proxy/server.js
```
Expected: `server.js` 存在。

- [ ] **Step 2: 跑 start.sh、選 10、走完 wizard**

Run:
```bash
./start.sh
```
然後：選 provider `10`、按指示完成 OAuth 登入（瀏覽器登入 Claude Max）、選模型（建議 `2` sonnet）。Wizard 結束後應自動進入主選單 → 選 `1` Launch AI。

Expected:
- `data/home/.claude/.credentials.json` 被建立
- `data/ai_settings.env` 含 `AI_PROVIDER=openai`、`OPENAI_BASE_URL=http://127.0.0.1:3456/v1`、`OPENAI_API_KEY=sk-portable-...`、`CLAUDE_PROXY_MODE=1`
- `tools/claude-proxy/.env` 含同一個 `API_KEY=sk-portable-...`
- 啟動引擎前看到 `[OK] Claude Max proxy ready (PID ...)`
- 引擎內跟 Claude 對話能得到正常回應

- [ ] **Step 3: 驗證 proxy log 有收到請求**

對話一兩句後，另開 terminal:
```bash
tail -20 "data/claude-proxy.log"
```
Expected: 看到 `REQ chatcmpl-... | model=... | stream=...` 之類的請求記錄，且沒有反覆的 error。

- [ ] **Step 4: 驗證引擎結束後 proxy 被 kill**

在引擎內 `Ctrl+C` 或 `/exit` 退出，然後:
```bash
sleep 2
lsof -nP -iTCP:3456 -sTCP:LISTEN 2>/dev/null || echo "no proxy listening — good"
ps aux | grep -v grep | grep "claude-proxy/server.js" || echo "no orphan proxy process — good"
```
Expected: 兩行都顯示「good」（proxy 已隨引擎結束）。

- [ ] **Step 5: 驗證重跑走捷徑（不再 wizard）**

Run:
```bash
./start.sh
```
Expected: 不再問 provider（因為 `ai_settings.env` 已存在）；直接顯示 `Provider : Custom OpenAI-Compatible`（或類似，因為 `OPENAI_BASE_URL` 是 localhost:3456 — 注意 `start.sh:736-745` 的 PROVIDER_NAME 判斷會落到「Custom OpenAI-Compatible」，**這是已知的小瑕疵**，Task 11 文件會說明）；自動起 proxy；選 1 能直接對話。

- [ ] **Step 6: 切回其他 provider 驗證 proxy 不再起**

Run:
```bash
./tools/change_provider.sh
```
（這一步要等 Task 8 完成 change_provider.sh 改動後才有 `10)` 選項；此 step 先驗證「切到非 Claude Max provider 後 proxy 不起」這個既有行為。）選一個 free OpenRouter model（或任何非 10 的選項）→ 回到 `./start.sh` → 確認啟動訊息**沒有** `Starting Claude Max proxy`（因為 `CLAUDE_PROXY_MODE` 已不在 env 裡）。

- [ ] **Step 7: 如果有 bug，記錄並回對應 task 修；全綠則進 Task 8**

無 commit（驗證 task）。如果 Task 4/5/6 有需要修的，修完重跑本 task。

---

## Task 8: `tools/change_provider.sh` — 鏡像第 10 個 provider

**Files:**
- Modify: `tools/change_provider.sh`

- [ ] **Step 1: 先讀 change_provider.sh 結構**

Run:
```bash
grep -nE "Select|case|setup_|source|ROOT_DIR|ENGINE_DIR|DATA_DIR|NPM_BIN|save_env" tools/change_provider.sh | head -30
```
確認它有定義 `ROOT_DIR`、`ENGINE_DIR`、`DATA_DIR`、`ENV_FILE`、`NODE_BIN`、`NPM_BIN`、`NPM_CACHE_DIR`、顏色變數、`save_env()`。如果某些沒定義，補上（對照 `start.sh` 開頭的定義）。

- [ ] **Step 2: source `_claude_max_lib.sh`**

在 `tools/change_provider.sh` 的 `setup_*` 函式與選單之前，新增（與 Task 5 Step 1 相同）：
```bash
if [ -f "$ROOT_DIR/tools/_claude_max_lib.sh" ]; then
    # shellcheck disable=SC1091
    source "$ROOT_DIR/tools/_claude_max_lib.sh"
fi
```
（如果 `change_provider.sh` 用的變數名不是 `ROOT_DIR` 而是別的，調整 source 路徑與 lib 內依賴的變數名 —— 或在 source 前先 `ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"`。）

- [ ] **Step 3: 選單與 case 加第 10 項**

對照 Task 5 Step 2 與 Step 3，在 `change_provider.sh` 的 provider 選單字串加 `10) Claude (Max Subscription)` 那行、把選擇範圍改成 `1-10`、case 加 `10) setup_claude_max; return ;;`（或該腳本對應的 dispatch 寫法）。

- [ ] **Step 4: 語法檢查**

Run:
```bash
bash -n tools/change_provider.sh && echo "syntax OK"
```
Expected: `syntax OK`。

- [ ] **Step 5: 手動驗證 — change_provider 能切到 Claude Max 並切回**

Run:
```bash
./tools/change_provider.sh
```
選 `10` → 走完 wizard（OAuth 已存在的話會跳過登入）→ 確認 `ai_settings.env` 變成 Claude Max 設定。再跑一次 `./tools/change_provider.sh` 選 OpenRouter free → 確認切回。

- [ ] **Step 6: Commit**

Run:
```bash
git add tools/change_provider.sh
git commit -m "change_provider.sh: mirror Claude (Max Subscription) provider option"
```

---

## Task 9: `dashboard/server.mjs` — Claude Max proxy self-heal

**Files:**
- Modify: `dashboard/server.mjs`（imports + 啟動前初始化）

- [ ] **Step 1: import 加 `spawn`**

在 `dashboard/server.mjs:5`，把：
```javascript
import { execSync, exec } from 'child_process';
```
改成：
```javascript
import { execSync, exec, spawn } from 'child_process';
```

- [ ] **Step 2: 在 `server.listen(PORT, ...)` 之前加 self-heal**

在 `dashboard/server.mjs` 檔尾，`server.listen(PORT, () => {` 那行**之前**，新增：
```javascript
// ─── Claude Max proxy self-heal ──────────────────────────────
// 如果使用者直接跑 open_dashboard.sh（沒經 start.sh 主流程），且設定是
// Claude Max 模式但 proxy 沒在跑，這裡背景起一個。注意：detached + unref，
// dashboard 結束時 proxy 不會跟著被 kill（會變孤兒，需手動 lsof :3456 + kill）。
async function ensureClaudeMaxProxy() {
    const cfg = readConfig();
    if (cfg.CLAUDE_PROXY_MODE !== '1') return;
    if (!cfg.OPENAI_BASE_URL || !cfg.OPENAI_BASE_URL.includes('127.0.0.1:3456')) return;

    const healthOk = await fetch('http://127.0.0.1:3456/health')
        .then(r => r.ok).catch(() => false);
    if (healthOk) return;

    const proxyDir = join(ROOT_DIR, 'tools', 'claude-proxy');
    if (!existsSync(join(proxyDir, 'server.js'))) {
        console.log('  [WARN] CLAUDE_PROXY_MODE=1 but tools/claude-proxy/server.js missing.');
        return;
    }
    console.log('  [~] Claude Max proxy not running — starting it in background...');
    const proc = spawn(process.execPath, ['server.js'], {
        cwd: proxyDir, stdio: 'ignore', detached: true,
    });
    proc.unref();
    for (let i = 0; i < 5; i++) {
        await new Promise(r => setTimeout(r, 1000));
        const ok = await fetch('http://127.0.0.1:3456/health').then(r => r.ok).catch(() => false);
        if (ok) { console.log('  [OK] Claude Max proxy ready.'); return; }
    }
    console.log('  [WARN] Claude Max proxy did not become ready in 5s.');
}

await ensureClaudeMaxProxy();
```
（注意：`readConfig`、`existsSync`、`join`、`ROOT_DIR` 在 server.mjs 早已 import / 定義 — `readConfig` 在第 24 行附近，`existsSync` 在第 2 行 import，`join` 第 3 行，`ROOT_DIR` 第 8 行。`await` 在 module top-level：server.mjs 是 `.mjs` ESM 模組，top-level await 合法。）

- [ ] **Step 3: 語法 / 載入檢查**

Run:
```bash
node --check dashboard/server.mjs && echo "syntax OK"
```
Expected: `syntax OK`。

- [ ] **Step 4: 手動驗證 — 直接開 dashboard 會 self-heal 起 proxy**

前提：`ai_settings.env` 仍是 Claude Max 設定（Task 7 設好的）、proxy 目前**沒在跑**（確認 `lsof -nP -iTCP:3456 -sTCP:LISTEN` 無輸出）。

Run:
```bash
bash tools/open_dashboard.sh
```
觀察 console 應印 `[~] Claude Max proxy not running — starting it in background...` 然後 `[OK] Claude Max proxy ready.`。在瀏覽器 `http://localhost:3000` 開一個 chat（**chat 模式不是 agent 模式**）跟 Claude 對話，應有正常回應。

- [ ] **Step 5: 驗證 dashboard 關閉後 proxy 變孤兒（預期行為）**

`Ctrl+C` 關 dashboard，然後:
```bash
lsof -nP -iTCP:3456 -sTCP:LISTEN
```
Expected: proxy 仍在 listen（這是 detached 的預期行為）。手動清理：`kill $(lsof -ti TCP:3456)`。
（此行為在 README troubleshooting 會寫明 — Task 11。）

- [ ] **Step 6: Commit**

Run:
```bash
git add dashboard/server.mjs
git commit -m "dashboard: self-heal Claude Max proxy on startup when configured"
```

---

## Task 10: `tools/preinstall.sh` — 主動一次裝完所有依賴

**Files:**
- Create: `tools/preinstall.sh`

- [ ] **Step 1: 建立 `tools/preinstall.sh`**

Create `tools/preinstall.sh`:
```bash
#!/bin/bash
# =================================================================
#  Portable AI - Pre-install everything (no engine launch)
#  跑這支之後，第一次 ./start.sh 不會出現任何下載/安裝等待。
#  也會裝好 Claude Max 路徑需要的 claude CLI 與 proxy 依賴。
# =================================================================
set -e

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; DIM='\033[90m'; RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ""
echo -e "${CYAN}=========================================================${RESET}"
echo -e "  Portable AI - Pre-install"
echo -e "${CYAN}=========================================================${RESET}"
echo ""

# 1) Node.js + 引擎：直接借用 start.sh 的 bootstrap，但用 --quick 之外的方式跳過 launch。
#    最穩妥做法：呼叫 start.sh 並在引擎啟動前的階段就中止 —— 但 start.sh 沒有「只裝不跑」旗標。
#    改採：直接重跑 start.sh 內的 bootstrap 邏輯片段。為避免重複維護，這裡簡單呼叫：
echo -e "${YELLOW}[1/3] Node.js + OpenClaude engine${RESET}"
echo -e "${DIM}      （若已安裝會被 start.sh 的 'engine_ready' 略過）${RESET}"
# 用 timeout + 餵空白輸入讓 start.sh 跑到主選單前的 bootstrap；--offline 跳過更新檢查網路往返
( echo "" | timeout 600 bash "$ROOT_DIR/start.sh" --offline >/dev/null 2>&1 ) || true
# 上面那行不可靠（start.sh 會卡在 provider 設定或主選單）。改為直接檢查並提示：
if [ ! -f "$ROOT_DIR/engine/node_modules/@gitlawb/openclaude/dist/cli.mjs" ]; then
    echo -e "${YELLOW}      Engine not yet installed. Run ./start.sh once to bootstrap Node + engine, then re-run this.${RESET}"
fi

# 2) claude CLI（OAuth 登入用）
echo -e "${YELLOW}[2/3] @anthropic-ai/claude-code (claude CLI)${RESET}"
ENGINE_DIR="$ROOT_DIR/engine"
NPM_CACHE_DIR="$ROOT_DIR/data/npm-cache"
# 找 portable node 的 npm
PLATFORM=$(uname -s | tr '[:upper:]' '[:lower:]'); [ "$PLATFORM" = "darwin" ] || PLATFORM="linux"
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) ARCH=x64;; arm64|aarch64) ARCH=arm64;; esac
NPM_BIN="$ENGINE_DIR/node-$PLATFORM-$ARCH/bin/npm"
if [ -x "$NPM_BIN" ] && [ -d "$ENGINE_DIR/node_modules" ]; then
    mkdir -p "$NPM_CACHE_DIR"
    ( cd "$ENGINE_DIR" && NPM_CONFIG_CACHE="$NPM_CACHE_DIR" "$NPM_BIN" install @anthropic-ai/claude-code@latest \
        --no-audit --no-fund --loglevel=warn --no-bin-links --cache "$NPM_CACHE_DIR" ) \
        && echo -e "${GREEN}      OK${RESET}"
else
    echo -e "${YELLOW}      Portable Node not found yet — run ./start.sh once first.${RESET}"
fi

# 3) proxy submodule 依賴
echo -e "${YELLOW}[3/3] tools/claude-proxy dependencies${RESET}"
if [ -f "$ROOT_DIR/tools/claude-proxy/package.json" ]; then
    if [ -x "$NPM_BIN" ]; then
        ( cd "$ROOT_DIR/tools/claude-proxy" && NPM_CONFIG_CACHE="$NPM_CACHE_DIR" "$NPM_BIN" install \
            --no-audit --no-fund --loglevel=warn --cache "$NPM_CACHE_DIR" ) \
            && echo -e "${GREEN}      OK${RESET}"
    else
        echo -e "${YELLOW}      Skipped (portable Node not ready).${RESET}"
    fi
else
    echo -e "${YELLOW}      Submodule not initialised. Run: git submodule update --init${RESET}"
fi

echo ""
echo -e "${GREEN}Done. Next ./start.sh should skip the first-run install delay.${RESET}"
echo -e "${DIM}（Claude Max 路徑仍需在 wizard 裡完成一次 OAuth 登入。）${RESET}"
echo ""
```

> **實作注意：** 上面 Step 1 的「呼叫 start.sh bootstrap」那段是脆弱的（start.sh 沒有「只裝不跑」模式）。**更乾淨的做法**（實作者選擇）：把 `start.sh` 開頭「Node 下載」與「`install_engine` 呼叫」之間的邏輯抽出成 `tools/_bootstrap_lib.sh`，`start.sh` 與 `preinstall.sh` 都 source 它。如果選這個重構，把它也加進本 task 並對應改 `start.sh`。如果不想動 `start.sh` 太多，就保留上面的「檢查 + 提示使用者先跑一次 start.sh」的較弱版本 —— 對 Google Drive sync 場景（裝一次同步到處）這已足夠。**決策點留給實作者，但要在 commit message 註明選了哪個。**

- [ ] **Step 2: 加可執行權限 + 語法檢查**

Run:
```bash
chmod +x tools/preinstall.sh
bash -n tools/preinstall.sh && echo "syntax OK"
```
Expected: `syntax OK`。

- [ ] **Step 3: 手動驗證**

Run（在已經跑過 start.sh 至少一次的環境）:
```bash
./tools/preinstall.sh
```
Expected: 三步都印 `OK`（或合理的「先跑 start.sh」提示）；之後 `engine/node_modules/@anthropic-ai/claude-code/bin/claude` 與 `tools/claude-proxy/node_modules/express` 都存在。

- [ ] **Step 4: Commit**

Run:
```bash
git add tools/preinstall.sh
git commit -m "Add preinstall.sh: pre-fetch all deps without launching the engine"
```

---

## Task 11: README.md 更新

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Key Features 表加一列**

在 `README.md` 的 Key Features 表（`| Feature | Details |` 那張），新增一列：
```markdown
| **Claude Max Mode** | Use a $200/mo Claude subscription via OAuth + a bundled local proxy — no per-token API cost. macOS/Linux only. |
```

- [ ] **Step 2: Supported AI Providers 表加一列 + 註明限制**

在 Supported AI Providers 表新增：
```markdown
| **Claude (Max Subscription)** | Flat $200/mo | OAuth login (no API key) — macOS/Linux only |
```

- [ ] **Step 3: Project Structure 圖補 `tools/claude-proxy/` 與 `tools/preinstall.sh`、`tools/_claude_max_lib.sh`**

在 `README.md` 的 Project Structure 區塊的 `tools/` 子樹下新增（保持既有縮排風格）:
```
│   ├── _claude_max_lib.sh     Shared Claude Max wizard functions
│   ├── preinstall.sh          Pre-fetch all dependencies (no engine launch)
│   ├── claude-proxy/          Local OpenAI-compatible proxy → Claude Max (git submodule)
```

- [ ] **Step 4: 新增「Claude Max Subscription Mode」一節**

在 README 適當位置（建議放在「LM Studio Setup」與「Custom OpenAI-Compatible Provider」之間）新增：
```markdown
## Claude Max Subscription Mode (macOS / Linux)

Use your existing **Claude Max subscription** ($200/mo) instead of paying per-token API rates. Select option **`10) Claude (Max Subscription)`** in `start.sh` (or `tools/change_provider.sh`).

What happens on first setup:

1. Downloads the `claude` CLI and the bundled proxy's dependencies (~30–50 MB, one time).
2. Opens a browser for **OAuth login** with your Claude Max account. Credentials are stored **inside the project** at `data/home/.claude/` — nothing touches your real home directory.
3. You pick a default model: `claude-opus-4-7`, `claude-sonnet-4-6` (recommended), or `claude-haiku-4-5`.
4. A random local-only API key is generated and wired up automatically — you never type an API key.

On every launch after that, a local proxy starts on `127.0.0.1:3456` (logged to `data/claude-proxy.log`) and stops when the engine exits.

**Notes & limitations:**
- **macOS / Linux only.** The Windows launcher (`START.bat`) does not expose this option.
- **OAuth is per-machine.** If you move the project to a different machine or CPU architecture, you may need to re-run setup and log in again (`data/home/.claude/` credentials may not transfer).
- **Dashboard agent mode is not supported on Claude Max.** The proxy ignores OpenAI-style `tools`, so the dashboard's *agent* mode (which calls tools) silently behaves like plain chat. Use chat mode with Claude Max, or switch to a tool-calling provider (OpenRouter, OpenAI, …) for agent mode.
- After setup, `start.sh`'s header may show the provider as `Custom OpenAI-Compatible` (because the base URL is `localhost:3456`). That's cosmetic — it's still Claude Max.
- A re-login can be forced any time by deleting `data/home/.claude/` and re-running setup.
```

- [ ] **Step 5: Troubleshooting 表加幾列**

在 `README.md` 的 Troubleshooting 表新增：
```markdown
| `Claude Max proxy not responding` | Check `data/claude-proxy.log`. Common cause: OAuth credentials expired — re-run option `10` or delete `data/home/.claude/` and log in again. |
| Port 3456 still in use after closing the dashboard | The dashboard's self-heal starts the proxy *detached*, so it survives the dashboard. Run `kill $(lsof -ti TCP:3456)` to clear it. |
| `tools/claude-proxy` is empty | Submodule not initialised. Run `git submodule update --init tools/claude-proxy`. |
```

- [ ] **Step 6: 加 preinstall + 上游 sync 說明**

在 README 的「Quick Start」之後加一小節：
```markdown
### Pre-installing dependencies (optional)

To avoid the first-run download wait, run `./tools/preinstall.sh` once after cloning. It fetches Node.js, the engine, the `claude` CLI, and the proxy's dependencies without launching anything. (Claude Max mode still needs a one-time OAuth login during setup.)

### Keeping in sync with upstream

This repo tracks `techjarves/OpenClaude-Portable` as `upstream`:

```bash
git fetch upstream
git rebase upstream/main      # or: git merge upstream/main
```

The bundled proxy is a git submodule pointing at `photofanz/portable-claude-proxy` (derived from `photofanz/hermes-claude-proxy-v5`). To pull a newer proxy:

```bash
git submodule update --remote tools/claude-proxy
git add tools/claude-proxy && git commit -m "Update claude-proxy submodule"
```
```

- [ ] **Step 7: Commit**

Run:
```bash
git add README.md
git commit -m "docs: README updates for Claude Max Subscription mode, preinstall, upstream sync"
```

---

## Task 12: CLAUDE.md 更新

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 在「Provider 對應規則」表後新增 Claude Max 段落**

在 `CLAUDE.md` 的「### Provider 對應規則」那張表**之後**（NVIDIA NIM 段落之前或之後皆可），新增：
```markdown
### Claude Max Subscription 路徑（`10)` 選項，僅 macOS/Linux）

`tools/_claude_max_lib.sh` 的 `setup_claude_max()` 寫入：

```env
AI_PROVIDER=openai
CLAUDE_CODE_USE_OPENAI=1
OPENAI_BASE_URL=http://127.0.0.1:3456/v1
OPENAI_API_FORMAT=chat_completions
OPENAI_API_KEY=sk-portable-<random>     # 等同 tools/claude-proxy/.env 的 API_KEY
OPENAI_MODEL=claude-sonnet-4-6          # 或 opus-4-7 / haiku-4-5
AI_DISPLAY_MODEL=claude-sonnet-4-6
CLAUDE_PROXY_MODE=1                     # start.sh 與 dashboard 判斷旗標
```

走 OpenAI-相容路徑（**不傳** `--provider`），跟 OpenRouter / DeepSeek / LM Studio / Custom 同模式 —— 原因同那條規則：傳 `--provider openai` 會讓引擎吃使用者主機 Codex/OpenAI profile。

`CLAUDE_PROXY_MODE=1` 時，`start.sh` 在引擎啟動前背景起 `tools/claude-proxy/server.js`（git submodule，指向 `photofanz/portable-claude-proxy`，從 `hermes-claude-proxy-v5` 衍生 — 內部用 `@anthropic-ai/claude-agent-sdk` in-process，不 spawn CLI），引擎結束時 kill — 跟 Ollama 同模式。Proxy log 在 `data/claude-proxy.log`。OAuth credentials 在 `data/home/.claude/.credentials.json`（HOME 已被 portable 重導涵蓋）。`claude` CLI（`@anthropic-ai/claude-code`）只用於首次 `claude login`，runtime 不需要。

Dashboard（`dashboard/server.mjs`）的 OpenAI 路徑直接吃這個 proxy，0 改動；但 agent mode 的 OpenAI tools 會被 proxy 忽略（agent mode 對 Claude Max 沉默失效，見 README）。
```

- [ ] **Step 2: 在 CLAUDE.md 末尾新增「上游同步」章節**

新增：
```markdown
## 上游同步

本 repo 已是 git 控管，三個獨立上游：

- **引擎** `@gitlawb/openclaude` — `start.sh` 每次啟動自動 `npm outdated` 檢查升級，無需手動。
- **claude CLI** `@anthropic-ai/claude-code` — `start.sh` 同模式自動檢查（`--no-claude-cli-update` 可跳過）。
- **launcher 本體** `techjarves/OpenClaude-Portable` — `git fetch upstream && git rebase upstream/main`，手動。
- **proxy submodule** `photofanz/portable-claude-proxy` — `git submodule update --remote tools/claude-proxy`，手動。要拿 `hermes-claude-proxy-v5` 或 `ppcvote/openclaw-claude-proxy` 的修補，在 portable-claude-proxy repo 內 `git fetch hermes && git cherry-pick <sha>`。

`engine/` 與 `data/` 在 `.gitignore` 排除清單內（執行期下載/產生），git 操作不會碰它們。
```

- [ ] **Step 3: Commit**

Run:
```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md — Claude Max provider mapping + upstream sync section"
```

---

## Task 13: 最終整合驗證 + spec 對照

**Files:** 無（純驗證）

- [ ] **Step 1: 完整 happy path 重跑**

從乾淨狀態（或現有狀態）跑：
```bash
git submodule update --init tools/claude-proxy   # 若需要
./tools/preinstall.sh                            # 若想驗證 preinstall
./start.sh                                       # 選 10 → 走 wizard → 選 1 launch → 對話 → 退出
```
核對 spec「驗收條件」1-8 逐條：
1. `./start.sh` → `10)` → wizard → launch → 能跟 opus-4-7 / sonnet-4-6 / haiku-4-5 對話 ✓
2. `data/claude-proxy.log` 有請求記錄且 forward 成功 ✓
3. `Ctrl+C` 後無殘留 proxy PID（`lsof -nP -iTCP:3456 -sTCP:LISTEN` 空）✓
4. `bash tools/open_dashboard.sh` 後 dashboard chat 能跟 Claude Max 對話（self-heal 起 proxy）✓
5. 重跑 `./start.sh` 走捷徑、自動起 proxy ✓
6. `./tools/change_provider.sh` 切到 OpenRouter → 下次 `./start.sh` 不起 proxy ✓
7. `./tools/preinstall.sh` 跑完後 `./start.sh` 無 install/download 訊息 ✓
8. `git fetch upstream && git diff upstream/main...HEAD` 清楚列出整合 commit；`git rebase upstream/main` 無衝突成功（或衝突可控）✓

- [ ] **Step 2: spec 涵蓋度檢查**

對照 `docs/superpowers/specs/2026-05-10-claude-max-proxy-integration-design.md` 的「工項拆解」A.1–A.2、B.3–B.11 逐條打勾，確認都有對應的 plan task 實作過。記下任何缺漏。

- [ ] **Step 3: 收尾 commit（如有零星修正）**

如果驗證過程修了東西：
```bash
git add -A
git commit -m "Fix issues found in final integration verification"
```

- [ ] **Step 4: 確認 git 狀態乾淨**

Run:
```bash
git status
git submodule status
git log --oneline upstream/main..HEAD
```
Expected: working tree clean；submodule 在正確 SHA；`git log` 列出本次整合的所有 commit（約 12-14 個）。

---

## Self-Review（plan 作者已執行）

**1. Spec 涵蓋度：**
- A.1 git init + upstream → Task 1 ✓
- A.2 新建 portable-claude-proxy（從 hermes 起手 + 3 微調）→ Task 2 ✓
- B.3 加 submodule + .gitignore → Task 3 ✓
- B.4 proxy 3 處微調 + .env.example → Task 2 Step 3-8 ✓
- B.5 `_claude_max_lib.sh` → Task 4 ✓
- B.6 `start.sh`（選單 + case + claude_proxy_ready + 引擎啟停 + D12 更新檢查）→ Task 5 + Task 6 ✓
- B.7 `change_provider.sh` → Task 8 ✓
- B.8 `dashboard/server.mjs` self-heal → Task 9 ✓
- B.9 `preinstall.sh` → Task 10 ✓
- B.10 `.gitignore` → Task 3 Step 3 ✓
- B.11 文件（README + CLAUDE.md）→ Task 11 + Task 12 ✓
- 驗收條件 → Task 7（端到端）+ Task 13（最終對照）✓
- Future Work（agent tools）→ 明確排除，未進 plan ✓

**2. Placeholder 掃描：** Task 10 Step 1 標明「脆弱、決策點留給實作者」並給了具體的兩個選項（抽 `_bootstrap_lib.sh` 或保留弱版本）+ 要求 commit message 註明 — 不是 placeholder，是有意的實作判斷點。其餘步驟皆有具體 code/command。

**3. 型別/命名一致性：** `setup_claude_max` / `claude_proxy_ready` / `claude_oauth_present` / `claude_oauth_verify` / `claude_oauth_login` / `install_claude_max` / `ensureClaudeMaxProxy` / `CLAUDE_PROXY_MODE` / `CLAUDE_PROXY_PID` / `CLAUDE_MAX_MODEL` / `SKIP_CLAUDE_CLI_UPDATE` — 跨 Task 4/5/6/8/9 使用一致。Proxy port `3456` 一致。`tools/claude-proxy/` submodule 路徑一致。`OPENAI_BASE_URL=http://127.0.0.1:3456/v1`（含 `/v1`）在 Task 4 寫入、Task 9 self-heal 偵測時用 `includes('127.0.0.1:3456')`（不含 `/v1` 也能 match）— 一致無 bug。

**已知妥協（非 bug）：**
- `start.sh` header 的 PROVIDER_NAME 對 Claude Max 會顯示「Custom OpenAI-Compatible」— 文件已說明（Task 11 Step 4）。
- preinstall.sh Step 1 的 Node+engine bootstrap 較弱（依賴使用者先跑一次 start.sh）— 對 Drive sync 場景足夠；想完美要抽 `_bootstrap_lib.sh`（留給實作者）。
- dashboard self-heal 起的 proxy 是孤兒程序 — 文件已說明（Task 11 Step 5）。
