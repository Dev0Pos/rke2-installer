#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALLER_SCRIPT="$SCRIPT_DIR/rke2-uninstaller.sh"

TOTAL=0
FAILED=0

log_info()  { echo -e "[INFO]  $*"; }
log_error() { echo -e "[ERROR] $*" >&2; }

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]]
}

setup_uninstaller_test_env() {
  TEST_ROOT="$(mktemp -d)"
  export RKE2_CONFIG_DIR="$TEST_ROOT/etc/rancher/rke2"
  export RKE2_CONFIG_FILE="$RKE2_CONFIG_DIR/config.yaml"
  export RKE2_KUBECONFIG_FILE="$RKE2_CONFIG_DIR/rke2.yaml"
  export RKE2_NODE_TOKEN_FILE="$TEST_ROOT/var/lib/rancher/rke2/server/node-token"
  export RKE2_SYSTEMD_UNIT_DIR="$TEST_ROOT/usr/lib/systemd/system"
  export RKE2_SERVER_UNINSTALL_SCRIPT="$TEST_ROOT/usr/local/bin/rke2-uninstall.sh"
  export RKE2_AGENT_UNINSTALL_SCRIPT="$TEST_ROOT/usr/local/bin/rke2-agent-uninstall.sh"
  export RKE2_BINARY_PATH="$TEST_ROOT/usr/bin/rke2"
  export RKE2_BACKUP_ROOT="$TEST_ROOT/tmp"
  export RKE2_DATA_DIRS="$TEST_ROOT/var/lib/rancher/rke2 $RKE2_CONFIG_DIR $TEST_ROOT/opt/rke2"

  mkdir -p "$RKE2_CONFIG_DIR" "$RKE2_SYSTEMD_UNIT_DIR" "$(dirname "$RKE2_NODE_TOKEN_FILE")" "$(dirname "$RKE2_BINARY_PATH")" "$RKE2_BACKUP_ROOT"
  source "$UNINSTALLER_SCRIPT"
}

teardown_uninstaller_test_env() {
  rm -rf "${TEST_ROOT:-}"
}

run_test() {
  local name="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if ( "$@" ); then
    log_info "✓ $name"
  else
    FAILED=$((FAILED + 1))
    log_error "✗ $name"
  fi
}

test_syntax_and_help() {
  setup_uninstaller_test_env
  bash -n "$UNINSTALLER_SCRIPT"
  local help_output
  help_output="$(print_usage)"
  assert_contains "$help_output" "RKE2 Uninstaller"
  assert_contains "$help_output" "--clean-data"
  teardown_uninstaller_test_env
}

test_role_validation_and_detection() {
  setup_uninstaller_test_env
  validate_role server
  validate_role agent
  if validate_role bad >/dev/null 2>&1; then
    teardown_uninstaller_test_env
    return 1
  fi

  [[ "$(detect_role)" == "none" ]]
  touch "$RKE2_SYSTEMD_UNIT_DIR/rke2-server.service"
  [[ "$(detect_role)" == "server" ]]
  touch "$RKE2_SYSTEMD_UNIT_DIR/rke2-agent.service"
  [[ "$(detect_role)" == "both" ]]
  rm -f "$RKE2_SYSTEMD_UNIT_DIR/rke2-server.service"
  [[ "$(detect_role)" == "agent" ]]

  teardown_uninstaller_test_env
}

test_backup_and_cleanup() {
  setup_uninstaller_test_env

  mkdir -p "$RKE2_CONFIG_DIR" "$(dirname "$RKE2_NODE_TOKEN_FILE")"
  echo "cfg" > "$RKE2_CONFIG_FILE"
  echo "kube" > "$RKE2_KUBECONFIG_FILE"
  echo "token" > "$RKE2_NODE_TOKEN_FILE"
  touch "$RKE2_SYSTEMD_UNIT_DIR/rke2-server.service"
  local backup_dir="$TEST_ROOT/backup"

  create_backup server "$backup_dir"
  [[ -f "$backup_dir/config.yaml" ]]
  [[ -f "$backup_dir/rke2.yaml" ]]
  [[ -f "$backup_dir/node-token" ]]
  [[ -f "$backup_dir/rke2-server.service" ]]

  mkdir -p "$TEST_ROOT/var/lib/rancher/rke2" "$TEST_ROOT/opt/rke2"
  touch "$RKE2_BINARY_PATH"
  touch "$RKE2_SERVER_UNINSTALL_SCRIPT" "$RKE2_AGENT_UNINSTALL_SCRIPT"
  clean_data_directories server
  [[ ! -d "$TEST_ROOT/var/lib/rancher/rke2" ]]
  [[ ! -f "$RKE2_BINARY_PATH" ]]

  teardown_uninstaller_test_env
}

