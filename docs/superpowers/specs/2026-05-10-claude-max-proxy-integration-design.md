---
date: 2026-05-10
status: approved-design
topic: Claude Max Subscription Proxy Integration
scope: macOS / Linux only (Windows explicitly out of scope)
related:
  - tools/local-proxy.js (sibling pattern reference)
  - https://github.com/photofanz/hermes-claude-proxy-v5 (proxy 起手版本 — v5.0 persistent-session edition；本整合不直接動它)
  - https://github.com/photofanz/portable-claude-proxy (本整合用的 portable-specific fork — 從 hermes-v5 起手新開的 repo)
---

# Claude Max Subscription Proxy 整合設計

把 `openclaude-claude-proxy` 整合進 OpenClaude-Portable，讓使用者透過 Claude Max ($200/月) 訂閱與 OAuth 認證使用 Claude，無需 Anthropic API key。

## 背景

OpenClaude-Portable 既有的 `5) Claude` 選項只支援真 Anthropic API（`sk-ant-...` key 走 `api.anthropic.com`，按 token 計費）。

**Proxy 來源族譜：**
- 上上游：`ppcvote/openclaw-claude-proxy`（spawn `claude --print` 子行程的 OpenAI 相容 wrapper）
- 中游：`photofanz/hermes-claude-proxy-v5`（使用者大幅改造的 detached fork，v5.0 persistent-session edition：用 `@anthropic-ai/claude-agent-sdk` in-process 呼叫，不再 spawn CLI；給 Hermes Agent 主用）
- 本整合用：**新開 `photofanz/portable-claude-proxy` repo**，從 hermes-v5 起手、加入 portable 特化的 3 處微調（loopback bind、零節流、EADDRINUSE handler）。**hermes-v5 完全不被本整合動到** — 兩個 repo 平行演進。

整合目標：在 Portable 主選單**新增**一個 `10) Claude (Max Subscription)` 入口，使用者完全不需要管 API key，背後走 OAuth + portable-claude-proxy。

## 決策摘要

| ID | 決策 | 理由 |
|---|---|---|
| D1 | Portable 內含 claude CLI（為了 OAuth 登入指令）、OAuth credentials 落在 `data/home/.claude/` | 維持「USB 插上就跑」精神（在同架構主機上）；HOME 已被 portable 重導；hermes proxy 內部用 SDK 不 spawn CLI，但首次 OAuth `claude login` 仍要 CLI |
| D2 | 主選單**新增** `10) Claude (Max Subscription)`，原 `5) Claude` 不動 | 向後相容；既有 sk-ant 使用者 0 影響 |
| D3 | proxy 對接走 OpenAI-相容 API：hermes `/v1/chat/completions` + `OPENAI_BASE_URL` | hermes-v5 只暴露 OpenAI endpoint（沒 `/v1/messages`）；Portable 既有 OpenAI-相容路徑（OpenRouter / DeepSeek / LM Studio / Custom）成熟、driver 共用、dashboard 0 改動 |
| D4 | proxy 按需起停（跟 Ollama 同模式）；Dashboard 順手對接 | 不選 Claude Max 的使用者不會被多 30 MB 下載拖慢；Dashboard 既有 OpenAI 路徑直接吃 |
| D5 | proxy API_KEY 自動產生隨機 token，wizard 同步寫雙邊，使用者看不到 | 使用者免管理；loopback only 安全 OK |
| ~~D6~~ | ~~用 `ANTHROPIC_AUTH_TOKEN` 避開 approval gate~~ | **已刪除** — 走 OpenAI 路徑後引擎不檢查 `ANTHROPIC_API_KEY`，approval gate 不適用 |
| D7 | proxy 用 `tools/claude-proxy/` 路徑名，git submodule 指向**新開的** `photofanz/portable-claude-proxy` | 路徑名稱保留中性「claude-proxy」（不暴露 hermes 品牌）；新 repo 從 hermes-v5 起手、portable 特化改動只進這個新 repo；hermes-v5 完全不動 |
| D8 | Windows 不支援；START.bat / change_provider.bat 不動 | 使用者選擇；batch 對等實作工作量大 |
| D9 | 新增 `tools/preinstall.sh` 主動一次裝完所有依賴 | 把首次啟動的 install 等待時點提前；對 Google Drive sync 場景特別有用（一次裝完、Drive 同步到所有同架構機器） |
| D10 | Portable repo 本身 `git init` 並加 `techjarves/OpenClaude-Portable` 為 upstream remote | 上游活躍（3 天前才更新、603 stars），未來能 `git fetch upstream && git rebase upstream/main` sync |
| D11 | `tools/claude-proxy/` 用 git submodule，指向 `photofanz/portable-claude-proxy` (default branch `main`) | 從 hermes-v5/main 起手新建；portable 特化改動只在這個 repo；hermes-v5 完全不被影響；hermes-v5 有更新時可手動 `git remote add hermes ... && cherry-pick` |
| D12 | `start.sh` 每日更新檢查順手追加 `@anthropic-ai/claude-code`，跟既有 `@gitlawb/openclaude` 同模式 | claude CLI bug fix 自動拿到；`--no-claude-cli-update` 旗標可跳過避開 breaking change 偶發 |

