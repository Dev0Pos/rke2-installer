#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_SCRIPT="$SCRIPT_DIR/rke2-installer.sh"

log_info()  { echo -e "[INFO]  $*"; }
log_warn()  { echo -e "[WARN]  $*"; }
log_error() { echo -e "[ERROR] $*" >&2; }

test_help() {
  log_info "Testing help output..."
  if "$INSTALLER_SCRIPT" install -h | grep -q "RKE2 Installer"; then
    log_info "✓ Help output works"
  else
    log_error "✗ Help output failed"
    return 1
  fi
}

test_validation() {
  log_info "Testing validation..."
  
  # Test root requirement
  local output
  output="$("$INSTALLER_SCRIPT" install 2>&1 || true)"
  if echo "$output" | grep -q "Run as root"; then
    log_info "✓ Root requirement validation works"
  else
    log_error "✗ Root requirement validation failed"
    return 1
  fi
  
  # Test invalid role (this will also fail on root requirement, so we'll skip it)
  log_info "✓ Validation tests completed (root requirement prevents further testing)"
}

test_syntax() {
  log_info "Testing script syntax..."
  if bash -n "$INSTALLER_SCRIPT"; then
    log_info "✓ Script syntax is valid"
  else
    log_error "✗ Script syntax is invalid"
    return 1
  fi
}

test_functions() {
  log_info "Testing function definitions..."
  
  # Test if key functions exist by checking the script content
  local functions=("log_info" "log_warn" "log_error" "require_root" "validate_system" "check_prerequisites")
  for func in "${functions[@]}"; do
    if grep -q "^${func}()" "$INSTALLER_SCRIPT"; then
      log_info "✓ Function $func exists"
    else
      log_error "✗ Function $func missing"
      return 1
    fi
  done
}

test_example_configs() {
  log_info "Testing example configs..."
  
  # Test server config
  if [[ -f "examples/server-config.yaml" ]]; then
    log_info "✓ Config file examples/server-config.yaml exists"
    if grep -q "write-kubeconfig-mode" "examples/server-config.yaml"; then
      log_info "✓ Config file examples/server-config.yaml has valid content"
    else
      log_error "✗ Config file examples/server-config.yaml has invalid content"
      return 1
    fi
  else
    log_error "✗ Config file examples/server-config.yaml missing"
    return 1
  fi
  
  # Test agent config
  if [[ -f "examples/agent-config.yaml" ]]; then
    log_info "✓ Config file examples/agent-config.yaml exists"
    if grep -q "server:" "examples/agent-config.yaml"; then
      log_info "✓ Config file examples/agent-config.yaml has valid content"
    else
      log_error "✗ Config file examples/agent-config.yaml has invalid content"
      return 1
    fi
  else
    log_error "✗ Config file examples/agent-config.yaml missing"
    return 1
  fi
}

main() {
  log_info "Starting RKE2 installer tests..."
  
  local tests=("test_syntax" "test_functions" "test_help" "test_validation" "test_example_configs")
  local failed=0
  
  for test in "${tests[@]}"; do
    if "$test"; then
      log_info "✓ $test passed"
    else
      log_error "✗ $test failed"
      ((failed++))
    fi
    echo
  done
  
  if [[ $failed -eq 0 ]]; then
    log_info "All tests passed! ✓"
    exit 0
  else
    log_error "$failed test(s) failed! ✗"
    exit 1
  fi
}

main "$@"
