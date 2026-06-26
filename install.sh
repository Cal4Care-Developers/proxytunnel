#!/bin/bash
# =============================================================================
# RingQ NX Device Proxy -- Idempotent Production Installer  v3.0
# =============================================================================
# Safe to run multiple times:
#   * Re-run after partial failure    -> picks up where it left off
#   * Re-run on already-installed box -> skips everything already done
#   * Re-run after config change      -> updates only what changed
#
# Flags:
#   --yes         Use existing config; skip all prompts (for CI / re-install)
#   --reconfigure Force re-prompt for all config values
#   --reinstall   Force re-download Go and re-clone repo even if current
#
# GitHub : https://github.com/Cal4Care-Developers/proxytunnel.git
# Install: /root/ringqproxy
# Service: ringqproxy (systemd)
# =============================================================================
set -euo pipefail

# ── Parse flags ───────────────────────────────────────────────────────────
OPT_YES=false
OPT_RECONFIGURE=false
OPT_REINSTALL=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y)          OPT_YES=true ;;
        --reconfigure|-r)  OPT_RECONFIGURE=true ;;
        --reinstall)       OPT_REINSTALL=true ;;
        --help|-h)
            echo "Usage: $0 [--yes] [--reconfigure] [--reinstall]"
            echo "  --yes          Non-interactive: use existing config"
            echo "  --reconfigure  Re-prompt all config values"
            echo "  --reinstall    Force re-download Go + re-clone repo"
            exit 0 ;;
        *) echo "Unknown flag: $arg  (use --help)"; exit 1 ;;
    esac
done

# ── Colour helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
skip()    { echo -e "  ${CYAN}↩${NC} $* (already done -- skipping)"; }

# ── Constants ─────────────────────────────────────────────────────────────
REPO_URL="https://github.com/Cal4Care-Developers/proxytunnel.git"
INSTALL_DIR="/root/ringqproxy"
BUILD_DIR="/tmp/ringqproxy-build"
SERVICE_NAME="ringqproxy"
BINARY_NAME="sipproxy"
CONFIG_FILE="${INSTALL_DIR}/sip-proxy.yaml"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOCK_FILE="/var/lock/ringqproxy-install.lock"
ROLLBACK_BINARY="${INSTALL_DIR}/${BINARY_NAME}.rollback"
GO_MIN_MAJOR=1; GO_MIN_MINOR=21
GO_INSTALL_VERSION="1.22.4"
GO_ARCH="amd64"

# ── Root check ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { error "Run as root: sudo $0"; exit 1; }

# ── Lock file -- prevent concurrent installs ──────────────────────────────
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    error "Another install is already running (lock: ${LOCK_FILE})"
    exit 1
fi
# Lock is released automatically when the script exits (fd 200 closes)

# ── Banner ────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ____  _             ___    _   _ __  __
 |  _ \(_)_ __   __ _/ _ \  | \ | \ \/ /
 | |_) | | '_ \ / _` | | | | |  \| |\  /
 |  _ <| | | | | (_| | |_| | | |\  |/  \
 |_| \_\_|_| |_|\__, |\__\_\ |_| \_/_/\_\
                |___/
  NX Device Proxy Installer  v3.0  (idempotent)
EOF
echo -e "${NC}"

# ── Cleanup / rollback trap ───────────────────────────────────────────────
# Called automatically if any command exits non-zero (set -e).
INSTALL_PHASE="init"
cleanup_on_error() {
    local exit_code=$?
    echo ""
    error "Installation failed during phase: ${INSTALL_PHASE} (exit code: ${exit_code})"
    echo ""

    # Remove incomplete new binary (never disturb existing one)
    [[ -f "${INSTALL_DIR}/${BINARY_NAME}.new" ]] && \
        rm -f "${INSTALL_DIR}/${BINARY_NAME}.new" && \
        warn "Removed incomplete binary (.new)"

    # Restore rollback binary if we replaced it
    if [[ -f "${ROLLBACK_BINARY}" ]] && [[ ! -f "${INSTALL_DIR}/${BINARY_NAME}" ]]; then
        mv "${ROLLBACK_BINARY}" "${INSTALL_DIR}/${BINARY_NAME}"
        warn "Restored previous binary from rollback copy"
        systemctl start "${SERVICE_NAME}" 2>/dev/null && \
            warn "Previous version restarted" || true
    fi

    # Remove partial build dir
    rm -rf "${BUILD_DIR}"

    echo ""
    echo -e "${YELLOW}Re-run the installer to try again -- completed steps will be skipped.${NC}"
    exit "${exit_code}"
}
trap cleanup_on_error ERR

# ── OS detection ──────────────────────────────────────────────────────────
section "System Check"
INSTALL_PHASE="system-check"

[[ -f /etc/os-release ]] || { error "Cannot detect OS. Requires Debian/Ubuntu."; exit 1; }
. /etc/os-release
OS_ID="${ID:-unknown}"
case "${OS_ID}" in
    debian|ubuntu|raspbian) ok "OS: ${NAME} ${VERSION_ID}" ;;
    *)
        warn "OS '${NAME}' not officially tested (Debian/Ubuntu recommended)."
        $OPT_YES || { read -rp "Continue anyway? [y/N]: " C; [[ "${C,,}" == "y" ]] || exit 1; }
        ;;
