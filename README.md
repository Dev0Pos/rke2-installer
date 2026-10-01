# rke2-installer

Minimal Bash toolkit to install, manage, and uninstall RKE2 nodes (`server` / `agent`).

## Requirements
- Linux with `systemd`
- `root` or `sudo`
- `curl`
- Internet access to `get.rke2.io`

## Quick start
1) Server (first node):
```bash
sudo ./scripts/rke2-installer.sh install --role server --cluster-init
# Safer mode (downloads installer script before execution)
sudo ./scripts/rke2-installer.sh install --role server --cluster-init --secure-install
# Safer mode with explicit SHA256 verification
sudo ./scripts/rke2-installer.sh install --role server --cluster-init --secure-install --installer-sha256 <sha256>
# Safer mode with checksum file URL verification
sudo ./scripts/rke2-installer.sh install --role server --cluster-init --secure-install --installer-sha256-url <checksum-url>
```

2) Agent:
```bash
sudo ./scripts/rke2-installer.sh install \
  --role agent \
  --server-url https://<server-address>:9345 \
  --token <token>
```

Get token from first server:
```bash
cat /var/lib/rancher/rke2/server/node-token
```

## Secure install (recommended)
```bash
sudo ./scripts/rke2-installer.sh install --role server --cluster-init --secure-install
```

With explicit checksum:
```bash
sudo ./scripts/rke2-installer.sh install \
  --role server \
  --cluster-init \
  --secure-install \
  --installer-sha256 <sha256>
```

With checksum file URL:
```bash
sudo ./scripts/rke2-installer.sh install \
  --role server \
  --cluster-init \
  --secure-install \
  --installer-sha256-url <checksum-url>
```

## Useful commands
```bash
# status / info
./scripts/rke2-installer.sh status --role server
./scripts/rke2-installer.sh info --role server

# uninstall helper
sudo ./scripts/rke2-uninstaller.sh --role server --force
./scripts/rke2-uninstaller.sh --dry-run
```

## Configuration
- Use `--config <path>` to pass your own `config.yaml`
- Ready examples:
  - `examples/server-config.yaml`
  - `examples/agent-config.yaml`
  - `examples/server-config-extended-tokens.yaml`

## Quality checks
```bash
./scripts/test-all.sh
./scripts/check-coverage.sh
```

## Release artifacts
```bash
./scripts/build-release-artifacts.sh vX.Y.Z
```

Tag `v*` triggers automatic GitHub release with artifact + SHA256.

## License
MIT (see `LICENSE`).
