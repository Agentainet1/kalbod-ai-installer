#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# Universal AI Installer & Antigravity Bridge
# One-command installer for Hermes Agent, Claude Code, and OpenAI Codex CLI
# with Google Antigravity (Gemini/Claude/GPT-OSS) + geo-bypass proxy.
# =====================================================================

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }
step() { echo -e "\n${BOLD}${MAGENTA}===> $*${NC}"; }

PROXY_PORT=18089
PROXY_DIR="/opt/kalbod-ai-proxy"
PROXY_SERVICE="kalbod-ai-proxy.service"
PROXY_URL="socks5h://127.0.0.1:${PROXY_PORT}"

MODE_HERMES=0
MODE_CLAUDE=0
MODE_CODEX=0
MODE_ALL=0

# ---------- CLI flags ----------
for arg in "$@"; do
  case "$arg" in
    --hermes) MODE_HERMES=1 ;;
    --claude) MODE_CLAUDE=1 ;;
    --codex)  MODE_CODEX=1 ;;
    --all)    MODE_ALL=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--hermes] [--claude] [--codex] [--all]
  --hermes   Install/configure Hermes Agent only
  --claude   Install/configure Claude Code only
  --codex    Install/configure OpenAI Codex CLI only
  --all      Install/configure all three
  (no flags) Interactive menu
EOF
      exit 0 ;;
    *) err "Unknown flag: $arg"; exit 1 ;;
  esac
done

if (( MODE_ALL )); then MODE_HERMES=1; MODE_CLAUDE=1; MODE_CODEX=1; fi
if (( !MODE_HERMES && !MODE_CLAUDE && !MODE_CODEX )); then
  # interactive menu
  echo -e "${BOLD}Universal AI Installer & Antigravity Bridge${NC}"
  echo "1) Hermes Agent"
  echo "2) Claude Code"
  echo "3) OpenAI Codex CLI"
  echo "4) All-in-One"
  read -rp "Select [1-4]: " choice
  case "$choice" in
    1) MODE_HERMES=1 ;;
    2) MODE_CLAUDE=1 ;;
    3) MODE_CODEX=1 ;;
    4) MODE_HERMES=1; MODE_CLAUDE=1; MODE_CODEX=1 ;;
    *) err "Invalid choice"; exit 1 ;;
  esac
fi

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
  err "Please run as root (use sudo)."
  exit 1
fi

# ---------- Helpers ----------
need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_pkg() {
  if need_cmd apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
  elif need_cmd yum; then
    yum install -y "$@" >/dev/null 2>&1
  elif need_cmd dnf; then
    dnf install -y "$@" >/dev/null 2>&1
  else
    err "No supported package manager found."
    return 1
  fi
}

