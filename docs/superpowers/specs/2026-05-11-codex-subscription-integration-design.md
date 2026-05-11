---
date: 2026-05-11
status: approved-design
topic: OpenAI Codex (ChatGPT Subscription) Integration
scope: macOS / Linux only (Windows out of scope, same as Claude Max path)
related:
  - docs/superpowers/specs/2026-05-10-claude-max-proxy-integration-design.md (sibling: Claude Max path)
  - tools/_claude_max_lib.sh (wizard pattern to mirror)
  - "@openai/codex" npm package (Codex CLI — for OAuth login)
---

# OpenAI Codex (ChatGPT Subscription) 整合設計

在 OpenClaude-Portable 主選單新增 `11) OpenAI Codex (ChatGPT Subscription)`，透過 ChatGPT 訂閱（Plus/Pro/Team/Enterprise）的 OAuth 登入使用 Codex 模型（gpt-5.x-codex 系列），不需 API key、**不需 proxy**（OpenClaude 引擎原生直連 Codex 後端）。

## 背景：為什麼不需 proxy

OpenClaude 引擎（`@gitlawb/openclaude` ≥ 0.9.x）原生內建 Codex / ChatGPT-OAuth 支援（grep `dist/cli.mjs` 已驗證）：

| 機制 | 細節 |
|---|---|
| Codex 後端 | `DEFAULT_CODEX_BASE_URL = "https://chatgpt.com/backend-api/codex"`；`--provider codex`（或 codex-alias 模型）→ 引擎用 `codex_responses` transport（OpenAI Responses API 格式）直連 |
| OAuth credentials | `resolveCodexAuthPath()`：`CODEX_AUTH_JSON_PATH` > `CODEX_HOME`/auth.json > `~/.codex/auth.json`。引擎自己讀 token、自己 refresh（`https://auth.openai.com/oauth/token`，client_id `app_EMoamEEZ73f0CkXaXp7hrann`） |
| auth.json schema | Codex CLI 標準格式（nested）：`{ openai_api_key, tokens: { access_token, refresh_token, id_token, account_id }, last_refresh }`。引擎 `readNestedString` 容多種 key 形狀 |
| profile file | `.openclaude-profile.json` 存在 `CLAUDE_CONFIG_DIR`（已被 start.sh 重導到 `data/openclaude/`）；TUI 選 Codex 時寫入 `{profile:"codex", env:{CODEX_CREDENTIAL_SOURCE:"oauth", ...}}`。**我們不依賴這個** — 直接走 `CODEX_HOME` + `--provider codex` 即可，引擎不需要 profile file 也能用 OAuth credentials。 |

**結論：** wizard 只要 (1) 裝 `@openai/codex` CLI 來做 OAuth 登入、(2) 把登入結果（auth.json）放在 `data/codex/`、(3) `ai_settings.env` 設 `AI_PROVIDER=codex` + `CODEX_HOME=$DATA_DIR/codex` + 模型 + `CODEX_CREDENTIAL_SOURCE=oauth`、(4) `start.sh` export `CODEX_HOME` 並 launch `--provider codex`。引擎其餘自理。

## 決策摘要

| ID | 決策 | 理由 |
|---|---|---|
| D1 | 不用 proxy；engine native `--provider codex` | 引擎已內建 Codex OAuth + Responses transport（grep 驗證） |
| D2 | OAuth 登入用外部 `@openai/codex` CLI（`codex login`），credentials 放 `data/codex/auth.json`（靠 `CODEX_HOME`，不重導 HOME） | 跟 Claude Max 同骨架；`CODEX_HOME` 比重導 HOME 乾淨（只影響 Codex，不影響其他） |
| D3 | 主選單**新增** `11) OpenAI Codex (ChatGPT Subscription)`，不動既有項目 | 向後相容；跟 Claude Max 第 10 項並列 |
| D4 | wizard 共用 `tools/_claude_max_lib.sh`（或視情況拆 `tools/_codex_lib.sh`），骨架同 `setup_claude_max` | DRY；同樣的「裝 CLI → OAuth login → 選模型 → 寫 env」流程 |
| D5 | 模型三選一：`gpt-5.1-codex` / `gpt-5.1-codex-max` / `gpt-5.1-codex-mini`（依 `getCodexModelOptions()` 當前清單，實作時對齊引擎版本） | 引擎有完整清單；wizard 給常用三個 |
| D6 | Dashboard 也整合：新增 `callAI_Codex`（讀 auth.json + token refresh + Responses API 直連 + Responses SSE 解析） | 使用者要求；但這是非平凡的 ~150-250 行（不像 Claude Max 0 改動） |
| D7 | Windows 不支援；START.bat / change_provider.bat 不動 | 同 Claude Max 決策 |
| D8 | `change_provider.sh` 加一個「Switch to OpenAI Codex (ChatGPT Subscription)」選項（同 Claude Max 的「5)」做法） | 一致性 |

