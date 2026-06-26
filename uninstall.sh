#!/bin/bash
# =============================================================================
# RingQ NX Device Proxy -- Complete Uninstaller
# =============================================================================
# Removes:
#   - systemd service (stopped, disabled, deleted)
#   - /root/ringqproxy  (binary, config, logs, scripts)
#   - iptables rules added by install.sh
#   - /etc/systemd/system/ringqproxy.service
#   - Lock file /var/lock/ringqproxy-install.lock
#   - PATH entries added to /root/.bashrc  (optional)
#   - Go runtime /usr/local/go             (optional)
#   - apt packages installed by installer  (optional)
#
# Does NOT remove:
#   - Phone provisioning settings on the phones themselves
#   - Any data on the Cloud PBX (registrations expire naturally)
#   - Other system configuration not touched by install.sh
#
# Usage: chmod +x uninstall.sh && sudo ./uninstall.sh
# =============================================================================
set -euo pipefail

# ---- Colour helpers ---------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() { echo -e "\n${BOLD}${BLUE}--- $* ---${NC}"; }
ok()      { echo -e "  ${GREEN}DONE${NC} $*"; }
skip()    { echo -e "  ${CYAN}SKIP${NC} $* (not found)"; }

# ---- Constants --------------------------------------------------------------
SERVICE_NAME="ringqproxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_DIR="/root/ringqproxy"
LOCK_FILE="/var/lock/ringqproxy-install.lock"
GO_DIR="/usr/local/go"

# ---- Root check -------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo -e "${RED}[ERROR]${NC} Run as root: sudo $0"; exit 1; }

