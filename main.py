import uuid
import json
import subprocess
import sqlite3
import os
from datetime import datetime
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel
from typing import Optional

app = FastAPI(title="Xray Panel")
templates = Jinja2Templates(directory="templates")

XRAY_CONFIG_PATH = os.environ.get("XRAY_CONFIG_PATH", "/usr/local/etc/xray/config.json")
DB_PATH = os.environ.get("DB_PATH", "/var/lib/xray-panel/users.db")
PANEL_PORT = int(os.environ.get("PANEL_PORT", "8080"))

os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)

# ── Database ──────────────────────────────────────────────────────────────────

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    with get_db() as db:
        db.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id      INTEGER PRIMARY KEY AUTOINCREMENT,
                name    TEXT NOT NULL,
                uuid    TEXT NOT NULL UNIQUE,
                enabled INTEGER NOT NULL DEFAULT 1,
                note    TEXT DEFAULT '',
                created TEXT NOT NULL
            )
        """)
        db.commit()

init_db()

# ── Xray config helpers ───────────────────────────────────────────────────────

def read_xray_config() -> dict:
    try:
        with open(XRAY_CONFIG_PATH, "r") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}

def write_xray_config(cfg: dict):
    with open(XRAY_CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)

def sync_users_to_xray():
    """Pull all enabled users from DB and write them into Xray config clients list."""
    cfg = read_xray_config()
    if not cfg:
        return False

    with get_db() as db:
        rows = db.execute("SELECT uuid FROM users WHERE enabled=1").fetchall()

    clients = [{"id": row["uuid"], "alterId": 0} for row in rows]

    try:
        for inbound in cfg.get("inbounds", []):
            settings = inbound.get("settings", {})
            if "clients" in settings:
                settings["clients"] = clients
        write_xray_config(cfg)
        return True
    except Exception:
        return False

def restart_xray() -> tuple[bool, str]:
    try:
        result = subprocess.run(
            ["systemctl", "restart", "xray"],
            capture_output=True, text=True, timeout=10
        )
        return result.returncode == 0, result.stderr.strip()
    except Exception as e:
        return False, str(e)

def get_xray_status() -> dict:
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "xray"],
            capture_output=True, text=True, timeout=5
        )
        active = result.stdout.strip() == "active"

        uptime_result = subprocess.run(
            ["systemctl", "show", "xray", "--property=ActiveEnterTimestamp"],
            capture_output=True, text=True, timeout=5
        )
        uptime_str = uptime_result.stdout.strip().replace("ActiveEnterTimestamp=", "")

        version_result = subprocess.run(
            ["xray", "version"],
            capture_output=True, text=True, timeout=5
        )
        version_line = version_result.stdout.splitlines()[0] if version_result.stdout else "unknown"

        return {
            "active": active,
            "status": "running" if active else "stopped",
            "since": uptime_str,
            "version": version_line
        }
    except Exception as e:
        return {"active": False, "status": "error", "since": "", "version": str(e)}

# ── Pydantic models ───────────────────────────────────────────────────────────

class UserCreate(BaseModel):
    name: str
    note: Optional[str] = ""

class UserUpdate(BaseModel):
    name: Optional[str] = None
    enabled: Optional[bool] = None
    note: Optional[str] = None

# ── API routes ────────────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})

@app.get("/api/status")
def api_status():
    return get_xray_status()

@app.get("/api/users")
def api_list_users():
    with get_db() as db:
        rows = db.execute("SELECT * FROM users ORDER BY id DESC").fetchall()
    return [dict(r) for r in rows]

@app.post("/api/users")
def api_create_user(body: UserCreate):
    new_uuid = str(uuid.uuid4())
    created = datetime.utcnow().isoformat()
    try:
        with get_db() as db:
            db.execute(
                "INSERT INTO users (name, uuid, enabled, note, created) VALUES (?,?,1,?,?)",
                (body.name, new_uuid, body.note, created)
            )
            db.commit()
    except sqlite3.IntegrityError:
        raise HTTPException(400, "User already exists")

    sync_users_to_xray()
    ok, err = restart_xray()
    return {"success": True, "uuid": new_uuid, "xray_restarted": ok, "error": err}

@app.patch("/api/users/{user_id}")
def api_update_user(user_id: int, body: UserUpdate):
    with get_db() as db:
        row = db.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        if not row:
            raise HTTPException(404, "User not found")

        if body.name is not None:
            db.execute("UPDATE users SET name=? WHERE id=?", (body.name, user_id))
        if body.enabled is not None:
            db.execute("UPDATE users SET enabled=? WHERE id=?", (int(body.enabled), user_id))
        if body.note is not None:
            db.execute("UPDATE users SET note=? WHERE id=?", (body.note, user_id))
        db.commit()

    sync_users_to_xray()
    ok, err = restart_xray()
    return {"success": True, "xray_restarted": ok, "error": err}

@app.delete("/api/users/{user_id}")
def api_delete_user(user_id: int):
    with get_db() as db:
        row = db.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        if not row:
            raise HTTPException(404, "User not found")
        db.execute("DELETE FROM users WHERE id=?", (user_id,))
        db.commit()

    sync_users_to_xray()
    ok, err = restart_xray()
    return {"success": True, "xray_restarted": ok, "error": err}

@app.post("/api/xray/restart")
def api_restart_xray():
    ok, err = restart_xray()
    return {"success": ok, "error": err}