## 架構

### Runtime topology（選了 `11) OpenAI Codex` 之後）

```
OpenClaude 引擎  ──codex_responses transport──►  https://chatgpt.com/backend-api/codex/responses
  --provider codex                                  ▲
  CODEX_HOME=data/codex                              │ Authorization: Bearer <access_token>
  CODEX_CREDENTIAL_SOURCE=oauth                      │ chatgpt-account-id: <account_id>
  (引擎自動 refresh token)                            │
                                            data/codex/auth.json  ← codex login 寫入
```

首次 OAuth 登入（wizard 階段，僅一次）：

```
wizard  ──CODEX_HOME=data/codex──►  node engine/node_modules/@openai/codex/bin/codex.js login
                                          │
                                          ▼ 開瀏覽器、使用者用 ChatGPT 帳號登入
                                          ▼ 寫入
                                          data/codex/auth.json
```

Dashboard（chat 模式）：

```
dashboard/server.mjs  callAI_Codex
  ├─ 讀 data/codex/auth.json → access_token, refresh_token, account_id
  ├─ access_token 過期？ → POST auth.openai.com/oauth/token (refresh) → 寫回 auth.json
  ├─ 轉 messages → Responses API input items
  ├─ POST chatgpt.com/backend-api/codex/responses (stream)
  │    headers: Authorization Bearer, chatgpt-account-id, originator: codex_cli_rs, OpenAI-Beta: responses=experimental
  └─ 解析 Responses SSE（response.output_text.delta / response.completed / ...）
```

### 目錄結構變更

```
tools/
├── _claude_max_lib.sh        ← 既有；可能擴充 setup_codex()，或新增 _codex_lib.sh
├── claude-proxy/             ← 既有（Claude Max 用，Codex 不用）
data/
├── codex/auth.json           ← 新增（codex login 寫入；gitignored）
├── home/.claude/...          ← 既有（Claude Max OAuth）
├── ai_settings.env           ← Codex 模式時寫 AI_PROVIDER=codex + CODEX_HOME + ...
engine/node_modules/@openai/codex/                ← 新增（Codex CLI；gitignored，wizard 安裝）
engine/node_modules/@openai/codex-darwin-arm64/   ← 平台專屬 binary（同上）
```

## Env 契約

`data/ai_settings.env` 在 Codex 模式：

```env
AI_PROVIDER=codex
CODEX_HOME=<absolute path to data/codex>
CODEX_CREDENTIAL_SOURCE=oauth
OPENAI_MODEL=gpt-5.1-codex                # 或 gpt-5.1-codex-max / gpt-5.1-codex-mini
AI_DISPLAY_MODEL=gpt-5.1-codex
CLAUDE_PROXY_MODE=                         # 不設 / 留空 — Codex 不起任何 proxy
```

（注意：不寫 `OPENAI_BASE_URL` — 讓引擎用 `DEFAULT_CODEX_BASE_URL`。不寫 `OPENAI_API_KEY` — 走 OAuth。不寫 `CLAUDE_CODE_USE_OPENAI` — `--provider codex` 自帶。）

### `start.sh` 改動

- Provider 選單加第 11 項；`setup_provider` 接受 1-11；case 加 `11) setup_codex; return ;;`
- 引擎啟動段：`AI_PROVIDER=codex` 時 export `CODEX_HOME`（值來自 env file），`PROVIDER_ARGS=(--provider codex)`。**不起 proxy。**
- 不需要在 trap / kill 段加東西（沒有 proxy 程序）
- 每日更新檢查：可順手追加 `@openai/codex`（同 `@anthropic-ai/claude-code` 的 D12 模式，`--no-codex-cli-update` 旗標）

