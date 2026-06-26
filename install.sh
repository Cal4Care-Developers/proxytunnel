#!/bin/bash
# =============================================================================
# RingQ NX Device Proxy -- Idempotent Production Installer  v3.1
# =============================================================================
# REQUIRED input (2 values only):
#   1. PBX Domain    (e.g. customer.ringq.ai)
#   2. Tunnel Auth Key (from RingQ portal -> Tunnel Connections)
#
# Everything else is auto-detected:
#   PBX API URL      -> https://<domain>:8443
#   PBX Tunnel host  -> <domain>:6010
#   LAN IP           -> first non-loopback interface IP
#   Public IP        -> https://api.ipify.org
#   SIP ports        -> UDP/5060, TCP/5061
#   Admin port       -> 8899
#
# Flags:
#   --yes         Non-interactive: reuse existing config (re-install / update)
#   --advanced    Show all prompts for manual override
#   --reconfigure Force re-prompt (domain + auth key only, unless --advanced)
#   --reinstall   Force re-download Go + re-clone even if current
#   --help        Show this message
#
# GitHub : https://github.com/Cal4Care-Developers/proxytunnel.git
# Install: /root/ringqproxy
# Service: ringqproxy (systemd)
# =============================================================================
set -euo pipefail

# -- Parse flags -----------------------------------------------------------
OPT_YES=false
OPT_ADVANCED=false
OPT_RECONFIGURE=false
OPT_REINSTALL=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y)          OPT_YES=true ;;
        --advanced|-a)     OPT_ADVANCED=true ;;
        --reconfigure|-r)  OPT_RECONFIGURE=true ;;
        --reinstall)       OPT_REINSTALL=true ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown flag: $arg  (use --help)"; exit 1 ;;
    esac
done

# -- Colour helpers ---------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${BLUE}--- $* --------------------------------------------${NC}"; }
ok()      { echo -e "  ${GREEN}OK${NC}   $*"; }
skip()    { echo -e "  ${CYAN}SKIP${NC} $* (already done)"; }

# -- Root check ------------------------------------------------------------
[[ $EUID -eq 0 ]] || { error "Run as root: sudo $0"; exit 1; }

# -- Lock file -- prevent concurrent installs ------------------------------
LOCK_FILE="/var/lock/ringqproxy-install.lock"
exec 200>"${LOCK_FILE}"
flock -n 200 || { error "Another install is already running"; exit 1; }

# -- Constants -------------------------------------------------------------
REPO_URL="https://github.com/Cal4Care-Developers/proxytunnel.git"
INSTALL_DIR="/root/ringqproxy"
BUILD_DIR="/tmp/ringqproxy-build"
SERVICE_NAME="ringqproxy"
BINARY_NAME="sipproxy"
CONFIG_FILE="${INSTALL_DIR}/sip-proxy.yaml"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ROLLBACK_BINARY="${INSTALL_DIR}/${BINARY_NAME}.rollback"
GO_MIN_MAJOR=1; GO_MIN_MINOR=21
GO_INSTALL_VERSION="1.22.4"

# -- Banner ----------------------------------------------------------------
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ____  _             ___    _   _ __  __
 |  _ \(_)_ __   __ _/ _ \  | \ | \ \/ /
 | |_) | | '_ \ / _` | | | | |  \| |\  /
 |  _ <| | | | | (_| | |_| | | |\  |/  \
 |_| \_\_|_| |_|\__, |\__\_\ |_| \_/_/\_\
                |___/
  NX Device Proxy Installer  v3.1
EOF
echo -e "${NC}"

# -- Cleanup / rollback on any failure ------------------------------------
INSTALL_PHASE="init"
cleanup_on_error() {
    local code=$?
    echo ""
    error "Failed during: ${INSTALL_PHASE} (exit code: ${code})"
    # Remove incomplete .new binary (never touch the running one)
    rm -f "${INSTALL_DIR}/${BINARY_NAME}.new" 2>/dev/null || true
    # Restore rollback binary if main binary was removed
    if [[ -f "${ROLLBACK_BINARY}" ]] && [[ ! -f "${INSTALL_DIR}/${BINARY_NAME}" ]]; then
        mv "${ROLLBACK_BINARY}" "${INSTALL_DIR}/${BINARY_NAME}"
        warn "Restored previous binary from rollback copy"
        systemctl start "${SERVICE_NAME}" 2>/dev/null || true
    fi
    rm -rf "${BUILD_DIR}" 2>/dev/null || true
    echo -e "\n${YELLOW}Re-run the installer -- completed steps will be skipped.${NC}"
    exit "${code}"
}
trap cleanup_on_error ERR

# -- System check ---------------------------------------------------------
section "System Check"
INSTALL_PHASE="system-check"

[[ -f /etc/os-release ]] || { error "Cannot detect OS"; exit 1; }
. /etc/os-release
case "${ID:-}" in
    debian|ubuntu|raspbian) ok "OS: ${NAME} ${VERSION_ID}" ;;
    *)
        warn "OS '${NAME:-unknown}' not officially tested."
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
ok "Architecture: ${ARCH}"

