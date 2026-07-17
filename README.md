# RingQ Tunnel -- Complete Architecture Guide

## 1. Authentication Model

The NX Device POSTs to `https://<pbx-domain>:8443/tunnel/bind` with:

``` json
{
  "auth_key":        "R1_2T8cPh...",
  "device_id":       "536ea166fec7445d99df4e44df9fced9",
  "device_public_ip":"43.225.164.198",
  "device_local_ip": "192.168.10.130"
}
```

The PBX (RingQ) queries:
```sql
SELECT * FROM tunnel_config
WHERE auth_key = ? AND domain = '<pbx-domain>'
```

Both must match -- wrong domain means the HTTPS endpoint itself rejects the request;
wrong auth-key means the DB lookup returns nothing and the PBX returns 401/403.
The SIP gate (`tunnelBound`) stays closed; phones receive 503 immediately.

---

## 2. Network Topology

Two completely separate internet paths exist between NX Device and PBX:
- **TCP/6010**: SIP signalling only (REGISTER, INVITE, 200 OK, BYE, OPTIONS …)
- **UDP direct**: RTP media only — voice audio, does NOT go through TCP/6010

```
 LAN SIDE                 INTERNET                      CLOUD PBX
 ===========          ==============               =====================
                                                   ┌─────────────────────┐
 Phones                                            │ Cloud Security Group│
 192.168.x.x                                       │                     │
      │                                            │ MUST ALLOW:         │
      │ ① SIP UDP/5060                             │  TCP 6010 ✓         │
      │   (to NX Device,                           │  TCP 8443 ✓         │
      │    LAN only)                               │  UDP 16384-32768    │
      │                                            │  FROM 43.225.x.x ✓ │
      │ ② RTP UDP                                  │  (NX Device IP)     │
      │   to 192.168.x.x:40000-41999               └─────────┬───────────┘
      │   (to NX relay,                                       │
      │    LAN only, no internet)                             ▼
      ▼                                                FreeSWITCH
 +------------------+   ③ TCP/6010 ═══════════════► 172.16.x.x:5060
 │ NX Device Proxy  │══════════════════════════════  (SIP only, all messages)
 │ LAN:192.168.x.x  │
 │ WAN:43.225.x.x   │   ④ UDP direct ──────────────► FS RTP port
 │                  │─────────────────────────────►  16384-32768
 │  SIP proxy       │   src: 43.225.x.x:wanPort      (voice audio)
 │  RTP relay:      │   dst: FS_IP:FS_RTP_port
 │   lanHalf←phones │   NOT through TCP/6010
 │   wanHalf──────► │
 +------------------+
```

**Critical requirement**: If the cloud security group blocks UDP 16384-32768
from NX Device IP, RTP path ④ cannot reach FreeSWITCH and there will be no
voice. OS-level iptables rules alone are not enough — the cloud provider
firewall must also allow it.

**RTP firewall rule (cloud security group AND OS level):**
```
UDP  16384-32768  FROM <NX_Device_public_IP>  → ALLOW
```
Restrict to NX Device IP only (not 0.0.0.0/0) for security.
Only NX Device sends RTP to PBX — phones never send directly to PBX.

---

## 3. Port Reference

### NX Device (Linux/Debian server)

| Port          | Protocol | Direction | Purpose                              |
|---------------|----------|-----------|--------------------------------------|
| 5060          | UDP      | Inbound   | SIP from LAN phones                  |
| 5061          | TCP      | Inbound   | SIP from LAN phones (TCP mode)       |
| 8899          | TCP      | Inbound   | Admin API (local LAN only)           |
| 40000–41999   | UDP      | Inbound   | RTP relay — LAN phones send audio here |
| 6010          | TCP      | Outbound  | SIP tunnel to Cloud PBX              |
| 8443          | TCP      | Outbound  | REST API to Cloud PBX (bind/HB)      |
| 443           | TCP      | Outbound  | HTTPS for RingQ portal               |
| 40000–41999   | UDP      | Outbound  | RTP relay — proxy forwards audio to PBX |

### Cloud PBX (RingQ server)

