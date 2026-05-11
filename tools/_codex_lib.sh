#!/bin/bash
# =================================================================
#  OpenAI Codex (ChatGPT Subscription) 共用函式庫
#  被 start.sh 與 tools/change_provider.sh source。
#  依賴 caller 已定義：ROOT_DIR ENGINE_DIR DATA_DIR ENV_FILE
#  NODE_BIN NPM_BIN NPM_CACHE_DIR、顏色變數、save_env()。
#  引擎原生支援 --provider codex + Codex OAuth；不需要 proxy。
# =================================================================

CODEX_HOME_DIR="$DATA_DIR/codex"

# Codex CLI 是 Node wrapper：engine/node_modules/@openai/codex/bin/codex.js
# （wrapper 會 dispatch 到平台專屬 binary @openai/codex-<plat>-<arch>）
_resolve_codex_cli_js() {
    echo "$ENGINE_DIR/node_modules/@openai/codex/bin/codex.js"
}
CODEX_CLI_JS="$(_resolve_codex_cli_js)"

# Codex CLI 裝好了嗎？
codex_ready() {
    CODEX_CLI_JS="$(_resolve_codex_cli_js)"
    [ -f "$CODEX_CLI_JS" ]
}

# data/codex/auth.json 存在且含 access token？（容 nested tokens.access_token 與舊式扁平 key）
codex_oauth_ok() {
    local f="$CODEX_HOME_DIR/auth.json"
    [ -f "$f" ] || return 1
    grep -q '"access_token"' "$f"
}

# 安裝 Codex CLI（沿用 start.sh 既有的 npm cache）
install_codex() {
    echo -e "  ${YELLOW}[~] Installing OpenAI Codex CLI...${RESET}"
    echo -e "  ${DIM}    First time: downloads ~20-40 MB. Slow USB drives can look idle for a few minutes.${RESET}"
    mkdir -p "$NPM_CACHE_DIR"
    ( cd "$ENGINE_DIR" && NPM_CONFIG_CACHE="$NPM_CACHE_DIR" "$NPM_BIN" install @openai/codex@latest \
        --no-audit --no-fund --loglevel=warn --no-bin-links --cache "$NPM_CACHE_DIR" )
    CODEX_CLI_JS="$(_resolve_codex_cli_js)"
    if [ ! -f "$CODEX_CLI_JS" ]; then
        echo -e "  ${RED}[ERROR] Codex CLI install incomplete (missing $CODEX_CLI_JS).${RESET}"
        return 1
    fi
    echo -e "  ${GREEN}[OK] Codex CLI installed.${RESET}"
}

# 用 CODEX_HOME=data/codex 跑 'codex login'（瀏覽器 ChatGPT 訂閱登入）
# 完成後 credentials 落在 data/codex/auth.json
codex_oauth_login() {
    echo ""
    echo -e "  ${CYAN}--- CODEX OAUTH LOGIN ---${RESET}"
    echo -e "  ${DIM}A browser window will open. Sign in with your ChatGPT account (Plus/Pro/Team).${RESET}"
    echo -e "  ${DIM}Credentials are saved INSIDE this folder (data/codex/auth.json) via CODEX_HOME.${RESET}"
    echo ""
    read -p "  Press Enter to start login... " _
    mkdir -p "$CODEX_HOME_DIR"
    CODEX_CLI_JS="$(_resolve_codex_cli_js)"
    CODEX_HOME="$CODEX_HOME_DIR" "$NODE_BIN" "$CODEX_CLI_JS" login
    echo ""
    if codex_oauth_ok; then
        echo -e "  ${GREEN}[OK] Logged in (data/codex/auth.json written).${RESET}"
        return 0
    fi
    echo -e "  ${RED}[ERROR] Login did not produce data/codex/auth.json with an access token.${RESET}"
    echo -e "  ${DIM}        Retry, or run: CODEX_HOME=\"$CODEX_HOME_DIR\" \"$NODE_BIN\" \"$CODEX_CLI_JS\" login${RESET}"
    return 1
}

setup_codex() {
    echo ""
    echo -e "  ${CYAN}--- OPENAI CODEX (CHATGPT SUBSCRIPTION) SETUP ---${RESET}"
    echo ""
    echo -e "  ${DIM}Uses your ChatGPT subscription (Plus/Pro/Team) via OAuth — no API key needed.${RESET}"
    echo -e "  ${DIM}Credentials live in data/codex/ (portable via CODEX_HOME). No proxy — the engine connects to Codex directly.${RESET}"
    echo -e "  ${DIM}macOS / Linux only.${RESET}"
    echo ""

    # 1) Codex CLI
    if ! codex_ready; then
        install_codex || { echo -e "  ${RED}[ERROR] Setup aborted.${RESET}"; return 1; }
    fi

    # 2) OAuth
    if codex_oauth_ok; then
        echo -e "  ${GREEN}[OK] Existing Codex credentials found (data/codex/auth.json).${RESET}"
    else
        codex_oauth_login || { echo -e "  ${RED}[ERROR] Setup aborted (Codex OAuth login failed).${RESET}"; return 1; }
    fi

    # 3) 模型三選一（對齊引擎 getCodexModelOptions 的 codex 系列）
    echo ""
    echo -e "  ${CYAN}Choose default model:${RESET}"
    echo -e "    ${CYAN}1)${RESET} gpt-5.1-codex       ${DIM}- balanced (recommended)${RESET}"
    echo -e "    ${CYAN}2)${RESET} gpt-5.1-codex-max   ${DIM}- highest quality${RESET}"
    echo -e "    ${CYAN}3)${RESET} gpt-5.1-codex-mini  ${DIM}- fastest / lightest${RESET}"
    read -p "  Select (1-3) [Enter for 1]: " _MSEL
    case "$_MSEL" in
        2) CODEX_MODEL="gpt-5.1-codex-max" ;;
        3) CODEX_MODEL="gpt-5.1-codex-mini" ;;
        *) CODEX_MODEL="gpt-5.1-codex" ;;
    esac

    # 4) 寫 ai_settings.env
    #    引擎的「codex」不是 --provider 值，而是走 provider=openai + Codex backend base URL
    #    + OAuth credentials（從 $CODEX_HOME/auth.json）。OPENAI_API_KEY 用引擎自己的
    #    placeholder「codex-oauth-token-for-validation」讓 pre-flight 檢查過關；實際請求用
    #    auth.json 的 access token。codex base URL → 引擎自動用 codex_responses transport。
    save_env "# ========================================================
# Portable AI - Master Switchboard (OpenAI Codex via ChatGPT subscription)
# ========================================================
AI_PROVIDER=openai
CLAUDE_CODE_USE_OPENAI=1
OPENAI_BASE_URL=https://chatgpt.com/backend-api/codex
OPENAI_API_KEY=codex-oauth-token-for-validation
OPENAI_MODEL=$CODEX_MODEL
AI_DISPLAY_MODEL=$CODEX_MODEL
CODEX_HOME=$CODEX_HOME_DIR
CODEX_CREDENTIAL_SOURCE=oauth"

    echo ""
    echo -e "  ${GREEN}[OK] Codex configured (model: $CODEX_MODEL). No proxy needed — the engine connects to Codex directly.${RESET}"
}
