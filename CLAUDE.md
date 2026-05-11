# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 專案性質

OpenClaude-Portable 是一個**可攜式啟動器**，把上游的 `@gitlawb/openclaude` 引擎包成「插上隨身碟即跑、不污染主機」的形式。整個 repo 沒有自家原始碼編譯、沒有 `package.json`、沒有 build/test/lint 流程：所有要修改的東西都是執行期腳本（bash / batch / Node）。

兩條互不依賴的執行路徑：

1. **CLI 啟動器** — `start.sh` (macOS/Linux) 與 `START.bat` (Windows)：bootstrap Node + 引擎、跑 provider 設定精靈、最後 `exec` 引擎。
2. **Web Dashboard** — `dashboard/server.mjs` + `dashboard/index.html`：自寫的 Node HTTP server (port 3000)，純手刻 SSE，不依賴任何 npm 套件。

兩條路徑共用同一份設定檔 `data/ai_settings.env`，互相 round-trip。

## 常用指令

> 沒有 build / test / lint。執行的東西都是「跑起來」型指令。

```bash
# 主入口（互動式選單，10 秒倒數預設 Normal Mode）
./start.sh

# 直接進 Limitless Mode（--dangerously-skip-permissions）
./start.sh --quick

# 跳過每日引擎更新檢查
./start.sh --offline

# 工具子腳本（START 選單也是 exec 這些）
bash tools/change_provider.sh        # 換 provider / API key
bash tools/open_dashboard.sh         # 起 Dashboard 並開瀏覽器
bash tools/setup_local_models.sh     # 下載 Ollama 模型

# 直接起 Dashboard（不經 open_dashboard.sh）
./engine/node-darwin-arm64/bin/node dashboard/server.mjs
```

第一次執行需要網路：會下載 Node 22.14.0 (~25 MB) 到 `engine/node-<platform>-<arch>/`、`npm install @gitlawb/openclaude@latest` 到 `engine/node_modules/@gitlawb/openclaude/`。下載/安裝日誌分別在 [engine/node-download.log](engine/node-download.log) 和 [engine/openclaude-engine-install.log](engine/openclaude-engine-install.log)。

## 高階架構

### Bootstrap → Provider Wizard → Engine Launch（[start.sh](start.sh) / [START.bat](START.bat)）

兩個檔案是同一套邏輯的雙平台實作，編輯一個通常要同步另一個。流程：

1. 偵測 OS/arch → 解出 `NODE_DIR`、`OC_BIN`、`OC_CLI` 路徑。
2. 若缺 Node 則從 nodejs.org 下載 + 解壓；若缺/壞引擎則 `npm install` 重灌。
3. **強制把所有寫入點重導到 `data/`** — `XDG_CONFIG_HOME`、`XDG_DATA_HOME`、`XDG_CACHE_HOME`、`CLAUDE_CONFIG_DIR`、`HOME`、`USERPROFILE`、`APPDATA`、`LOCALAPPDATA` 全部指進 `data/` 子目錄。**任何新加入的程式都必須尊重這套重導**，否則會破壞「零足跡」承諾。
4. 載入或建立 `data/ai_settings.env`（每次讀取都 `tr -d '\r'` 防 CRLF — 過去吃過虧）。
5. 顯示主選單，根據選擇 `exec` 子腳本或 `exec` 引擎。
6. 啟動引擎時會根據 provider 加上不同的 `--provider` / `--model` 參數，詳見下節。
7. `--setting-sources user,project,local` —— **`user` 一定要在裡面**，否則引擎不會載入 `$CLAUDE_CONFIG_DIR/skills/`（= `data/openclaude/skills/`，使用者的 64 個 skill）與 user-level agents/MCP/settings（引擎的 `getSkillDirCommands` 裡 `loadSkillsFromSkillsDir(userSkillsDir)` 被 `isSettingSourceEnabled("userSettings")` gate 住）。`HOME` 與 `CLAUDE_CONFIG_DIR` 都已重導到 `data/` 內，所以「user」指的是這份 portable copy 自己的 `data/openclaude/`，不會碰主機真實的 `~/.claude/`。（gstack 系列 skill 的 `SKILL.md` 是相對 symlink `../gstack/<skill>/SKILL.md`，指向同目錄下自包含的 `gstack/` monorepo 複本，所以可攜。）

### Provider 對應規則（**最容易踩雷的地方**）

`AI_PROVIDER` 在 env 檔裡的值不一定等於送給引擎的 `--provider`：

