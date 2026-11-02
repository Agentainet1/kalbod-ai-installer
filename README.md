# Universal AI Installer & Antigravity Bridge

One-command installer that connects **Hermes Agent**, **Claude Code**, and **OpenAI Codex CLI** to **Google Antigravity** (Gemini 3.x, Claude 4.6, GPT-OSS) with an isolated geo-bypass proxy.

## One-liners

### 1) Hermes Agent + Antigravity
```bash
curl -fsSL https://raw.githubusercontent.com/kalbod-team/kalbod-ai-installer/main/install.sh | bash -s -- --hermes
```

### 2) Claude Code + Antigravity
```bash
curl -fsSL https://raw.githubusercontent.com/kalbod-team/kalbod-ai-installer/main/install.sh | bash -s -- --claude
```

### 3) OpenAI Codex CLI + Antigravity
```bash
curl -fsSL https://raw.githubusercontent.com/kalbod-team/kalbod-ai-installer/main/install.sh | bash -s -- --codex
```

### All-in-One
```bash
curl -fsSL https://raw.githubusercontent.com/kalbod-team/kalbod-ai-installer/main/install.sh | bash -s -- --all
```

## فارسی

نصب‌کنندهٔ جامع و خودکار برای اتصال Hermes Agent، Claude Code و Codex CLI به Google Antigravity با پروکسی ایزولهٔ دور زدن تحریم.

### دستورات تک‌خطی

1. نصب و اتصال خودکار Hermes:
```bash
curl -fsSL https://raw.githubusercontent.com/kalbod-team/kalbod-ai-installer/main/install.sh | bash -s -- --hermes
```

2. نصب و اتصال خودکار Claude Code:
```bash
curl -fsSL https://raw.githubusercontent.com/kalbod-team/kalbod-ai-installer/main/install.sh | bash -s -- --claude
```

3. نصب و اتصال خودکار Codex CLI:
```bash
curl -fsSL https://raw.githubusercontent.com/kalbod-team/kalbod-ai-installer/main/install.sh | bash -s -- --codex
```

## Features
- VLESS / SOCKS5 parser → isolated Xray proxy on 127.0.0.1:18089
- Separate systemd service `kalbod-ai-proxy.service` (no conflict with server VPN panels)
- Auto-install antigravity-cleaner + patch agy
- Google OAuth login with device code
- Real model testing & extraction
- Proxy env injection for Hermes/Claude/Codex

## License
MIT
EOF
echo done