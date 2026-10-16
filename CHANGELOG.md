# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- SHA256 verification flags for secure installer downloads (`--installer-sha256`, `--installer-sha256-url`).
- CLI-level integration test suite (`scripts/test-integration.sh`).
- Automated release artifact builder (`scripts/build-release-artifacts.sh`).
- GitHub release workflow for tag-based releases with auto-generated notes.

### Changed
- CI now validates integration tests and release artifact generation in addition to lint, unit tests, and coverage gates.
- README documents checksum install, dual uninstallers, config overwrite rules, path overrides, and operator pitfalls.
- `status` and `rke2-uninstaller.sh` resolve unit files across tarball (`/usr/local/lib`), RPM (`/usr/lib`), relocated (`/etc/systemd`), and systemd `FragmentPath` layouts.
- README documents unit-file search order, `RKE2_SYSTEMD_UNIT_SEARCH_DIRS`, and Ubuntu/Debian tarball install paths.