| 使用者選的 Provider | env 寫入的 `AI_PROVIDER` | 給 openclaude 的 `--provider` |
|---|---|---|
| Anthropic Claude | `anthropic` | `--provider anthropic` |
| Google Gemini | `gemini` | `--provider gemini` |
| Ollama | `ollama` | `--provider ollama` |
| NVIDIA NIM | `openai` (+ NIM URL) | `--provider nvidia-nim`（靠 URL 子字串判斷） |
| OpenAI / OpenRouter / DeepSeek / LM Studio / Custom | `openai` | **不傳** `--provider`，全靠 `OPENAI_BASE_URL` + `OPENAI_API_FORMAT=chat_completions` + `CLAUDE_CODE_USE_OPENAI=1` 切換 |

最後一條是有意為之 — 傳 `--provider openai` 會讓引擎去吃使用者主機上的 Codex/OpenAI profile，覆蓋我們設定的 base URL。新增 OpenAI-相容 provider 時請延續這套寫法。

NVIDIA NIM 還會額外寫入 `CLAUDE_CODE_AGENT_LIST_IN_MESSAGES=false` 與 `CLAUDE_CODE_SIMPLE=1`：NIM 的嚴格 schema 會拒收 system-reminder 那種 content array，這個旗標會把它們轉回字串。動到 NIM 設定時不要拿掉。

### Claude Max Subscription 路徑（`10)` 選項，僅 macOS/Linux）

[tools/_claude_max_lib.sh](tools/_claude_max_lib.sh) 的 `setup_claude_max()`（被 `start.sh` 與 `tools/change_provider.sh` source）寫入 `data/ai_settings.env`：

```env
AI_PROVIDER=openai
CLAUDE_CODE_USE_OPENAI=1
OPENAI_BASE_URL=http://127.0.0.1:3456/v1
OPENAI_API_FORMAT=chat_completions
OPENAI_API_KEY=sk-portable-<random>     # 等同 tools/claude-proxy/.env 的 API_KEY（wizard 一次產生寫兩處）
OPENAI_MODEL=claude-sonnet-4-6          # 或 opus-4-7 / haiku-4-5
AI_DISPLAY_MODEL=claude-sonnet-4-6
CLAUDE_PROXY_MODE=1                     # start.sh 與 dashboard 判斷旗標
```

走 OpenAI-相容路徑（**不傳** `--provider`），跟 OpenRouter / DeepSeek / LM Studio / Custom 同模式 —— 原因同上一條規則。`CLAUDE_PROXY_MODE=1` 時 `start.sh` 在引擎啟動前背景起 [tools/claude-proxy/server.js](tools/claude-proxy/)（git submodule，指向 `photofanz/portable-claude-proxy`，從 `hermes-claude-proxy-v5` 衍生 — 內部用 `@anthropic-ai/claude-agent-sdk` in-process，**不 spawn CLI**），引擎結束時 kill — 跟 Ollama 同模式。Proxy log 在 `data/claude-proxy.log`，bind `127.0.0.1:3456` only。OAuth credentials 在 `data/home/.claude/.credentials.json`（HOME 已被 portable 重導涵蓋）。`claude` CLI（`@anthropic-ai/claude-code`）只用於首次 `claude login`，runtime 不需要 — 但 `start.sh` 的每日更新檢查會順手 `npm outdated @anthropic-ai/claude-code`（`--no-claude-cli-update` 可跳過）。Dashboard（[dashboard/server.mjs](dashboard/server.mjs)）的 OpenAI 路徑直接吃這個 proxy（0 改動），啟動時若偵測 `CLAUDE_PROXY_MODE=1` 且 proxy 沒在跑會 self-heal（detached spawn，dashboard 結束不會 kill proxy — 會變孤兒）；**但 agent mode 的 OpenAI tools 會被 proxy 忽略**（agent mode 對 Claude Max 沉默失效，見 README）。

### OpenAI Codex 路徑（`11)` 選項，僅 macOS/Linux）

**「codex」不是 `--provider` 值** —— 引擎的 valid providers 清單裡沒有 `codex`。它是 OpenClaude 的一個 *profile*，實際走法是 `provider=openai` + Codex 後端 base URL + OAuth credentials（從 `auth.json` via `CODEX_HOME`）+ placeholder key `codex-oauth-token-for-validation`（引擎自己用的標記）。base URL 是 codex 後端 → 引擎自動用 `codex_responses` transport。

[tools/_codex_lib.sh](tools/_codex_lib.sh) 的 `setup_codex()`（被 `start.sh` 與 `tools/change_provider.sh` source）寫入 `data/ai_settings.env`：