esac

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  GO_ARCH="amd64" ;;
    aarch64) GO_ARCH="arm64" ;;
    armv7l)  GO_ARCH="armv6l" ;;
    *) error "Unsupported architecture: $ARCH"; exit 1 ;;
esac
ok "Architecture: ${ARCH} -> Go GOARCH: ${GO_ARCH}"

# Machine ID (device-id -- stable, unique per machine)
DEVICE_ID=""
if [[ -f /etc/machine-id ]]; then
    DEVICE_ID=$(tr -d '[:space:]' < /etc/machine-id)
    ok "Device ID: ${DEVICE_ID}"
else
    warn "/etc/machine-id not found -- generating"
    systemd-machine-id-setup 2>/dev/null || true
    DEVICE_ID=$(tr -d '[:space:]' < /etc/machine-id 2>/dev/null || echo "")
    [[ -n "$DEVICE_ID" ]] || { error "Cannot determine device-id"; exit 1; }
fi

# ── Read existing config (for idempotent re-runs) ─────────────────────────
# If config exists, extract current values to pre-populate prompts.
# The user only needs to press Enter to keep existing values.
EXISTING_PBX_DOMAIN=""; EXISTING_AUTH_KEY=""; EXISTING_API_URL=""
EXISTING_PBX_TUNNEL_HOST=""; EXISTING_TUNNEL_PORT=""
EXISTING_LAN_IP=""; EXISTING_PUBLIC_IP=""
EXISTING_UDP_PORT=""; EXISTING_TCP_PORT=""; EXISTING_ADMIN_PORT=""

read_yaml_value() {
    # read_yaml_value KEY FILE  -- returns value after "key: " stripping quotes
    local key="$1" file="$2"
    grep -m1 "^[[:space:]]*${key}:" "$file" 2>/dev/null | \
        sed 's/.*: *//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' | \
        tr -d '[:space:]' || echo ""
}

CONFIG_EXISTS=false
if [[ -f "${CONFIG_FILE}" ]]; then
    CONFIG_EXISTS=true
    EXISTING_PBX_DOMAIN=$(read_yaml_value "pbx-domain"   "${CONFIG_FILE}")
    EXISTING_AUTH_KEY=$(read_yaml_value   "auth-key"      "${CONFIG_FILE}")
    EXISTING_API_URL=$(read_yaml_value    "pbx-api-url"   "${CONFIG_FILE}")
    # Extract from backends line: "address: tcp://HOST:PORT"
    EXISTING_PBX_TUNNEL_HOST=$(grep -m1 'address: tcp://' "${CONFIG_FILE}" 2>/dev/null | \
        sed 's|.*tcp://||; s|:.*||' || echo "")
    EXISTING_TUNNEL_PORT=$(grep -m1 'address: tcp://' "${CONFIG_FILE}" 2>/dev/null | \
        sed 's|.*:||; s|".*||' || echo "")
    # Extract from "address: X.X.X.X" (listen address -- first occurrence)
    EXISTING_LAN_IP=$(read_yaml_value "address" "${CONFIG_FILE}")
    # Extract from "via: udp://IP:PORT"
    EXISTING_PUBLIC_IP=$(grep -m1 'via: udp://' "${CONFIG_FILE}" 2>/dev/null | \
        sed 's|.*udp://||; s|:.*||; s|"||g' || echo "")
    EXISTING_UDP_PORT=$(grep -m1 'udp-port' "${CONFIG_FILE}" 2>/dev/null | \
        grep -oP '\d+' | head -1 || echo "")
    EXISTING_TCP_PORT=$(grep -m1 'tcp-port' "${CONFIG_FILE}" 2>/dev/null | \
        grep -oP '\d+' | head -1 || echo "")
    EXISTING_ADMIN_PORT=$(grep -m1 'addr:' "${CONFIG_FILE}" 2>/dev/null | \
        grep -oP ':\d+' | head -1 | tr -d ':' || echo "")
    info "Found existing config: ${CONFIG_FILE}"