## 架構

### Runtime topology（選了 `10) Claude (Max Subscription)` 之後）

```
OpenClaude 引擎  ──OpenAI Chat Completions──►  127.0.0.1:3456 (hermes-claude-proxy-v5)
                  OPENAI_BASE_URL                       │
                  OPENAI_API_KEY                        │ in-process: require('@anthropic-ai/claude-agent-sdk')
                                                          ▼
                                            Persistent SDK session per model
                                            HOME=$DATA_DIR/home (portable HOME 重導)
                                                          │
                                                          ▼ reads OAuth credentials
                                            data/home/.claude/.credentials.json
                                                          │
                                                          ▼ HTTPS
                                            api.anthropic.com (Claude Max sub)
```

**首次 OAuth 登入路徑**（wizard 階段、僅一次）：

```
wizard 子 shell  ──env HOME=data/home──►  engine/.../bin/claude login
                                                │
                                                ▼ 開瀏覽器、使用者完成 Anthropic OAuth
                                                ▼ 寫入
                                                data/home/.claude/.credentials.json
```

### 目錄結構變更

```
Portable_USB/
├─ engine/
│   ├─ node-darwin-arm64/bin/node                   ← 既有
│   ├─ node_modules/@gitlawb/openclaude/            ← 既有
│   └─ node_modules/@anthropic-ai/claude-code/      ← 新增（claude CLI）
│       └─ bin/claude
├─ tools/
│   ├─ local-proxy.js                               ← 既有（Ollama 用）
│   ├─ _claude_max_lib.sh                           ← 新增（共用 wizard 函式）
│   ├─ preinstall.sh                                ← 新增（D9：主動一次裝完所有依賴）
│   └─ claude-proxy/                                ← 新增（git submodule，指向 user fork）
│       ├─ server.js                                ← fork 端微調過：bind 127.0.0.1 等 4 處
│       ├─ plugins/
│       │   ├─ content-filter.js
│       │   ├─ cost-tracker.js
│       │   └─ language-enforcer.js
│       ├─ package.json
│       ├─ .env.example
│       └─ node_modules/                            ← bootstrap 時 npm install（gitignored）
├─ data/
│   ├─ home/.claude/.credentials.json               ← OAuth 落點（HOME 已重導）
│   ├─ ai_settings.env                              ← 新增 5 個 ANTHROPIC_* / CLAUDE_PROXY_MODE 鍵
│   └─ claude-proxy.log                             ← proxy stderr/stdout
├─ .git/                                             ← 新增（D10：git init + add upstream）
├─ .gitmodules                                       ← 新增（D11：紀錄 claude-proxy submodule）
└─ start.sh                                          ← 加 setup_claude_max + 起 proxy 段
```

## Env 契約

`data/ai_settings.env` 在 Claude Max 模式寫入：

```env
AI_PROVIDER=openai
CLAUDE_CODE_USE_OPENAI=1
OPENAI_BASE_URL=http://127.0.0.1:3456/v1                    # hermes proxy endpoint
OPENAI_API_FORMAT=chat_completions
OPENAI_API_KEY=sk-portable-<auto-generated-32-hex>          # 等同 hermes API_KEY
OPENAI_MODEL=claude-sonnet-4-6                              # 三選一：opus-4-7 / sonnet-4-6 / haiku-4-5
AI_DISPLAY_MODEL=claude-sonnet-4-6
CLAUDE_PROXY_MODE=1                                         # start.sh 與 dashboard 判斷旗標
```

`tools/claude-proxy/.env` 同時寫入：

