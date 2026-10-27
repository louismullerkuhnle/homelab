# Cloudflare tunnel for the Proxmox web UI

Expose the Proxmox web UI on `https://<public name>` through a Cloudflare tunnel (`cloudflared`), without opening any port on the router, behind Cloudflare Access.

|            |                                                                                                                                                                  |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Target** | Proxmox VE 9 host (Debian 13), domain managed by Cloudflare                                                                                                      |
| **URL**    | `https://<public name>` → `https://localhost:8006`                                                                                                               |
| **Files**  | `/usr/share/keyrings/cloudflare-main.gpg`, `/etc/apt/sources.list.d/cloudflared.list`, `/etc/cloudflared/tunnel.env`, `/etc/systemd/system/cloudflared.service` |

## Order

1. **Dashboard**: create the tunnel and copy its token (step 1).
2. **Host**: run the script, or follow steps 2 and 3.
3. **Dashboard**: protect with Access (step 4), **then** publish the route (step 5).
4. **Host**: check with `--check`.

## Script

```bash
curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/pve/cloudflared.sh | bash
```

The script asks for the public name, then for the token as hidden input (the token alone or the whole command copied from the dashboard). It shows the tunnel ID read from the token: check in the dashboard that it is the right one.

| Option        | Effect                                                              |
| ------------- | ------------------------------------------------------------------- |
| `--check`     | checks the service, the connections, and that Access protects the URL |
| `--new-token` | replaces the token                                                  |
| `--uninstall` | stops the tunnel and removes `cloudflared`                          |

Usage: `curl … | bash -s -- --check`.

## Manual

### 1. Create the tunnel (dashboard)

[one.dash.cloudflare.com](https://one.dash.cloudflare.com) → **Networks** → **Tunnels** → **Create a tunnel** → **Cloudflared**, name the tunnel, copy the token from the install command shown.

### 2. Install `cloudflared`

```bash
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
gpg --show-keys /usr/share/keyrings/cloudflare-main.gpg

echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
  > /etc/apt/sources.list.d/cloudflared.list
apt update && apt install -y cloudflared
```

> Expected fingerprint: `CC94B39C77AE7342A68B89628A682D308D4E5E73`. Key renewed on 2025-10-30 ([pkg.cloudflare.com](https://pkg.cloudflare.com/)): on Debian 13, an older key makes `apt update` fail.

### 3. Create the systemd service

```bash
install -d -m 700 /etc/cloudflared
install -m 600 /dev/null /etc/cloudflared/tunnel.env
nano /etc/cloudflared/tunnel.env                                                      # TUNNEL_TOKEN=<token>

cat > /etc/systemd/system/cloudflared.service <<'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=/etc/cloudflared/tunnel.env
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run
Restart=always
RestartSec=5s
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable --now cloudflared.service
```

> `TUNNEL_TOKEN=` is required before the token: without a variable name, systemd ignores the line. The dashboard should then show the tunnel as **HEALTHY**.

### 4. Protect with Cloudflare Access (dashboard)

**Access** → **Applications** → **Add an application** → **Self-hosted**:

| Field              | Value                     |
| ------------------ | ------------------------- |
| Application domain | `<public name>`           |
| Policy → Action    | `Allow`                   |
| Policy → Include   | `Emails` → `<your email>` |

> **Before** the route in step 5: otherwise the Proxmox login page is public while you create the application.

### 5. Publish the web UI (dashboard)

In the tunnel → **Published application routes** → **Add**:

| Field                                         | Value            |
| --------------------------------------------- | ---------------- |
| Subdomain / Domain                            | `<public name>`  |
| Service → Type                                | `HTTPS`          |
| Service → URL                                 | `localhost:8006` |
| Additional settings → TLS → **No TLS Verify** | `On`             |

> `No TLS Verify`: Proxmox serves a self-signed certificate. The route creates the CNAME `<public name>` → `<TUNNEL_ID>.cfargotunnel.com`.

### 6. Check

```bash
journalctl -u cloudflared -n 20 --no-pager                                            # "Registered tunnel connection" x4
curl -sI --doh-url https://cloudflare-dns.com/dns-query https://<public name> | grep -i '^location'   # → https://<team>.cloudflareaccess.com/…
```

> `--doh-url`: on Proxmox, `/etc/hosts` maps the host's own name to its LAN IP; public DNS goes through the tunnel instead. Same check from the workstation: plain `curl -sI`. A `200` without `location`: no Access application, or a bypass rule for your IP.

> No redirect to `cloudflareaccess.com`: Access protects nothing.

## Undo

```bash
systemctl disable --now cloudflared.service
rm -rf /etc/systemd/system/cloudflared.service /etc/cloudflared
systemctl daemon-reload
apt purge -y cloudflared
rm -f /etc/apt/sources.list.d/cloudflared.list /usr/share/keyrings/cloudflare-main.gpg
```

Then delete the tunnel and the Access application in the dashboard.

## Notes

- **Token**: it grants access to the tunnel. If it leaks: dashboard → tunnel → **Refresh token**, then `--new-token`.
- **DNS zone wiped**: the CNAME is gone, the URL stops answering while the tunnel stays HEALTHY. Save the route again (step 5).
- **noVNC / xterm.js console**: works through the tunnel.
- **Other services**: more routes on the same tunnel, each behind its own Access application.
- **ISO upload**: 100 MB max per request on the free plan; use the local IP for large files.