fi

# ── Interactive configuration ─────────────────────────────────────────────
section "Configuration"

# Detect IPs for defaults (only if no existing values)
DETECTED_LAN_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' 2>/dev/null | \
    grep -v '^172\.' | head -1 || echo "0.0.0.0")
DETECTED_PUBLIC_IP=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
                     curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "")

# Resolve defaults: existing config wins > auto-detected > hardcoded
D_PBX_DOMAIN="${EXISTING_PBX_DOMAIN:-}"
D_AUTH_KEY="${EXISTING_AUTH_KEY:-}"
D_API_URL="${EXISTING_API_URL:-}"
D_PBX_TUNNEL_HOST="${EXISTING_PBX_TUNNEL_HOST:-}"
D_TUNNEL_PORT="${EXISTING_TUNNEL_PORT:-6010}"
D_LAN_IP="${EXISTING_LAN_IP:-${DETECTED_LAN_IP}}"
D_PUBLIC_IP="${EXISTING_PUBLIC_IP:-${DETECTED_PUBLIC_IP:-$D_LAN_IP}}"
D_UDP_PORT="${EXISTING_UDP_PORT:-5060}"
D_TCP_PORT="${EXISTING_TCP_PORT:-5061}"
D_ADMIN_PORT="${EXISTING_ADMIN_PORT:-8899}"

prompt() {
    # prompt VAR_NAME "Question" "default_value"
    local varname="$1" question="$2" default="$3"
    if $OPT_YES && [[ -n "$default" ]]; then
        printf -v "$varname" '%s' "$default"
        echo -e "  ${CYAN}[auto]${NC} ${question}: ${YELLOW}${default}${NC}"
    else
        local def_hint=""
        [[ -n "$default" ]] && def_hint=" [${default}]"
        read -rp "  ${question}${def_hint}: " val
        val="${val:-$default}"
        [[ -n "$val" ]] || { error "${question} is required"; exit 1; }
        printf -v "$varname" '%s' "$val"
    fi
}

if $OPT_YES && $CONFIG_EXISTS && ! $OPT_RECONFIGURE; then
    echo -e "${CYAN}Using existing configuration (--yes mode). Use --reconfigure to change values.${NC}"
else
    if $CONFIG_EXISTS && ! $OPT_RECONFIGURE; then
        echo -e "${CYAN}Existing config found. Press Enter to keep current values.${NC}\n"
    fi
    prompt PBX_DOMAIN   "PBX Domain (e.g. customer.ringq.ai)"      "${D_PBX_DOMAIN}"
    prompt AUTH_KEY     "Tunnel Auth Key (from RingQ portal)"       "${D_AUTH_KEY}"
    D_API_URL="${D_API_URL:-https://${D_PBX_DOMAIN}:8443}"
    prompt PBX_API_URL  "PBX API URL"                               "${D_API_URL}"
    prompt PBX_TUNNEL_HOST "PBX Tunnel IP or hostname"              "${D_PBX_TUNNEL_HOST:-${D_PBX_DOMAIN}}"
    prompt TUNNEL_PORT  "PBX Tunnel TCP port"                       "${D_TUNNEL_PORT}"
    prompt LAN_IP       "NX Device LAN listen address"              "${D_LAN_IP}"
    prompt PUBLIC_IP    "NX Device Public IP"                       "${D_PUBLIC_IP}"
    prompt UDP_PORT     "UDP SIP port for phones"                   "${D_UDP_PORT}"
    prompt TCP_PORT     "TCP SIP port for phones"                   "${D_TCP_PORT}"
    prompt ADMIN_PORT   "Admin API port"                            "${D_ADMIN_PORT}"
fi

