# Home Assistant OS

Smart home platform running as a Proxmox VM.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the VM using the community HAOS script. |
| `update.sh` | Upgrades core/supervisor/OS/add-ons via guest agent, then pending `update.*` entities (Marketplace, formerly HACS) via the HA API. |

## Execution order

```
install.sh
update.sh   (run any time to upgrade)
```

## Configuration

| Variable | Description |
|---|---|
| `HA_TOKEN` / `HA_TOKEN_FILE` | Long-lived access token for Marketplace updates (HA: Profile -> Security -> Long-lived access tokens). Without it, core/supervisor/OS/add-ons still update; Marketplace is skipped. |
| `HA_URL` | Home Assistant base URL (default `http://<vm-ip>:8123`). |
