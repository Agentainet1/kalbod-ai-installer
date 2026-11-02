#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'
info(){ echo -e "${CYAN}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERR]${NC} $*" >&2; }
step(){ echo -e "\n${BOLD}${MAGENTA}===> $*${NC}"; }

TTY=/dev/tty
[[ -r "$TTY" ]] || TTY=/dev/stdin
ask(){ local prompt="$1" var="$2" input=""; printf '%s' "$prompt" > "$TTY"; IFS= read -r input < "$TTY" || true; printf -v "$var" '%s' "$input"; }

PROXY_PORT=18089
PROXY_DIR="/opt/kalbod-ai-proxy"
PROXY_SERVICE="kalbod-ai-proxy.service"
PROXY_URL="socks5h://127.0.0.1:${PROXY_PORT}"
WORKING_MODELS_FILE="${PROXY_DIR}/working-models.txt"

MODE_HERMES=0; MODE_CLAUDE=0; MODE_CODEX=0; MODE_ALL=0
for arg in "$@"; do
  case "$arg" in
    --hermes) MODE_HERMES=1 ;;
    --claude) MODE_CLAUDE=1 ;;
    --codex)  MODE_CODEX=1 ;;
    --all)    MODE_ALL=1 ;;
    -h|--help) cat <<EOF
Usage: $0 [--hermes] [--claude] [--codex] [--all]
EOF
      exit 0 ;;
    *) err "Unknown flag: $arg"; exit 1 ;;
  esac
done
if (( MODE_ALL )); then MODE_HERMES=1; MODE_CLAUDE=1; MODE_CODEX=1; fi
if (( !MODE_HERMES && !MODE_CLAUDE && !MODE_CODEX )); then
  echo -e "${BOLD}Universal AI Installer & Antigravity Bridge v2${NC}"
  echo "1) Hermes Agent"; echo "2) Claude Code"; echo "3) OpenAI Codex CLI"; echo "4) All-in-One"
  ask "Select [1-4]: " choice
  case "${choice:-}" in
    1) MODE_HERMES=1 ;; 2) MODE_CLAUDE=1 ;; 3) MODE_CODEX=1 ;;
    4) MODE_HERMES=1; MODE_CLAUDE=1; MODE_CODEX=1 ;;
    *) err "Invalid choice"; exit 1 ;;
  esac
fi
if [[ $EUID -ne 0 ]]; then err "Please run as root (use sudo)."; exit 1; fi

need_cmd(){ command -v "$1" >/dev/null 2>&1; }
install_pkg(){
  if need_cmd apt-get; then DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
  elif need_cmd yum; then yum install -y "$@" >/dev/null 2>&1
  elif need_cmd dnf; then dnf install -y "$@" >/dev/null 2>&1
  else err "No supported package manager."; return 1; fi
}

detect_arch_xray(){
  case "$(uname -m)" in
    x86_64|amd64) echo "64" ;;
    aarch64|arm64) echo "arm64-v8a" ;;
    armv7l|armv7) echo "arm32-v7a" ;;
    riscv64) echo "riscv64" ;;
    *) echo "" ;;
  esac
}
detect_arch_node(){
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7l" ;;
    *) echo "" ;;
  esac
}