# Device ID -- stable unique ID per machine
[[ -f /etc/machine-id ]] || systemd-machine-id-setup 2>/dev/null || true
DEVICE_ID=$(tr -d '[:space:]' < /etc/machine-id 2>/dev/null || echo "")
[[ -n "$DEVICE_ID" ]] || { error "Cannot read /etc/machine-id"; exit 1; }
ok "Device ID: ${DEVICE_ID}"

# Auto-detect LAN IP (first global non-docker/loopback interface)
DETECTED_LAN_IP=$(ip -4 addr show scope global 2>/dev/null | \
    grep -oP '(?<=inet\s)\d+(\.\d+){3}' | \
    grep -Ev '^(127\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | \
    head -1 || echo "")
[[ -n "$DETECTED_LAN_IP" ]] || DETECTED_LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "0.0.0.0")
ok "Detected LAN IP: ${DETECTED_LAN_IP}"

# Auto-detect public IP
info "Detecting public IP..."
DETECTED_PUBLIC_IP=$(curl -s --connect-timeout 8 --max-time 10 https://api.ipify.org 2>/dev/null || \
                     curl -s --connect-timeout 8 --max-time 10 https://ifconfig.me 2>/dev/null || \
                     echo "${DETECTED_LAN_IP}")
ok "Detected Public IP: ${DETECTED_PUBLIC_IP}"

# -- Read existing config if present --------------------------------------
read_yaml() {
    # read_yaml KEY FILE
    grep -m1 "^[[:space:]]*${1}:" "${2}" 2>/dev/null | \
        sed 's/.*:[[:space:]]*//' | tr -d '"'"'"' [:space:]' || echo ""
}

CONFIG_EXISTS=false
E_PBX_DOMAIN=""; E_AUTH_KEY=""; E_API_URL=""; E_TUNNEL_HOST=""
E_TUNNEL_PORT=""; E_LAN_IP=""; E_PUBLIC_IP=""; E_UDP_PORT=""
E_TCP_PORT=""; E_ADMIN_PORT=""

if [[ -f "${CONFIG_FILE}" ]]; then
    CONFIG_EXISTS=true
    E_PBX_DOMAIN=$(read_yaml "pbx-domain"  "${CONFIG_FILE}")
    E_AUTH_KEY=$(read_yaml   "auth-key"     "${CONFIG_FILE}")
    E_API_URL=$(read_yaml    "pbx-api-url"  "${CONFIG_FILE}")
    E_TUNNEL_HOST=$(grep -m1 'address: "tcp://' "${CONFIG_FILE}" 2>/dev/null | \
        sed 's|.*tcp://||;s|:.*||;s|".*||' || echo "")
    E_TUNNEL_PORT=$(grep -m1 'address: "tcp://' "${CONFIG_FILE}" 2>/dev/null | \
        grep -oP ':\d+"' | tr -d ':"' || echo "")
    E_LAN_IP=$(grep -m1 '^[[:space:]]*address:' "${CONFIG_FILE}" 2>/dev/null | \
        head -1 | sed 's/.*: //;s/"//g;s/ .*//' || echo "")
    E_PUBLIC_IP=$(grep -m1 'via: "udp://' "${CONFIG_FILE}" 2>/dev/null | \
        sed 's|.*udp://||;s|:.*||;s|"||g' || echo "")
    E_UDP_PORT=$(grep -m1 'udp-port:' "${CONFIG_FILE}" 2>/dev/null | grep -oP '\d+' || echo "")
    E_TCP_PORT=$(grep -m1 'tcp-port:' "${CONFIG_FILE}" 2>/dev/null | grep -oP '\d+' || echo "")
    E_ADMIN_PORT=$(grep -m1 'addr:' "${CONFIG_FILE}" 2>/dev/null | grep -oP ':\d+' | tr -d ':' || echo "")
    info "Existing config found: will pre-fill values"