```env
AI_PROVIDER=openai
CLAUDE_CODE_USE_OPENAI=1
OPENAI_BASE_URL=https://chatgpt.com/backend-api/codex
OPENAI_API_KEY=codex-oauth-token-for-validation     # 引擎的 codex OAuth placeholder；實際請求用 auth.json 的 access token
OPENAI_MODEL=gpt-5.3-codex             # 或 gpt-5.3-codex-spark / gpt-5.5 / gpt-5.4 / gpt-5.2-codex / gpt-5.1-codex-max / gpt-5.1-codex-mini / gpt-5.5-mini（引擎預設 codexplan = gpt-5.5 high reasoning；以 `getCodexModelOptions()` 為準）
AI_DISPLAY_MODEL=gpt-5.3-codex
CODEX_HOME=<absolute path to data/codex>
CODEX_CREDENTIAL_SOURCE=oauth
```

**不需要 proxy** — OpenClaude 引擎原生支援 Codex OAuth（`dist/cli.mjs` 有 `codexOAuthShared` / `codexCredentials` 模組）：引擎讀 `$CODEX_HOME/auth.json` 的 OAuth token、自己 refresh（`https://auth.openai.com/oauth/token`，client_id `app_EMoamEEZ73f0CkXaXp7hrann`）、用 `codex_responses` transport 直連 `https://chatgpt.com/backend-api/codex`。`start.sh` 因為 `AI_PROVIDER=openai` 走 OpenAI-相容路徑（**不傳** `--provider`，同 OpenRouter/DeepSeek/LM Studio/Custom）；`CODEX_HOME` 已由 env 載入迴圈 export。**不起任何 proxy、不需要在 trap/kill 段加東西**。（header 會顯示 `Custom OpenAI-Compatible` — 純顯示問題。）

`auth.json` 由 `@openai/codex` CLI 的 `codex login` 寫入（入口 `engine/node_modules/@openai/codex/bin/codex.js` 是 Node wrapper，用 `$NODE_BIN` 跑；平台原生 binary 在 `@openai/codex-<plat>-<arch>/`）；用 `CODEX_HOME=$DATA_DIR/codex` 讓 credentials 落在資料夾內。`codex` CLI 只用於首次登入，runtime 不需要（引擎自理）— 但 `start.sh` 每日更新檢查會順手 `npm outdated @openai/codex`（`--no-codex-cli-update` 可跳過）。

Dashboard（[dashboard/server.mjs](dashboard/server.mjs)）有自己的輕量 Codex 實作 `callAI_Codex` + `streamChatResponse` 的 Codex 分支（用 `isCodexSetup(cfg)` 偵測：codex 後端 URL / `CODEX_CREDENTIAL_SOURCE=oauth` / 舊式 `AI_PROVIDER=codex`，**在 openai 分支之前判斷**）：讀 `$CODEX_HOME/auth.json`、token 過期就 refresh 並寫回（保留 Codex CLI 的 nested `tokens` 結構）、用 Responses API（`POST chatgpt.com/backend-api/codex/responses`，headers `Authorization Bearer` + `chatgpt-account-id` + `originator: openclaude`）。**chat 模式可用 Codex；agent 模式的 tools 不傳給 Codex**（退化成 chat，同 Claude Max）。

### Local Speed Proxy（[tools/local-proxy.js](tools/local-proxy.js)）

獨立 Node HTTP server，**只**在 Ollama 路徑會被啟動：

- 監聽 `127.0.0.1:11435`，把 `POST /chat/completions` 的 `messages` 中所有 `role:"system"` 內容截斷到 ~1200 字元（≈300 tokens），其餘原樣轉發到 `127.0.0.1:11434`。
- **絕不能寫 stdout/stderr** — OpenClaude 是 TUI，stdout 一被污染整個畫面就壞掉。所有 log 一律走 `appendFileSync` 到 [data/proxy.log](data/proxy.log)。
- `EADDRINUSE` 不是錯誤：表示前一個 session 的 proxy 還在跑，直接 `process.exit(0)` 重用它。

### Dashboard Server（[dashboard/server.mjs](dashboard/server.mjs)）

單檔 1000+ 行的純原生 Node 服務，故意不引任何 npm 依賴（這個 repo 根本沒有 `package.json`）。重要結構：

