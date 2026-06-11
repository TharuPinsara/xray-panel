# Xray Panel — VLESS + WS + TLS

A minimal self-hosted panel for managing Xray users.  
No Marzban, no 3X-UI — just Python (FastAPI) + SQLite + Xray.

## Stack
| Layer | Tool |
|-------|------|
| Proxy | Xray-core (VLESS + WebSocket + TLS on port 443) |
| Panel backend | FastAPI + Uvicorn |
| Database | SQLite (single file) |
| TLS | Let's Encrypt via Certbot |
| Reverse proxy | Nginx (panel on port 8443) |

## Requirements
- Ubuntu 22.04 or 24.04
- A domain with an A record pointing to your VPS
- Port 80, 443, 8443 open

## Install (one command)

```bash
git clone https://github.com/TharuPinsara/xray-panel   # or copy files to your VPS
cd xray-panel
sudo bash install.sh --domain your.domain.com
```

After install the panel is at **https://your.domain.com:8443**

---

## Manual install steps

### 1. Install Xray
```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)"
```

### 2. Get TLS cert
```bash
certbot certonly --standalone -d your.domain.com
mkdir -p /etc/ssl/xray
ln -sf /etc/letsencrypt/live/your.domain.com/fullchain.pem /etc/ssl/xray/fullchain.pem
ln -sf /etc/letsencrypt/live/your.domain.com/privkey.pem   /etc/ssl/xray/privkey.pem
```

### 3. Copy Xray config
```bash
cp xray-config-template.json /usr/local/etc/xray/config.json
systemctl restart xray
```

### 4. Set up panel
```bash
cp -r . /opt/xray-panel
cd /opt/xray-panel
python3 -m venv venv
venv/bin/pip install -r requirements.txt
mkdir -p /var/lib/xray-panel
```

### 5. Run panel
```bash
venv/bin/uvicorn main:app --host 127.0.0.1 --port 8080
```
Or use the provided systemd service:
```bash
cp xray-panel.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now xray-panel
```

---

## API reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/status` | Xray status + version |
| GET | `/api/users` | List all users |
| POST | `/api/users` | Add user `{name, note}` |
| PATCH | `/api/users/{id}` | Update `{name, enabled, note}` |
| DELETE | `/api/users/{id}` | Delete user |
| POST | `/api/xray/restart` | Restart Xray |

Every write operation syncs users to `config.json` and restarts Xray automatically.

---

## Client VLESS link format

```
vless://<UUID>@your.domain.com:443?encryption=none&security=tls&type=ws&path=%2Fvless#UserName
```

Works with: **v2rayN**, **v2rayNG**, **Hiddify**, **Shadowrocket**, **NekoRay**

---

## Security notes

- The panel has **no authentication** by default — bind to `127.0.0.1` (already done) and use a firewall or VPN to access it, or add HTTP Basic Auth to Nginx.
- To add Nginx Basic Auth:
  ```bash
  apt install apache2-utils
  htpasswd -c /etc/nginx/.htpasswd admin
  # Then add to the Nginx server block:
  # auth_basic "Panel"; auth_basic_user_file /etc/nginx/.htpasswd;
  ```

## File structure
```
xray-panel/
├── main.py                    # FastAPI app
├── requirements.txt
├── templates/
│   └── index.html             # Dashboard UI
├── xray-config-template.json  # Xray config (VLESS+WS+TLS)
├── xray-panel.service         # Systemd unit
├── install.sh                 # Full auto-installer
└── README.md
```