```env
PORT=3456
API_KEY=<same as OPENAI_API_KEY above>
MAX_CONCURRENT=2
REQUEST_TIMEOUT=300000
MAX_RETRIES=2
PLUGINS_DIR=./plugins
# STATELESS_MODE=1   # 預設 persistent session；除錯時可開
```

兩邊的 token 必須**逐字對齊**（wizard 一次產生、寫入兩處）。

### 為什麼走 OpenAI 路徑而非 Anthropic 路徑

hermes-claude-proxy-v5 只暴露 `POST /v1/chat/completions`、`GET /v1/models`、`GET /health`、`GET /stats` 四個 endpoint。沒有 `/v1/messages`，所以走 `ANTHROPIC_BASE_URL` 會 404。改走 OpenAI-相容路徑是事實適配 + 額外好處：(a) Portable 既有 OpenAI 路徑（OpenRouter、DeepSeek、LM Studio、Custom）成熟、driver 共用；(b) Dashboard 既有 `callAI_OpenAI` 路徑早就支援可配置 baseUrl，0 改動；(c) 引擎走 openai 路徑時根本不檢查 `ANTHROPIC_API_KEY`，沒有 `customApiKeyResponses.approved` 的 approval gate 問題。

### `--provider` 旗標

按 [CLAUDE.md](../../../CLAUDE.md) 的「Provider 對應規則」既有慣例：OpenAI-相容路徑（OpenRouter / DeepSeek / LM Studio / Custom）**不傳** `--provider openai`，靠 `OPENAI_BASE_URL` + `CLAUDE_CODE_USE_OPENAI=1` 切換。Claude Max 路徑**沿用同模式不傳 `--provider`** — 這樣引擎不會誤吃使用者主機 Codex/OpenAI profile 覆蓋我們的 base URL。

## Wizard 流程

新函式 `setup_claude_max()` 放在 `tools/_claude_max_lib.sh`，`start.sh` 與 `tools/change_provider.sh` 共用 source。

```
1. 顯示警示
   - 「這是訂閱制路徑，不需要 API key，但需要 Claude Max 訂閱與一次 OAuth 登入」
   - 「OAuth credentials 會存進 data/home/.claude/，跨主機/跨架構可能要重新登入」
   - 「macOS / Linux only — Windows 暫不支援」

2. claude_proxy_ready() 檢查
   - 若失敗 → install_claude_max():
       cd ENGINE_DIR && npm install @anthropic-ai/claude-code@latest
       cd tools/claude-proxy && npm install
       兩者共用 NPM_CACHE_DIR；沿用 install_engine 的 progress monitor

3. OAuth 認證
   - 檢查 data/home/.claude/.credentials.json:
       存在 → 跑 timeout 5 claude --print "ping" 驗證
       不存在 / 驗證失敗 → 進子 shell 自動登入：
           env HOME="$DATA_DIR/home" PATH="$ENGINE_DIR/node_modules/@anthropic-ai/claude-code/bin:$PATH" \
               bash -c 'claude login'
       → 子 shell 結束後重新驗證 → 仍失敗就 abort wizard 並顯示手動修復指令

4. 模型三選一（對齊 hermes-v5 server.js:218-220）
   echo「選擇預設模型：」
     1) claude-opus-4-7     — 最強，成本最高（仍含於 Max 訂閱）
     2) claude-sonnet-4-6   — 平衡（推薦，hermes 預設）
     3) claude-haiku-4-5    — 最快
   read SEL → MODEL = 對應字串

5. 自動產生 token + 寫雙邊 env
   PROXY_TOKEN="sk-portable-$(openssl rand -hex 16)"
   寫 tools/claude-proxy/.env (PORT, API_KEY=PROXY_TOKEN, CLAUDE_CLI_PATH, ...)
   save_env 到 data/ai_settings.env (上節「Env 契約」內容)

6. 結束 wizard，回到主流程繼續
```

## Bootstrap 與生命週期

### `claude_proxy_ready()`

```bash
claude_proxy_ready() {
    [ -f "$ENGINE_DIR/node_modules/@anthropic-ai/claude-code/bin/claude" ] && \
    [ -d "$ROOT_DIR/tools/claude-proxy/node_modules/express" ]
}
```

只在 wizard 內呼叫，**不在** start.sh 開頭主 bootstrap 觸發 — 不選 Claude Max 的使用者不該下載。

### Provider 選單變更