| Port        | Protocol | Direction                  | Purpose                            |
|-------------|----------|----------------------------|------------------------------------|
| 6010        | TCP      | Inbound                    | NX Device tunnel connections       |
| 5060        | TCP/UDP  | Internal                   | FreeSWITCH SIP (behind firewall)   |
| 8443        | TCP      | Inbound                    | RingQ REST API                     |

> **Note**: RTP media from phones is relayed through the NX Device proxy.
> The PBX only needs to accept UDP from the NX Device's public IP — not from all internet.

---

## 4. How Data Travels

### 4.1 Registration Flow

```
Phone                NX Device Proxy           Cloud PBX (RingQ)
  |                        |                         |
  |--REGISTER (UDP/5060)-->|                         |
  |  To: sip:user@192.168. |                         |
  |  Contact: user@lan-ip  |                         |
  |                        |-- Rewrite headers:      |
  |                        |   Request-URI -> pbxdomain
  |                        |   Contact -> public-ip;transport=tcp;ob
  |                        |   Via -> TCP transport  |
  |                        |   +X-Device-ID header   |
  |                        |   +X-RingQ-Auth header  |
  |                        |--REGISTER (TCP/6010)--->|
  |                        |                         |-- DB lookup user
  |<--401 Unauthorized-----|<---401 Unauthorized-----|
  |                        |                         |
  |--REGISTER+Auth(UDP)--->|--REGISTER+Auth(TCP)---->|
  |                        |                         |-- Verify credentials
  |<--200 OK (expires=300)-|<---200 OK---------------|
```

**Key header rewrites by proxy:**
- `Request-URI: sip:192.168.x.x` → `sip:sgringq.ringq.ai`
- `Contact: <sip:user@lan-ip;ob>` → `<sip:user@public-ip:5060;transport=tcp;ob>`
- `Via: SIP/2.0/UDP` → `Via: SIP/2.0/TCP`

### 4.2 Keepalive Flow (Dual Layer)

```
NX Device Proxy                        Cloud PBX (RingQ)
      |                                      |
      |--CRLF ping (\r\n\r\n, every 30s)--->|   Layer 1: TCP connection alive
      |<--CRLF pong (\r\n)------------------|
      |                                      |
      |<--OPTIONS (ping user, TCP/6010)------|   Layer 2: SIP registration alive
      |--200 OK (TCP/6010)------------------>|   RingQ logs: Ping-Status: Reachable
```

### 4.3 Outbound Call + RTP Relay Flow (Phone → PBX)

```
Phone A              NX Device Proxy (RTP relay)      Cloud PBX (FS)
  |                         |                               |
  |--INVITE SDP(A_IP:A_rtp)→|  Alloc lanPort P1, wanPort P2|
  |                         |  Rewrite SDP: c=publicIP:P2   |
  |                         |--INVITE SDP(publicIP:P2)----->|
  |                         |                               |-- allocate FS_RTP
  |                         |<--200 OK SDP(FS_IP:FS_RTP)---|
  |                         |  Rewrite SDP: c=LAN_IP:P1     |
  |<--200 OK SDP(LAN_IP:P1)-|  Start relay goroutines       |
  |--ACK------------------->|--ACK------------------------->|
  |                         |                               |
  |--RTP→LAN_IP:P1(lanHalf)→|→(via wanHalf.conn)→FS_IP:P2→|  phone audio
  |←RTP←LAN_IP:P1(wanHalf)←|←FS sends to publicIP:P2←-----|  PBX audio
```

> **RTP path (separate from TCP/6010)**: SIP signalling travels through the
> TCP/6010 tunnel. RTP travels as direct internet UDP from wanHalf to FS's RTP port.
>
> **Cross-socket write**: phone audio received on `lanHalf (P1)` is forwarded to PBX
> **using `wanHalf.conn (P2)`** as the source. FreeSWITCH always sees one consistent
> source port (P2 = wanHalf) for both hole-punch and audio — prevents FS symmetric-RTP
> from redirecting audio away from wanHalf.

### 4.4 Inbound Call + RTP Relay Flow (PBX → LAN Phone, B-leg)

