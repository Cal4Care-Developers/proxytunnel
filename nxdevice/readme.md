# RingQ NX Device — Provisioning API Reference

Base URL: `http://<device-lan-ip>:8099`

The provisioning API runs on the NX Device and lets your UI configure the
RingQ tunnel without SSH. All requests and responses use JSON.

---

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/status` | Check current configuration and service state |
| POST | `/api/configure` | Fresh install — first-time setup |
| POST | `/api/reconfigure` | Change PBX domain or auth key on an existing install |

---

## GET /api/status

Check whether the NX Device is already configured and whether the tunnel
service is running.

### Request

```
GET http://192.168.102.1:8099/api/status
```

No body required.

### Response — device already configured

```json
{
  "configured":       true,
  "service":          "active",
  "version":          "facbed8",
  "pbx_domain":       "cal4care.ringq.ai",
  "pbx_api_url":      "https://cal4care.ringq.ai:8443",
  "device_id":        "dca2dcbb3a534193b8f7f113b0f9d33f",
  "auth_key_prefix":  "wijXFIPp..."
}
```

### Response — device not yet configured

```json
{
  "configured": false,
  "service":    "inactive",
  "version":    "unknown"
}
```

### Response fields

| Field | Type | Description |
|-------|------|-------------|
| `configured` | boolean | `true` if `sip-proxy.yaml` exists on device |
| `service` | string | systemd service state: `active`, `inactive`, `failed`, `unknown` |
| `version` | string | Git short hash of the running binary, or `unknown` |
| `pbx_domain` | string | PBX domain currently configured (only when `configured: true`) |
| `pbx_api_url` | string | PBX API URL currently configured (only when `configured: true`) |
| `device_id` | string | Device machine ID bound to this tunnel (only when `configured: true`) |
| `auth_key_prefix` | string | First 8 chars of auth key + `...` for verification (only when `configured: true`) |

---

## POST /api/configure

Run a **fresh install** on an unconfigured device. Downloads the latest
binary from GitHub, writes `sip-proxy.yaml`, and starts the tunnel service.

Use this when setting up a new NX Device for the first time.

### Request

```
POST http://192.168.102.1:8099/api/configure
Content-Type: application/json
```

```json
{
  "domain":   "cal4care.ringq.ai",
  "auth_key": "wijXFIPpzos9WdKo2Gecqw",
  "lan_ip":   "192.168.102.1"
}
```

### Request fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `domain` | string | ✅ Yes | PBX domain from RingQ portal (e.g. `customer.ringq.ai`) |
| `auth_key` | string | ✅ Yes | Tunnel auth key from RingQ portal |
| `lan_ip` | string | ✅ Yes | NX Device LAN IP that phones connect to (e.g. `192.168.102.1`) |

### Response — success

```json
{
  "success": true,
  "output":  "--- System Check ---\nOK  OS: Debian GNU/Linux 12\nOK  Detected LAN IP: 192.168.102.1\n...\n=== Install complete ===",
  "status":  "active"
}
```

### Response — failure (validation error)

HTTP 400

```json
{
  "success": false,
  "errors":  ["domain is required", "auth_key is required"]
}
```

### Response — failure (install error)

HTTP 500

```json
{
  "success": false,
  "output":  "... install log with error details ...",
  "status":  "failed"
}
```

### Response fields

| Field | Type | Description |
|-------|------|-------------|
| `success` | boolean | `true` if install completed and service started |
| `output` | string | Full install log output (stdout + stderr) |
| `status` | string | Service state after install: `active`, `failed` |
| `errors` | array | Validation errors (only on HTTP 400) |

### Notes

- This call takes **30–120 seconds** — it downloads and installs the binary.
  Your UI should show a loading/progress indicator and not timeout early.
- If the device is already configured, calling `/api/configure` will
  reinstall over the existing config using the new values provided.
- The tunnel service starts automatically after a successful install.

---

## POST /api/reconfigure

Change the **PBX domain or auth key** on an already-configured device.
Does not re-download the binary — only rewrites the configuration and
restarts the service.

Use this when a customer's auth key is rotated or the device is moved to
a different PBX.

### Request

```
POST http://192.168.102.1:8099/api/reconfigure
Content-Type: application/json
```

```json
{
  "domain":   "newpbx.ringq.ai",
  "auth_key": "newAuthKey123",
  "lan_ip":   "192.168.102.1"
}
```

### Request fields

Same as `/api/configure` — all three fields are required.

### Response — success

```json
{
  "success": true,
  "output":  "... reconfigure log ...",
  "status":  "active"
}
```

### Response — failure

Same structure as `/api/configure` failure responses.

### Notes

- Faster than `/api/configure` as it skips the binary download.
- The existing tunnel is stopped, config is rewritten, and the service
  is restarted automatically.
- The auth key in the RingQ portal must be valid for the new domain,
  otherwise the tunnel service will start but remain in `BLOCKED` state.

---

## Error Reference

| HTTP Code | Meaning |
|-----------|---------|
| 200 | Request processed. Check `success` field for install result. |
| 400 | Missing or invalid request fields. See `errors` array. |
| 404 | Unknown endpoint path. |
| 500 | Install or reconfigure failed. See `output` for details. |

---

## Example — JavaScript fetch

```javascript
// Check status
const status = await fetch('http://192.168.102.1:8099/api/status')
  .then(r => r.json());

if (!status.configured) {
  // First time setup
  const result = await fetch('http://192.168.102.1:8099/api/configure', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      domain:   'cal4care.ringq.ai',
      auth_key: 'wijXFIPpzos9WdKo2Gecqw',
      lan_ip:   '192.168.102.1'
    })
  }).then(r => r.json());

  if (result.success) {
    console.log('Tunnel configured and active');
  } else {
    console.error('Install failed:', result.output);
  }
}
```

---

## Service Management (on NX Device)

```bash
# Check API server status
systemctl status ringq-provision

# View API logs
journalctl -u ringq-provision -f

# Restart API server
systemctl restart ringq-provision

# Check tunnel status after configure
ringqtunnel-status
```