`start.sh:244-252` 區塊加第 10 項：

```
  10) Claude (Max Subscription) - $200/mo, OAuth, no per-token cost (macOS/Linux)
```

對應 `case` 加 `10) setup_claude_max; return ;;`。`setup_provider()` 的輸入範圍從 1-9 擴成 1-10。`change_provider.sh` 對等加同一項。

### 引擎啟動段（`start.sh:825` 附近）

仿照既有 Ollama 啟動 pattern：

```bash
if [ "$CLAUDE_PROXY_MODE" = "1" ]; then
    PROXY_LOG="$DATA_DIR/claude-proxy.log"
    cd "$ROOT_DIR/tools/claude-proxy"
    "$NODE_BIN" server.js >> "$PROXY_LOG" 2>&1 &
    CLAUDE_PROXY_PID=$!
    cd "$ENGINE_DIR"

    # health check（最多 5 秒）
    for i in 1 2 3 4 5; do
        sleep 1
        if curl -sf http://127.0.0.1:3456/health > /dev/null 2>&1; then
            echo "[OK] Claude Max proxy ready (PID $CLAUDE_PROXY_PID)"
            break
        fi
    done

    # 5 秒沒起來警示但不 abort（讓 openclaude 自己回 connection error）
    if ! curl -sf http://127.0.0.1:3456/health > /dev/null 2>&1; then
        echo "[WARN] Claude Max proxy not responding after 5s — check $PROXY_LOG"
    fi
fi
```

引擎結束後段加 trap：

```bash
[ -n "$CLAUDE_PROXY_PID" ] && kill "$CLAUDE_PROXY_PID" 2>/dev/null && wait "$CLAUDE_PROXY_PID" 2>/dev/null
```

不衝突檢查：proxy 用 3456，Dashboard 3000，Ollama 11434，local-proxy 11435 — 全錯開。

## Dashboard 整合

走 OpenAI-相容路徑後，`dashboard/server.mjs` 既有的 `callAI_OpenAI`（第 363-396 行）與 `streamChatResponse` 的 openai 分支（第 642-666 行）已經支援可配置 `baseUrl`：

```javascript
// dashboard/server.mjs:365 — 既有實作早就支援我們需要的行為
const baseUrl = cfg.OPENAI_BASE_URL || 'https://api.openai.com/v1';
```

**結論：dashboard 的 OpenAI 路徑 0 改動就支援 hermes proxy。** 待驗證的細節：

1. **Tools 參數透傳**：dashboard agent 模式（`/api/agent`）會把 `toolsForOpenAI()` 帶在 payload。hermes server.js 第 263 行 `let { messages, model, stream, max_tokens, tools } = req.body;` — 接受 tools 參數但內部不傳給 SDK，會被靜默忽略。**意味著 dashboard agent 模式的 tool calling 在 Claude Max 路徑會失效**（不會 crash，但 LLM 不知道有 tools 可用）。Trade-off：要不要在 hermes 端加 tool support？或者 portable 端在偵測 hermes proxy 時，對 dashboard 提示「agent mode 不支援 Claude Max」？
   **建議：本期不處理（YAGNI）**；dashboard chat 模式（無 tools）正常運作即可，agent 模式留給 OpenRouter / OpenAI 等真支援 tool calling 的 provider 用。如果使用者實際需要再加。

2. **Self-heal 偵測 env 改成 `OPENAI_BASE_URL`**：

```javascript
// dashboard/server.mjs 啟動前加
if (process.env.CLAUDE_PROXY_MODE === '1' &&
    process.env.OPENAI_BASE_URL?.includes('127.0.0.1:3456')) {
    const healthOk = await fetch('http://127.0.0.1:3456/health').then(r => r.ok).catch(() => false);
    if (!healthOk) {
        const proxyDir = join(ROOT_DIR, 'tools', 'claude-proxy');
        const proc = spawn(process.execPath, ['server.js'], {
            cwd: proxyDir, stdio: 'ignore', detached: true
        });
        proc.unref();
        // 等 health
        for (let i = 0; i < 5; i++) {
            await new Promise(r => setTimeout(r, 1000));
            if (await fetch('http://127.0.0.1:3456/health').then(r => r.ok).catch(() => false)) break;
        }
    }
}
```