# ---------- Phase 1: Proxy setup ----------
setup_proxy() {
  step "Setting up isolated local proxy (port ${PROXY_PORT})"

  mkdir -p "$PROXY_DIR"
  if ! need_cmd xray && [[ ! -x /usr/local/bin/xray ]]; then
    info "Downloading Xray-core..."
    cd /tmp
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64) XRAY_ARCH="64" ;;
      aarch64) XRAY_ARCH="arm64-v8a" ;;
      *) err "Unsupported arch: $ARCH"; exit 1 ;;
    esac
    wget -q "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip" -O /tmp/xray.zip
    python3 -c "import zipfile; zipfile.ZipFile('/tmp/xray.zip').extractall('/tmp/xraydir')" 2>/dev/null || \
      (need_cmd unzip && unzip -o /tmp/xray.zip -d /tmp/xraydir)
    install -m 0755 /tmp/xraydir/xray "$PROXY_DIR/xray"
  else
    if need_cmd xray; then install -m 0755 "$(command -v xray)" "$PROXY_DIR/xray"; fi
  fi

  # Ask for config link
  while true; do
    echo -e "${YELLOW}Paste your vless:// or socks5:// config link:${NC}"
    read -rp "> " CONFIG_LINK
    [[ -z "$CONFIG_LINK" ]] && { err "Empty input"; continue; }

    if [[ "$CONFIG_LINK" == socks5://* || "$CONFIG_LINK" == socks5h://* ]]; then
      # Simple socks upstream: just forward via a direct socks outbound is not supported by xray easily;
      # we treat it as the final proxy directly by writing a passthrough. For simplicity, use the link as PROXY_URL.
      PROXY_URL="${CONFIG_LINK/socks5:/socks5h:}"
      echo "$PROXY_URL" > "$PROXY_DIR/proxy.url"
      ok "Using SOCKS5 proxy directly: $PROXY_URL"
      break
    fi

    if [[ "$CONFIG_LINK" == vless://* ]]; then
      info "Parsing VLESS link with built-in Python parser..."
      python3 - "$CONFIG_LINK" "$PROXY_DIR/config.json" <<'PYEOF'
import sys, urllib.parse, json, base64

link = sys.argv[1]
out = sys.argv[2]
u = urllib.parse.urlparse(link)
if u.scheme != "vless":
    print("Not a vless link"); sys.exit(1)
uuid = u.username
params = urllib.parse.parse_qs(u.query)
address = u.hostname
port = u.port or 443
net = params.get("type", ["tcp"])[0]
sec = params.get("security", ["none"])[0]
path = urllib.parse.unquote(params.get("path", ["/"])[0])
sni = params.get("sni", [address])[0]
fp = params.get("fp", ["chrome"])[0]
pbk = params.get("pbk", [""])[0]
sid = params.get("sid", [""])[0]
alpn = params.get("alpn", [""])[0]

outbound = {
  "protocol": "vless",
  "settings": {"vnext": [{"address": address, "port": port, "users": [{"id": uuid, "encryption": "none"}]}]},
  "streamSettings": {"network": net}
}
if net == "ws":
    outbound["streamSettings"]["wsSettings"] = {"path": path}
if sec == "tls":
    outbound["streamSettings"]["security"] = "tls"
    outbound["streamSettings"]["tlsSettings"] = {"serverName": sni, "fingerprint": fp}
    if alpn:
        outbound["streamSettings"]["tlsSettings"]["alpn"] = [x for x in alpn.split(",") if x]
elif sec == "reality":
    outbound["streamSettings"]["security"] = "reality"
    outbound["streamSettings"]["realitySettings"] = {"serverName": sni, "fingerprint": fp, "publicKey": pbk, "shortId": sid, "spiderX": path if path else "/"}

config = {
  "inbounds": [{"port": 18089, "listen": "127.0.0.1", "protocol": "socks", "settings": {"auth": "noauth", "udp": True}}],
  "outbounds": [outbound]
}
with open(out, "w") as f:
    json.dump(config, f, indent=2)
print("Config written")
PYEOF
      if [[ $? -ne 0 ]]; then err "Failed to parse VLESS link"; continue; fi
      PROXY_URL="$PROXY_URL"
      break
    fi

    err "Unsupported link scheme. Use vless:// or socks5://"
  done

  # If socks direct, skip xray service
  if [[ "$CONFIG_LINK" == vless://* ]]; then
    # systemd service
    cat > /etc/systemd/system/${PROXY_SERVICE} <<EOF
[Unit]
Description=Kalbod AI Local Proxy (Xray)
After=network.target

[Service]
Type=simple
ExecStart=${PROXY_DIR}/xray run -config ${PROXY_DIR}/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$PROXY_SERVICE"
  fi

  # Test connectivity
  info "Testing proxy connectivity to Google..."
  for i in 1 2 3; do
    if curl -s -o /dev/null --max-time 15 -x "$PROXY_URL" https://accounts.google.com; then
      ok "Proxy is working."
      return 0
    fi
    warn "Attempt $i failed, retrying..."
    sleep 2
  done
  err "Proxy test failed. Please provide another config link."
  # allow retry by re-running setup_proxy
  setup_proxy
}

# ---------- Phase 2: Antigravity ----------
setup_antigravity() {
  step "Installing & patching Google Antigravity (agy)"
  if ! need_cmd antigravity-cleaner; then
    curl -fsSL https://raw.githubusercontent.com/tawroot/antigravity-cleaner/main/install.sh | bash
  fi
  antigravity-cleaner patch all || true

  if ! need_cmd agy; then
    warn "agy not found. Please install from https://antigravity.google/cli then re-run."
    return 1
  fi

  export HTTPS_PROXY="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL"
  export ALL_PROXY="$PROXY_URL"

  info "Logging in to Google Antigravity..."
  # Run agy login flow and capture URL; user pastes code
  TMP=$(mktemp -d)
  (
    cd "$TMP"
    /root/.local/bin/agy -p "Reply with exactly: OK" --print-timeout 5m
  ) &
  AGY_PID=$!
  sleep 3
  # We cannot automate code entry fully; instruct user
  warn "If a login URL is shown above, open it in your browser and paste the code here."
  wait $AGY_PID || true

  # Verify
  if /root/.local/bin/agy models >/dev/null 2>&1; then
    ok "Antigravity login verified."
  else
    err "Antigravity login failed. Re-run after manual login."
  fi
}

# ---------- Hermes ----------
setup_hermes() {
  step "Setting up Hermes Agent"
  if ! need_cmd hermes; then
    info "Installing Hermes Agent..."
    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
  fi

  # plugin
  if [[ ! -d "$HOME/.hermes/plugins/antigravity-oauth" ]]; then
    hermes plugins install https://github.com/neerazz/hermes-antigravity-oauth --enable || true
  fi

  # env
  ENV_FILE="$HOME/.hermes/.env"
  touch "$ENV_FILE"
  for v in HTTPS_PROXY HTTP_PROXY ALL_PROXY; do
    if ! grep -q "^${v}=" "$ENV_FILE"; then
      echo "${v}=${PROXY_URL}" >> "$ENV_FILE"
    fi
  done

  # config
  python3 - <<PYEOF
import re, pathlib
p = pathlib.Path("$HOME/.hermes/config.yaml")
# best-effort: ensure model provider set via hermes cli if available
PYEOF
  hermes config set model.provider antigravity-oauth || true
  hermes config set model.default gemini-3.8-flash || true

  ok "Hermes configured. Use: hermes model  (to pick default model)"
}

# ---------- Claude Code ----------
setup_claude() {
  step "Setting up Claude Code"
  if ! need_cmd node; then
    info "Installing Node.js..."
    install_pkg nodejs npm || true
  fi
  if ! need_cmd claude; then
    info "Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 || warn "Claude install failed"
  fi

  # proxy env in shell rc
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    touch "$rc"
    for v in HTTPS_PROXY HTTP_PROXY ALL_PROXY; do
      grep -q "export ${v}=" "$rc" || echo "export ${v}=${PROXY_URL}" >> "$rc"
    done
  done
  ok "Claude Code configured (proxy env set)."
}

# ---------- Codex ----------
setup_codex() {
  step "Setting up OpenAI Codex CLI"
  if ! need_cmd node; then
    install_pkg nodejs npm || true
  fi
  if ! need_cmd codex; then
    info "Installing Codex CLI..."
    npm install -g @openai/codex >/dev/null 2>&1 || warn "Codex install failed"
  fi
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    touch "$rc"
    for v in HTTPS_PROXY HTTP_PROXY ALL_PROXY; do
      grep -q "export ${v}=" "$rc" || echo "export ${v}=${PROXY_URL}" >> "$rc"
    done
  done
  ok "Codex CLI configured (proxy env set)."
}

# ---------- Main ----------
main() {
  setup_proxy
  setup_antigravity

  (( MODE_HERMES )) && setup_hermes
  (( MODE_CLAUDE )) && setup_claude
  (( MODE_CODEX ))  && setup_codex

  step "All done!"
  echo -e "${GREEN}Proxy:${NC} $PROXY_URL"
  echo -e "${GREEN}Antigravity models:${NC} gemini-3.8-flash-{high,medium,low}, claude-sonnet-4-6, claude-opus-4-6-thinking, gpt-oss-120b-medium"
  echo -e "Use ${BOLD}hermes model${NC} to set default model in Hermes."
}

main "$@"
EOF
chmod +x /root/kalbod-ai-installer/install.sh
bash -n /root/kalbod-ai-installer/install.sh && echo "SYNTAX OK"