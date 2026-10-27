# Tailscale

Private remote access to the LAN over Tailscale (subnet router + split DNS).
Public exposure is out of scope — see `docs/internet-exposure-plan.md`.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the dedicated router LXC, installs Tailscale, advertises the LAN route. |
| `update.sh` | Re-converges TUN/forwarding, upgrades Tailscale, re-asserts the advertised route. |
| `lib.sh` | Shared converge helpers (sourced by the scripts above, not run directly). |

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
| `TAILSCALE_AUTHKEY` | yes, first login | Auth key, needed only while the router is not on the tailnet. Transported via a pushed 0600 file and read with `--auth-key=file:`, never in argv or logs. Ignored with a warning when already logged in. |
| `TAILSCALE_LAN_CIDR` | no | LAN route to advertise. Auto-detected from the bridge; both scripts fail fast if undetectable, ambiguous, or invalid. |
| `TAILSCALE_ROUTER_NAME` | no | Router LXC name (default `tailscale-router`). Do not change after creation: the scripts resolve by exact name, so a rename orphans the old router instead of adopting it. |
| `TAILSCALE_DNS_IP` | no | AdGuard IP for the split-DNS hint. Auto-detected from the `adguard` container. |
| `TAILSCALE_DNS_ZONE` | no | Internal zone (default `marx.home`). |
| `TAILSCALE_LXC_CONF_DIR` | no | LXC config dir for the TUN passthrough lines (default `/etc/pve/lxc`). |

## Ports

Outbound only: `443/tcp` (control plane) and `41641/udp` (direct WireGuard).
No inbound port-forwards are opened.

## Caddy

The router LXC is always tagged `no-auto-proxy` (hardcoded) and must never
get a Caddy route. `caddy/generate-caddyfile.sh` lists every guest, so skip
`tailscale-router` manually when prompted. Automatic tag filtering is future
work (see `docs/internet-exposure-plan.md` Phase 4).

## Access model

Self-access only. Colleagues get nothing by default; grants are created
manually in the admin console, never by these scripts.

## Notes

- Both scripts fail fast without `/dev/net/tun` on the host.
- A re-run restarts the router briefly whenever TUN/forwarding converge;
  plan re-runs accordingly.
- When already logged in, `install.sh` skips `tailscale up` and only
  re-asserts routes — confirm the tailnet identity with
  `pct exec <id> -- tailscale status` before approving routes.
