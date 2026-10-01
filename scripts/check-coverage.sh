#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/../coverage}"

if ! command -v kcov >/dev/null 2>&1; then
  echo "[ERROR] kcov is required to compute coverage." >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

kcov --clean --include-path="$SCRIPT_DIR" "$OUT_DIR/installer" "$SCRIPT_DIR/test-installer.sh"
kcov --clean --include-path="$SCRIPT_DIR" "$OUT_DIR/uninstaller" "$SCRIPT_DIR/test-uninstaller.sh"

python3 - "$OUT_DIR/installer/cobertura.xml" "$SCRIPT_DIR/rke2-installer.sh" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

xml_path, target_path = sys.argv[1], os.path.realpath(sys.argv[2])
tree = ET.parse(xml_path)
root = tree.getroot()

for class_node in root.findall(".//class"):
    filename = class_node.attrib.get("filename", "")
    candidates = [
        os.path.realpath(filename),
        os.path.realpath(os.path.join(os.path.dirname(target_path), filename)),
        os.path.realpath(os.path.join(os.path.dirname(os.path.dirname(target_path)), filename)),
    ]
    if target_path in candidates:
        rate = float(class_node.attrib.get("line-rate", "0"))
        if rate != 1.0:
            print(f"[ERROR] Installer coverage is {rate * 100:.2f}%, expected 100%.", file=sys.stderr)
            sys.exit(1)
        print("[INFO]  Installer coverage is 100%")
        sys.exit(0)

print("[ERROR] Installer coverage report entry not found.", file=sys.stderr)
sys.exit(1)
PY

python3 - "$OUT_DIR/uninstaller/cobertura.xml" "$SCRIPT_DIR/rke2-uninstaller.sh" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

xml_path, target_path = sys.argv[1], os.path.realpath(sys.argv[2])
tree = ET.parse(xml_path)
root = tree.getroot()

for class_node in root.findall(".//class"):
    filename = class_node.attrib.get("filename", "")
    candidates = [
        os.path.realpath(filename),
        os.path.realpath(os.path.join(os.path.dirname(target_path), filename)),
        os.path.realpath(os.path.join(os.path.dirname(os.path.dirname(target_path)), filename)),
    ]
    if target_path in candidates:
        rate = float(class_node.attrib.get("line-rate", "0"))
        if rate != 1.0:
            print(f"[ERROR] Uninstaller coverage is {rate * 100:.2f}%, expected 100%.", file=sys.stderr)
            sys.exit(1)
        print("[INFO]  Uninstaller coverage is 100%")
        sys.exit(0)

print("[ERROR] Uninstaller coverage report entry not found.", file=sys.stderr)
sys.exit(1)
PY

echo "[INFO]  Coverage checks passed"