**注意：用 `detached: true` + `.unref()`，dashboard 結束時 proxy 不會跟著被 kill — 會變孤兒程序留在 :3456**。這是有意設計（避免 dashboard 重啟時頻繁 spawn/kill），但意味著使用者偶爾要 `lsof -i :3456` + `kill <PID>` 手動清。為了讓 START.sh 後續啟動時能直接重用既有 instance 而非 crash，hermes server.js 需要加 EADDRINUSE handler（見「Proxy 程式碼微調」）。

## Proxy 程式碼微調

在**新開的 `photofanz/portable-claude-proxy`** 的 `main` 分支上做 3 處改動（commit & push 到新 repo，portable 端 `git submodule update --remote` 拉到）。**`hermes-claude-proxy-v5` 不被動到**：

| 位置 | 變更前 | 變更後 | 理由 |
|---|---|---|---|
| `app.listen(PORT, '0.0.0.0', ...)` 第 417 行 | bind 0.0.0.0 | bind `127.0.0.1` | Loopback only，不要外洩 |
| `MIN_REQUEST_INTERVAL_MS = 3000` 第 38 行 | 3 秒間隔 | `0` | 單使用者場景不需節流 |
| `app.listen(...)` 改寫 | 無 EADDRINUSE 處理 | `const server = app.listen(...); server.on('error', err => { if (err.code === 'EADDRINUSE') { console.log('Port already in use - exiting'); process.exit(0); } else throw err; })` | 仿 local-proxy.js 的 reuse-existing-instance 行為，避免 dashboard self-heal 與 START.sh 的 race |

`MAX_RETRIES` 從 default 1 提到 2（寫進 hermes 的 `.env.example`），緩解 Max rate limit 偶發性錯誤。

> **注意：** v4 版本的 `cwd: process.env.HOME || '/home/ubuntu'` HOME fallback 在 v5 不存在了 — hermes-v5 不再 spawn `claude` CLI 子行程，全部走 SDK in-process，HOME 直接從 portable `start.sh` 透過 env 繼承。

## 風險與緩解

| 風險 | 機率 | 影響 | 緩解 |
|---|---|---|---|
| OAuth credentials 換主機 / 換架構失效 | 高 | 使用者要重登 | README 寫清楚；wizard 提供「重新登入」入口；錯誤時自動引導重跑 `claude login` |
| `claude --print` 每次 spawn 子行程，互動體驗慢 | 中 | UX | `MIN_REQUEST_INTERVAL_MS=0`；`MAX_RETRIES=2`；first-token 仍可能 5-10 秒（Claude Max + spawn 開銷固定成本） |
| Claude Max rate limit 觸發 | 中 | 失敗無友善錯誤 | proxy 已有 retry；429 訊息透過 SSE 傳回引擎與 Dashboard |
| 引擎升級時誤升 `@anthropic-ai/claude-code` | 低 | claude CLI 變動可能破壞 proxy | 引擎更新檢查（`start.sh:207` 的 `npm outdated`）只盯 `@gitlawb/openclaude`，不動 claude CLI |
| `tools/claude-proxy/node_modules/` 在 Google Drive 同步路徑下 sync 衝突 | 中 | 啟動失敗 / 檔案損毀 | `.gitignore` 加；README 寫「Drive 路徑下建議排除這個資料夾不同步」 |
| Google Drive 路徑包含特殊字元（中文 / 括號 / 空白）破壞腳本 | 中 | proxy spawn / npm install 失敗 | wizard 啟動前測 `printf '%q' "$ROOT_DIR"` 後跑一次空操作驗證；失敗時提示使用者搬到無特殊字元路徑 |
| ~~引擎不認 `ANTHROPIC_BASE_URL`~~ | — | — | **已不適用**：D3 改走 OpenAI 路徑後，根本不用 ANTHROPIC_BASE_URL |
| ~~`ANTHROPIC_AUTH_TOKEN` 認證問題~~ | — | — | **已不適用**：D6 已刪除 |
| Dashboard agent 模式（含 tools）對 Claude Max 路徑沉默失效 | 中 | 使用者困惑 | UI 在偵測 `CLAUDE_PROXY_MODE=1` 時顯示「Agent mode 不支援 Claude Max；請用 chat mode 或切換 provider」提示。本期可不做（YAGNI），先文件標明。 |
| Hermes v5 SDK API 變動破壞 proxy | 低 | proxy crash | hermes 自己用 npm `@anthropic-ai/claude-agent-sdk` semver 釘版本；升級時手動測 |