# If --yes with existing config, use the read values directly
if $OPT_YES && $CONFIG_EXISTS && ! $OPT_RECONFIGURE; then
    PBX_DOMAIN="${D_PBX_DOMAIN}";         AUTH_KEY="${D_AUTH_KEY}"
    PBX_API_URL="${D_API_URL}";           PBX_TUNNEL_HOST="${D_PBX_TUNNEL_HOST}"
    TUNNEL_PORT="${D_TUNNEL_PORT}";       LAN_IP="${D_LAN_IP}"
    PUBLIC_IP="${D_PUBLIC_IP}";           UDP_PORT="${D_UDP_PORT}"
    TCP_PORT="${D_TCP_PORT}";             ADMIN_PORT="${D_ADMIN_PORT}"
fi

# Validate required fields
[[ -n "${PBX_DOMAIN:-}" ]]  || { error "PBX Domain is required"; exit 1; }
[[ -n "${AUTH_KEY:-}" ]]    || { error "Auth Key is required"; exit 1; }
[[ -n "${LAN_IP:-}" ]]      || { error "LAN IP is required"; exit 1; }

# Confirm (skip in --yes mode)
if ! $OPT_YES; then
    echo ""
    echo -e "${BOLD}${CYAN}Configuration Summary:${NC}"
    echo -e "  PBX Domain    : ${YELLOW}${PBX_DOMAIN}${NC}"
    echo -e "  Auth Key      : ${YELLOW}${AUTH_KEY:0:12}...${NC}"
    echo -e "  PBX API URL   : ${YELLOW}${PBX_API_URL}${NC}"
    echo -e "  PBX Tunnel    : ${YELLOW}tcp://${PBX_TUNNEL_HOST}:${TUNNEL_PORT}${NC}"
    echo -e "  NX LAN IP     : ${YELLOW}${LAN_IP}${NC}"
    echo -e "  NX Public IP  : ${YELLOW}${PUBLIC_IP}${NC}"
    echo -e "  Phone ports   : ${YELLOW}UDP/${UDP_PORT}, TCP/${TCP_PORT}${NC}"
    echo -e "  Device ID     : ${YELLOW}${DEVICE_ID}${NC}"
    echo ""
    read -rp "Proceed? [Y/n]: " CONFIRM
    [[ "${CONFIRM,,}" != "n" ]] || { info "Aborted."; exit 0; }
fi

# ── Install system packages (idempotent -- apt skips if already installed) ─
section "System Dependencies"
INSTALL_PHASE="system-packages"

NEED_PKG=()
for pkg in git curl ca-certificates iptables-persistent netfilter-persistent; do
    dpkg -s "$pkg" &>/dev/null 2>&1 && skip "Package: $pkg" || NEED_PKG+=("$pkg")
done

