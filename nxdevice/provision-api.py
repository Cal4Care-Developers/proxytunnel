#!/usr/bin/env python3
"""
RingQ NX Device Provisioning API
Listens on port 8099. Your existing UI calls this to install/reconfigure.

Endpoints:
  POST /api/configure   { domain, auth_key, lan_ip }  → runs install.sh
  GET  /api/status                                     → current config status
  POST /api/reconfigure { domain, auth_key, lan_ip }  → change PBX/key
"""

import json
import os
import subprocess
import sys
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

INSTALL_SH   = "/tmp/install.sh"
CONFIG_FILE  = "/root/ringqproxy/sip-proxy.yaml"
VERSION_FILE = "/root/ringqproxy/version.txt"
API_PORT     = 8099
INSTALL_URL  = "https://raw.githubusercontent.com/Cal4Care-Developers/proxytunnel/master/install.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

def read_yaml_key(key):
    """Read a single value from sip-proxy.yaml without external libs."""
    try:
        with open(CONFIG_FILE) as f:
            for line in f:
                stripped = line.strip()
                if stripped.startswith(key + ":"):
                    val = stripped.split(":", 1)[1].strip().strip('"\'')
                    return val
    except Exception:
        pass
    return ""

def service_status():
    try:
        r = subprocess.run(["systemctl", "is-active", "ringqproxy"],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except Exception:
        return "unknown"

def run_install(domain, auth_key, lan_ip, reconfigure=False):
    """Download and run install.sh non-interactively with env vars."""
    # Download latest install.sh
    dl = subprocess.run(
        ["curl", "-fsSL", INSTALL_URL, "-o", INSTALL_SH],
        capture_output=True, text=True, timeout=60
    )
    if dl.returncode != 0:
        return False, "Failed to download install.sh: " + dl.stderr

    os.chmod(INSTALL_SH, 0o755)

    env = os.environ.copy()
    env["RINGQ_DOMAIN"]   = domain
    env["RINGQ_AUTH_KEY"] = auth_key
    env["RINGQ_LAN_IP"]   = lan_ip

    cmd = [INSTALL_SH, "--yes"]
    if reconfigure:
        cmd = [INSTALL_SH, "--reconfigure"]

    result = subprocess.run(
        cmd, env=env,
        capture_output=True, text=True,
        timeout=300
    )
    return result.returncode == 0, result.stdout + result.stderr


# ── Request handler ───────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(f"[API] {self.address_string()} {fmt % args}")

    def send_json(self, code, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def parse_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except Exception:
            return {}

    # ── GET /api/status ───────────────────────────────────────────────────────
    def handle_status(self):
        configured = os.path.exists(CONFIG_FILE)
        data = {
            "configured": configured,
            "service":    service_status(),
            "version":    open(VERSION_FILE).read().strip()
                          if os.path.exists(VERSION_FILE) else "unknown",
        }
        if configured:
            data["pbx_domain"] = read_yaml_key("pbx-domain")
            data["pbx_api_url"] = read_yaml_key("pbx-api-url")
            data["device_id"]   = read_yaml_key("device-id")
            # Mask auth key — show only first 8 chars
            key = read_yaml_key("auth-key")
            data["auth_key_prefix"] = key[:8] + "..." if key else ""
        self.send_json(200, data)

    # ── POST /api/configure  OR  /api/reconfigure ─────────────────────────────
    def handle_configure(self, reconfigure=False):
        body = self.parse_body()
        domain   = body.get("domain",   "").strip()
        auth_key = body.get("auth_key", "").strip()
        lan_ip   = body.get("lan_ip",   "").strip()

        # Validate
        errors = []
        if not domain:
            errors.append("domain is required")
        if not auth_key:
            errors.append("auth_key is required")
        if not lan_ip:
            errors.append("lan_ip is required")
        if errors:
            self.send_json(400, {"success": False, "errors": errors})
            return

        print(f"[API] {'Reconfigure' if reconfigure else 'Configure'}: "
              f"domain={domain} lan_ip={lan_ip} key={auth_key[:8]}...")

        success, output = run_install(domain, auth_key, lan_ip, reconfigure)

        self.send_json(200 if success else 500, {
            "success": success,
            "output":  output,
            "status":  service_status(),
        })

    # ── Router ────────────────────────────────────────────────────────────────
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/status":
            self.handle_status()
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/configure":
            self.handle_configure(reconfigure=False)
        elif path == "/api/reconfigure":
            self.handle_configure(reconfigure=True)
        else:
            self.send_json(404, {"error": "not found"})


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if os.geteuid() != 0:
        print("ERROR: must run as root (needs to write config + start service)")
        sys.exit(1)

    port = int(os.environ.get("RINGQ_API_PORT", API_PORT))
    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"[API] RingQ Provisioning API listening on port {port}")
    print(f"[API] Endpoints:")
    print(f"[API]   GET  /api/status")
    print(f"[API]   POST /api/configure   {{domain, auth_key, lan_ip}}")
    print(f"[API]   POST /api/reconfigure {{domain, auth_key, lan_ip}}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[API] Stopped")