## 工項拆解

執行順序由依賴鏈決定：

### A. 上游關係建立（一次性 setup）

1. **Portable repo `git init` + 加 upstream remote**
   ```bash
   git init
   git remote add upstream https://github.com/techjarves/OpenClaude-Portable.git
   git fetch upstream
   # 用 upstream 的 main 為基底匯入既有檔案
   git checkout -b main upstream/main
   # 把本地實際內容（如果與 upstream 已分歧）以一個 commit 蓋上
   git add -A && git commit -m "Local snapshot before Claude Max integration"
   ```

2. **新開 `photofanz/portable-claude-proxy` repo**（在 GitHub 介面手動建立空 repo），然後在本機：
   ```bash
   git clone https://github.com/photofanz/hermes-claude-proxy-v5.git portable-claude-proxy
   cd portable-claude-proxy
   git remote rename origin hermes                              # 保留 hermes 為衍生來源 remote
   git remote add origin https://github.com/photofanz/portable-claude-proxy.git
   # 改 README 標明「衍生自 hermes-v5、為 OpenClaude-Portable 特化」
   # 做 3 處微調（見「Proxy 程式碼微調」段）
   git add -A && git commit -m "Portable-specific bind/throttle/EADDRINUSE adjustments"
   git push -u origin main
   ```
   未來想 sync hermes-v5 的更新：`git fetch hermes && git cherry-pick <sha>`（手動篩選相容變動）。

### B. 整合本體實作

3. **加 proxy submodule**
   ```bash
   git submodule add -b main https://github.com/photofanz/portable-claude-proxy.git tools/claude-proxy
   ```
   submodule 路徑名用中性「claude-proxy」而非「portable-claude-proxy」或「hermes-claude-proxy-v5」（D7：portable 端不暴露 proxy 品牌、未來換 proxy 實作時無痛）。

4. **Portable proxy 3 處微調**（在新 repo `photofanz/portable-claude-proxy` 的 main 分支做，工項 2 內已完成）
   - 第 417 行 bind 改 `127.0.0.1`
   - 第 38 行 `MIN_REQUEST_INTERVAL_MS = 0`
   - `app.listen` 加 EADDRINUSE handler（仿 local-proxy.js）
   - `.env.example` 加 `MAX_RETRIES=2`

5. **新增 `tools/_claude_max_lib.sh`** — `setup_claude_max()` + 子函式（OAuth 子 shell 登入、模型三選、token 產生、雙邊 env 寫入）。

6. **`start.sh` 改動**
   - `claude_proxy_ready()` 加在 `engine_ready()` 旁邊
   - Provider 選單加第 10 項
   - `setup_provider` case 加 `10) setup_claude_max`
   - 主流程引擎啟動段加 proxy 起停 + trap kill
   - 引擎更新檢查段（207 行附近）順手追加 `@anthropic-ai/claude-code` 一同檢查（D12），並支援 `--no-claude-cli-update` 旗標

7. **`tools/change_provider.sh` 改動** — 加第 10 項，source 同一個 lib。

8. **`dashboard/server.mjs` 改動** — 既有 `callAI_OpenAI` / `streamChatResponse` openai 分支早就支援 baseUrl，**0 改動**。只新增啟動初始化區的 self-heal（偵測 `OPENAI_BASE_URL` 含 `127.0.0.1:3456` 且 health 失敗時背景起 proxy）。

9. **新增 `tools/preinstall.sh`**（D9）
   - 抽出 `start.sh` 既有 Node 下載 + `install_engine` 邏輯，**不啟動引擎**
   - 額外裝 `@anthropic-ai/claude-code`（不論使用者最後選不選 Claude Max — 這就是「預先裝完」的全集）
   - `cd tools/claude-proxy && npm install`
   - 執行完印「Done. You can now `./start.sh` without first-run install delay.」

10. **`.gitignore` 加** — `tools/claude-proxy/node_modules/` 與 `tools/claude-proxy/.env`（這兩個其實在 submodule 自身的 .gitignore 已涵蓋，但 portable repo 端再加一道保險）。

11. **文件更新** — README.md（features 表、provider 表、project structure、troubleshooting、preinstall.sh 用法、上游 sync workflow）、CLAUDE.md（provider 對應規則表後新增 Claude Max 區段、上游同步章節）。

預估增量：~250 行 bash + ~30 行 JS + ~80 行 markdown + 1 個 git submodule + 1 個 preinstall 入口。