fi

# -- Configuration prompts (minimal: domain + auth key only) --------------
section "Configuration"
INSTALL_PHASE="config-input"

# Shortcut: --yes with existing config skips all prompts
if $OPT_YES && $CONFIG_EXISTS && ! $OPT_RECONFIGURE; then
    PBX_DOMAIN="${E_PBX_DOMAIN}";     AUTH_KEY="${E_AUTH_KEY}"
    PBX_API_URL="${E_API_URL}";        PBX_TUNNEL_HOST="${E_TUNNEL_HOST}"
    TUNNEL_PORT="${E_TUNNEL_PORT}";   LAN_IP="${E_LAN_IP}"
    PUBLIC_IP="${E_PUBLIC_IP}";        UDP_PORT="${E_UDP_PORT}"
    TCP_PORT="${E_TCP_PORT}";          ADMIN_PORT="${E_ADMIN_PORT}"
    echo -e "${CYAN}  Using existing configuration (--yes). Use --reconfigure to change.${NC}"
else
    echo -e "${CYAN}  Enter PBX Domain and Auth Key. All other values are auto-detected.${NC}"
    $OPT_ADVANCED && echo -e "${YELLOW}  Advanced mode: all values will be shown for override.${NC}"
    echo ""

    # -- Required: PBX Domain --
    if $OPT_YES && [[ -n "${E_PBX_DOMAIN}" ]]; then
        PBX_DOMAIN="${E_PBX_DOMAIN}"
        echo -e "  ${GREEN}[auto]${NC} PBX Domain: ${YELLOW}${PBX_DOMAIN}${NC}"
    else
        DEF="${E_PBX_DOMAIN:-}"
        HINT=""; [[ -n "$DEF" ]] && HINT=" [${DEF}]"
        read -rp "  PBX Domain (e.g. customer.ringq.ai)${HINT}: " PBX_DOMAIN
        PBX_DOMAIN="${PBX_DOMAIN:-$DEF}"
        [[ -n "$PBX_DOMAIN" ]] || { error "PBX Domain is required"; exit 1; }
    fi

    # -- Required: Auth Key --
    if $OPT_YES && [[ -n "${E_AUTH_KEY}" ]]; then
        AUTH_KEY="${E_AUTH_KEY}"
        echo -e "  ${GREEN}[auto]${NC} Auth Key: ${YELLOW}${AUTH_KEY:0:12}...${NC}"
    else
        DEF="${E_AUTH_KEY:-}"
        HINT=""; [[ -n "$DEF" ]] && HINT=" [${DEF:0:12}...]"
        read -rp "  Tunnel Auth Key (from RingQ portal)${HINT}: " AUTH_KEY
        AUTH_KEY="${AUTH_KEY:-$DEF}"
        [[ -n "$AUTH_KEY" ]] || { error "Auth Key is required"; exit 1; }
    fi

    echo ""

    # -- Advanced overrides (optional) --
    # Auto-compute smart defaults from domain
    AUTO_API_URL="${E_API_URL:-https://${PBX_DOMAIN}:8443}"
    AUTO_TUNNEL_HOST="${E_TUNNEL_HOST:-${PBX_DOMAIN}}"
    AUTO_TUNNEL_PORT="${E_TUNNEL_PORT:-6010}"
    AUTO_LAN_IP="${E_LAN_IP:-${DETECTED_LAN_IP}}"
    AUTO_PUBLIC_IP="${E_PUBLIC_IP:-${DETECTED_PUBLIC_IP}}"
    AUTO_UDP_PORT="${E_UDP_PORT:-5060}"
    AUTO_TCP_PORT="${E_TCP_PORT:-5061}"
    AUTO_ADMIN_PORT="${E_ADMIN_PORT:-8899}"

    if $OPT_ADVANCED; then
        # Show all values with override prompt
        echo -e "${YELLOW}  Advanced: press Enter to accept auto-detected value, or type new value.${NC}\n"

        adv_prompt() {
            local varname="$1" label="$2" default="$3"
            read -rp "  ${label} [${default}]: " val
            printf -v "$varname" '%s' "${val:-$default}"
        }
        adv_prompt PBX_API_URL     "PBX API URL"                "${AUTO_API_URL}"
        adv_prompt PBX_TUNNEL_HOST "PBX Tunnel host/IP"         "${AUTO_TUNNEL_HOST}"
        adv_prompt TUNNEL_PORT     "PBX Tunnel TCP port"        "${AUTO_TUNNEL_PORT}"
        adv_prompt LAN_IP          "NX Device LAN listen IP"    "${AUTO_LAN_IP}"
        adv_prompt PUBLIC_IP       "NX Device Public IP"        "${AUTO_PUBLIC_IP}"
        adv_prompt UDP_PORT        "UDP SIP port for phones"    "${AUTO_UDP_PORT}"
        adv_prompt TCP_PORT        "TCP SIP port for phones"    "${AUTO_TCP_PORT}"
        adv_prompt ADMIN_PORT      "Admin API port"             "${AUTO_ADMIN_PORT}"
    else
        # Use auto values silently
        PBX_API_URL="${AUTO_API_URL}";        PBX_TUNNEL_HOST="${AUTO_TUNNEL_HOST}"
        TUNNEL_PORT="${AUTO_TUNNEL_PORT}";    LAN_IP="${AUTO_LAN_IP}"
        PUBLIC_IP="${AUTO_PUBLIC_IP}";        UDP_PORT="${AUTO_UDP_PORT}"
        TCP_PORT="${AUTO_TCP_PORT}";          ADMIN_PORT="${AUTO_ADMIN_PORT}"
    fi
