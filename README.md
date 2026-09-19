# RingQ Tunnel — Complete Architecture & Developer Guide

---

## 1. Authentication Model

The NX Device POSTs to `https://<pbx-domain>:443/sbc/tunnel/bind` on startup:

```json
{
  "auth_key":         "R1_2T8cPh...",
  "device_id":        "536ea166fec7445d99df4e44df9fced9",
  "device_public_ip": "43.225.164.198",
  "device_local_ip":  "192.168.10.130"
}
```

The PBX queries:
```sql
SELECT * FROM tunnel_config
WHERE auth_key = ? AND domain = '<pbx-domain>' AND deleted_at IS NULL
```

- ✅ Match → HTTP 200 → SIP gate opens → phones can register and call
- ❌ No match → HTTP 401/403 → SIP gate stays closed → phones get 503

---

## 2. Network Topology

Two completely separate internet paths:
- **TCP/6010** — SIP signalling only (REGISTER, INVITE, BYE …)
- **UDP direct** — RTP voice audio only, does NOT go through TCP/6010

```
 LAN SIDE                 INTERNET                      CLOUD PBX
 ===========          ==============               =====================
                                                   ┌─────────────────────┐
 Phones                                            │ Cloud Security Group│
 192.168.x.x                                       │                     │
      │                                            │ MUST ALLOW:         │
      │ ① SIP UDP/5060                             │  TCP 6010 ✓         │
      │   (to NX Device, LAN only)                 │  TCP 443  ✓         │
      │                                            │  UDP 16384-32768    │
      │ ② RTP UDP                                  │  FROM NX_IP only ✓  │
      │   to 192.168.x.x:40000-41999               └─────────┬───────────┘
      │   (LAN only, never crosses internet)                  │
      ▼                                                       ▼
 +------------------+   ③ TCP/6010 ══════════════════► RingQ FreeSWITCH
 │ NX Device Proxy  │   (SIP signalling only)          172.16.x.x:5060
 │ LAN:192.168.x.x  │
 │ WAN:43.225.x.x   │   ④ UDP direct ─────────────────► FS RTP ports
 │                  │   (voice audio, NOT via TCP/6010)  16384-32768
 │  RTP relay:      │   src: 43.225.x.x:wanPort
 │   lanHalf←phones │   dst: FS_IP:FS_RTP_port
 │   wanHalf──────► │
 +------------------+
```

---

## 3. Port Reference

### NX Device

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| 5060 | UDP | Inbound | SIP from LAN phones |
| 5061 | TCP | Inbound | SIP from LAN phones (TCP) |
| 8099 | TCP | Inbound | Provision API (UI-driven setup) |
| 8899 | TCP | Inbound | Admin API (`/healthz`, `/status`) |
| 40000–41999 | UDP | Inbound | RTP relay — phones send audio here |
| 6010 | TCP | Outbound | SIP tunnel to Cloud PBX |
| 443 | TCP | Outbound | REST API to PBX (bind/heartbeat) |
| 40000–41999 | UDP | Outbound | RTP relay — proxy forwards to PBX |

### Cloud PBX

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| 6010 | TCP | Inbound | NX Device SIP tunnel |
| 443 | TCP | Inbound | REST API (bind/heartbeat) |
| 16384–32768 | UDP | From NX IP only | RTP media from proxy relay |

---

## 4. How Data Travels

### 4.1 Registration Flow

```
Phone → NX Device → Cloud PBX

Phone sends REGISTER (UDP/5060 to NX Device LAN IP)
  ↓
NX Device rewrites headers:
  Request-URI: sip:192.168.x.x → sip:pbxdomain
  Contact:     user@lan-ip     → user@public-ip;transport=tcp;ob
  Via:         SIP/2.0/UDP     → SIP/2.0/TCP
  +X-Device-ID header
  +X-RingQ-Auth header
  ↓
Forwards via TCP/6010 to PBX
  ↓
PBX returns 401 → phone sends REGISTER+credentials → PBX returns 200 OK
```

### 4.2 Keepalive — Two Layers