## 上游同步策略

整合完成後有 **3 個獨立上游**要追蹤：

| 上游 | 路徑 | 同步機制 | 觸發時機 |
|---|---|---|---|
| `@gitlawb/openclaude`（引擎） | `engine/node_modules/@gitlawb/openclaude/` | `start.sh` 已有 `npm outdated` 自動檢查（每次啟動） | 每次 `./start.sh` |
| `@anthropic-ai/claude-code`（claude CLI） | `engine/node_modules/@anthropic-ai/claude-code/` | 同上模式（D12 新增） | 每次 `./start.sh`，可用 `--no-claude-cli-update` 跳過 |
| `photofanz/portable-claude-proxy`（vendored proxy） | `tools/claude-proxy/`（submodule） | 你自己維護新 repo；portable 端 `git submodule update --remote` 拉最新 | 手動，使用者按需 |
| `photofanz/hermes-claude-proxy-v5`（衍生來源） | 不在 portable repo 內 | 在 portable-claude-proxy repo 內 `git fetch hermes && git cherry-pick <sha>` | 手動，當 hermes 有相容 bug fix / feature 想拿時 |
| `techjarves/OpenClaude-Portable`（launcher 本體） | repo root | `git fetch upstream && git rebase upstream/main`（或 merge） | 手動，使用者按需 |

### Proxy submodule sync 流程

當你在 `portable-claude-proxy` repo 推了新 commit、想讓 portable 拿到時：

```bash
# 在 portable repo 內
cd ~/path/to/OpenClaude-Portable
git submodule update --remote tools/claude-proxy
git add tools/claude-proxy
git commit -m "Update claude-proxy submodule to <new-sha>"
```

### 從 hermes-v5 / ppcvote cherry-pick 上游修補

`portable-claude-proxy` repo 的標準 remote 配置：

```
origin   = github.com/photofanz/portable-claude-proxy   (push)
hermes   = github.com/photofanz/hermes-claude-proxy-v5  (fetch only)
# 可選
ppcvote  = github.com/ppcvote/openclaw-claude-proxy     (fetch only)
```

想拿 hermes 的某個 bug fix：
```bash
cd ~/path/to/portable-claude-proxy
git fetch hermes
git log hermes/main --oneline | head -10        # 找想要的 commit
git cherry-pick <sha>                            # 衝突手動解
git push origin main
```

不刻意追蹤 / rebase：hermes 跟 ppcvote 與 portable-claude-proxy 三者架構分歧已大，全自動同步成本高於收益。

### Portable launcher sync 流程

```bash
git fetch upstream
git diff upstream/main...HEAD              # 看你的 fork 跟 upstream 差多遠
git rebase upstream/main                   # 把你的 Claude Max 整合 rebase 到 upstream 最新
# 衝突區可能在 start.sh 的 setup_provider 區塊（如果上游也加了新 provider）
# 衝突區可能在 dashboard/server.mjs 的 callAI_Anthropic（如果上游動到 Anthropic header）
```

> **注意：** spec 第 1 段提到「Portable 內含 claude CLI 落在 `engine/`」— 這是執行期下載的，仍在 `.gitignore` 排除清單內，不會被 git 追蹤。所以 `git rebase upstream/main` 只會合併 launcher 程式碼變動，不影響 `engine/` 內容。

## 範圍外（顯式排除）

- **Windows 對等實作** — `START.bat`、`change_provider.bat`、`tools/claude-proxy/` Windows 啟動腳本一律不做。Windows 使用者選單不會出現第 10 項。
- **Dashboard server self-heal 跨架構自動重登 OAuth** — 只負責偵測 proxy 沒起並起 proxy；OAuth 失效要使用者手動處理。
- **Claude Pro ($20/mo) 訂閱支援** — Pro tier 的 `claude --print` 配額可能不夠 portable agent 用；不額外處理。
- **多 token 切換 / 多 Max 帳號管理** — 一個 portable 一個 OAuth 帳號。
- **Anthropic 真 API key 走 proxy（白手套）** — 既有 `5) Claude` 已涵蓋這個用例。
- **Telegram / Discord / Slack 等 channel 整合** — 上游 setup.sh 有的 OpenClaw gateway 配置不在本整合範圍。
- **PR 給上游 ppcvote** — 我們的 3 處微調（loopback bind、零節流、EADDRINUSE handler）對其他使用者也合理，但本 spec 不負責對 ppcvote 發 PR；hermes 是 detached repo，跟 ppcvote 已大幅分歧。
- **Dashboard agent mode 支援 Claude Max** — hermes proxy 接收 OpenAI tools 參數但內部不傳給 SDK，agent mode 會沉默失效；本期不修。