# ---- Banner -----------------------------------------------------------------
echo -e "${BOLD}${RED}"
cat << 'EOF'
  ____  _             ___    _   _ __  __
 |  _ \(_)_ __   __ _/ _ \  | \ | \ \/ /
 | |_) | | '_ \ / _` | | | | |  \| |\  /
 |  _ <| | | | | (_| | |_| | | |\  |/  \
 |_| \_\_|_| |_|\__, |\__\_\ |_| \_/_/\_\
                |___/
  NX Device Proxy -- Uninstaller
EOF
echo -e "${NC}"

# ---- Confirm ----------------------------------------------------------------
echo -e "${YELLOW}This will completely remove the RingQ NX Device Proxy from this machine.${NC}"
echo ""
echo -e "  Service   : ${CYAN}${SERVICE_NAME}${NC}"
echo -e "  Directory : ${CYAN}${INSTALL_DIR}${NC}"
echo -e "  Config    : ${CYAN}${INSTALL_DIR}/sip-proxy.yaml${NC}"
echo ""
read -rp "Are you sure you want to uninstall? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { info "Aborted -- nothing removed."; exit 0; }
echo ""

# ---- Optional removals (ask upfront) ----------------------------------------
REMOVE_GO=false
REMOVE_PACKAGES=false
REMOVE_BASHRC=false

read -rp "Also remove Go runtime (/usr/local/go)? [y/N]: " R
[[ "${R,,}" == "y" ]] && REMOVE_GO=true

read -rp "Also remove packages installed by install.sh (iptables-persistent etc.)? [y/N]: " R
[[ "${R,,}" == "y" ]] && REMOVE_PACKAGES=true

read -rp "Also remove PATH entries added to /root/.bashrc? [y/N]: " R
[[ "${R,,}" == "y" ]] && REMOVE_BASHRC=true

echo ""

# =============================================================================
# STEP 1 -- Stop and disable systemd service
# =============================================================================
section "Stopping Service"

if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    info "Sending OFFLINE status to PBX before stopping..."
    # Give the service 6 seconds to send the OFFLINE status via SIGTERM
    systemctl stop "${SERVICE_NAME}" &
    STOP_PID=$!
    sleep 6
    wait "${STOP_PID}" 2>/dev/null || true
    ok "Service stopped (OFFLINE status sent to PBX)"
else
    skip "Service ${SERVICE_NAME} was not running"
fi

if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    systemctl disable "${SERVICE_NAME}"
    ok "Service disabled (will not start on boot)"
else
    skip "Service was not enabled"
fi

# =============================================================================
# STEP 2 -- Remove systemd service file
# =============================================================================
section "Removing Service File"

if [[ -f "${SERVICE_FILE}" ]]; then
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
    ok "Removed: ${SERVICE_FILE}"
else
    skip "${SERVICE_FILE}"
fi

# =============================================================================
# STEP 3 -- Remove install directory
# =============================================================================
section "Removing Install Directory"

if [[ -d "${INSTALL_DIR}" ]]; then
    # Show what will be deleted
    echo -e "  Contents of ${INSTALL_DIR}:"
    ls -lh "${INSTALL_DIR}" 2>/dev/null | tail -n +2 | \
        awk '{printf "    %-40s %s\n", $NF, $5}' || true
    echo ""
    rm -rf "${INSTALL_DIR}"
    ok "Removed: ${INSTALL_DIR}"
else
    skip "${INSTALL_DIR} (already gone)"
fi

# =============================================================================
# STEP 4 -- Remove iptables rules added by install.sh
# =============================================================================
section "Removing iptables Rules"

# Helper: delete rule if it exists (suppress errors for non-existent rules)
ipt_del() {
    iptables -D "$@" 2>/dev/null && \
        echo -e "  ${GREEN}DONE${NC} Removed iptables: $*" || \
        echo -e "  ${CYAN}SKIP${NC} Rule not found: $*"
}

# INPUT rules (phone SIP ports + admin API)
ipt_del INPUT -p udp --dport 5060 -j ACCEPT \
    -m comment --comment "RingQ-phones-udp"
ipt_del INPUT -p tcp --dport 5061 -j ACCEPT \
    -m comment --comment "RingQ-phones-tcp"
ipt_del INPUT -s 192.168.0.0/16 -p tcp --dport 8899 -j ACCEPT \
    -m comment --comment "RingQ-admin-lan"
ipt_del INPUT -s 10.0.0.0/8    -p tcp --dport 8899 -j ACCEPT \
    -m comment --comment "RingQ-admin-lan"

# OUTPUT rules (tunnel + API)
ipt_del OUTPUT -p tcp --dport 6010 -j ACCEPT \
    -m comment --comment "RingQ-pbx-tunnel"
ipt_del OUTPUT -p tcp --dport 8443 -j ACCEPT \
    -m comment --comment "RingQ-pbx-api"
ipt_del OUTPUT -p tcp --dport 443  -j ACCEPT \
    -m comment --comment "RingQ-https"

# Save cleaned rules
if command -v iptables-save &>/dev/null; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ok "iptables rules saved (RingQ rules removed)"
fi

# =============================================================================
# STEP 5 -- Remove lock file
# =============================================================================
section "Removing Lock File"

[[ -f "${LOCK_FILE}" ]] && { rm -f "${LOCK_FILE}"; ok "Removed: ${LOCK_FILE}"; } || \
    skip "${LOCK_FILE}"

# =============================================================================
# STEP 6 -- Remove Go runtime (optional)
# =============================================================================
section "Go Runtime"

if $REMOVE_GO; then
    if [[ -d "${GO_DIR}" ]]; then
        rm -rf "${GO_DIR}"
        rm -rf /root/go
        ok "Removed: ${GO_DIR} and /root/go"
    else
        skip "${GO_DIR} (not found)"
    fi
else
    skip "Go runtime (kept -- you chose not to remove it)"
fi

# =============================================================================
# STEP 7 -- Remove .bashrc entries (optional)
# =============================================================================
section ".bashrc Cleanup"

if $REMOVE_BASHRC && [[ -f /root/.bashrc ]]; then
    # Remove the lines added by install.sh
    sed -i '/\/usr\/local\/go\/bin/d' /root/.bashrc
    sed -i '/GOPATH=\/root\/go/d' /root/.bashrc
    ok "Removed Go PATH entries from /root/.bashrc"
else
    skip ".bashrc entries (kept)"
fi

# =============================================================================
# STEP 8 -- Remove installed packages (optional)
# =============================================================================
section "apt Packages"

if $REMOVE_PACKAGES; then
    PKGS_TO_REMOVE=""
    for pkg in iptables-persistent netfilter-persistent; do
        dpkg -s "$pkg" &>/dev/null && PKGS_TO_REMOVE="${PKGS_TO_REMOVE} ${pkg}" || true
    done
    if [[ -n "${PKGS_TO_REMOVE}" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq ${PKGS_TO_REMOVE}
        ok "Removed packages:${PKGS_TO_REMOVE}"
    else
        skip "No installer packages found to remove"
    fi
    # Note: curl, git, ca-certificates are kept (commonly needed by other things)
    warn "curl, git, ca-certificates kept (used by other system components)"
else
    skip "apt packages (kept -- you chose not to remove them)"
fi

# =============================================================================
# Final Summary
# =============================================================================
section "Uninstall Complete"
echo ""
echo -e "${BOLD}${GREEN}RingQ NX Device Proxy has been completely removed.${NC}"
echo ""
echo -e "  ${GREEN}Removed:${NC}"
echo -e "    - systemd service ${SERVICE_NAME} (stopped, disabled, deleted)"
echo -e "    - Install directory ${INSTALL_DIR} (binary + config + scripts)"
echo -e "    - iptables rules added by RingQ installer"
echo -e "    - Lock file ${LOCK_FILE}"
$REMOVE_GO      && echo -e "    - Go runtime ${GO_DIR}"
$REMOVE_BASHRC  && echo -e "    - PATH entries in /root/.bashrc"
$REMOVE_PACKAGES && echo -e "    - apt packages (iptables-persistent, netfilter-persistent)"
echo ""
echo -e "  ${YELLOW}Not removed (not touched by installer):${NC}"
echo -e "    - Phone provisioning settings (change SIP server on each phone manually)"
echo -e "    - Cloud PBX registrations (will expire naturally within 10 minutes)"
echo -e "    - Cloud PBX tunnel_config entry (delete from RingQ portal if needed)"
echo ""
echo -e "  ${CYAN}To reinstall later:${NC}"
echo -e "    curl -fsSL https://raw.githubusercontent.com/Cal4Care-Developers/proxytunnel/master/install.sh | bash"
echo ""