if [[ ${#NEED_PKG[@]} -gt 0 ]]; then
    info "Installing: ${NEED_PKG[*]}"
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${NEED_PKG[@]}"
    ok "Packages installed: ${NEED_PKG[*]}"
fi

# ── Install Go (idempotent -- skip if correct version already present) ────
section "Go Language Runtime"
INSTALL_PHASE="go-install"

export PATH="/usr/local/go/bin:${PATH}"
export GOPATH="/root/go"

go_version_ok() {
    command -v go &>/dev/null || return 1
    local cur major minor
    cur=$(go version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
    major=$(echo "$cur" | cut -d. -f1)
    minor=$(echo "$cur" | cut -d. -f2)
    (( major > GO_MIN_MAJOR )) || (( major == GO_MIN_MAJOR && minor >= GO_MIN_MINOR ))
}

if go_version_ok && ! $OPT_REINSTALL; then
    skip "Go $(go version | awk '{print $3}') already installed and meets minimum ${GO_MIN_MAJOR}.${GO_MIN_MINOR}"
else
    GO_TAR="go${GO_INSTALL_VERSION}.linux-${GO_ARCH}.tar.gz"
    GO_URL="https://go.dev/dl/${GO_TAR}"
    GO_TMP="/tmp/${GO_TAR}"

    # Download only if file not already cached from a previous attempt
    if [[ -f "${GO_TMP}" ]]; then
        info "Using cached Go tarball: ${GO_TMP}"
    else
        info "Downloading Go ${GO_INSTALL_VERSION} for ${GO_ARCH}..."
        curl -fsSL --retry 3 --retry-delay 5 "${GO_URL}" -o "${GO_TMP}"
    fi

    info "Installing Go ${GO_INSTALL_VERSION}..."
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "${GO_TMP}"
    rm -f "${GO_TMP}"    # remove cache after successful extract

    ok "Go ${GO_INSTALL_VERSION} installed to /usr/local/go"
fi

go_version_ok || { error "Go still not meeting minimum version after install"; exit 1; }
go version | awk '{print $3}' | xargs -I{} ok "Active Go: {}"

# Persist PATH for root's future shells
grep -q '/usr/local/go/bin' /root/.bashrc 2>/dev/null || {
    echo 'export PATH="/usr/local/go/bin:$PATH"' >> /root/.bashrc
    echo 'export GOPATH="/root/go"'              >> /root/.bashrc
}

# ── Create install directory ──────────────────────────────────────────────
section "Install Directory"
INSTALL_PHASE="directory"

if [[ -d "${INSTALL_DIR}" ]]; then
    skip "Directory ${INSTALL_DIR} already exists"
else
    mkdir -p "${INSTALL_DIR}"
    chmod 700 "${INSTALL_DIR}"
    ok "Created: ${INSTALL_DIR}"
fi

# ── Clone and build (with atomic binary replacement) ──────────────────────
section "Build SIP Proxy"
INSTALL_PHASE="build"

# Determine if we need to rebuild
NEED_BUILD=true
CURRENT_VERSION=""
NEW_VERSION=""

# Get latest remote commit hash (lightweight)
REMOTE_HASH=$(git ls-remote "${REPO_URL}" HEAD 2>/dev/null | awk '{print substr($1,1,7)}' || echo "unknown")
[[ -f "${INSTALL_DIR}/version.txt" ]] && CURRENT_VERSION=$(cat "${INSTALL_DIR}/version.txt")

if [[ "${CURRENT_VERSION}" == "${REMOTE_HASH}" ]] && \
   [[ -x "${INSTALL_DIR}/${BINARY_NAME}" ]] && \
   ! $OPT_REINSTALL; then
    skip "Binary is up to date (version: ${CURRENT_VERSION})"
    NEED_BUILD=false
else
    if [[ -n "${CURRENT_VERSION}" ]]; then
        info "Update available: ${CURRENT_VERSION} -> ${REMOTE_HASH}"
    else
        info "Building from ${REPO_URL}..."
    fi
fi

if $NEED_BUILD; then
    # Stop service ONLY while we have the old binary safely backed up
    if [[ -x "${INSTALL_DIR}/${BINARY_NAME}" ]]; then
        cp "${INSTALL_DIR}/${BINARY_NAME}" "${ROLLBACK_BINARY}"
        ok "Rollback copy saved: ${ROLLBACK_BINARY}"
    fi
    systemctl stop "${SERVICE_NAME}" 2>/dev/null && info "Service stopped" || true

    # Fresh build directory (clean any partial state from prior failed attempt)
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"

    info "Cloning repository..."
    git clone --depth 1 "${REPO_URL}" "${BUILD_DIR}" 2>&1 | grep -E 'Cloning|done\.' || true
    NEW_VERSION=$(git -C "${BUILD_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    ok "Cloned at commit: ${NEW_VERSION}"

    info "Building binary..."
    cd "${BUILD_DIR}"
    GOOS=linux GOARCH=$(go env GOARCH) \
        go build -ldflags="-s -w" -o "${INSTALL_DIR}/${BINARY_NAME}.new" .

    # Verify the new binary is valid before replacing
    if [[ ! -x "${INSTALL_DIR}/${BINARY_NAME}.new" ]]; then
        error "Build produced no executable"
        exit 1
    fi
    NEW_SIZE=$(du -sh "${INSTALL_DIR}/${BINARY_NAME}.new" | cut -f1)
    ok "Binary built: ${NEW_SIZE}"

    # Atomic replacement: mv is atomic on same filesystem
    mv "${INSTALL_DIR}/${BINARY_NAME}.new" "${INSTALL_DIR}/${BINARY_NAME}"
    echo "${NEW_VERSION}" > "${INSTALL_DIR}/version.txt"
    rm -f "${ROLLBACK_BINARY}"    # build succeeded; no longer need rollback
    ok "Binary installed: ${INSTALL_DIR}/${BINARY_NAME} (${NEW_VERSION})"

    # Cleanup build dir
    rm -rf "${BUILD_DIR}"
    cd /
fi

# ── Write config (only if changed or new) ────────────────────────────────
section "Configuration File"
INSTALL_PHASE="config"

# Build the canonical config we want
DESIRED_CONFIG="${INSTALL_DIR}/sip-proxy.yaml.desired"
cat > "${DESIRED_CONFIG}" << YAML
# RingQ NX Device SIP Proxy Configuration
# Generated: $(date)
# Edit this file and run: systemctl restart ${SERVICE_NAME}

admin:
  addr: "${LAN_IP}:${ADMIN_PORT}"

proxies:
  - name: "RingQ-Proxy"
    auth-key: "${AUTH_KEY}"
    device-id: "${DEVICE_ID}"
    pbx-domain: "${PBX_DOMAIN}"
    pbx-api-url: "${PBX_API_URL}"
    dialog-timeout: 1200
    must-record-route: true
    keep-next-hop-route: "no"

    listens:
      - address: "${LAN_IP}"
        udp-port: ${UDP_PORT}
        tcp-port: ${TCP_PORT}
        via: "udp://${PUBLIC_IP}:${UDP_PORT}"
        backends:
          - address: "tcp://${PBX_TUNNEL_HOST}:${TUNNEL_PORT}"

    route:
      - dests: ["${PBX_TUNNEL_HOST}"]
        protocol: tcp
        nexthop: "${PBX_TUNNEL_HOST}:${TUNNEL_PORT}"
      - dests: ["default"]
        protocol: tcp
        nexthop: "${PBX_TUNNEL_HOST}:${TUNNEL_PORT}"

    hosts:
      - name: "${PBX_TUNNEL_HOST}"
        ip: "${PBX_TUNNEL_HOST}"
      - name: "${LAN_IP},${PUBLIC_IP}"
        ip: "${LAN_IP}"

hosts:
  - name: "${PBX_TUNNEL_HOST}"
    ip: "${PBX_TUNNEL_HOST}"
  - name: "${LAN_IP},${PUBLIC_IP}"
    ip: "${LAN_IP}"
YAML

# Compare with existing (ignore the "Generated:" timestamp line)
CONFIG_CHANGED=true
if [[ -f "${CONFIG_FILE}" ]]; then
    # Strip the timestamp comment line before comparing
    if diff <(grep -v '^# Generated:' "${CONFIG_FILE}") \
            <(grep -v '^# Generated:' "${DESIRED_CONFIG}") &>/dev/null; then
        CONFIG_CHANGED=false
    fi
fi

if $CONFIG_CHANGED; then
    # Backup existing config before overwriting
    if [[ -f "${CONFIG_FILE}" ]]; then
        BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "${CONFIG_FILE}" "${BACKUP}"
        ok "Previous config backed up: ${BACKUP}"
    fi
    cp "${DESIRED_CONFIG}" "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"   # auth-key is sensitive
    ok "Config written: ${CONFIG_FILE}"
else
    skip "Config unchanged: ${CONFIG_FILE}"
fi
rm -f "${DESIRED_CONFIG}"

# ── systemd service (idempotent) ──────────────────────────────────────────
section "systemd Service"
INSTALL_PHASE="service"

DESIRED_SERVICE="/tmp/ringqproxy.service.desired"
cat > "${DESIRED_SERVICE}" << SYSTEMD
[Unit]
Description=RingQ NX Device SIP Proxy
Documentation=https://github.com/Cal4Care-Developers/proxytunnel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/${BINARY_NAME} -c ${CONFIG_FILE} --log-level Info
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}
PrivateTmp=yes
LimitNOFILE=65536
LimitNPROC=512

[Install]
WantedBy=multi-user.target
SYSTEMD

SERVICE_CHANGED=false
if [[ ! -f "${SERVICE_FILE}" ]] || \
   ! diff -q "${DESIRED_SERVICE}" "${SERVICE_FILE}" &>/dev/null; then
    SERVICE_CHANGED=true
    cp "${DESIRED_SERVICE}" "${SERVICE_FILE}"
    systemctl daemon-reload
    ok "Service file updated and daemon reloaded"
else
    skip "Service file unchanged"
fi
rm -f "${DESIRED_SERVICE}"

# Ensure service is enabled (idempotent)
if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    skip "Service already enabled"
else
    systemctl enable "${SERVICE_NAME}"
    ok "Service enabled (auto-start on boot)"
fi

# ── iptables (each rule checked before adding) ────────────────────────────
section "Firewall (iptables)"
INSTALL_PHASE="iptables"

# Helper: add rule only if it doesn't exist
ipt_add() {
    iptables -C "$@" 2>/dev/null && \
        echo -e "  ${CYAN}↩${NC} iptables rule already exists -- skipping" || \
        { iptables -A "$@"; ok "Added: iptables -A $*"; }
}

ipt_add INPUT -i lo -j ACCEPT
ipt_add INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ipt_add INPUT -p udp --dport "${UDP_PORT}" -j ACCEPT \
    -m comment --comment "RingQ: SIP UDP from phones"
ipt_add INPUT -p tcp --dport "${TCP_PORT}" -j ACCEPT \
    -m comment --comment "RingQ: SIP TCP from phones"
ipt_add INPUT -s 192.168.0.0/16 -p tcp --dport "${ADMIN_PORT}" -j ACCEPT \
    -m comment --comment "RingQ: admin API LAN"
ipt_add INPUT -s 10.0.0.0/8 -p tcp --dport "${ADMIN_PORT}" -j ACCEPT \
    -m comment --comment "RingQ: admin API LAN"
ipt_add OUTPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT \
    -m comment --comment "RingQ: tunnel to PBX"
ipt_add OUTPUT -p tcp --dport 8443 -j ACCEPT \
    -m comment --comment "RingQ: PBX REST API"
ipt_add OUTPUT -p tcp --dport 443  -j ACCEPT \
    -m comment --comment "RingQ: HTTPS"

# Save rules
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
ok "iptables rules persisted to /etc/iptables/rules.v4"
systemctl enable netfilter-persistent 2>/dev/null || true

# ── Permissions ───────────────────────────────────────────────────────────
section "Permissions"
INSTALL_PHASE="permissions"

chmod 700 "${INSTALL_DIR}"
chmod 700 "${INSTALL_DIR}/${BINARY_NAME}"
chmod 600 "${CONFIG_FILE}"
[[ -f "${INSTALL_DIR}/version.txt" ]] && chmod 644 "${INSTALL_DIR}/version.txt"
ok "Permissions set"

# ── Update script ─────────────────────────────────────────────────────────
# Regenerate only if different
DESIRED_UPDATE="/tmp/ringqproxy-update.desired"
cat > "${DESIRED_UPDATE}" << 'UPDATESCRIPT'
#!/bin/bash
# RingQ NX Device Proxy -- Update to latest version
set -euo pipefail
REPO_URL="https://github.com/Cal4Care-Developers/proxytunnel.git"
INSTALL_DIR="/root/ringqproxy"
BUILD_DIR="/tmp/ringqproxy-build"
BINARY_NAME="sipproxy"
SERVICE_NAME="ringqproxy"
ROLLBACK="${INSTALL_DIR}/${BINARY_NAME}.rollback"

export PATH="/usr/local/go/bin:$PATH"
export GOPATH="/root/go"

# Check if already on latest
REMOTE=$(git ls-remote "${REPO_URL}" HEAD 2>/dev/null | awk '{print substr($1,1,7)}' || echo "")
CURRENT=$(cat "${INSTALL_DIR}/version.txt" 2>/dev/null || echo "")
if [[ -n "$REMOTE" && "$REMOTE" == "$CURRENT" ]]; then
    echo "[UPDATE] Already on latest version: ${CURRENT}"
    exit 0
fi
echo "[UPDATE] Updating ${CURRENT} -> ${REMOTE}..."

# Backup and stop
[[ -x "${INSTALL_DIR}/${BINARY_NAME}" ]] && \
    cp "${INSTALL_DIR}/${BINARY_NAME}" "${ROLLBACK}"
systemctl stop "$SERVICE_NAME" || true

# Build new binary to temp location
rm -rf "$BUILD_DIR"
git clone --depth 1 "$REPO_URL" "$BUILD_DIR"
NEW_VER=$(git -C "$BUILD_DIR" rev-parse --short HEAD)
cd "$BUILD_DIR"
GOOS=linux go build -ldflags="-s -w" -o "${INSTALL_DIR}/${BINARY_NAME}.new" .

# Atomic replace
mv "${INSTALL_DIR}/${BINARY_NAME}.new" "${INSTALL_DIR}/${BINARY_NAME}"
echo "$NEW_VER" > "${INSTALL_DIR}/version.txt"
rm -f "${ROLLBACK}" "$BUILD_DIR" 2>/dev/null || true

systemctl start "$SERVICE_NAME"
sleep 2
systemctl is-active --quiet "$SERVICE_NAME" && \
    echo "[UPDATE] OK -- running version: $NEW_VER" || \
    { echo "[UPDATE] Service failed -- check: journalctl -u $SERVICE_NAME -n 30"; exit 1; }
UPDATESCRIPT

UPDATE_SCRIPT="${INSTALL_DIR}/update.sh"
if [[ ! -f "${UPDATE_SCRIPT}" ]] || \
   ! diff -q "${DESIRED_UPDATE}" "${UPDATE_SCRIPT}" &>/dev/null; then
    cp "${DESIRED_UPDATE}" "${UPDATE_SCRIPT}"
    chmod +x "${UPDATE_SCRIPT}"
    ok "Update script: ${UPDATE_SCRIPT}"
else
    skip "Update script unchanged"
fi
rm -f "${DESIRED_UPDATE}"

# ── Start / restart service ───────────────────────────────────────────────
section "Starting Service"
INSTALL_PHASE="start"

if systemctl is-active --quiet "${SERVICE_NAME}"; then
    if $NEED_BUILD || $CONFIG_CHANGED || $SERVICE_CHANGED; then
        systemctl restart "${SERVICE_NAME}"
        ok "Service restarted (config/binary changed)"
    else
        skip "Service already running and nothing changed"
    fi
else
    systemctl start "${SERVICE_NAME}"
    ok "Service started"
fi

# Wait for service to settle
sleep 3

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    error "Service is NOT running after start. Last 30 log lines:"
    journalctl -u "${SERVICE_NAME}" --no-pager -n 30
    exit 1
fi
ok "Service is active"

# Check bind result in recent logs
sleep 2
RECENT_LOG=$(journalctl -u "${SERVICE_NAME}" --no-pager -n 30 --since "15 seconds ago" 2>/dev/null || "")
if echo "${RECENT_LOG}" | grep -q "bind successful"; then
    ok "Tunnel authenticated with PBX (ONLINE)"
elif echo "${RECENT_LOG}" | grep -q "bind rejected\|auth failed\|BLOCKED"; then
    warn "Tunnel authentication FAILED"
    warn "Edit ${CONFIG_FILE} (check auth-key + pbx-domain)"
    warn "Then: systemctl restart ${SERVICE_NAME}"
else
    info "Bind result pending -- check: journalctl -u ${SERVICE_NAME} -f"
fi

# ── Final summary ─────────────────────────────────────────────────────────
section "Installation Complete"
echo ""
echo -e "${BOLD}${GREEN}RingQ NX Device Proxy is installed and running.${NC}"
echo ""
echo -e "${BOLD}Files:${NC}"
echo -e "  Binary  : ${CYAN}${INSTALL_DIR}/${BINARY_NAME}${NC}"
echo -e "  Config  : ${CYAN}${CONFIG_FILE}${NC}"
echo -e "  Service : ${CYAN}${SERVICE_FILE}${NC}"
echo -e "  Version : ${CYAN}$(cat ${INSTALL_DIR}/version.txt 2>/dev/null || echo 'unknown')${NC}"
echo ""
echo -e "${BOLD}Commands:${NC}"
echo -e "  Live logs  : ${YELLOW}journalctl -u ${SERVICE_NAME} -f${NC}"
echo -e "  Status     : ${YELLOW}systemctl status ${SERVICE_NAME}${NC}"
echo -e "  Restart    : ${YELLOW}systemctl restart ${SERVICE_NAME}${NC}"
echo -e "  Edit config: ${YELLOW}nano ${CONFIG_FILE}${NC}"
echo -e "  Update     : ${YELLOW}${INSTALL_DIR}/update.sh${NC}"
echo -e "  Re-install : ${YELLOW}$0 --yes${NC}   (keeps config)"
echo -e "  Reconfigure: ${YELLOW}$0 --reconfigure${NC}"
echo ""
echo -e "${BOLD}Phone Provisioning:${NC}"
echo -e "  SIP Server  : ${YELLOW}${LAN_IP}${NC}"
echo -e "  SIP Port    : ${YELLOW}${UDP_PORT}${NC}  (UDP)"
echo -e "  SIP Domain  : ${YELLOW}${PBX_DOMAIN}${NC}"
echo ""

# Remove lock (script exit also releases it, but be explicit)
flock -u 200
