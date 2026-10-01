#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_SCRIPT="$SCRIPT_DIR/rke2-installer.sh"
UNINSTALLER_SCRIPT="$SCRIPT_DIR/rke2-uninstaller.sh"

log_info() { echo -e "[INFO]  $*"; }
log_error() { echo -e "[ERROR] $*" >&2; }

assert_file_exists() {
	local path="$1"
	[[ -f "$path" ]]
}

assert_contains() {
	local haystack="$1" needle="$2"
	[[ "$haystack" == *"$needle"* ]]
}

setup_env() {
	TEST_ROOT="$(mktemp -d)"
	FAKE_BIN="$TEST_ROOT/fake-bin"
	STATE_DIR="$TEST_ROOT/state"
	mkdir -p "$FAKE_BIN" "$STATE_DIR"

	export MOCK_UID=0
	export MOCK_SYSTEMD_STATE_DIR="$STATE_DIR/systemd"
	export MOCK_STATE_DIR="$STATE_DIR/mock"
	export RKE2_CONFIG_DIR="$TEST_ROOT/etc/rancher/rke2"
	export RKE2_CONFIG_FILE="$RKE2_CONFIG_DIR/config.yaml"
	export RKE2_KUBECONFIG_FILE="$RKE2_CONFIG_DIR/rke2.yaml"
	export RKE2_NODE_TOKEN_FILE="$TEST_ROOT/var/lib/rancher/rke2/server/node-token"
	export RKE2_SYSTEMD_UNIT_DIR="$TEST_ROOT/usr/lib/systemd/system"
	export RKE2_SERVER_UNINSTALL_SCRIPT="$TEST_ROOT/usr/local/bin/rke2-uninstall.sh"
	export RKE2_AGENT_UNINSTALL_SCRIPT="$TEST_ROOT/usr/local/bin/rke2-agent-uninstall.sh"
	export RKE2_BINARY_PATH="$TEST_ROOT/usr/bin/rke2"
	export RKE2_BACKUP_ROOT="$TEST_ROOT/tmp"
	export RKE2_OS_RELEASE_FILE="$TEST_ROOT/etc/os-release"
	export RKE2_DATA_DIRS="$TEST_ROOT/var/lib/rancher/rke2 $RKE2_CONFIG_DIR $TEST_ROOT/opt/rke2"
	export RKE2_LOG_FILES="$TEST_ROOT/var/log/rke2.log $TEST_ROOT/var/log/rke2-server.log $TEST_ROOT/var/log/rke2-agent.log"

	mkdir -p \
		"$RKE2_CONFIG_DIR" \
		"$(dirname "$RKE2_NODE_TOKEN_FILE")" \
		"$RKE2_SYSTEMD_UNIT_DIR" \
		"$(dirname "$RKE2_SERVER_UNINSTALL_SCRIPT")" \
		"$(dirname "$RKE2_AGENT_UNINSTALL_SCRIPT")" \
		"$(dirname "$RKE2_BINARY_PATH")" \
		"$RKE2_BACKUP_ROOT" \
		"$(dirname "$RKE2_OS_RELEASE_FILE")" \
		"$MOCK_SYSTEMD_STATE_DIR" \
		"$MOCK_STATE_DIR"
	echo 'ID=ubuntu' >"$RKE2_OS_RELEASE_FILE"
	echo 'PRETTY_NAME="Mock Ubuntu"' >>"$RKE2_OS_RELEASE_FILE"

	cat >"$FAKE_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
  echo "${MOCK_UID:-0}"
else
  /usr/bin/id "$@"
fi
EOF

	cat >"$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="${MOCK_SYSTEMD_STATE_DIR:?}"
mkdir -p "$state_dir"
cmd="${1:-}"
case "$cmd" in
  enable)
    svc="$2"
    touch "$state_dir/${svc}.enabled"
    ;;
  restart)
    svc="$2"
    touch "$state_dir/${svc}.active"
    ;;
  stop)
    svc="$2"
    rm -f "$state_dir/${svc}.active"
    ;;
  disable)
    svc="$2"
    rm -f "$state_dir/${svc}.enabled"
    ;;
  is-active)
    if [[ "${2:-}" == "--quiet" ]]; then
      svc="$3"
    else
      svc="$2"
    fi
    [[ -f "$state_dir/${svc}.active" ]]
    ;;
  is-enabled)
    svc="$2"
    [[ -f "$state_dir/${svc}.enabled" ]]
    ;;
  list-unit-files)
    if [[ -f "${RKE2_SYSTEMD_UNIT_DIR}/rke2-server.service" ]]; then
      echo "rke2-server.service enabled"
    fi
    if [[ -f "${RKE2_SYSTEMD_UNIT_DIR}/rke2-agent.service" ]]; then
      echo "rke2-agent.service enabled"
    fi
    ;;
  show)
    svc="$2"
    echo "FragmentPath=${RKE2_SYSTEMD_UNIT_DIR}/${svc}.service"
    ;;
  status)
    svc="$2"
    echo "mock status for ${svc}"
    ;;
  *)
    echo "mocked systemctl: $*" >/dev/null
    ;;
