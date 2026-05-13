#!/bin/bash
# =================================================================
#  Non-interactive OAuth-provider setup (Claude Max / Codex)
#  用法: bash tools/setup_oauth_provider.sh <claude-max|codex> [model]
#
#  被 dashboard/server.mjs 的 /api/setup/oauth-provider 端點呼叫，
#  也可手動執行。需要 portable Node/engine 已安裝（缺套件時 setup 函式會自己 npm install）。
#  「非互動」= 跳過 _claude_max_lib.sh / _codex_lib.sh 裡的 read -p（model 由參數帶入），
#  但 OAuth 'claude auth login' / 'codex login' 仍會開瀏覽器，需使用者完成授權。
#  僅 macOS / Linux。
# =================================================================
PROVIDER="${1:-}"
MODEL_ARG="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$ROOT_DIR/data"
ENGINE_DIR="$ROOT_DIR/engine"
ENV_FILE="$DATA_DIR/ai_settings.env"
NPM_CACHE_DIR="$DATA_DIR/npm-cache"

_PLATFORM=$(uname -s | tr '[:upper:]' '[:lower:]'); [ "$_PLATFORM" = "darwin" ] || _PLATFORM="linux"
_ARCH=$(uname -m); case "$_ARCH" in x86_64|amd64) _ARCH=x64;; arm64|aarch64) _ARCH=arm64;; esac
NODE_BIN="$ENGINE_DIR/node-$_PLATFORM-$_ARCH/bin/node"
NPM_BIN="$ENGINE_DIR/node-$_PLATFORM-$_ARCH/bin/npm"
export PATH="$ENGINE_DIR/node-$_PLATFORM-$_ARCH/bin:$PATH"

# 顏色變數：dashboard 端會原樣轉發 stdout，所以這裡留空字串避免 ANSI 雜訊
CYAN=''; GREEN=''; YELLOW=''; RED=''; DIM=''; BOLD=''; RESET=''

save_env() { echo "$1" > "$ENV_FILE"; }

# 非互動：libs 會看這個旗標跳過 'Press Enter to start login...' 的 read
export OPENCLAUDE_NONINTERACTIVE=1

if [ ! -x "$NODE_BIN" ]; then
    echo "[ERROR] Portable Node not found at $NODE_BIN — run ./start.sh once first to bootstrap the engine."
    exit 2
fi

case "$PROVIDER" in
    claude-max)
        [ -n "$MODEL_ARG" ] && export CLAUDE_MAX_MODEL="$MODEL_ARG"
        # shellcheck source=/dev/null
        . "$ROOT_DIR/tools/_claude_max_lib.sh"
        setup_claude_max
        ;;
    codex)
        [ -n "$MODEL_ARG" ] && export CODEX_MODEL="$MODEL_ARG"
        # shellcheck source=/dev/null
        . "$ROOT_DIR/tools/_codex_lib.sh"
        setup_codex
        ;;
    *)
        echo "[ERROR] Usage: bash tools/setup_oauth_provider.sh <claude-max|codex> [model]"
        exit 2
        ;;
esac
exit $?