fi

# Show summary + confirm
echo ""
echo -e "${BOLD}${CYAN}  Configuration:${NC}"
echo -e "    PBX Domain    : ${YELLOW}${PBX_DOMAIN}${NC}"
echo -e "    Auth Key      : ${YELLOW}${AUTH_KEY:0:16}...${NC}"
echo -e "    PBX API URL   : ${YELLOW}${PBX_API_URL}${NC}"
echo -e "    PBX Tunnel    : ${YELLOW}tcp://${PBX_TUNNEL_HOST}:${TUNNEL_PORT}${NC}"
echo -e "    NX LAN IP     : ${YELLOW}${LAN_IP}${NC}"
echo -e "    NX Public IP  : ${YELLOW}${PUBLIC_IP}${NC}"
echo -e "    Phone ports   : ${YELLOW}UDP/${UDP_PORT}  TCP/${TCP_PORT}${NC}"
echo -e "    Device ID     : ${YELLOW}${DEVICE_ID}${NC}"

if ! $OPT_YES; then
    echo ""
    read -rp "  Proceed with installation? [Y/n]: " CONFIRM
    [[ "${CONFIRM,,}" != "n" ]] || { info "Aborted."; exit 0; }
fi

# -- System packages -------------------------------------------------------
section "System Dependencies"
INSTALL_PHASE="packages"

NEED_PKG=()
for pkg in git curl ca-certificates iptables-persistent netfilter-persistent; do
    dpkg -s "$pkg" &>/dev/null && skip "Package: $pkg" || NEED_PKG+=("$pkg")