```
Layer 1 — TCP connection alive (every 30s):
  NX Device ──CRLF ping(\r\n\r\n)──► PBX
  NX Device ◄─CRLF pong(\r\n)─────── PBX

Layer 2 — SIP registration alive:
  PBX ──OPTIONS──► NX Device (via TCP/6010)
  PBX ◄──200 OK─── NX Device
  (PBX logs: Ping-Status: Reachable)
```

### 4.3 Outbound Call + RTP Relay (Phone → PBX)

```
Phone sends INVITE with SDP (own RTP IP:port)
  ↓
NX Device allocates lanPort P1 + wanPort P2
Rewrites SDP: tells PBX to send audio to publicIP:P2
Forwards INVITE to PBX via TCP/6010
  ↓
PBX replies 200 OK with its RTP address
NX Device rewrites SDP: tells phone to send audio to LAN_IP:P1
Starts relay goroutines
  ↓
Voice path:
  Phone → P1(lanHalf) → [via wanHalf.conn] → PBX RTP port
  PBX   → P2(wanHalf) → Phone
```

> **Cross-socket write**: phone audio arrives at lanHalf (P1) but is
> forwarded to PBX using wanHalf.conn (P2) as source. FreeSWITCH always
> sees one consistent source port — prevents symmetric-RTP confusion.

### 4.4 Inbound Call (PBX → Phone)

```
PBX sends INVITE to NX Device with its RTP address
  ↓
NX Device allocates lanPort P3 + wanPort P4
Rewrites SDP: tells phone to send audio to LAN_IP:P3
Forwards INVITE to phone
  ↓
Phone replies 200 OK with its RTP address
NX Device rewrites SDP: tells PBX to send audio to publicIP:P4
Starts relay goroutines
  ↓
Voice path same as outbound but reversed
```

---

## 5. Heartbeat Health Data (every 30 seconds)

The NX Device sends a full health payload every 30 seconds:

```
POST https://<pbx-domain>:443/sbc/tunnel/heartbeat
```

```json
{
  "auth_key":          "wijXFIPp...",
  "device_id":         "c261550561764c27...",
  "domain":            "cal4care.ringq.ai",
  "status":            1,
  "local_ip":          "192.168.0.234",
  "public_ip":         "43.225.164.198",
  "phones_registered": 3,
  "rtp_sessions":      1,
  "uptime_seconds":    9240,
  "version":           "facbed8"
}
```

**PBX response rules:**
- `200 OK` → auth valid → update DB, keep gate open
- `401 Unauthorized` → key revoked → gate closes, phones get 503 within 62s
- `403 Forbidden` → device mismatch → gate closes

**Offline reasons** (sent in `/sbc/tunnel/status`):

| Scenario | `reason` value | Detected how |
|---|---|---|
| `systemctl stop ringqproxy` | `shutdown` | SIGTERM caught by proxy |
| Auth key deleted from portal | `auth_revoked` | Heartbeat gets 401/403 |
| Power off / crash / network down | `timeout` | PBX auto-expire job |

---

## 6. tunnel_config Database Schema

### Existing columns (already in DB)

| Column | Type | Purpose |
|---|---|---|
| `id` | UUID | Primary key |
| `domain_uuid` | UUID | RingQ tenant/domain |
| `auth_key` | VARCHAR | Secret key from RingQ portal |
| `device_id` | VARCHAR | /etc/machine-id, bound on first connect |
| `device_public_ip` | VARCHAR | Office internet IP |
| `device_local_ip` | VARCHAR | NX Device LAN IP |
| `status` | INT | 0=OFFLINE, 1=ONLINE |
| `last_seen` | TIMESTAMP | Last heartbeat time |
| `deleted_at` | TIMESTAMP | Soft delete / key revocation |

### New columns to add (run once on PBX DB)

```sql
ALTER TABLE tunnel_config
    ADD COLUMN IF NOT EXISTS phones_registered  INT         DEFAULT 0,
    ADD COLUMN IF NOT EXISTS rtp_sessions       INT         DEFAULT 0,
    ADD COLUMN IF NOT EXISTS uptime_seconds     BIGINT      DEFAULT 0,
    ADD COLUMN IF NOT EXISTS version            VARCHAR(20) DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS offline_reason     VARCHAR(30) DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS public_ip          VARCHAR(45) DEFAULT NULL;
```