test_dry_run_confirm_and_uninstall() {
  setup_uninstaller_test_env

  mkdir -p "$RKE2_CONFIG_DIR" "$(dirname "$RKE2_NODE_TOKEN_FILE")" "$(dirname "$RKE2_SERVER_UNINSTALL_SCRIPT")" "$(dirname "$RKE2_AGENT_UNINSTALL_SCRIPT")"
  echo "cfg" > "$RKE2_CONFIG_FILE"
  echo "token" > "$RKE2_NODE_TOKEN_FILE"
  touch "$RKE2_SYSTEMD_UNIT_DIR/rke2-server.service"
  touch "$RKE2_SYSTEMD_UNIT_DIR/rke2-agent.service"

  local dry_run_output
  dry_run_output="$(show_what_will_be_done server "$TEST_ROOT/backup-preview" true)"
  assert_contains "$dry_run_output" "DRY RUN"
  assert_contains "$dry_run_output" "$RKE2_CONFIG_FILE"

  local confirm_cancel_output
  confirm_cancel_output="$( (echo "no" | confirm_uninstall server false) 2>&1 || true )"
  assert_contains "$confirm_cancel_output" "Uninstall cancelled."

  (echo "yes" | confirm_uninstall server true) >/tmp/uninstaller-test.out 2>&1

  cat > "$RKE2_SERVER_UNINSTALL_SCRIPT" <<'EOF'
#!/usr/bin/env bash
echo server >> "${RKE2_BACKUP_ROOT}/uninstall.log"
EOF
  cat > "$RKE2_AGENT_UNINSTALL_SCRIPT" <<'EOF'
#!/usr/bin/env bash
echo agent >> "${RKE2_BACKUP_ROOT}/uninstall.log"
EOF
  chmod +x "$RKE2_SERVER_UNINSTALL_SCRIPT" "$RKE2_AGENT_UNINSTALL_SCRIPT"

  systemctl() {
    case "$1" in
      stop|disable|list-unit-files) return 0 ;;
      is-active) return 0 ;;
      *) return 0 ;;
    esac
  }
  do_uninstall server "$TEST_ROOT/backup" false
  do_uninstall agent "$TEST_ROOT/backup" false
  assert_contains "$(cat "$RKE2_BACKUP_ROOT/uninstall.log")" "server"
  assert_contains "$(cat "$RKE2_BACKUP_ROOT/uninstall.log")" "agent"

  teardown_uninstaller_test_env
}

test_main_dispatch() {
  setup_uninstaller_test_env

  mkdir -p "$RKE2_SYSTEMD_UNIT_DIR"
  touch "$RKE2_SYSTEMD_UNIT_DIR/rke2-server.service"
  touch "$RKE2_SYSTEMD_UNIT_DIR/rke2-agent.service"

  require_root() { :; }
  validate_role() { [[ "$1" == "server" || "$1" == "agent" ]]; }
  create_backup() { :; }
  confirm_uninstall() { :; }
  do_uninstall() { :; }
  show_what_will_be_done() { :; }

  ( main --role server --dry-run )
  main --role agent --force

  if ( main --role invalid --force >/tmp/uninstaller-test.err 2>&1 ); then
    teardown_uninstaller_test_env
    return 1
  fi

  rm -f "$RKE2_SYSTEMD_UNIT_DIR/rke2-server.service" "$RKE2_SYSTEMD_UNIT_DIR/rke2-agent.service"
  if ( main --force >/tmp/uninstaller-test.err 2>&1 ); then
    teardown_uninstaller_test_env
    return 1
  fi

  teardown_uninstaller_test_env
}

main() {
  log_info "Running uninstaller unit tests..."
  run_test "syntax and help" test_syntax_and_help
  run_test "role validation and detection" test_role_validation_and_detection
  run_test "backup and cleanup operations" test_backup_and_cleanup
  run_test "dry run prompt and uninstall paths" test_dry_run_confirm_and_uninstall
  run_test "main dispatch and validation" test_main_dispatch

  if [[ "$FAILED" -ne 0 ]]; then
    log_error "$FAILED/$TOTAL tests failed"
    exit 1
  fi

  log_info "All $TOTAL uninstaller tests passed"
}

main "$@"