- **Provider 抽象層**：`callAI_OpenAI` / `callAI_Anthropic` / `callAI_Gemini` 三個對等的非串流呼叫，加上 `streamChatResponse` 的串流版本。每個 provider 各有一份 tool 格式轉換器：`toolsForOpenAI` / `toolsForAnthropic` / `toolsForGemini`。
- **Agent 工具迴圈**（`/api/agent`）：最多 `MAX_ITERATIONS = 15` 圈。每圈呼叫 LLM → 若回 `toolCalls` 就執行並把結果接回 messages → 繼續；無 tool 呼叫即為終止文字。Normal mode 下 `WRITE_TOOLS` (`write_file`, `execute_command`) 會卡 SSE，等待前端 `POST /api/agent/approve`；Limitless mode 直接跳過審核。
- **5 個內建工具**（[server.mjs:200-271](dashboard/server.mjs#L200-L271) 與 [server.mjs:302-358](dashboard/server.mjs#L302-L358)）：`write_file`、`read_file`、`list_directory`、`execute_command`、`search_files`。新增工具時要同步：(a) `TOOL_DEFS`、(b) `executeTool` 的 switch、(c) 若是寫操作則加進 `WRITE_TOOLS`、(d) 三個 `toolsFor*` 轉換器自動處理（除非 schema 有 provider 特異性）、(e) `appendAssistantMessage` / `appendToolResult` 的訊息回填邏輯。
- **路由**：傳統 if-串接（[server.mjs:720+](dashboard/server.mjs#L720)），不是 router 物件。所有 `/api/*` 端點都在 `createServer` 的同一個 callback 裡。
- **回退**：若 provider 不支援 tool calling，第一圈失敗會自動 fallback 到 `callAI(..., false)`（不帶 tools）後直接收尾。

### 跨平台慣例

- [.gitattributes](.gitattributes) 強制：`*.sh` 一律 LF、`*.bat`/`*.cmd`/`*.ps1` 一律 CRLF。在 Windows 上不小心把 `*.sh` 存成 CRLF 會炸開（這就是 `start.sh` 為何到處 `tr -d '\r'`）。
- 每個工具腳本都有 `.sh` 與 `.bat`（有時還加 `.ps1`）對應檔。修一邊就要修另一邊；行為要對齊。
- `engine/`、`data/`、`Windows/bin/`、`Linux/bin/`、`Mac/bin/` 全在 [.gitignore](.gitignore) 裡 — 它們是執行期下載/產生的，**不要 commit**。

## 修改時的注意事項

- 改動 provider 設定流程時，三處要同步：[start.sh](start.sh) 的 `setup_*` 函式、[START.bat](START.bat) 對應段落、[tools/change_provider.sh](tools/change_provider.sh)（與 `.bat` peer），以及 [dashboard/server.mjs](dashboard/server.mjs) 的 `callAI_*`。Dashboard 與 CLI 共用 `data/ai_settings.env`，env key 名稱不能漂移。
- 任何寫檔/落地的新功能 — 先確認落點在 `data/` 裡。寫到 `~/.config/`、`~/Library/`、`%APPDATA%` 真實位置等同破壞「零足跡」。
- README 提到 `RESUME.bat <session-id>`，但這個檔案目前**並不存在**於 repo 裡；不要假設它在。如果要加，行為應對齊「以 `--resume <id>` 啟動引擎、複用既有 `data/` 設定」。
- Dashboard 的 SSE 沒有 keepalive ping、`fetchExternal` / `streamExternal` 都寫死 60s timeout — 改長任務時記得把這個拉高。

## 上游同步

本 repo 是 git 控管（透過 `git init` + `git remote add upstream techjarves/OpenClaude-Portable` 接上），三個獨立上游：

- **引擎** `@gitlawb/openclaude` — `start.sh` 每次啟動自動 `npm outdated` 檢查升級，無需手動。
- **claude CLI** `@anthropic-ai/claude-code` — `start.sh` 同模式自動檢查（`--no-claude-cli-update` 可跳過）；只在 Claude Max 路徑用。
- **codex CLI** `@openai/codex` — `start.sh` 同模式自動檢查（`--no-codex-cli-update` 可跳過）；只在 Codex 路徑首次登入用。
- **launcher 本體** `techjarves/OpenClaude-Portable` — `git fetch upstream && git rebase upstream/main`，手動。本地第一個 commit 是「本地改動 layer 在 upstream snapshot 之上」，所以 rebase 有共同祖先。
- **proxy submodule** `photofanz/portable-claude-proxy`（[tools/claude-proxy/](tools/claude-proxy/)，從 `hermes-claude-proxy-v5` 衍生）— `git submodule update --remote tools/claude-proxy` 手動拉。要拿 hermes / ppcvote 上游的修補，在 portable-claude-proxy repo 內 `git fetch hermes && git cherry-pick <sha>`（remote 配置：`origin`=portable-claude-proxy、`hermes`=hermes-claude-proxy-v5）。

`engine/`、`data/`、`tools/claude-proxy/node_modules/`、`tools/claude-proxy/.env`、舊的 `openclaude-claude-proxy/` 都在 `.gitignore` 排除清單內 — git 操作不會碰它們。**注意：本 repo 若放在 Google Drive / Dropbox 同步路徑下，做 git commit / rebase / submodule update 時建議暫停同步**，避免 `.git/objects/` 同步到一半損毀。
