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

# 用一個子 shell，把 HOME 暫時指到 $DATA_DIR/home，跑 'claude login'
# 完成後 OAuth credentials 落在 $DATA_DIR/home/.claude/.credentials.json
claude_oauth_login() {
    echo ""
    echo -e "  ${CYAN}--- CLAUDE OAUTH LOGIN ---${RESET}"
    echo -e "  ${DIM}A browser window will open. Log in with your Claude Max account.${RESET}"
    echo -e "  ${DIM}Credentials are saved INSIDE this folder (data/home/.claude/), not your real home.${RESET}"
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

# 驗證現有 OAuth 還活著（15 秒 timeout）
claude_oauth_verify() {
    env HOME="$DATA_DIR/home" \
        PATH="$ENGINE_DIR/node_modules/@anthropic-ai/claude-code/bin:$PATH" \
        bash -c 'timeout 15 claude --print "ping" >/dev/null 2>&1'
}

setup_claude_max() {
    echo ""
    echo -e "  ${CYAN}--- CLAUDE (MAX SUBSCRIPTION) SETUP ---${RESET}"
    echo ""
    echo -e "  ${DIM}This uses your Claude Max (\$200/mo) subscription via OAuth — no API key needed.${RESET}"
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
MIN_REQUEST_INTERVAL_MS=0
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
