``` installation comment

### First install -- interactive prompts
sudo ./install.sh

### Re-run after partial failure -- uses existing config, skips unchanged steps
sudo ./install.sh --yes

### Change PBX domain or auth-key -- re-prompts everything
sudo ./install.sh --reconfigure

### Force re-download Go and re-clone repo (e.g. Go version pinned upgrade)
sudo ./install.sh --reinstall

```

# RingQ NX Device Proxy -- Complete Architecture Guide

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

```
 LAN SIDE (NX Device)                  INTERNET                CLOUD PBX
 ========================          ==============          =====================
                                                           Firewall
 IP Phones (192.168.x.x)                                  +-----------------+
   MicroSIP 1000                                          | DNAT:           |
   Yealink 1004                                          | 103.102.235.105:6010
   Client Win 1008                                       |  -> 172.16.12.105:5060|
        |                                                +-----------------+
        | UDP/5060                                                |
        v                                                         | TCP/5060
  +---------------------+       TCP/6010 (persistent)   +--------v--------+
  | NX Device Proxy     |================================| RingQ      |
  | 192.168.10.130      |  single long-lived connection  | 172.16.12.105   |
  | Public: 43.225.164.198|  CRLF keepalive every 30s   | (internal)      |
  +---------------------+                                +-----------------+
                                                                  |
  Admin API (port 8899)                                  RingQ DB
  Heartbeat -> :8443/tunnel/heartbeat                   tunnel_config table
```

---

## 3. Port Reference

### NX Device (Linux/Debian server)

| Port      | Protocol | Direction | Purpose                              |
|-----------|----------|-----------|--------------------------------------|
| 5060      | UDP      | Inbound   | SIP from LAN phones                  |
| 5061      | TCP      | Inbound   | SIP from LAN phones (TCP mode)       |
| 8899      | TCP      | Inbound   | Admin API (local LAN only)           |
| 6010      | TCP      | Outbound  | SIP tunnel to Cloud PBX              |
| 8443      | TCP      | Outbound  | REST API to Cloud PBX (bind/HB)      |
| 443       | TCP      | Outbound  | HTTPS for RingQ portal (fallback)    |

### Cloud PBX (RingQ server)

| Port        | Protocol | Direction | Purpose                            |
|-------------|----------|-----------|------------------------------------|
| 6010        | TCP      | Inbound   | NX Device tunnel connections       |
| 5060        | TCP/UDP  | Internal  | RingQ SIP (behind firewall)   |
| 8443        | TCP      | Inbound   | RingQ REST API                 |
| 7443        | TCP      | Inbound   | WebSocket SIP (WSS clients)        |
| 16384-32768 | UDP      | Inbound   | RTP media (phone calls audio)      |

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
  |  Contact confirmed     |  FS stores:             |
  |                        |   Registered(TCP-NAT)   |
  |                        |   fs_path=proxy:port    |
```

**Key header rewrites by proxy:**
- `Request-URI: sip:192.168.10.130` -> `sip:sgringq102.ringq.ai`
- `Contact: <sip:user@192.168.x.x:port;ob>` -> `<sip:user@43.225.164.198:5060;transport=tcp;ob>`
- `Via: SIP/2.0/UDP 192.168.x.x` -> `Via: SIP/2.0/TCP 43.225.164.198:5060`

### 4.2 Keepalive Flow (Dual Layer)

```
NX Device Proxy                        Cloud PBX (RingQ)
      |                                      |
      |--CRLF ping (\r\n\r\n, every 30s)--->|   Layer 1: TCP connection alive
      |<--CRLF pong (\r\n)------------------|   (prevents Firewall idle timeout)
      |                                      |
      |<--OPTIONS (ping user, TCP/6010)------|   Layer 2: SIP registration alive
      |  Via: SIP/2.0/TCP 172.16.x.x        |   (RingQ verifies phone is reachable)
      |--200 OK (TCP/6010)------------------>|
      |                                      |   RingQ logs: Ping-Status: Reachable
```

Why both layers are needed:
- CRLF: keeps the Fortigate TCP session table entry from expiring (idle timeout)
- OPTIONS: tells FreeSWITCH the registered phone is reachable via this TCP path

### 4.3 Outbound Call Flow (Phone -> PBX)

```
Phone                NX Device Proxy           Cloud PBX (RingQ)         Callee Phone
  |                        |                         |                       |
  |--INVITE (UDP/5060)---->|                         |                       |
  |  To: sip:1008@proxy    |-- Rewrite + forward --->|                       |
  |<--100 Trying (synth.)--|  (TCP/6010)             |-- dialplan lookup---->|
  |                        |                         |-- INVITE (TCP/6010)-->|
  |                        |<-100 Trying (from FS)---|                       |
  |<--180 Ringing---------|<--180 Ringing------------|<--180 Ringing---------|
  |<--200 OK (with SDP)----|<--200 OK (with SDP)-----|<--200 OK with SDP-----|
  |--ACK------------------>|--ACK------------------->|--ACK----------------->|
  |                        |                         |                       |
  |<========= RTP audio direct (phone to phone, no proxy involvement) ======>|
  |                        |                         |                       |
  |--BYE------------------>|--BYE------------------->|--BYE----------------->|
