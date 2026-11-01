# rke2-installer

Bash wrapper around the official [RKE2](https://docs.rke2.io/) installer (`https://get.rke2.io`). Writes `config.yaml`, runs `INSTALL_RKE2_*`, then enables `rke2-server` / `rke2-agent` with retries.

## Requirements

- Linux + `systemd` + `curl`; `install` / `uninstall` need `root`
- Arch: `x86_64`, `amd64`, `aarch64`, `arm64` (others exit)
- OS ID warn-only unless `ubuntu|debian|centos|rhel|rocky|alma|fedora|amzn`
- Under 1 GiB free on `/` or 512 MiB available RAM: warn, do not fail
- Swap on: warn unless `--auto-swapoff` (comments `fstab` swap lines after a timestamped backup)

## Install

### Server (first node)

```bash
sudo ./scripts/rke2-installer.sh install --role server --cluster-init
```

Token for other nodes:

```bash
cat /var/lib/rancher/rke2/server/node-token
```

Kubeconfig: `/etc/rancher/rke2/rke2.yaml` (generated with `write-kubeconfig-mode: "0644"`).

### Agent

```bash
sudo ./scripts/rke2-installer.sh install \
  --role agent \
  --server-url https://<server>:9345 \
  --token <token>
```

`--token-file <path>` is accepted instead of `--token`. Agent always requires a CLI token (`--token` or `--token-file`), even when `--config` already contains `token:`. `--server-url` is required only when the script generates config (not when `--config` is set).

### Additional servers

`--server-url` is written only for `--role agent`. A joining server needs `--config` with `token` and `server:` (port `9345`). `--cluster-init` is first-node only.

### Safer download

Default install is `curl | sh -`. Prefer:

```bash
sudo ./scripts/rke2-installer.sh install \
  --role server \
  --cluster-init \
  --secure-install \
  --installer-sha256 <64-hex>
```

Or `--installer-sha256-url <url>` (sha256sum-style file). Either checksum flag turns on `--secure-install`. If both are set, the hex value wins. Mismatch or a non-64-hex digest exits.

`--secure-install` without a checksum still downloads to a `0700` tempfile, then `sh`s it (no pipe).

## Flags (`install`)

| Flag | Effect |
|------|--------|
| `--role server\|agent` | Required |
| `--channel <name>` | `INSTALL_RKE2_CHANNEL` (default `stable`) |
| `--version <vX.Y.Z+rke2rN>` | `INSTALL_RKE2_VERSION` |
| `--config <path>` | Copy over `/etc/rancher/rke2/config.yaml` (overwrites) |
| `--server-url <url>` | Agent generated config only |
| `--token` / `--token-file` | Token; required for agent |
| `--cluster-init` | Write `cluster-init: true` (server) |
| `--auto-swapoff` | `swapoff -a` + comment fstab swap lines |
| `--force` | Reinstall even if `rke2` is already on PATH |
| `--secure-install` | Download-then-exec (no pipe-to-shell) |
| `--installer-sha256` | Expected digest of the installer script |
| `--installer-sha256-url` | Checksum file URL (bare hash or `hash  filename`) |

Already installed + no `--force` + no `--version` → skip download. The unit is still `enable`d and `restart`ed (first wait 120s), so a re-run is not a no-op on a healthy node.

Existing `/etc/rancher/rke2/config.yaml` is **not** overwritten when generating from flags. `--config` always copies. Generated or copied `config.yaml` is mode `0600` (it may contain a join token).

Examples: `examples/server-config.yaml`, `examples/agent-config.yaml`, `examples/server-config-extended-tokens.yaml`.

CNI tokens that drop daily: use the extended-tokens example (`service-account-max-token-expiration=168h`). The installer does not inject those args unless you pass `--config`.

## Commands

```bash
./scripts/rke2-installer.sh status --role server   # unit + version + config sizes
./scripts/rke2-installer.sh info --role server     # host, paths, dir sizes; no root
```

`status` exits `1` if no `rke2-<role>.service` is found (unit search below). Ubuntu/Debian `get.rke2.io` installs land in `/usr/local/lib`. `info` always prints (including “not installed”) and uses `systemctl list-unit-files`, not that search. Server `info` lists API `https://localhost:6443`, node port `9345`, default CNI text `Canal (Flannel + Calico)` (not probed), and any files that exist in `RKE2_LOG_FILES`.

Start path: `systemctl enable` + up to 3 `restart`s (first wait 120s, then 30s). Server then waits up to 60s for `etcd --config-file`. Failure: `journalctl -u rke2-<role> -e`.

## Uninstall

Two entry points. The dedicated script is the operator path.

| | `rke2-installer.sh uninstall --role …` | `rke2-uninstaller.sh` |
|---|---|---|
| Role | Required | Auto-detected with the same unit search as `status`; `--role` required if both exist |
| Confirm | None | Exact `yes` (any case). `y` / `true` cancel |
| Dry-run | No | `--dry-run` (no root, no backup) |
| Backup | `/tmp/rke2-backup-<timestamp>`: config, kubeconfig (server), node-token (dir `0700`, secret files `0600`) | Same + resolved unit file; `--backup-dir` overrides |
| Official script | First executable match: override path, then `/usr/local/bin`, `/usr/bin` (RPM), `/opt/rke2/bin`. Agent also falls back from `rke2-agent-uninstall.sh` to `rke2-uninstall.sh`. | Stop/disable unit first, then the same search |
| Data wipe | No | `--clean-data` removes `RKE2_DATA_DIRS`, `RKE2_BINARY_PATH`, and the preferred uninstall script paths only (not RPM `/usr/bin` copies). Not run if the official script exits non-zero |

```bash
./scripts/rke2-uninstaller.sh --dry-run --clean-data
sudo ./scripts/rke2-uninstaller.sh --role server --force
sudo ./scripts/rke2-installer.sh uninstall --role server
```

`/tmp` backups are ephemeral. Secret files in the backup are mode `0600`; a backup directory this script creates is `0700`. `--clean-data` is irreversible.

## Checks

```bash
./scripts/test-all.sh          # unit + CLI integration (mocked host; no live RKE2)
./scripts/check-coverage.sh    # 100% line gate used by CI
```

CI (`.github/workflows/ci.yml`) runs on pushes to `main` and `cursor/**`, and on PRs targeting `main`: `bash -n`, ShellCheck, shfmt, those two scripts, plus `./scripts/build-release-artifacts.sh ci-smoke /tmp/rke2-dist`. Coverage is an xtrace line gate over `rke2-installer.sh` and `rke2-uninstaller.sh`.

## Release

```bash
./scripts/build-release-artifacts.sh vX.Y.Z        # optional 2nd arg: output dir (default dist/)
```

Packs README, LICENSE, both scripts, and `examples/*.yaml`. Default version is `git describe --tags --always`. Push a `v*` tag (or `workflow_dispatch`) to publish the tarball + `.sha256` via `.github/workflows/release.yml`.

## Path overrides

Set before invoke (tests do this). Defaults:

| Variable | Default |
|----------|---------|
| `RKE2_CONFIG_DIR` | `/etc/rancher/rke2` |
| `RKE2_CONFIG_FILE` | `$RKE2_CONFIG_DIR/config.yaml` |
| `RKE2_KUBECONFIG_FILE` | `$RKE2_CONFIG_DIR/rke2.yaml` |
| `RKE2_NODE_TOKEN_FILE` | `/var/lib/rancher/rke2/server/node-token` |
| `RKE2_SYSTEMD_UNIT_DIR` | `/usr/lib/systemd/system` (checked first) |
| `RKE2_SYSTEMD_UNIT_SEARCH_DIRS` | `/usr/local/lib/systemd/system /usr/lib/systemd/system /etc/systemd/system` |
| `RKE2_INSTALL_URL` | `https://get.rke2.io` |
| `RKE2_BACKUP_ROOT` | `/tmp` |
| `RKE2_DATA_DIRS` | `/var/lib/rancher/rke2 /etc/rancher/rke2 /opt/rke2` |
| `RKE2_SERVER_UNINSTALL_SCRIPT` | `/usr/local/bin/rke2-uninstall.sh` (preferred; search continues if missing) |
| `RKE2_AGENT_UNINSTALL_SCRIPT` | `/usr/local/bin/rke2-agent-uninstall.sh` (preferred; search continues if missing) |
| `RKE2_UNINSTALL_SCRIPT_SEARCH_DIRS` | `/usr/local/bin /usr/bin /opt/rke2/bin` |
| `RKE2_BINARY_PATH` | `/usr/bin/rke2` (uninstaller `--clean-data` only) |
| `RKE2_FSTAB_FILE` | `/etc/fstab` (`--auto-swapoff`) |
| `RKE2_OS_RELEASE_FILE` | `/etc/os-release` |
| `RKE2_LOG_FILES` | `/var/log/rke2.log /var/log/rke2-server.log /var/log/rke2-agent.log` (`info` only) |

`status` and `rke2-uninstaller.sh` then fall back to `systemctl show --property=FragmentPath` if those dirs miss the unit.

## Pitfalls

- Re-run without `--force`/`--version` will not upgrade an existing binary, but still `systemctl restart`s the unit (first wait 120s).
- Flag-generated config will not replace an existing `config.yaml`.
- `--server-url` on `--role server` is ignored unless you pass `--config`.
- Agent `--config` still needs `--token` / `--token-file` on the CLI; a `token:` in the YAML is not enough.
- Checksum URL file: first 64-hex digest whose optional 2nd field is empty, equals `RKE2_INSTALL_URL` (or its basename, default `get.rke2.io`), or equals the tempfile path/basename. A leading `*` (sha256sum binary mode) is stripped. Other filenames are skipped.
- First `rke2-server` start blocks ~2 minutes for etcd.
- Both unit files installed → dedicated uninstaller needs `--role`.
- Dedicated confirm is the word `yes` (any case). `y` cancels.
- Official uninstall script non-zero exit is fatal (`set -e`). Dedicated `--clean-data` does not run after that.
- `--clean-data` deletes only the preferred uninstall script paths (`RKE2_SERVER_UNINSTALL_SCRIPT` / `RKE2_AGENT_UNINSTALL_SCRIPT`, default `/usr/local/bin`). RPM copies in `/usr/bin` stay. Relocated `/opt/rke2/bin` scripts go away only because `/opt/rke2` is in `RKE2_DATA_DIRS`.
- `status` is not a health probe; it only requires a resolvable unit file (tarball, RPM, relocated, or `FragmentPath`).
- Dedicated uninstaller refuses to run if that search finds nothing; `rke2-installer.sh uninstall` still only needs the official uninstall script.

## License

MIT