### What each new column stores

| Column | Updated | Example | Portal use |
|---|---|---|---|
| `phones_registered` | Every 30s | `3` | "3 phones connected" |
| `rtp_sessions` | Every 30s | `2` | "2 active calls" |
| `uptime_seconds` | Every 30s | `9240` | "2h 34m uptime" |
| `version` | Every 30s | `"facbed8"` | Show build, check for updates |
| `offline_reason` | On OFFLINE | `"timeout"` | Show why device went offline |
| `public_ip` | Every 30s | `"43.225.164.198"` | Current WAN IP for troubleshooting |

### PBX heartbeat handler (SQL)

```sql
-- On POST /sbc/tunnel/heartbeat:
UPDATE tunnel_config SET
    status             = 1,
    last_seen          = NOW(),
    public_ip          = :public_ip,
    phones_registered  = :phones_registered,
    rtp_sessions       = :rtp_sessions,
    uptime_seconds     = :uptime_seconds,
    version            = :version,
    offline_reason     = NULL
WHERE auth_key  = :auth_key
  AND device_id = :device_id
  AND deleted_at IS NULL;

-- 0 rows updated → return HTTP 401 (key revoked)
-- 1 row updated → return HTTP 200
```

### Auto-expire job (run every minute on PBX)

```sql
-- Marks timeout if no heartbeat in 90 seconds (3 × 30s interval)
UPDATE tunnel_config SET
    status         = 0,
    offline_reason = 'timeout'
WHERE status    = 1
  AND last_seen < NOW() - INTERVAL '90 seconds';
```

### Portal display logic

```
status=1                       → 🟢 ONLINE
status=0, reason=NULL          → 🔴 OFFLINE
status=0, reason='shutdown'    → ⚫ Stopped (admin action)
status=0, reason='auth_revoked'→ 🔴 Access Revoked
status=0, reason='timeout'     → 🟡 Unreachable (power/network)
```

---

## 7. Security Layers

| Layer | Mechanism | Where enforced |
|---|---|---|
| Tunnel auth | auth-key + domain validated via REST API | Proxy startup |
| Heartbeat | auth-key re-validated every 30s | Proxy heartbeat |
| Revocation | On 401/403: gate closed, registry cleared, OPTIONS dropped → FS expires in ~62s | Proxy |
| SIP auth | Digest MD5 realm=pbxdomain per phone | RingQ |
| Transport | TCP/6010 only for SIP; RTP via NX relay | Firewall |
| Device binding | device-id from /etc/machine-id bound per tunnel | RingQ DB |
| RTP restriction | PBX only accepts RTP from NX Device public IP | PBX iptables |

---

## 8. Admin APIs on NX Device

### Port 8899 — Go proxy admin (built into `sipproxy` binary)

| Method | Path | Description |
|---|---|---|
| GET | `/healthz` | Process alive check — returns `"ok"` |
| GET | `/loglevel` | Current log level |
| POST | `/loglevel?level=Debug` | Change log level dynamically |

### Port 8099 — Python provision API (separate `ringq-provision` service)

| Method | Path | Description | Response time |
|---|---|---|---|
| GET | `/api/status` | Config state + service status | < 1s |
| GET | `/api/health` | Deep real-time check (internet, DNS, PBX, tunnel) | 3–8s |
| POST | `/api/configure` | First-time install | 30–120s |
| POST | `/api/reconfigure` | Change domain or auth key | 15–30s |

---

## 9. Building a New Binary

### When to rebuild

- After any Go source file change (`proxy.go`, `main.go`, `rtprelay.go`, etc.)
- After adding new features or bug fixes
- Before pushing to GitHub for deployment

### Build steps (on your Linux build machine)

```bash
# Step 1 — go to source directory
cd ~/nxagent   # wherever your .go files are

# Step 2 — build stripped binary (smaller, no debug symbols)
go build -ldflags="-s -w" -o sipproxy .

# Step 3 — verify it's a valid ELF binary
file sipproxy
# Expected: ELF 64-bit LSB executable, x86-64, statically linked

# Step 4 — check the size (should be ~15-20 MB)
ls -lh sipproxy

# Step 5 — test it locally (optional)
./sipproxy -config sip-proxy.yaml --log-level Debug
```

