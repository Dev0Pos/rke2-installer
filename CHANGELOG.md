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
