#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/test-installer.sh"
"$SCRIPT_DIR/test-uninstaller.sh"
"$SCRIPT_DIR/test-integration.sh"

echo "[INFO]  All test suites passed"
