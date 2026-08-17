#!/bin/bash
# =============================================================================
# RingQ NX Device -- Provisioning API Setup
# Downloads and installs the provision API that your UI calls to configure
# the NX Device tunnel without needing SSH/PuTTY.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Cal4Care-Developers/proxytunnel/master/nxdevice/setup-provision-api.sh \
#     -o /tmp/setup-provision-api.sh && chmod +x /tmp/setup-provision-api.sh && sudo /tmp/setup-provision-api.sh
# =============================================================================
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }

BASE_URL="https://raw.githubusercontent.com/Cal4Care-Developers/proxytunnel/master/nxdevice"
API_BIN="/usr/local/bin/ringq-provision-api"
SVC_FILE="/etc/systemd/system/ringq-provision.service"
API_PORT=8099

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}OK${NC}   $*"; }
info() { echo -e "  ${YELLOW}...${NC}  $*"; }

echo ""
echo "=== RingQ Provisioning API Setup ==="
echo ""

# ── 1. Download provision-api.py ─────────────────────────────────────────────
info "Downloading provision-api.py..."
curl -fsSL "${BASE_URL}/provision-api.py" -o "${API_BIN}"
chmod +x "${API_BIN}"
ok "Installed: ${API_BIN}"

# ── 2. Download and install systemd service ───────────────────────────────────
info "Downloading provision-api.service..."
curl -fsSL "${BASE_URL}/provision-api.service" -o "${SVC_FILE}"
ok "Installed: ${SVC_FILE}"

# ── 3. Reload systemd and enable + start service ──────────────────────────────
info "Enabling and starting service..."
systemctl daemon-reload
systemctl enable ringq-provision
systemctl restart ringq-provision
sleep 2

# ── 4. Verify ────────────────────────────────────────────────────────────────
if systemctl is-active --quiet ringq-provision; then
    ok "Service running (ringq-provision)"
else
    echo "  ERROR: Service failed to start"
    journalctl -u ringq-provision --no-pager -n 10
    exit 1
fi

# ── 5. Quick API test ─────────────────────────────────────────────────────────
info "Testing API..."
sleep 1
STATUS=$(curl -sf http://127.0.0.1:${API_PORT}/api/status 2>/dev/null || echo "failed")
if echo "${STATUS}" | grep -q "configured"; then
    ok "API responding on port ${API_PORT}"
else
    echo "  WARN: API not responding yet (check: journalctl -u ringq-provision -f)"
fi

echo ""
echo "=== Done ==="
echo ""
echo "  API port : ${API_PORT}"
echo "  Endpoints:"
echo "    GET  http://<device-ip>:${API_PORT}/api/status"
echo "    POST http://<device-ip>:${API_PORT}/api/configure"
echo "    POST http://<device-ip>:${API_PORT}/api/reconfigure"
echo ""
echo "  Logs  : journalctl -u ringq-provision -f"
echo "  Status: systemctl status ringq-provision"
echo ""
