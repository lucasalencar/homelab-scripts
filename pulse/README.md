# Pulse

Real-time monitoring dashboard for Proxmox VE, PBS, Docker and more. Single-pane view of all nodes, VMs and containers with alerts for failed backups, full disks and offline guests.

Container creation and in-container setup delegate to the [community-scripts Pulse installer](https://github.com/community-scripts/ProxmoxVE/blob/main/ct/pulse.sh) (native binary + systemd service, no Docker).

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the `pulse` LXC container via the community script, then enables unprivileged ICMP probes (see `lib.sh`). |
| `update.sh` | Re-runs the community script (updates Pulse in place). |

## Execution order

```
install.sh
update.sh   (run any time to upgrade)
```

## Install

```bash
bash pulse/install.sh
```

See `pulse/install.sh` for what each step does.

## First-run setup

1. Open `http://<pulse-ip>:7655` and create the admin account.
2. In Proxmox, create a read-only monitor credential:
   - Datacenter -> Access -> Users -> Add (e.g. `pulse@pve`).
   - Permissions -> Add with role `PVEAuditor` (Sys.Audit, Datastore.Audit, VM.Audit) on `/`.
   - Select the user -> API Tokens -> Add, copy the token ID and secret.
3. In Pulse: Settings -> Infrastructure -> Add Proxmox, paste host, user (`pulse@pve`), token.

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
pct exec $(pct list | grep -i -w pulse | awk "{print \$1}") -- systemctl is-active pulse
pct exec $(pct list | grep -i -w pulse | awk "{print \$1}") -- curl -fsS http://127.0.0.1:7655/ -o /dev/null && echo OK
pct exec $(pct list | grep -i -w pulse | awk "{print \$1}") -- su -s /bin/sh pulse -c 'ping -c1 -W2 127.0.0.1'
```

## Resources

- [Pulse repo (rcourtman/Pulse)](https://github.com/rcourtman/Pulse)
- [Pulse MCP for AI agents](https://github.com/rcourtman/Pulse/blob/main/cmd/pulse-mcp/README.md)
