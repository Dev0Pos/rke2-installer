# rke2-installer

Small Bash toolkit for RKE2 install/uninstall (`server` / `agent`).

## Requirements
- Linux + `systemd`
- `root` or `sudo`
- `curl`

## Install
### Server (first node)
```bash
sudo ./scripts/rke2-installer.sh install --role server --cluster-init
```

### Agent
```bash
sudo ./scripts/rke2-installer.sh install \
  --role agent \
  --server-url https://<server>:9345 \
  --token <token>
```

Token:
```bash
cat /var/lib/rancher/rke2/server/node-token
```

## Safer mode
```bash
sudo ./scripts/rke2-installer.sh install \
  --role server \
  --cluster-init \
  --secure-install \
  --installer-sha256 <sha256>
```

## Useful commands
```bash
./scripts/rke2-installer.sh status --role server
./scripts/rke2-installer.sh info --role server
sudo ./scripts/rke2-uninstaller.sh --role server --force
```

## Checks
```bash
./scripts/test-all.sh
./scripts/check-coverage.sh
```

## License
MIT
