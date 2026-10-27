# Tailscale

Private remote access to the LAN over Tailscale (subnet router + split DNS).
Public exposure is out of scope — see `docs/internet-exposure-plan.md`.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the dedicated router LXC, installs Tailscale, advertises the LAN route. |
| `update.sh` | Upgrades Tailscale inside the router and re-asserts the advertised route. |

## Execution order

```
TAILSCALE_AUTHKEY='tskey-...' bash tailscale/install.sh   (first time + re-runs)
bash tailscale/update.sh                                   (run any time to upgrade)
```

Manual follow-ups printed by `install.sh`: approve the route in the admin
console, add the split-DNS entry, install clients with `--accept-routes`.

## Environment

| Variable | Required | Description |
|---|---|---|
| `TAILSCALE_AUTHKEY` | yes (install) | Auth key for the router node. Transported via a pushed 0600 file, never in argv/logs. |
| `TAILSCALE_LAN_CIDR` | no | LAN route to advertise. Auto-detected from the bridge; install fails fast if undetectable. |
| `TAILSCALE_ROUTER_NAME` | no | Router LXC name (default `tailscale-router`). |
| `TAILSCALE_ROUTER_TAGS` | no | Router LXC tags (default `no-auto-proxy`). |
| `TAILSCALE_DNS_IP` | no | AdGuard IP for the split-DNS hint. Auto-detected from the `adguard` container. |
| `TAILSCALE_DNS_ZONE` | no | Internal zone (default `marx.home`). |
| `TAILSCALE_LXC_CONF_DIR` | no | LXC config dir for the TUN passthrough lines (default `/etc/pve/lxc`). |

## Ports

Outbound only: `443/tcp` (control plane) and `41641/udp` (direct WireGuard).
No inbound port-forwards are opened.

## Caddy

The router LXC is tagged `no-auto-proxy` and must never get a Caddy route.
`caddy/generate-caddyfile.sh` lists every guest, so skip `tailscale-router`
manually when prompted. Automatic tag filtering is future work
(see `docs/internet-exposure-plan.md` Phase 4).

## Access model

Self-access only. Colleagues get nothing by default; grants are created
manually in the admin console, never by these scripts.