ensure_node(){
  if need_cmd node; then
    local v; v=$(node -v 2>/dev/null | tr -d 'v' | cut -d. -f1)
    if [[ "$v" =~ ^[0-9]+$ && "$v" -ge 18 ]]; then ok "Node.js $(node -v) present."; return 0; fi
    warn "Node.js too old ($(node -v)); upgrading."
  fi
  info "Installing Node.js..."
  if need_cmd apt-get; then
    if curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | bash - >/tmp/ns.log 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >/dev/null 2>&1 || true
    fi
  fi
  if ! need_cmd node || [[ "$(node -v 2>/dev/null | tr -d 'v' | cut -d. -f1)" -lt 18 ]]; then
    local arch; arch=$(detect_arch_node)
    [[ -z "$arch" ]] && { err "Unsupported arch for Node: $(uname -m)"; return 1; }
    local ver; ver=$(curl -fsSL https://nodejs.org/dist/latest/ 2>/dev/null | grep -oE 'node-v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [[ -z "$ver" ]] && ver="node-v20.11.1"
    local tar="${ver}-linux-${arch}.tar.xz"
    local tmp; tmp=$(mktemp -d)
    if curl -fsSL "https://nodejs.org/dist/latest/${tar}" -o "${tmp}/${tar}"; then
      tar -xf "${tmp}/${tar}" -C /usr/local --strip-components=1
    fi
    rm -rf "$tmp"
  fi
  if need_cmd node; then ok "Node.js $(node -v) ready."; else err "Node.js install failed."; return 1; fi
  export PATH="/usr/local/bin:$PATH"
}

setup_proxy(){
  step "Setting up isolated local proxy (port ${PROXY_PORT})"
  systemctl stop "$PROXY_SERVICE" 2>/dev/null || true
  if need_cmd fuser; then fuser -k "${PROXY_PORT}/tcp" 2>/dev/null || true; fi
  pkill -f "${PROXY_DIR}/xray run" 2>/dev/null || true
  sleep 1
  mkdir -p "$PROXY_DIR"

  if [[ ! -x "${PROXY_DIR}/xray" ]]; then
    info "Downloading Xray-core..."
    local arch; arch=$(detect_arch_xray)
    [[ -z "$arch" ]] && { err "Unsupported arch: $(uname -m)"; exit 1; }
    local tmp; tmp=$(mktemp -d)
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    if ! curl -fsSL "$url" -o "${tmp}/xray.zip"; then err "Xray download failed."; exit 1; fi
    python3 - "$tmp" <<'PYEOF'
import sys, zipfile, os
d=sys.argv[1]
zp=os.path.join(d,'xray.zip')
with zipfile.ZipFile(zp) as z:
    z.extractall(os.path.join(d,'xraydir'))
PYEOF
    if [[ ! -f "${tmp}/xraydir/xray" ]]; then err "Xray binary not found in archive."; exit 1; fi
    chmod +x "${tmp}/xraydir/xray"
    install -m 0755 "${tmp}/xraydir/xray" "${PROXY_DIR}/xray"
    rm -rf "$tmp"
    ok "Xray installed."
  else
    ok "Xray already present."
  fi

  while true; do
    ask "Paste your vless:// or socks5:// config link: " CONFIG_LINK
    [[ -z "${CONFIG_LINK:-}" ]] && { err "Empty input"; continue; }

    if python3 - "$CONFIG_LINK" "${PROXY_DIR}/config.json" "$PROXY_PORT" <<'PYEOF'
import sys, urllib.parse, json

link = sys.argv[1]
out_path = sys.argv[2]
port = int(sys.argv[3])

u = urllib.parse.urlparse(link)
if u.scheme not in ("vless","socks","socks5","socks5h"):
    print("Unsupported scheme"); sys.exit(1)

if u.scheme in ("socks","socks5","socks5h"):
    host = u.hostname
    p = u.port or 1080
    if not host:
        print("Missing socks host"); sys.exit(1)
    server = {"address": host, "port": p}
    if u.username:
        server["users"] = [{"user": urllib.parse.unquote(u.username), "pass": urllib.parse.unquote(u.password or "")}]
    outbound = {"protocol":"socks","settings":{"servers":[server]}}
else:
    if u.scheme != "vless":
        print("Not vless"); sys.exit(1)
    uuid = u.username
    if not uuid:
        print("Missing uuid"); sys.exit(1)
    params = urllib.parse.parse_qs(u.query, keep_blank_values=True)
    def get(k, d=""):
        v = params.get(k)
        return v[0] if v else d
    address = u.hostname
    if not address:
        print("Missing address"); sys.exit(1)
    rport = u.port or 443
    net = get("type","tcp") or "tcp"
    sec = get("security","none") or "none"
    path = get("path","/") or "/"
    sni = get("sni", address) or address
    fp = get("fp","chrome") or "chrome"
    pbk = get("pbk","")
    sid = get("sid","")
    alpn = get("alpn","")
    spx = get("spx","/") or "/"
    host = get("host","") or sni
    flow = get("flow","")
    svc = get("serviceName","")

    outbound = {
      "protocol": "vless",
      "settings": {"vnext": [{"address": address, "port": rport, "users": [{"id": uuid, "encryption": "none"}]}]},
      "streamSettings": {"network": net}
    }
    if flow:
        outbound["settings"]["vnext"][0]["users"][0]["flow"] = flow

    if net == "ws":
        outbound["streamSettings"]["wsSettings"] = {"path": path, "headers": {"Host": host}}
    elif net == "httpupgrade":
        outbound["streamSettings"]["httpupgradeSettings"] = {"path": path, "host": host}
    elif net == "xhttp":
        outbound["streamSettings"]["xhttpSettings"] = {"path": path, "host": host}
    elif net == "grpc":
        outbound["streamSettings"]["grpcSettings"] = {"serviceName": svc}
    elif net == "tcp":
        ht = get("headerType","")
        if ht == "http":
            outbound["streamSettings"]["tcpSettings"] = {"header": {"type": "http", "request": {"path": [path]}}}

    if sec == "tls":
        tls = {"serverName": sni, "fingerprint": fp}
        if alpn:
            tls["alpn"] = [x for x in alpn.split(",") if x]
        outbound["streamSettings"]["security"] = "tls"
        outbound["streamSettings"]["tlsSettings"] = tls
    elif sec == "reality":
        if not pbk:
            print("missing pbk for reality"); sys.exit(1)
        outbound["streamSettings"]["security"] = "reality"
        outbound["streamSettings"]["realitySettings"] = {
            "serverName": sni, "fingerprint": fp, "publicKey": pbk,
            "shortId": sid, "spiderX": spx
        }
    elif sec not in ("", "none"):
        outbound["streamSettings"]["security"] = sec

config = {
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": {"auth": "noauth", "udp": True}}],
  "outbounds": [outbound]
}
with open(out_path, "w") as f:
    json.dump(config, f, indent=2)
print("OK")
PYEOF
    then
      if ! python3 -m json.tool "${PROXY_DIR}/config.json" >/dev/null 2>&1; then
        err "Generated invalid JSON"; continue
      fi
      cat > "/etc/systemd/system/${PROXY_SERVICE}" <<EOF
[Unit]
Description=Kalbod AI Local Proxy (Xray) v2
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
      systemctl enable "$PROXY_SERVICE" >/dev/null 2>&1 || true
      systemctl restart "$PROXY_SERVICE"
      sleep 2

      okflag=0
      for i in 1 2 3 4 5; do
        if curl -s -o /dev/null --max-time 15 -x "$PROXY_URL" https://accounts.google.com; then
          okflag=1; break
        fi
        warn "Attempt $i failed, retrying..."
        sleep 2
      done
      if [[ "$okflag" == 1 ]]; then
        ok "Proxy is working on ${PROXY_URL}."
        echo "$PROXY_URL" > "${PROXY_DIR}/proxy.url"
        return 0
      else
        err "Proxy test failed. Please provide another config link."
        systemctl status "$PROXY_SERVICE" --no-pager 2>&1 | tail -20 || true
        continue
      fi
    else
      err "Failed to parse config link. Try again."
      continue
    fi
  done
}

setup_antigravity(){
  step "Installing & patching Google Antigravity (agy)"
  if ! need_cmd antigravity-cleaner; then
    info "Installing antigravity-cleaner..."
    curl -fsSL https://raw.githubusercontent.com/tawroot/antigravity-cleaner/main/install.sh | bash >/tmp/ac.log 2>&1 || warn "antigravity-cleaner install failed (see /tmp/ac.log)"
  fi
  if need_cmd antigravity-cleaner; then
    antigravity-cleaner patch all >/tmp/ac-patch.log 2>&1 || warn "patch failed (see /tmp/ac-patch.log)"
    ok "antigravity-cleaner ready."
  else
    warn "antigravity-cleaner not available."
  fi

  AGY_BIN=""
  for c in "$HOME/.local/bin/agy" "/usr/local/bin/agy" "$(command -v agy 2>/dev/null)"; do
    [[ -x "$c" ]] && { AGY_BIN="$c"; break; }
  done
  if [[ -z "$AGY_BIN" ]]; then
    warn "agy not found. Install Google Antigravity CLI manually, then re-run."
    return 1
  fi
  ok "agy: $AGY_BIN"

  export HTTPS_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL"

  if ! "$AGY_BIN" models >/dev/null 2>&1; then
    warn "Antigravity not logged in. Launching agy interactively..."
    info "Complete the Google login in your browser, then return here."
    "$AGY_BIN" </dev/tty >/dev/tty 2>&1 || true
  fi
  if ! "$AGY_BIN" models >/dev/null 2>&1; then
    err "Antigravity login not verified. Re-run after manual login: $AGY_BIN"
    return 1
  fi
  ok "Antigravity login verified."

  "$AGY_BIN" models > "${PROXY_DIR}/agy-models.txt" 2>/dev/null || true
  info "Available models:"
  cat "${PROXY_DIR}/agy-models.txt" 2>/dev/null || true

  : > "$WORKING_MODELS_FILE"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local_model=$(echo "$line" | awk '{print $1}')
    [[ -z "$local_model" ]] && continue
    info "Testing model: $local_model ..."
    if timeout 180 "$AGY_BIN" --model "$local_model" -p "Reply with exactly: OK" --print-timeout 90s </dev/null 2>/tmp/agy-test.err | grep -qx "OK"; then
      echo "$local_model" >> "$WORKING_MODELS_FILE"
      ok "  WORKS: $local_model"
    else
      warn "  FAILED: $local_model ($(head -c 120 /tmp/agy-test.err 2>/dev/null))"
    fi
  done < "${PROXY_DIR}/agy-models.txt"

  if [[ ! -s "$WORKING_MODELS_FILE" ]]; then
    warn "No models verified; falling back to agy list."
    awk '{print $1}' "${PROXY_DIR}/agy-models.txt" > "$WORKING_MODELS_FILE"
  fi
  ok "Working models saved to ${WORKING_MODELS_FILE}"
}

pick_default_model(){
  local models=()
  if [[ -s "$WORKING_MODELS_FILE" ]]; then
    while IFS= read -r m; do [[ -n "$m" ]] && models+=("$m"); done < "$WORKING_MODELS_FILE"
  fi
  if [[ ${#models[@]} -eq 0 ]]; then echo "gemini-3.8-flash-high"; return; fi
  if [[ ${#models[@]} -eq 1 ]]; then echo "${models[0]}"; return; fi
  echo "Working models:" > "$TTY"
  local i=1
  for m in "${models[@]}"; do echo "  $i) $m" > "$TTY"; i=$((i+1)); done
  ask "Select default model number [1]: " num
  num=${num:-1}
  if [[ "$num" =~ ^[0-9]+$ && "$num" -ge 1 && "$num" -le ${#models[@]} ]]; then
    echo "${models[$((num-1))]}"
  else
    echo "${models[0]}"
  fi
}

setup_hermes(){
  step "Setting up Hermes Agent"
  if ! need_cmd hermes; then
    info "Installing Hermes Agent..."
    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash >/tmp/hermes-install.log 2>&1 || warn "Hermes install failed (see /tmp/hermes-install.log)"
  fi
  if ! need_cmd hermes; then
    export PATH="$HOME/.local/bin:$PATH"
  fi
  if ! need_cmd hermes; then err "Hermes not installed."; return 1; fi
  ok "Hermes: $(command -v hermes)"

  if [[ ! -d "$HOME/.hermes/plugins/antigravity-oauth" ]]; then
    info "Installing antigravity-oauth plugin..."
    hermes plugins install https://github.com/neerazz/hermes-antigravity-oauth --enable --yes-deps >/tmp/hermes-plugin.log 2>&1 || warn "plugin install failed (see /tmp/hermes-plugin.log)"
  else
    hermes plugins enable antigravity-oauth >/dev/null 2>&1 || true
  fi

  ENV_FILE="$HOME/.hermes/.env"
  mkdir -p "$(dirname "$ENV_FILE")"
  touch "$ENV_FILE"
  for v in HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY; do
    sed -i "/^${v}=/d" "$ENV_FILE" 2>/dev/null || true
  done
  {
    echo "HTTPS_PROXY=${PROXY_URL}"
    echo "HTTP_PROXY=${PROXY_URL}"
    echo "ALL_PROXY=${PROXY_URL}"
    echo "NO_PROXY=localhost,127.0.0.1"
  } >> "$ENV_FILE"

  local default_model; default_model=$(pick_default_model)
  hermes config set model.provider antigravity-oauth >/dev/null 2>&1 || true
  hermes config set model.default "$default_model" >/dev/null 2>&1 || true
  ok "Hermes configured. Default model: $default_model"

  info "Verifying Hermes..."
  if hermes -z "Reply with exactly: OK" >/tmp/hermes-verify.log 2>&1; then
    if grep -q "OK" /tmp/hermes-verify.log; then ok "Hermes verification passed."; else warn "Hermes ran but OK not found (see /tmp/hermes-verify.log)."; fi
  else
    warn "Hermes verification failed (see /tmp/hermes-verify.log)."
  fi
}

setup_claude(){
  step "Setting up Claude Code"
  ensure_node
  if ! need_cmd claude; then
    info "Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code >/tmp/claude-install.log 2>&1 || warn "Claude install failed (see /tmp/claude-install.log)"
  fi
  if need_cmd claude; then ok "Claude Code installed: $(command -v claude)"; else warn "Claude Code not installed."; fi

  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    touch "$rc"
    for v in HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY; do
      sed -i "/^export ${v}=/d" "$rc" 2>/dev/null || true
    done
    {
      echo "export HTTPS_PROXY=${PROXY_URL}"
      echo "export HTTP_PROXY=${PROXY_URL}"
      echo "export ALL_PROXY=${PROXY_URL}"
      echo "export NO_PROXY=localhost,127.0.0.1"
    } >> "$rc"
  done
  ok "Claude Code proxy env configured."
  warn "NOTE: Claude Code uses Anthropic API. To use Antigravity models, run a local OpenAI/Claude-compatible bridge (e.g. CLIProxyAPI) and set ANTHROPIC_BASE_URL accordingly. This installer sets geo-bypass proxy only."
}

setup_codex(){
  step "Setting up OpenAI Codex CLI"
  ensure_node
  if ! need_cmd codex; then
    info "Installing Codex CLI..."
    npm install -g @openai/codex >/tmp/codex-install.log 2>&1 || warn "Codex install failed (see /tmp/codex-install.log)"
  fi
  if need_cmd codex; then ok "Codex CLI installed: $(command -v codex)"; else warn "Codex CLI not installed."; fi

  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    touch "$rc"
    for v in HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY; do
      sed -i "/^export ${v}=/d" "$rc" 2>/dev/null || true
    done
    {
      echo "export HTTPS_PROXY=${PROXY_URL}"
      echo "export HTTP_PROXY=${PROXY_URL}"
      echo "export ALL_PROXY=${PROXY_URL}"
      echo "export NO_PROXY=localhost,127.0.0.1"
    } >> "$rc"
  done
  ok "Codex CLI proxy env configured."
  warn "NOTE: Codex uses OpenAI API. To use Antigravity models, run a local OpenAI-compatible bridge (e.g. CLIProxyAPI) and set OPENAI_BASE_URL accordingly."
}

main(){
  setup_proxy
  setup_antigravity || warn "Antigravity setup incomplete."

  (( MODE_HERMES )) && setup_hermes
  (( MODE_CLAUDE )) && setup_claude
  (( MODE_CODEX ))  && setup_codex

  step "All done!"
  echo -e "${GREEN}Proxy:${NC} $PROXY_URL"
  if [[ -s "$WORKING_MODELS_FILE" ]]; then
    echo -e "${GREEN}Working Antigravity models:${NC}"
    sed 's/^/  - /' "$WORKING_MODELS_FILE"
  fi
  echo -e "Use ${BOLD}hermes model${NC} to change default model in Hermes."
}
main "$@"