```

Note: RTP (voice) bypasses the proxy -- it flows directly between phones
via RingQ as media anchor. Only SIP signalling passes through the proxy.

### 4.4 Inbound Call Flow (PBX -> LAN Phone, B-leg)

```
Cloud PBX (RingQ)         NX Device Proxy           LAN Phone
      |                        |                       |
      |--INVITE (TCP/6010)---->|                       |
      |  To: sip:user@proxy-ip |                       |
      |  Route: fs_path        | lookup user in        |
      |                        | registry -> lan-ip    |
      |                        |--INVITE (UDP/5060)--->|
      |<--100 Trying-----------|<--100 Trying----------|
      |<--180 Ringing---------|<--180 Ringing----------|
      |<--200 OK--------------|<--200 OK (with SDP)----|
      |--ACK----------------->|--ACK----------------->|
      |                        |                       |
      |<=== RTP audio RingQ <-> Phone directly ===========|
```

---

## 5. Security Layers

| Layer     | Mechanism                                         | Where enforced    |
|-----------|---------------------------------------------------|-------------------|
| Tunnel    | auth-key + domain validated via REST API          | Proxy startup     |
| SIP Auth  | Digest MD5 realm=pbxdomain per phone              | RingQ        |
| Transport | TCP/6010 only (no UDP from PBX to proxy needed)   | RingQ Firewall policy  |
| Device    | device-id (/etc/machine-id) bound per tunnel      | RingQ DB tunnel_config |
| Headers   | X-Device-ID + X-RingQ-Auth on all upstream SIP   | Proxy rewrite     |

---

## 6. Cloud PBX Configuration Checklist

### 6.1 Firewall / Security Group (Cloud Provider Level)

Open these ports **inbound** to your PBX server:

```
TCP  6010   from 0.0.0.0/0  (NX Device tunnel connections)
TCP  8443   from 0.0.0.0/0  (NX Device REST API / heartbeat)
TCP  7443   from 0.0.0.0/0  (WebSocket SIP clients)
UDP  16384-32768  from 0.0.0.0/0  (RTP media)
```

For tighter security, restrict TCP 6010 and 8443 to NX Device public IPs only.

### 6.2 PBX Server iptables (run on the PBX server)

```bash
# Allow NX Device tunnel
iptables -A INPUT -p tcp --dport 6010 -j ACCEPT

# Allow REST API from NX Devices (tighten source IP for production)
iptables -A INPUT -p tcp --dport 8443 -j ACCEPT

# Allow WebSocket SIP
iptables -A INPUT -p tcp --dport 7443 -j ACCEPT

# Allow RTP media
iptables -A INPUT -p udp --dport 16384:32768 -j ACCEPT

# Save
iptables-save > /etc/iptables/rules.v4
```

### 6.3 NAT/DNAT (if PBX has separate public and internal IPs)

On the cloud firewall or PBX server itself:
```bash
# DNAT: public:6010 -> RingQ internal:5060
iptables -t nat -A PREROUTING -p tcp --dport 6010 \
  -j DNAT --to-destination 172.16.12.105:5060

# Allow the forwarded traffic
iptables -A FORWARD -p tcp --dport 5060 \
  -d 172.16.12.105 -j ACCEPT
```

### 6.4 RingQ Tunnel Config (DB)

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

Or use the RingQ web portal under **Settings -> Call Flow -> Add Tunnel (last icon)**.


### 6.5 RingQ SIP Profile (verify TCP is enabled)

Ensure:
- `tcp-port` = 5060 (or 6010 if direct, without DNAT)
- `tls-port` = not required for NX tunneling
- `aggressive-nat-hack` = false (if possible; set true only if needed)
- `nat-options-ping` = false (NX proxy handles keepalives; FS does not need UDP pings)

---

## 7. What Does NOT Need Configuration

- **No Fortigate UDP port** for SIP from PBX to NX Device -- the TCP tunnel handles all directions
- **No STUN server** -- the proxy detects its public IP via the bind API response
- **No OpenVPN / IPSec** -- the TCP/6010 tunnel IS the secure channel
- **No port-forwarding for phones** -- phones talk to the NX Device on the LAN only
