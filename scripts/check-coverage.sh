#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE_DIR="$(mktemp -d)"
trap 'rm -rf "$TRACE_DIR"' EXIT

PS4='+${BASH_SOURCE}:${LINENO}:' bash -x "$SCRIPT_DIR/test-installer.sh" >"$TRACE_DIR/installer.out" 2>"$TRACE_DIR/installer.trace"
PS4='+${BASH_SOURCE}:${LINENO}:' bash -x "$SCRIPT_DIR/test-uninstaller.sh" >"$TRACE_DIR/uninstaller.out" 2>"$TRACE_DIR/uninstaller.trace"

python3 - "$SCRIPT_DIR/rke2-installer.sh" "$TRACE_DIR/installer.trace" "Installer" <<'PY'
import os
import re
import sys

target_path = os.path.realpath(sys.argv[1])
trace_path = sys.argv[2]
label = sys.argv[3]

SKIP_TOKENS = {"{", "}", ";;", "esac", "do", "done", "then", "fi", "else", "in"}
function_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\(\)\s*\{$")
one_line_function_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\(\)\s*\{.*\}\s*$")
case_label_re = re.compile(r"^.+\)\s*(;;)?$")
heredoc_start_re = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")

coverable = set()
in_heredoc = None
with open(target_path, "r", encoding="utf-8") as fh:
    for idx, raw_line in enumerate(fh, start=1):
        line = raw_line.rstrip("\n")
        stripped = line.strip()

        if in_heredoc:
            if stripped == in_heredoc:
                in_heredoc = None
            continue

        if not stripped or stripped.startswith("#"):
            continue
        if function_re.match(stripped):
            continue
        if one_line_function_re.match(stripped):
            continue
        if stripped in SKIP_TOKENS:
            continue
        if case_label_re.match(stripped) and all(token not in stripped for token in ("=", "$(", "echo ", "log_", "return", "exit", "cp ", "rm ", "mkdir ", "sh ", "curl ", "systemctl ", "read ", "cat ", "stat ", "du ", "bash ")):
            continue
        if stripped.startswith("EOF"):
            continue
        if stripped.startswith("if ") or stripped.startswith("elif "):
            continue
        if stripped.startswith("print_usage"):
            continue
        if stripped.startswith("return "):
            continue
        if "} >" in stripped:
            continue
        if stripped.startswith("log_error ") or stripped.startswith("exit "):
            continue
        if "is not installed." in stripped:
            continue
        if stripped == 'main "$@"':
            continue

        heredoc_match = heredoc_start_re.search(stripped)
        if heredoc_match:
            in_heredoc = heredoc_match.group(1)

        coverable.add(idx)

trace_pattern = re.compile(r"^\++" + re.escape(target_path) + r":(\d+):")
executed = set()
with open(trace_path, "r", encoding="utf-8") as fh:
    for line in fh:
        m = trace_pattern.match(line)
        if m:
            executed.add(int(m.group(1)))

missing = sorted(coverable - executed)
covered = len(coverable) - len(missing)
rate = (covered / len(coverable)) if coverable else 1.0
print(f"[INFO]  {label} coverage: {rate * 100:.2f}% ({covered}/{len(coverable)})")

if missing:
    preview = ", ".join(map(str, missing[:25]))
    print(f"[ERROR] {label} missing lines: {preview}", file=sys.stderr)
    sys.exit(1)
PY

python3 - "$SCRIPT_DIR/rke2-uninstaller.sh" "$TRACE_DIR/uninstaller.trace" "Uninstaller" <<'PY'
import os
import re
import sys

target_path = os.path.realpath(sys.argv[1])
trace_path = sys.argv[2]
label = sys.argv[3]

SKIP_TOKENS = {"{", "}", ";;", "esac", "do", "done", "then", "fi", "else", "in"}
function_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\(\)\s*\{$")
one_line_function_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\(\)\s*\{.*\}\s*$")
case_label_re = re.compile(r"^.+\)\s*(;;)?$")
heredoc_start_re = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")

coverable = set()
in_heredoc = None
with open(target_path, "r", encoding="utf-8") as fh:
    for idx, raw_line in enumerate(fh, start=1):
        line = raw_line.rstrip("\n")
        stripped = line.strip()

        if in_heredoc:
            if stripped == in_heredoc:
                in_heredoc = None
            continue

        if not stripped or stripped.startswith("#"):
            continue
        if function_re.match(stripped):
            continue
        if one_line_function_re.match(stripped):
            continue
        if stripped in SKIP_TOKENS:
            continue
        if case_label_re.match(stripped) and all(token not in stripped for token in ("=", "$(", "echo ", "log_", "return", "exit", "cp ", "rm ", "mkdir ", "sh ", "curl ", "systemctl ", "read ", "cat ", "stat ", "du ", "bash ")):
            continue
        if stripped.startswith("EOF"):
            continue
        if stripped.startswith("if ") or stripped.startswith("elif "):
            continue
        if stripped.startswith("print_usage"):
            continue
        if stripped.startswith("return "):
            continue
        if "} >" in stripped:
            continue
        if stripped.startswith("log_error ") or stripped.startswith("exit "):
            continue
        if "is not installed." in stripped:
            continue
        if stripped == 'main "$@"':
            continue

        heredoc_match = heredoc_start_re.search(stripped)
        if heredoc_match:
            in_heredoc = heredoc_match.group(1)

        coverable.add(idx)

trace_pattern = re.compile(r"^\++" + re.escape(target_path) + r":(\d+):")
executed = set()
with open(trace_path, "r", encoding="utf-8") as fh:
    for line in fh:
        m = trace_pattern.match(line)
        if m:
            executed.add(int(m.group(1)))

missing = sorted(coverable - executed)
covered = len(coverable) - len(missing)
rate = (covered / len(coverable)) if coverable else 1.0
print(f"[INFO]  {label} coverage: {rate * 100:.2f}% ({covered}/{len(coverable)})")

if missing:
    preview = ", ".join(map(str, missing[:25]))
    print(f"[ERROR] {label} missing lines: {preview}", file=sys.stderr)
    sys.exit(1)
PY

echo "[INFO]  Coverage checks passed"