### Wizard `setup_codex()`（在 `_claude_max_lib.sh` 或 `_codex_lib.sh`）

```
1. 顯示警示：訂閱制（ChatGPT Plus/Pro/Team）、需一次 OAuth、credentials 放 data/codex/、macOS/Linux only
2. codex_ready()? 否 → install_codex():
     cd ENGINE_DIR && npm install @openai/codex@latest --no-audit --no-fund --loglevel=warn --no-bin-links --cache NPM_CACHE_DIR
     解析 codex binary 入口：engine/node_modules/@openai/codex/bin/codex.js（用 NODE_BIN 跑）
3. codex_oauth_ok()?（CODEX_HOME=data/codex codex login status 或檢查 data/codex/auth.json + 解析 tokens.access_token）
     否 → codex_oauth_login():
         mkdir -p data/codex
         CODEX_HOME="$DATA_DIR/codex" "$NODE_BIN" "$CODEX_CLI_JS" login   # 開瀏覽器 ChatGPT 登入
         驗證 data/codex/auth.json 存在且含 tokens.access_token
4. 模型三選一（gpt-5.1-codex / -max / -mini）
5. 寫 ai_settings.env（上節 Env 契約）
6. 結束 wizard
```

### Dashboard `dashboard/server.mjs` 改動（D6）

新增 `callAI_Codex(messages, cfg, includeTools)`：
- `readCodexAuth()`：讀 `${cfg.CODEX_HOME}/auth.json`，解析 nested `tokens.{access_token, refresh_token, id_token, account_id}`（容 `openai_api_key` 等變體 key）
- `ensureFreshCodexToken(auth)`：decode `access_token` JWT 的 `exp`；若 < now + 60s → `POST https://auth.openai.com/oauth/token` `{grant_type:"refresh_token", client_id:"app_EMoamEEZ73f0CkXaXp7hrann", refresh_token, scope:"openid profile email offline_access ..."}` → 取新 token → 寫回 `${cfg.CODEX_HOME}/auth.json`（保留 nested 結構）
- 請求：`POST https://chatgpt.com/backend-api/codex/responses`（stream），headers：`Authorization: Bearer <access_token>`、`chatgpt-account-id: <account_id>`、`originator: codex_cli_rs`、`OpenAI-Beta: responses=experimental`、`Content-Type: application/json`；body：`{ model: cfg.OPENAI_MODEL, input: <messages 轉成 Responses input items>, stream: true, store: false }`
- 解析 Responses SSE：累積 `response.output_text.delta` 的 `delta` 欄位、`response.completed` 收尾、`response.failed`/`error` 報錯。轉成 dashboard 既有的 `{type:'delta', content}` / `{type:'done', fullText}` SSE 形狀
- `streamChatResponse` / `callAI` 的 dispatch：`provider === 'codex'` 時走 `callAI_Codex`
- self-heal：Codex 不需要 self-heal（沒有 proxy 程序）

> **實作時要驗證的非顯性細節**（在 plan 的第一個 Codex-dashboard task 做）：
> - 確切的 Responses API 請求 body shape（`input` items 格式：`{role, content:[{type:"input_text", text}]}` 還是別的？）— 對照 `engine/node_modules/@gitlawb/openclaude/dist/cli.mjs` 的 `codex_responses` transport 實作，或抓 `@openai/codex` 的請求
> - 確切的 SSE event 名稱（`response.output_text.delta` vs `response.output_item.added` 等）
> - 確切的 header 名稱大小寫 + 是否需要 `session_id` / `user_agent` / `version` 等
> - auth.json refresh 後 OpenAI 回的欄位名（`access_token` / `id_token` / `refresh_token` / `expires_in`）

## 風險與緩解