esac
EOF

	cat >"$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

	cat >"$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

	cat >"$FAKE_BIN/rke2" <<'EOF'
#!/usr/bin/env bash
if [[ -f "${MOCK_STATE_DIR}/rke2-installed" ]]; then
  echo "rke2 version v1.33.7+rke2r1"
  exit 0
fi
exit 1
EOF

	chmod +x "$FAKE_BIN/"*
	export PATH="$FAKE_BIN:/usr/bin:/bin"

	MOCK_INSTALLER_SCRIPT="$TEST_ROOT/mock-rke2-installer.sh"
	cat >"$MOCK_INSTALLER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${INSTALL_RKE2_TYPE:?}"
: "${MOCK_STATE_DIR:?}"
: "${RKE2_SYSTEMD_UNIT_DIR:?}"
: "${RKE2_SERVER_UNINSTALL_SCRIPT:?}"
: "${RKE2_AGENT_UNINSTALL_SCRIPT:?}"
mkdir -p "$RKE2_SYSTEMD_UNIT_DIR" "$(dirname "$RKE2_SERVER_UNINSTALL_SCRIPT")" "$(dirname "$RKE2_AGENT_UNINSTALL_SCRIPT")" "${MOCK_STATE_DIR}"
touch "$RKE2_SYSTEMD_UNIT_DIR/rke2-${INSTALL_RKE2_TYPE}.service"
touch "${MOCK_STATE_DIR}/rke2-installed"
cat >"$RKE2_SERVER_UNINSTALL_SCRIPT" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
echo "server-uninstall" >> "${MOCK_STATE_DIR}/uninstall.log"
EOS
cat >"$RKE2_AGENT_UNINSTALL_SCRIPT" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
echo "agent-uninstall" >> "${MOCK_STATE_DIR}/uninstall.log"
EOS
chmod +x "$RKE2_SERVER_UNINSTALL_SCRIPT" "$RKE2_AGENT_UNINSTALL_SCRIPT"
EOF
	chmod +x "$MOCK_INSTALLER_SCRIPT"

	MOCK_CHECKSUM_FILE="$TEST_ROOT/mock-rke2-installer.sha256"
	local installer_sha
	installer_sha="$(sha256sum "$MOCK_INSTALLER_SCRIPT" | awk '{print $1}')"
	echo "${installer_sha}  $(basename "$MOCK_INSTALLER_SCRIPT")" >"$MOCK_CHECKSUM_FILE"

	export RKE2_INSTALL_URL="file://$MOCK_INSTALLER_SCRIPT"
	export MOCK_INSTALLER_SHA="$installer_sha"
	export MOCK_CHECKSUM_URL="file://$MOCK_CHECKSUM_FILE"
}

teardown_env() {
	rm -rf "${TEST_ROOT:-}"
}

test_secure_install_checksum() {
	setup_env

	"$INSTALLER_SCRIPT" install --role server --cluster-init --secure-install --installer-sha256 "$MOCK_INSTALLER_SHA"
	assert_file_exists "$RKE2_SYSTEMD_UNIT_DIR/rke2-server.service"
	assert_file_exists "$RKE2_CONFIG_FILE"
	assert_file_exists "$MOCK_STATE_DIR/rke2-installed"

	local bad_sha
	bad_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if "$INSTALLER_SCRIPT" install --role server --force --secure-install --installer-sha256 "$bad_sha" >/tmp/rke2-integration.err 2>&1; then
		teardown_env
		return 1
	fi
	assert_contains "$(cat /tmp/rke2-integration.err)" "checksum mismatch"

	teardown_env
}

test_checksum_url_and_lifecycle() {
	setup_env
	echo "secure-token" >"$TEST_ROOT/token.txt"

	"$INSTALLER_SCRIPT" install --role server --cluster-init --secure-install --installer-sha256-url "$MOCK_CHECKSUM_URL"
	"$INSTALLER_SCRIPT" install --role agent --server-url "https://server.example:9345" --token-file "$TEST_ROOT/token.txt" --secure-install --installer-sha256-url "$MOCK_CHECKSUM_URL"

	local status_output info_output
	status_output="$("$INSTALLER_SCRIPT" status --role server)"
	info_output="$("$INSTALLER_SCRIPT" info --role server)"
	assert_contains "$status_output" "RKE2 server Status"
	assert_contains "$info_output" "RKE2 server Information"

	"$UNINSTALLER_SCRIPT" --role agent --force
	"$INSTALLER_SCRIPT" uninstall --role server
	assert_contains "$(cat "$MOCK_STATE_DIR/uninstall.log")" "agent-uninstall"
	assert_contains "$(cat "$MOCK_STATE_DIR/uninstall.log")" "server-uninstall"

	teardown_env
}

main() {
	log_info "Running integration tests..."
	test_secure_install_checksum
	log_info "✓ secure install checksum paths"
	test_checksum_url_and_lifecycle
	log_info "✓ checksum URL and lifecycle paths"
	log_info "All integration tests passed"
}

main "$@"
