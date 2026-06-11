#!/usr/bin/env bash
# ============================================================
# Xray Panel — Full install script for Ubuntu 22.04 / 24.04
# Usage: sudo bash install.sh --domain your.domain.com
# ============================================================
set -euo pipefail

# ── Parse args ───────────────────────────────────────────────
DOMAIN=""
PANEL_PORT=8080

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --port)   PANEL_PORT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$DOMAIN" ]]; then
  echo "Usage: sudo bash install.sh --domain your.domain.com"
  exit 1
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  Xray Panel Installer"
echo "  Domain  : $DOMAIN"
echo "  Port    : $PANEL_PORT (panel)"
echo "  Protocol: VLESS + WS + TLS on :443"
echo "═══════════════════════════════════════════"
echo ""

# ── 1. System deps ───────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip curl wget certbot nginx ufw

# ── 2. Install Xray ──────────────────────────────────────────
echo "[*] Installing Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
  @ install --without-geodata 2>&1 | tail -5

# ── 3. TLS certificate via Certbot ───────────────────────────
echo "[*] Obtaining TLS cert for $DOMAIN..."
systemctl stop nginx || true
certbot certonly --standalone --non-interactive --agree-tos \
  --register-unsafely-without-email -d "$DOMAIN" || {
    echo "⚠  Certbot failed — ensure DNS A record for $DOMAIN points to this server."
    exit 1
  }

mkdir -p /etc/ssl/xray
ln -sf /etc/letsencrypt/live/${DOMAIN}/fullchain.pem /etc/ssl/xray/fullchain.pem
ln -sf /etc/letsencrypt/live/${DOMAIN}/privkey.pem   /etc/ssl/xray/privkey.pem

# ── 4. Xray config.json (VLESS + WS + TLS) ───────────────────
echo "[*] Writing Xray config..."
mkdir -p /var/log/xray

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/ssl/xray/fullchain.pem",
              "keyFile": "/etc/ssl/xray/privkey.pem"
            }
          ]
        },
        "wsSettings": {
          "path": "/vless"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF

systemctl enable xray
systemctl restart xray
echo "[✓] Xray running"

# ── 5. Install panel ──────────────────────────────────────────
echo "[*] Installing panel..."
PANEL_DIR=/opt/xray-panel
mkdir -p "$PANEL_DIR"

# Copy files (assumes install script is alongside project files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -r "$SCRIPT_DIR/." "$PANEL_DIR/"

python3 -m venv "$PANEL_DIR/venv"
"$PANEL_DIR/venv/bin/pip" install -q -r "$PANEL_DIR/requirements.txt"

mkdir -p /var/lib/xray-panel

# ── 6. Systemd service ───────────────────────────────────────
cat > /etc/systemd/system/xray-panel.service <<EOF
[Unit]
Description=Xray Panel (FastAPI)
After=network.target xray.service

[Service]
Type=simple
User=root
WorkingDirectory=$PANEL_DIR
Environment=XRAY_CONFIG_PATH=/usr/local/etc/xray/config.json
Environment=DB_PATH=/var/lib/xray-panel/users.db
Environment=PANEL_PORT=$PANEL_PORT
ExecStart=$PANEL_DIR/venv/bin/uvicorn main:app --host 127.0.0.1 --port $PANEL_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray-panel
systemctl start xray-panel
echo "[✓] Panel running on 127.0.0.1:$PANEL_PORT"

# ── 7. Nginx reverse proxy for panel ─────────────────────────
echo "[*] Configuring Nginx..."

cat > /etc/nginx/sites-available/xray-panel <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 8443 ssl;
    server_name $DOMAIN;

    ssl_certificate     /etc/ssl/xray/fullchain.pem;
    ssl_certificate_key /etc/ssl/xray/privkey.pem;

    location / {
        proxy_pass         http://127.0.0.1:$PANEL_PORT;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/xray-panel /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
echo "[✓] Nginx configured"

# ── 8. Firewall ───────────────────────────────────────────────
ufw allow 443/tcp
ufw allow 8443/tcp
ufw --force enable
echo "[✓] Firewall updated"

# ── 9. Auto-renew cert ───────────────────────────────────────
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem /etc/ssl/xray/fullchain.pem && cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem /etc/ssl/xray/privkey.pem && systemctl restart xray'") | crontab -

echo ""
echo "═══════════════════════════════════════════"
echo "  ✓ Installation complete!"
echo ""
echo "  Panel URL : https://$DOMAIN:8443"
echo "  VLESS port: 443"
echo "  WS path   : /vless"
echo ""
echo "  Client link format:"
echo "  vless://<UUID>@${DOMAIN}:443?encryption=none&security=tls&type=ws&path=%2Fvless#UserName"
echo "═══════════════════════════════════════════"