### Push to GitHub

```bash
# Set executable permission (critical — GitHub strips it otherwise)
git update-index --chmod=+x sipproxy

# Commit and push
git add sipproxy
git commit -m "build: update binary $(date +%Y-%m-%d)"
git push origin master
```

### Deploy to NX Device

```bash
# Option A — run update script on device
/root/ringqproxy/update.sh

# Option B — manual update
git clone --depth 1 https://github.com/Cal4Care-Developers/proxytunnel.git /tmp/update-build
chmod +x /tmp/update-build/sipproxy
cp /tmp/update-build/sipproxy /root/ringqproxy/sipproxy
git -C /tmp/update-build rev-parse --short HEAD > /root/ringqproxy/version.txt
systemctl restart ringqproxy
rm -rf /tmp/update-build
```

### Verify new binary is running

```bash
# Check version
cat /root/ringqproxy/version.txt

# Check service started cleanly
journalctl -u ringqproxy -n 20 --no-pager | grep -E "bind|RTP proxy|version"

# Quick status
ringqtunnel-status
```

---

## 10. Installation (Manual / PuTTY)

```bash
# Download and run installer
curl -fsSL https://raw.githubusercontent.com/Cal4Care-Developers/proxytunnel/master/install.sh \
  -o /tmp/install.sh && chmod +x /tmp/install.sh && sudo /tmp/install.sh

# Flags
sudo /tmp/install.sh --yes          # reuse existing config (no prompts)
sudo /tmp/install.sh --reconfigure  # change PBX domain or auth key
sudo /tmp/install.sh --reinstall    # force re-download binary
```

## 11. Installation (UI / API-driven)

```bash
# Install provision API on NX Device (one-time)
curl -fsSL https://raw.githubusercontent.com/Cal4Care-Developers/proxytunnel/master/nxdevice/setup-provision-api.sh \
  -o /tmp/setup.sh && chmod +x /tmp/setup.sh && sudo /tmp/setup.sh

# Then your UI calls:
POST http://<device-lan-ip>:8099/api/configure
{ "domain": "cal4care.ringq.ai", "auth_key": "...", "lan_ip": "192.168.x.x" }
```

## 12. Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/Cal4Care-Developers/proxytunnel/master/uninstall.sh \
  -o /tmp/uninstall.sh && chmod +x /tmp/uninstall.sh && sudo /tmp/uninstall.sh
```

## 13. Status Check

```bash
ringqtunnel-status           # one-shot
ringqtunnel-status --watch   # live refresh every 5s
ringqtunnel-status --json    # JSON for portal/monitoring
```

---

## 14. Troubleshooting

```bash
# [NX Device] Service logs
journalctl -u ringqproxy -f

# [NX Device] Confirm voice audio flowing during call
journalctl -u ringqproxy -f -n 0 | grep -iE "forwarding|lan.pbx|wan.phone"

# [NX Device] Check nftables RTP rule
nft list ruleset | grep -E "40000|policy"

# [NX Device] Check if phone audio reaches relay
tcpdump -i any -n 'udp dst portrange 40000-41999' -c 10

# [PBX] Confirm audio arriving from NX Device
tcpdump -n 'udp and src host <NX_PUBLIC_IP>' -c 20

# [PBX] Watch extension registrations
watch -n 10 'fs_cli -x "sofia status profile internal reg" | grep -E "User:|Ping-Status:"'

# [PBX] Check active calls and codecs
fs_cli -x "show channels"

# [PBX] Check RTP config
fs_cli -x "sofia status profile internal" | grep -iE "rtp|ext|ip"

# [PBX] Unban NX Device from fail2ban
sudo fail2ban-client set <jail-name> unbanip <NX_PUBLIC_IP>

# [PBX] Fix NAT rules for 6010
sudo iptables -t nat -L PREROUTING -n -v --line-numbers
sudo iptables -t nat -D PREROUTING <line-number>
sudo iptables-save > /etc/iptables/rules.v4
```