```
Cloud PBX (FS)       NX Device Proxy (RTP relay)      LAN Phone B
      |                         |                            |
      |--INVITE SDP(FS_IP:FS_P)→|  Alloc lanPort P3, wanPort P4
      |                         |  Rewrite SDP: c=LAN_IP:P3  |
      |                         |--INVITE SDP(LAN_IP:P3)---->|
      |                         |<--200 OK SDP(B_IP:B_rtp)---|
      |                         |  Start relay goroutines     |
      |<--200 OK SDP(publicIP:P4)|  Rewrite SDP: c=publicIP:P4|
      |--ACK------------------->|--ACK---------------------->|
      |                         |                            |
      |←RTP← from publicIP:P4←--|←(wanHalf P4 receives)←B→  |  phone B audio
      |→RTP→ to LAN_IP:P3 ----→|→(wanHalf.conn P4 forwards)→|  PBX audio
```

---

## 5. Security Layers

| Layer     | Mechanism                                         | Where enforced    |
|-----------|---------------------------------------------------|-------------------|
| Tunnel    | auth-key + domain validated via REST API          | Proxy startup     |
| Heartbeat | auth-key re-validated every 60s                   | Proxy heartbeat   |
| Revocation| On 401/403: tunnelBound=0, registry cleared, OPTIONS dropped → FS expires registrations within ~92s | Proxy |
| SIP Auth  | Digest MD5 realm=pbxdomain per phone              | RingQ             |
| Transport | TCP/6010 only for SIP; RTP via NX relay           | Firewall policy   |
| Device    | device-id (/etc/machine-id) bound per tunnel      | RingQ DB          |
| RTP       | PBX only accepts RTP from NX Device public IP     | PBX iptables      |

---

## 6. Cloud PBX Configuration Checklist

### 6.1 Firewall / Security Group (Cloud Provider Level)

Open these ports **inbound** to your PBX server:

```
TCP  6010   from 0.0.0.0/0            (NX Device SIP tunnel)
TCP  8443   from 0.0.0.0/0            (NX Device REST API / heartbeat)
```

### 6.2 PBX Server Rules — run `pbx-setup.sh`

The `pbx-setup.sh` script handles everything. Run it once on the PBX:

```bash
sudo bash pbx-setup.sh
```

It sets up:
1. `INPUT tcp/6010` — NX Device SIP tunnel
2. `DNAT tcp/6010 → FS_internal:5060` — route tunnel to FreeSWITCH
3. `FORWARD tcp → FS_internal:5060` — allow forwarded traffic
4. `INPUT udp from <NX_PUBLIC_IP>` — allow NX Device RTP media relay

> **Important**: The PBX does NOT need to allow UDP 40000-41999.
> Those are NX Device's local relay ports, not PBX ports.

### 6.3 RingQ Tunnel Config (DB)

For each NX Device, insert a row in `tunnel_config`:

```sql
INSERT INTO tunnel_config (
  domain_uuid, auth_key, device_id, description, enabled
) VALUES (
  '<your-domain-uuid>',
  'R1_<your-auth-key-here>',
  '',          -- device_id populated automatically on first bind
  'NX Device - Branch Office',
  true
);
```

Or use the RingQ web portal under **Settings → Tunnel Connections → Add Tunnel**.

### 6.4 Heartbeat API — portal must return 401/403 for revoked keys

```
POST /tunnel/heartbeat
Body: {"auth_key": "...", "device_id": "..."}

Valid key   → HTTP 200 (update last_seen only — never write auth_key from request)
Revoked key → HTTP 401
Device mismatch → HTTP 403
```

### 6.5 RingQ SIP Profile

| Setting             | Value              | Notes                                   |
|---------------------|--------------------|-----------------------------------------|
| `rtp-ip`            | `$${local_ip_v4}`  | FS binds RTP to its internal IP         |
| `ext-rtp-ip`        | `autonat:$${ext_ip}` | FS advertises external IP in SDP      |
| `ext-sip-ip`        | `$${ext_ip}`       | FS SIP signalling external IP           |
| `nat-options-ping`  | false              | NX proxy handles OPTIONS keepalives     |

---

## 7. NX Device — RTP Relay Architecture

The proxy uses two UDP sockets per call leg:

