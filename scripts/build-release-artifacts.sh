#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="${1:-}"
OUTPUT_DIR="${2:-$REPO_ROOT/dist}"

if [[ -z "$VERSION" ]]; then
	VERSION="$(git -C "$REPO_ROOT" describe --tags --always)"
fi

PACKAGE_NAME="rke2-installer-${VERSION}"
WORK_DIR="$(mktemp -d)"
PACKAGE_DIR="$WORK_DIR/$PACKAGE_NAME"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$PACKAGE_DIR/scripts" "$PACKAGE_DIR/examples"
cp "$REPO_ROOT"/README.md "$REPO_ROOT"/LICENSE "$PACKAGE_DIR"/
cp "$REPO_ROOT"/scripts/rke2-installer.sh "$REPO_ROOT"/scripts/rke2-uninstaller.sh "$PACKAGE_DIR/scripts/"
cp "$REPO_ROOT"/examples/*.yaml "$PACKAGE_DIR/examples/"

mkdir -p "$OUTPUT_DIR"
TARBALL_PATH="$OUTPUT_DIR/${PACKAGE_NAME}.tar.gz"
tar -czf "$TARBALL_PATH" -C "$WORK_DIR" "$PACKAGE_NAME"
sha256sum "$TARBALL_PATH" >"${TARBALL_PATH}.sha256"

echo "[INFO]  Created release artifacts:"
echo "[INFO]  - $TARBALL_PATH"
echo "[INFO]  - ${TARBALL_PATH}.sha256"