| 風險 | 機率 | 影響 | 緩解 |
|---|---|---|---|
| `@openai/codex` binary 入口路徑跟預期不同 | 中 | wizard 安裝後找不到 | `bin/codex.js` 是 Node wrapper（已從 npm pack 確認）→ `node bin/codex.js`；platform 套件 `@openai/codex-<plat>-<arch>` 也在；加 fallback resolution（同 claude-code 的教訓） |
| `codex login` 不認 `CODEX_HOME` 環境變數 | 低-中 | credentials 落在 `~/.codex/` 而非 `data/codex/` | Codex CLI 文件確認支援 `CODEX_HOME`；若不行，fallback：登入後把 `~/.codex/auth.json` 複製/symlink 進 `data/codex/`，並在 README 註明 |
| Codex Responses API 請求格式錯（dashboard） | 中-高 | dashboard chat 對 Codex 失敗（CLI 不受影響） | plan 第一步先對照引擎 transport 實作 / 實測；dashboard task 設計成可獨立失敗回退（CLI 已可用） |
| ChatGPT OAuth token refresh 失敗 / 過期太快 | 中 | dashboard 對話中斷 | 引擎端自理（CLI 不受影響）；dashboard 端 catch refresh 錯誤、提示「重跑 wizard 重新登入」 |
| ChatGPT 訂閱 rate limit | 中 | 偶發 429 | 把 429 訊息透傳回 dashboard / 引擎自己處理 |
| `--provider codex` 第一次跑沒有 auth.json 就 launch | 低 | 引擎啟動報錯 | wizard 保證先有 auth.json 才寫 `AI_PROVIDER=codex` |

## 工項拆解（給 writing-plans）

### A. CLI 路徑（engine native）
1. `tools/_claude_max_lib.sh`（或新 `_codex_lib.sh`）加 `codex_ready()` / `install_codex()` / `codex_oauth_ok()` / `codex_oauth_login()` / `setup_codex()` + `_resolve_codex_cli()`
2. `start.sh`：provider 選單第 11 項；case `11) setup_codex`；引擎啟動段 `AI_PROVIDER=codex` → export `CODEX_HOME` + `PROVIDER_ARGS=(--provider codex)`；每日更新檢查追加 `@openai/codex`（`--no-codex-cli-update` 旗標）
3. `tools/change_provider.sh`：加「Switch to OpenAI Codex (ChatGPT Subscription)」選項（source 同一個 lib）
4. `tools/preinstall.sh`：順手也裝 `@openai/codex`（同 `@anthropic-ai/claude-code` 那段）
5. `.gitignore`：`/data/codex/`（其實 `/data/` 整個已 ignored — 確認即可，不用加）

### B. Dashboard 路徑（callAI_Codex）
6. **先驗證** Responses API 請求/回應格式（對照引擎 `codex_responses` transport）
7. `dashboard/server.mjs`：`readCodexAuth()` + `ensureFreshCodexToken()` + `callAI_Codex()`（非串流 + 串流）+ dispatch `provider === 'codex'` + import 需要的（`readFileSync`/`writeFileSync` 已有）

### C. 文件
8. README.md：features 表、provider 表、新「OpenAI Codex (ChatGPT Subscription) Mode」一節、troubleshooting；CLAUDE.md：provider 對應規則表加 Codex 列 + 區段；spec 上游同步章節提一下 `@openai/codex` 也是自動更新檢查的對象

## 驗收條件
1. `./start.sh` → `11)` → wizard（裝 codex CLI → ChatGPT OAuth 登入 → 選 gpt-5.1-codex）→ launch → 跟 Codex 模型對話成功
2. `data/codex/auth.json` 存在且含 `tokens.access_token`
3. 引擎啟動訊息**沒有** proxy 相關（Codex 不起 proxy）
4. `Ctrl+C` 退出後無殘留程序（沒有 proxy 要 kill）
5. 重跑 `./start.sh` 走捷徑（env 已存）、不重 OAuth
6. `bash tools/open_dashboard.sh` → dashboard chat 模式跟 Codex 對話成功（callAI_Codex 工作、token refresh 正常）
7. `./tools/change_provider.sh` 切到 Codex / 切回其他 provider 都正常
8. `git status` 乾淨

## 範圍外
- **Windows 對等**（START.bat / change_provider.bat 不動）
- **Dashboard agent mode（tools）對 Codex** — Codex Responses API 有 tools/function-calling，但 dashboard agent loop 的整合留 Phase 2（同 Claude Max 的 agent tools 待辦）
- **Codex 的非 OAuth（API key）模式** — 既有 `6) OpenAI` 已涵蓋
- **PR 給上游 / 多帳號切換**

## 開放問題
無 — engine native 支援已 grep 驗證；Responses API 細節列為「實作第一步驗證」項。