| Socket    | Port     | Faces    | Purpose                                    |
|-----------|----------|----------|--------------------------------------------|
| lanHalf   | P1 (even)| LAN phone| Receives phone RTP; writes to PBX via wanHalf.conn |
| wanHalf   | P2 (odd) | Cloud PBX| Receives PBX RTP; forwards to phone. Hole-punch source. |

**Cross-socket write** (critical for FreeSWITCH compatibility):
- Phone audio arrives at `lanHalf (P1)`
- It is forwarded to PBX using `wanHalf.conn (P2)` as the source
- FS always sees one consistent source (P2) → symmetric-RTP stays stable

**NX Device nftables rule required** (systems with `policy drop` on input chain):
```bash
nft insert rule inet filter input udp dport 40000-41999 accept comment "RingQ RTP"
# Persist in /etc/nftables.conf
```

The install.sh handles this automatically.

---

## 8. What Does NOT Need Configuration

- **No open RTP to the world** — PBX only needs UDP from NX Device public IP
- **No Fortigate UDP port-forward** — NX Device initiates outbound; hole-punch handles NAT
- **No STUN server** — proxy detects public IP via bind API response
- **No OpenVPN / IPSec** — TCP/6010 tunnel IS the secure channel
- **No port-forwarding for phones** — phones talk to NX Device on LAN only

---

## 9. Installation

```bash
curl -fsSL https://raw.githubusercontent.com/Cal4Care-Developers/proxytunnel/master/install.sh -o /tmp/install.sh

# Make executable and run
chmod +x /tmp/install.sh
sudo /tmp/install.sh

# Re-run after partial failure -- uses existing config, skips unchanged steps
sudo /tmp/install.sh --yes

# Change PBX domain or auth-key -- re-prompts everything
sudo /tmp/install.sh --reconfigure

# Force re-download Go and re-clone repo (e.g. Go version pinned upgrade)
sudo /tmp/install.sh --reinstall
```

## 10. Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/Cal4Care-Developers/proxytunnel/master/uninstall.sh -o /tmp/uninstall.sh

chmod +x /tmp/uninstall.sh

sudo /tmp/uninstall.sh
```

## 11. Status

```bash
# One-shot tunnel status (service, auth, IPs, last active)
ringqtunnel-status

# Live refresh every 5s
ringqtunnel-status --watch

# JSON output (for portal/monitoring)
ringqtunnel-status --json
```

## 12. Troubleshooting

```bash
# Service logs (real-time)
journalctl -u ringqproxy -f

# RTP relay — confirm audio flowing during a call
journalctl -u ringqproxy -f -n 0 | grep -iE "forwarding|lan.pbx|wan.phone"

# Check nftables RTP rule (NX Device)
nft list ruleset | grep -E "40000|policy"

# On PBX — confirm audio arriving from NX Device
tcpdump -n 'udp and src host <NX_PUBLIC_IP>' -c 20

# Watch extension registrations (PBX)
watch -n 10 'fs_cli -x "sofia status profile internal reg" | grep -E "User:|Status:|Ping-Status:"'

# Check active calls + codecs (PBX)
fs_cli -x "show channels"

# Check FreeSWITCH RTP config (PBX)
fs_cli -x "sofia status profile internal" | grep -iE "rtp|ext|ip"

# Fail2ban — unban NX Device if accidentally blocked (PBX)
sudo fail2ban-client banned <NX_PUBLIC_IP>
sudo fail2ban-client set <jail-name> unbanip <NX_PUBLIC_IP>

# Check the NAT table for a forwarding rule:
sudo iptables -t nat -L -n -v --line-numbers | grep -i 6010
sudo iptables -t nat -S | grep 6010

# Also check the full NAT table to see what pattern the other working tenants use (so we can replicate it for this one):
sudo iptables -t nat -L PREROUTING -n -v --line-numbers

# delete rule bad one and the redundant duplicate rule
sudo iptables -t nat -D PREROUTING 3
sudo iptables-save > /etc/iptables/rules.v4

# Manual binary run (NX Device, debug mode)
cd /root/nxagent

# Build and Manullay run RingQ Tunnel
go build -o sipproxy .
./sipproxy -config sip-proxy.yaml --log-level Debug
```
