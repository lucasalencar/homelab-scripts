# Pulse

Real-time monitoring dashboard for Proxmox VE, PBS, Docker and more. Single-pane view of all nodes, VMs and containers with alerts for failed backups, full disks and offline guests.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the `pulse` LXC container and installs Pulse via Docker. |
| `container/provision.sh` | Runs inside the LXC: installs Docker and starts Pulse on :7655. |
| `container/update.sh` | Runs inside the LXC: pulls and recreates the Pulse container. |
| `update.sh` | Updates OS packages inside the LXC, then runs `container/update.sh`. |

## Execution order

```
install.sh
update.sh   (run any time to upgrade)
```

## Install

```bash
bash pulse/install.sh
```

Pin a version:

```bash
PULSE_VERSION=vX.Y.Z bash pulse/install.sh
```

See `pulse/install.sh` for what each step does.

## First-run setup

1. Get the one-time setup token:
   ```bash
   pct exec <pulse-id> -- docker exec pulse /app/pulse bootstrap-token
   ```
2. Open `http://<pulse-ip>:7655`, paste the token, create the admin account.
3. In Proxmox, create a read-only monitor credential:
   - Datacenter -> Access -> Users -> Add (e.g. `pulse@pve`).
   - Permissions -> Add with role `PVEAuditor` (Sys.Audit, Datastore.Audit, VM.Audit) on `/`.
   - Select the user -> API Tokens -> Add, copy the token ID and secret.
4. In Pulse: Settings -> Infrastructure -> Add Proxmox, paste host, user (`pulse@pve`), token.

## Update

```bash
bash pulse/update.sh
```

See `pulse/update.sh` for details.

## Ports & Caddy

| Service | Port | Hostname |
|---|---|---|
| Pulse web UI + API | 7655 | `pulse.marx.home` |

Single CT = single port. Append to `caddy/Caddyfile.local`:

```
pulse.marx.home {
    tls internal
    reverse_proxy <IP>:7655
}
```

Then:

```bash
bash caddy/generate-caddyfile.sh
```

## Verification

```bash
pct exec $(pct list | grep -i -w pulse | awk "{print \$1}") -- docker ps --filter name=pulse
pct exec $(pct list | grep -i -w pulse | awk "{print \$1}") -- curl -fsS http://127.0.0.1:7655/ -o /dev/null && echo OK
ss -tlnp | grep 7655
```

## Resources

- [Pulse repo (rcourtman/Pulse)](https://github.com/rcourtman/Pulse)
- [Pulse MCP for AI agents](https://github.com/rcourtman/Pulse/blob/main/cmd/pulse-mcp/README.md)
- Default: 2 cores / 2048 MB / 8 GB / 512 MB swap. Adjust `CT_CORES`/`CT_MEMORY`/`CT_DISK`/`CT_SWAP` in `pulse/install.sh` if needed.
