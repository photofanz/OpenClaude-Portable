#!/bin/bash
# =================================================================
#  Portable AI - Pre-install dependencies (no engine launch)
#
#  跑這支之後，第一次 ./start.sh 不會出現 claude CLI / proxy 的下載等待。
#  注意：Node.js 與 OpenClaude 引擎本身仍由 ./start.sh 第一次啟動時 bootstrap
#  （start.sh 沒有「只裝不跑」模式，硬抽出來會增加維護負擔）。所以建議流程：
#    1) ./start.sh 跑一次（會裝好 Node + 引擎，可在 provider 選單按 Ctrl+C）
#    2) ./tools/preinstall.sh （裝好 claude CLI + proxy 依賴）
#    3) 之後 ./start.sh 選 10 走 Claude Max wizard 就不會卡 install
#  對 Google Drive sync 場景：一台機器跑完 1+2，engine/ 與 tools/claude-proxy/node_modules/
#  會同步到所有同架構機器。
# =================================================================
set -e

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; DIM='\033[90m'; RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE_DIR="$ROOT_DIR/engine"
NPM_CACHE_DIR="$ROOT_DIR/data/npm-cache"

echo ""
echo -e "${CYAN}=========================================================${RESET}"
echo -e "  Portable AI - Pre-install"
echo -e "${CYAN}=========================================================${RESET}"
echo ""

# ── 找 portable node 的 npm ─────────────────────────────────
PLATFORM=$(uname -s | tr '[:upper:]' '[:lower:]'); [ "$PLATFORM" = "darwin" ] || PLATFORM="linux"
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) ARCH=x64;; arm64|aarch64) ARCH=arm64;; esac
NODE_DIR="$ENGINE_DIR/node-$PLATFORM-$ARCH"
NPM_BIN="$NODE_DIR/bin/npm"

if [ ! -x "$NPM_BIN" ] || [ ! -d "$ENGINE_DIR/node_modules" ]; then
    echo -e "${YELLOW}[!] Portable Node / OpenClaude engine not installed yet.${RESET}"
    echo -e "${DIM}    Run ./start.sh once first (you can Ctrl+C at the provider menu),${RESET}"
    echo -e "${DIM}    then re-run ./tools/preinstall.sh.${RESET}"
    echo ""
    exit 1
fi

mkdir -p "$NPM_CACHE_DIR"

# ── 1) claude CLI（OAuth 登入用）────────────────────────────
echo -e "${YELLOW}[1/3] @anthropic-ai/claude-code (claude CLI, for Claude Max OAuth login)${RESET}"
( cd "$ENGINE_DIR" && NPM_CONFIG_CACHE="$NPM_CACHE_DIR" "$NPM_BIN" install @anthropic-ai/claude-code@latest \
    --no-audit --no-fund --loglevel=warn --no-bin-links --cache "$NPM_CACHE_DIR" )
# 平台專屬原生 binary 在 @anthropic-ai/claude-code-<platform>-<arch>/claude
_CLIP=$PLATFORM; _CLIA=$ARCH
if [ -f "$ENGINE_DIR/node_modules/@anthropic-ai/claude-code-${_CLIP}-${_CLIA}/claude" ] \
   || [ -f "$ENGINE_DIR/node_modules/@anthropic-ai/claude-code/bin/claude.exe" ] \
   || [ -f "$ENGINE_DIR/node_modules/@anthropic-ai/claude-code/bin/claude" ]; then
    echo -e "${GREEN}      OK${RESET}"
else
    echo -e "${RED}      install incomplete (no claude binary found)${RESET}"; exit 1
fi

# ── 2) Codex CLI（ChatGPT 訂閱 OAuth 登入用）────────────────
echo -e "${YELLOW}[2/3] @openai/codex (Codex CLI, for ChatGPT-subscription OAuth login)${RESET}"
( cd "$ENGINE_DIR" && NPM_CONFIG_CACHE="$NPM_CACHE_DIR" "$NPM_BIN" install @openai/codex@latest \
    --no-audit --no-fund --loglevel=warn --no-bin-links --cache "$NPM_CACHE_DIR" )
if [ -f "$ENGINE_DIR/node_modules/@openai/codex/bin/codex.js" ]; then
    echo -e "${GREEN}      OK${RESET}"
else
    echo -e "${RED}      install incomplete (no codex/bin/codex.js found)${RESET}"; exit 1
fi

# ── 3) proxy submodule 依賴（Claude Max 用）────────────────
echo -e "${YELLOW}[3/3] tools/claude-proxy dependencies (for Claude Max)${RESET}"
if [ ! -f "$ROOT_DIR/tools/claude-proxy/package.json" ]; then
    echo -e "${YELLOW}      Submodule not initialised. Run: git submodule update --init tools/claude-proxy${RESET}"
    exit 1
fi
( cd "$ROOT_DIR/tools/claude-proxy" && NPM_CONFIG_CACHE="$NPM_CACHE_DIR" "$NPM_BIN" install \
    --no-audit --no-fund --loglevel=warn --cache "$NPM_CACHE_DIR" )
if [ -d "$ROOT_DIR/tools/claude-proxy/node_modules/express" ]; then
    echo -e "${GREEN}      OK${RESET}"
else
    echo -e "${RED}      install incomplete${RESET}"; exit 1
fi

echo ""
echo -e "${GREEN}Done. Next ./start.sh → option 10 (Claude Max) or 11 (Codex) skips the dependency install.${RESET}"
echo -e "${DIM}（Claude Max 與 Codex 路徑都仍需在 wizard 裡完成一次 OAuth 登入。）${RESET}"
echo ""