## 驗收條件

按 D1-D5、D7-D12 全部成立後（D6 已刪）：

1. `./start.sh` → 選 `10) Claude (Max Subscription)` → 完成 wizard → 引擎啟動 → 能跟 Claude Opus / Sonnet / Haiku 對話。
2. 對話過程觀察 `data/claude-proxy.log` 看到請求被 proxy 收到並 forward 成功。
3. `Ctrl+C` 引擎結束後 `ps aux | grep claude-proxy` 應該找不到殘留 PID。
4. `./tools/open_dashboard.sh` 後在 Dashboard UI 也能跟 Claude Max 對話。
5. 重跑 `./start.sh`（不再經 wizard，env 已存）→ 走捷徑直接 launch + 起 proxy。
6. `./tools/change_provider.sh` 換成其他 provider（如 OpenRouter）→ 下次 `./start.sh` proxy 不該被起（CLAUDE_PROXY_MODE 沒了）。
7. `./tools/preinstall.sh` 在乾淨環境跑完後，下一次 `./start.sh` 不會出現任何 install / download 訊息。
8. `git fetch upstream` 後 `git diff upstream/main...HEAD` 可以清楚看到 Claude Max 整合的所有 commit；`git rebase upstream/main` 在沒有衝突的情況下成功（驗證 fork 結構不破壞）。

## Future Work（Phase 2，本 spec 不實作）

### Dashboard agent mode tools support for Claude Max

**現況問題：** Dashboard 的 `/api/agent` 路徑會帶 OpenAI 風格 `tools: [{type:'function', function:{name, parameters}}]` 給 LLM，期待回 `tool_calls`。`portable-claude-proxy`（從 hermes-v5 起手）收到 tools 但內部不傳給 Claude Agent SDK，LLM 不知道有 tools 可用，sliently fall back 到 chat 行為。

**Phase 2 設計思路（不在本 spec 範圍）：**

在 `portable-claude-proxy/server.js` 加 OpenAI ↔ Anthropic tool calling 雙向翻譯層：

1. **入站**：`POST /v1/chat/completions` 收到 `tools` 參數時，把每個 OpenAI function definition 轉成 Anthropic SDK 的 tool 格式（注意 JSON Schema 對應）：
   ```javascript
   const anthTools = tools?.map(t => ({
       name: t.function.name,
       description: t.function.description,
       input_schema: t.function.parameters
   }));
   ```
2. **傳給 SDK**：在 `sendToSession` / `callClaude` 把 `anthTools` 透過 SDK options 傳入；Claude Agent SDK 應有對應 API（待研究 — `@anthropic-ai/claude-agent-sdk` 文件）
3. **出站 tool_use 回 OpenAI 格式**：SDK 回應的 `content: [{type:'tool_use', id, name, input}]` 區塊抽出來，包成 OpenAI 的：
   ```javascript
   {
     tool_calls: [{
       id, type: 'function',
       function: { name, arguments: JSON.stringify(input) }
     }]
   }
   ```
4. **Multi-turn**：下一個請求進來如果有 `messages: [{role:'tool', tool_call_id, content}]`，要轉回 Anthropic 的 `{type:'tool_result', tool_use_id, content}` 接回同一個 SDK session
5. **Streaming**：SSE 串流階段 `tool_use` 區塊要怎麼包進 OpenAI streaming format（`delta.tool_calls` 部分 JSON 累積）也要設計
6. **Persistent session 衝突**：v5 的核心特色是 per-model 持久 session 序列化請求；tool call 是多輪互動，要確認 session 狀態正確

**規模估計：** server.js +150~250 行；要讀 Claude Agent SDK 的 tool API 文件 + 實測複雜互動。獨立 spec 走完整 brainstorm → plan → implement 流程。

**觸發條件：** 等使用者實際在 Dashboard agent mode 用 Claude Max 遇到「LLM 沒 call tool」的 friction，再啟動 phase 2 spec。

## 開放問題

無 — 所有設計決策已透過 brainstorming 確認，技術可行性已透過 grep 驗證。