done
if [[ ${#NEED_PKG[@]} -gt 0 ]]; then
    info "Installing: ${NEED_PKG[*]}"
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${NEED_PKG[@]}"
    ok "Packages installed: ${NEED_PKG[*]}"
fi

# -- Go installation -------------------------------------------------------
section "Go Language Runtime"
INSTALL_PHASE="go-install"

export PATH="/usr/local/go/bin:${PATH}"
export GOPATH="/root/go"
export GOMODCACHE="${GOPATH}/pkg/mod"

go_version_ok() {
    command -v go &>/dev/null || return 1
    local cur
    cur=$(go version 2>/dev/null | grep -oP 'go\K\d+\.\d+' | head -1)
    local maj min
    maj=$(echo "$cur" | cut -d. -f1)
    min=$(echo "$cur" | cut -d. -f2)
    (( maj > GO_MIN_MAJOR )) || (( maj == GO_MIN_MAJOR && min >= GO_MIN_MINOR ))
}

if go_version_ok && ! $OPT_REINSTALL; then
    GO_VER=$(go version | awk '{print $3}')
    skip "Go ${GO_VER} already installed (meets minimum ${GO_MIN_MAJOR}.${GO_MIN_MINOR})"
else
    GO_TAR="go${GO_INSTALL_VERSION}.linux-${GO_ARCH}.tar.gz"
    GO_TMP="/tmp/${GO_TAR}"
    GO_URL="https://go.dev/dl/${GO_TAR}"

    if [[ -f "${GO_TMP}" ]]; then
        info "Using cached tarball: ${GO_TMP}"
    else
        info "Downloading Go ${GO_INSTALL_VERSION} for ${GO_ARCH}..."
        curl -fsSL --retry 3 --retry-delay 5 "${GO_URL}" -o "${GO_TMP}"
    fi

    info "Installing Go ${GO_INSTALL_VERSION}..."
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "${GO_TMP}"
    rm -f "${GO_TMP}"
    ok "Go ${GO_INSTALL_VERSION} installed to /usr/local/go"
fi

# Verify Go works (do NOT pipe to xargs -- shell functions can't be called via xargs)
go_version_ok || { error "Go not functional after install"; exit 1; }
GO_ACTIVE=$(go version | awk '{print $3}')
ok "Active Go runtime: ${GO_ACTIVE}"

# Persist PATH
grep -q '/usr/local/go/bin' /root/.bashrc 2>/dev/null || {
    printf '\nexport PATH="/usr/local/go/bin:$PATH"\nexport GOPATH="/root/go"\n' >> /root/.bashrc
}

# -- Create install directory ----------------------------------------------
section "Install Directory"
INSTALL_PHASE="directory"

if [[ -d "${INSTALL_DIR}" ]]; then
    skip "Directory ${INSTALL_DIR} exists"
else
    mkdir -p "${INSTALL_DIR}"
    chmod 700 "${INSTALL_DIR}"
    ok "Created: ${INSTALL_DIR}"
fi

# -- Build (with atomic replacement + rollback) ----------------------------
section "Build SIP Proxy"
INSTALL_PHASE="build"

NEED_BUILD=true
REMOTE_HASH=$(git ls-remote "${REPO_URL}" HEAD 2>/dev/null | awk '{print substr($1,1,7)}' || echo "")
CURRENT_VER=$(cat "${INSTALL_DIR}/version.txt" 2>/dev/null || echo "")

if [[ -n "${REMOTE_HASH}" ]] && \
   [[ "${CURRENT_VER}" == "${REMOTE_HASH}" ]] && \
   [[ -x "${INSTALL_DIR}/${BINARY_NAME}" ]] && \
   ! $OPT_REINSTALL; then
    skip "Binary already at latest (${CURRENT_VER})"
    NEED_BUILD=false
else
    [[ -n "${CURRENT_VER}" ]] && info "Update: ${CURRENT_VER} -> ${REMOTE_HASH:-latest}" || \
        info "Fresh build from ${REPO_URL}"
fi

if $NEED_BUILD; then
    # Backup existing binary before stopping service
    if [[ -x "${INSTALL_DIR}/${BINARY_NAME}" ]]; then
        cp "${INSTALL_DIR}/${BINARY_NAME}" "${ROLLBACK_BINARY}"
        ok "Rollback copy saved"
    fi
    systemctl stop "${SERVICE_NAME}" 2>/dev/null && info "Service stopped" || true

    # Clean build dir (handles any partial state from prior failed attempt)
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"

    info "Cloning ${REPO_URL}..."
    git clone --depth 1 "${REPO_URL}" "${BUILD_DIR}" 2>&1 | grep -E 'Cloning|done\.' || true
    NEW_VER=$(git -C "${BUILD_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    ok "Cloned at ${NEW_VER}"

    # - Decide: use pre-built binary or build from source -
    # Priority:
    #   1. Pre-built binary in repo root  -> copy directly (no Go needed)
    #   2. Go source files in repo        -> build from source
    #   3. Neither                        -> error with clear instructions

    GO_FILE_COUNT=$(find "${BUILD_DIR}" -maxdepth 3 -name "*.go" 2>/dev/null | wc -l)
    PREBUILT_BINARY=""
    for candidate in "${BUILD_DIR}/${BINARY_NAME}" "${BUILD_DIR}/bin/${BINARY_NAME}"; do
        if [[ -f "${candidate}" ]]; then
            # Verify it is an ELF executable (not a shell script or text file)
            file "${candidate}" 2>/dev/null | grep -qi 'ELF' && PREBUILT_BINARY="${candidate}" && break
        fi
    done

    if [[ -n "${PREBUILT_BINARY}" && "${GO_FILE_COUNT}" -eq 0 ]]; then
        # - Mode 1: Pre-built binary in repo, no source files -
        info "Using pre-built binary from repository (no source files found)"
        warn "To build from source in future, push .go files to: ${REPO_URL}"
        cp "${PREBUILT_BINARY}" "${INSTALL_DIR}/${BINARY_NAME}.new"
        chmod +x "${INSTALL_DIR}/${BINARY_NAME}.new"

    elif [[ "${GO_FILE_COUNT}" -gt 0 ]]; then
        # - Mode 2: Source files present -- build -
        info "Source files found (${GO_FILE_COUNT} .go files) -- building..."
        GO_SRC="${BUILD_DIR}"
        if [[ ! -f "${GO_SRC}/go.mod" ]]; then
            FOUND_MOD=$(find "${BUILD_DIR}" -name "go.mod" -maxdepth 3 -type f 2>/dev/null | head -1)
            if [[ -n "${FOUND_MOD}" ]]; then
                GO_SRC=$(dirname "${FOUND_MOD}")
                info "Go module found in: ${GO_SRC}"
            else
                warn "go.mod missing -- auto-initialising module"
                cd "${BUILD_DIR}"
                go mod init github.com/ochinchina/sipproxy
                go mod tidy
                GO_SRC="${BUILD_DIR}"
            fi
        fi
        cd "${GO_SRC}"
        GOOS=linux GOARCH=$(go env GOARCH) \
            go build -ldflags="-s -w" -o "${INSTALL_DIR}/${BINARY_NAME}.new" .

    else
        # - Mode 3: Nothing usable in repo -
        error "Repository contains neither Go source files nor a pre-built binary."
        error ""
        error "To fix, push your source files from the build machine:"
        error "  cd ~/nxagent"
        error "  git remote add origin ${REPO_URL}"
        error "  git add *.go go.mod go.sum"
        error "  git commit -m 'add source'"
        error "  git push -u origin master"
        error ""
        error "OR push the pre-built binary:"
        error "  cp ~/nxagent/sipproxy ."
        error "  git add sipproxy && git commit -m 'add binary' && git push"
        exit 1
    fi

    [[ -x "${INSTALL_DIR}/${BINARY_NAME}.new" ]] || { error "Build produced no executable"; exit 1; }
    BIN_SIZE=$(du -sh "${INSTALL_DIR}/${BINARY_NAME}.new" | cut -f1)

    # Atomic replace (mv is atomic on same filesystem)
    mv "${INSTALL_DIR}/${BINARY_NAME}.new" "${INSTALL_DIR}/${BINARY_NAME}"
    echo "${NEW_VER}" > "${INSTALL_DIR}/version.txt"
    rm -f "${ROLLBACK_BINARY}"
    rm -rf "${BUILD_DIR}"
    cd /

    ok "Binary installed: ${INSTALL_DIR}/${BINARY_NAME} (${BIN_SIZE}, v${NEW_VER})"
fi

# -- Config file -----------------------------------------------------------
section "Configuration File"
INSTALL_PHASE="config-write"

DESIRED_CFG="/tmp/ringqproxy-desired.yaml"
cat > "${DESIRED_CFG}" << YAML
# RingQ NX Device SIP Proxy Configuration
# Generated: $(date)
# Edit then run: systemctl restart ${SERVICE_NAME}

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

CFG_CHANGED=true
if [[ -f "${CONFIG_FILE}" ]]; then
    if diff <(grep -v '^# Generated:' "${CONFIG_FILE}") \
            <(grep -v '^# Generated:' "${DESIRED_CFG}") &>/dev/null; then
        CFG_CHANGED=false
    fi
fi

if $CFG_CHANGED; then
    [[ -f "${CONFIG_FILE}" ]] && \
        cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)" && \
        ok "Previous config backed up"
    cp "${DESIRED_CFG}" "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    ok "Config written: ${CONFIG_FILE}"
else
    skip "Config unchanged"
fi
rm -f "${DESIRED_CFG}"

# -- systemd service -------------------------------------------------------
section "systemd Service"
INSTALL_PHASE="service"

DESIRED_SVC="/tmp/ringqproxy.service.desired"
cat > "${DESIRED_SVC}" << SYSTEMD
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

SVC_CHANGED=false
if [[ ! -f "${SERVICE_FILE}" ]] || \
   ! diff -q "${DESIRED_SVC}" "${SERVICE_FILE}" &>/dev/null; then
    cp "${DESIRED_SVC}" "${SERVICE_FILE}"
    systemctl daemon-reload
    SVC_CHANGED=true
    ok "Service file updated"
else
    skip "Service file unchanged"
fi
rm -f "${DESIRED_SVC}"

systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null && \
    skip "Service already enabled" || \
    { systemctl enable "${SERVICE_NAME}"; ok "Service enabled (auto-start on boot)"; }

# -- iptables --------------------------------------------------------------
section "Firewall (iptables)"
INSTALL_PHASE="iptables"

ipt_add() {
    if iptables -C "$@" 2>/dev/null; then
        echo -e "  ${CYAN}SKIP${NC} iptables: $*"
    else
        iptables -A "$@"
        ok "iptables: $*"
    fi
}

ipt_add INPUT  -i lo -j ACCEPT
ipt_add INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
ipt_add INPUT  -p udp --dport "${UDP_PORT}" -j ACCEPT \
    -m comment --comment "RingQ-phones-udp"
ipt_add INPUT  -p tcp --dport "${TCP_PORT}" -j ACCEPT \
    -m comment --comment "RingQ-phones-tcp"
ipt_add INPUT  -s 192.168.0.0/16 -p tcp --dport "${ADMIN_PORT}" -j ACCEPT \
    -m comment --comment "RingQ-admin-lan"
ipt_add INPUT  -s 10.0.0.0/8    -p tcp --dport "${ADMIN_PORT}" -j ACCEPT \
    -m comment --comment "RingQ-admin-lan"
ipt_add OUTPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT \
    -m comment --comment "RingQ-pbx-tunnel"
ipt_add OUTPUT -p tcp --dport 8443 -j ACCEPT \
    -m comment --comment "RingQ-pbx-api"
ipt_add OUTPUT -p tcp --dport 443  -j ACCEPT \
    -m comment --comment "RingQ-https"

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
ok "iptables rules persisted"
systemctl enable netfilter-persistent 2>/dev/null || true

# -- Permissions -----------------------------------------------------------
INSTALL_PHASE="permissions"
chmod 700 "${INSTALL_DIR}" "${INSTALL_DIR}/${BINARY_NAME}"
chmod 600 "${CONFIG_FILE}"
[[ -f "${INSTALL_DIR}/version.txt" ]] && chmod 644 "${INSTALL_DIR}/version.txt"

# -- update.sh -------------------------------------------------------------
DESIRED_UPD="/tmp/ringqproxy-update.desired"
cat > "${DESIRED_UPD}" << 'UPDATESCRIPT'
#!/bin/bash
# RingQ NX Proxy -- update to latest version
set -euo pipefail
REPO_URL="https://github.com/Cal4Care-Developers/proxytunnel.git"
INSTALL_DIR="/root/ringqproxy"; BUILD_DIR="/tmp/ringqproxy-build"
BINARY_NAME="sipproxy"; SERVICE_NAME="ringqproxy"
ROLLBACK="${INSTALL_DIR}/${BINARY_NAME}.rollback"
export PATH="/usr/local/go/bin:$PATH"; export GOPATH="/root/go"

REMOTE=$(git ls-remote "${REPO_URL}" HEAD 2>/dev/null | awk '{print substr($1,1,7)}' || echo "")
CURRENT=$(cat "${INSTALL_DIR}/version.txt" 2>/dev/null || echo "")
if [[ -n "$REMOTE" && "$REMOTE" == "$CURRENT" ]]; then
    echo "[UPDATE] Already on latest: ${CURRENT}"; exit 0
fi
echo "[UPDATE] ${CURRENT} -> ${REMOTE}"
[[ -x "${INSTALL_DIR}/${BINARY_NAME}" ]] && cp "${INSTALL_DIR}/${BINARY_NAME}" "${ROLLBACK}"
systemctl stop "$SERVICE_NAME" || true
rm -rf "$BUILD_DIR"; git clone --depth 1 "$REPO_URL" "$BUILD_DIR"
VER=$(git -C "$BUILD_DIR" rev-parse --short HEAD)
cd "$BUILD_DIR"
if [[ ! -f "go.mod" ]]; then
    FOUND=$(find . -name "go.mod" -maxdepth 3 | head -1)
    [[ -n "$FOUND" ]] && cd "$(dirname $FOUND)" || { go mod init github.com/ochinchina/sipproxy; go mod tidy; }
fi
GOOS=linux go build -ldflags="-s -w" -o "${INSTALL_DIR}/${BINARY_NAME}.new" .
mv "${INSTALL_DIR}/${BINARY_NAME}.new" "${INSTALL_DIR}/${BINARY_NAME}"
echo "$VER" > "${INSTALL_DIR}/version.txt"; rm -f "${ROLLBACK}"; rm -rf "${BUILD_DIR}"; cd /
systemctl start "$SERVICE_NAME"; sleep 2
systemctl is-active --quiet "$SERVICE_NAME" && \
    echo "[UPDATE] Running v${VER}" || \
    { echo "[UPDATE] FAILED -- check: journalctl -u $SERVICE_NAME -n 30"; exit 1; }
UPDATESCRIPT

UPD_PATH="${INSTALL_DIR}/update.sh"
if [[ ! -f "${UPD_PATH}" ]] || ! diff -q "${DESIRED_UPD}" "${UPD_PATH}" &>/dev/null; then
    cp "${DESIRED_UPD}" "${UPD_PATH}"; chmod +x "${UPD_PATH}"; ok "Update script: ${UPD_PATH}"
else
    skip "Update script unchanged"
fi
rm -f "${DESIRED_UPD}"

# -- Start / restart service -----------------------------------------------
section "Starting Service"
INSTALL_PHASE="start"

if systemctl is-active --quiet "${SERVICE_NAME}"; then
    if $NEED_BUILD || $CFG_CHANGED || $SVC_CHANGED; then
        systemctl restart "${SERVICE_NAME}"; ok "Service restarted"
    else
        skip "Service already running and nothing changed"
    fi
else
    systemctl start "${SERVICE_NAME}"; ok "Service started"
fi

sleep 4
if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    error "Service not running after start. Logs:"
    journalctl -u "${SERVICE_NAME}" --no-pager -n 30
    exit 1
fi
ok "Service is active"

sleep 2
RECENT=$(journalctl -u "${SERVICE_NAME}" --no-pager -n 20 --since "20 seconds ago" 2>/dev/null || echo "")
if echo "${RECENT}" | grep -q "bind successful"; then
    ok "Tunnel authenticated (ONLINE)"
elif echo "${RECENT}" | grep -q "bind rejected\|auth failed\|BLOCKED"; then
    warn "Tunnel auth FAILED -- check auth-key and pbx-domain in:"
    warn "  ${CONFIG_FILE}"
    warn "Fix then: systemctl restart ${SERVICE_NAME}"
else
    info "Bind result pending -- watch: journalctl -u ${SERVICE_NAME} -f"
fi

# -- Final summary ---------------------------------------------------------
section "Done"
echo ""
echo -e "${BOLD}${GREEN}RingQ NX Device Proxy installed successfully.${NC}"
echo ""
echo -e "  Version  : ${CYAN}$(cat ${INSTALL_DIR}/version.txt 2>/dev/null || echo unknown)${NC}"
echo -e "  Config   : ${CYAN}${CONFIG_FILE}${NC}"
echo -e "  Logs     : ${YELLOW}journalctl -u ${SERVICE_NAME} -f${NC}"
echo -e "  Status   : ${YELLOW}systemctl status ${SERVICE_NAME}${NC}"
echo -e "  Update   : ${YELLOW}${INSTALL_DIR}/update.sh${NC}"
echo -e "  Re-run   : ${YELLOW}$0 --yes${NC}"
echo -e "  Re-config: ${YELLOW}$0 --reconfigure${NC}  (change domain/key)"
echo -e "  Advanced : ${YELLOW}$0 --advanced --reconfigure${NC}"
echo ""
echo -e "${BOLD}Phone provisioning:${NC}"
echo -e "  SIP Server  : ${YELLOW}${LAN_IP}${NC}  (port ${UDP_PORT} UDP)"
echo -e "  SIP Domain  : ${YELLOW}${PBX_DOMAIN}${NC}"
echo ""

flock -u 200
