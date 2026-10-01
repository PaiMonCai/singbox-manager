# singbox-manager

A lightweight operations wrapper for running [sing-box](https://github.com/SagerNet/sing-box) with Docker Compose.

The project keeps sing-box itself clean and adds a host-side `sbx` command for installation, lifecycle management, config validation, logs, backup/restore, connectivity tests, and controlled upgrades.

> Status: MVP / first usable version.

## Quick start

```bash
git clone https://github.com/PaiMonCai/singbox-manager.git
cd singbox-manager
sudo bash install.sh
```

After installation:

```bash
sbx
```

or use direct commands:

```bash
sbx status
sbx start
sbx stop
sbx restart
sbx logs
sbx edit
sbx check
sbx format
sbx test
sbx backup
sbx restore
sbx version
sbx upgrade v1.14.1
```

## Design

```text
Host
├── /usr/local/bin/sbx
└── /opt/singbox-manager
    ├── compose.yml
    ├── .env
    ├── config/
    │   └── config.json
    ├── data/
    └── backup/
            │
            ▼
      sing-box container
```

The container only runs sing-box. Management stays on the host, so restarting, updating, editing configuration, backups, and Docker operations do not interfere with the container's PID 1.

## Default behavior

The example configuration exposes a mixed HTTP/SOCKS inbound on container port `7890`, mapped to host `127.0.0.1:7890`.

The included example outbound is `direct` so the initial configuration is valid before you add your own proxy node. Replace or extend the outbound section in:

```text
/opt/singbox-manager/config/config.json
```

Then validate and restart:

```bash
sbx check
sbx restart
```

For applications that support an explicit HTTP proxy:

```bash
export HTTP_PROXY=http://127.0.0.1:7890
export HTTPS_PROXY=http://127.0.0.1:7890
```

## Commands

| Command | Description |
| --- | --- |
| `sbx` | Open interactive menu |
| `sbx status` | Show container status |
| `sbx start` | Start sing-box |
| `sbx stop` | Stop sing-box |
| `sbx restart` | Restart sing-box after config validation |
| `sbx logs` | Follow logs |
| `sbx edit` | Edit `config.json` |
| `sbx check` | Run sing-box config check |
| `sbx format` | Format configuration |
| `sbx test` | Test local proxy and international connectivity |
| `sbx backup` | Create a timestamped config backup |
| `sbx restore [file]` | Restore a config backup |
| `sbx version` | Show manager and sing-box versions |
| `sbx upgrade <tag>` | Switch to a specific sing-box image tag |
| `sbx pull` | Pull the currently pinned image |
| `sbx uninstall` | Remove manager; preserves backups by default |

## Upgrade safety

`sbx upgrade <tag>` follows this sequence:

1. Back up the current config.
2. Update the pinned image tag in `.env`.
3. Pull the requested image.
4. Validate the existing config with the new image.
5. Recreate the container only when validation succeeds.
6. Restore the previous version setting if validation fails.

This keeps image upgrades explicit and reduces accidental breakage.

## Files

```text
.
├── .env.example
├── .github/workflows/ci.yml
├── .gitignore
├── bin/
│   └── sbx
├── compose.yml
├── config/
│   └── config.example.json
└── install.sh
```

## Requirements

- Linux
- root/sudo for installation
- Docker Engine
- Docker Compose v2
- curl
- tar
- a text editor such as `vi`, `vim`, or `nano`

## Roadmap

Planned next layers:

- node add/remove/list commands
- subscription import
- route presets
- Docker / APT / Git / npm proxy helpers
- transparent proxy / TUN mode
- health diagnostics
- remote manager integration

## Security notes

- The proxy port is bound to `127.0.0.1` by default and is not exposed publicly.
- Do not commit real node credentials or private keys to the repository.
- Keep your production `config.json` outside Git; the repository only tracks an example.
