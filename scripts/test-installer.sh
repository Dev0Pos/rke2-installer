#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2317

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_SCRIPT="$SCRIPT_DIR/rke2-installer.sh"

TOTAL=0
FAILED=0

log_info() { echo -e "[INFO]  $*"; }
log_error() { echo -e "[ERROR] $*" >&2; }

assert_contains() {
	local haystack="$1" needle="$2"
	[[ "$haystack" == *"$needle"* ]]
}

setup_installer_test_env() {
	TEST_ROOT="$(mktemp -d)"
	export RKE2_CONFIG_DIR="$TEST_ROOT/etc/rancher/rke2"
	export RKE2_CONFIG_FILE="$RKE2_CONFIG_DIR/config.yaml"
	export RKE2_KUBECONFIG_FILE="$RKE2_CONFIG_DIR/rke2.yaml"
	export RKE2_NODE_TOKEN_FILE="$TEST_ROOT/var/lib/rancher/rke2/server/node-token"
	export RKE2_SYSTEMD_UNIT_DIR="$TEST_ROOT/usr/lib/systemd/system"
	export RKE2_SERVER_UNINSTALL_SCRIPT="$TEST_ROOT/usr/local/bin/rke2-uninstall.sh"
	export RKE2_AGENT_UNINSTALL_SCRIPT="$TEST_ROOT/usr/local/bin/rke2-agent-uninstall.sh"
	export RKE2_FSTAB_FILE="$TEST_ROOT/etc/fstab"
	export RKE2_INSTALL_URL="https://example.invalid/get.rke2.io"
	export RKE2_BACKUP_ROOT="$TEST_ROOT/tmp"
	export RKE2_OS_RELEASE_FILE="$TEST_ROOT/etc/os-release"
	export RKE2_DATA_DIRS="$TEST_ROOT/var/lib/rancher/rke2 $RKE2_CONFIG_DIR $TEST_ROOT/opt/rke2"
	export RKE2_LOG_FILES="$TEST_ROOT/var/log/rke2.log $TEST_ROOT/var/log/rke2-server.log $TEST_ROOT/var/log/rke2-agent.log"

	mkdir -p "$RKE2_CONFIG_DIR" "$RKE2_SYSTEMD_UNIT_DIR" "$(dirname "$RKE2_NODE_TOKEN_FILE")" "$RKE2_BACKUP_ROOT"
	echo 'ID=ubuntu' >"$RKE2_OS_RELEASE_FILE"
	source "$INSTALLER_SCRIPT"
}

teardown_installer_test_env() {
	rm -rf "${TEST_ROOT:-}"
}

run_test() {
	local name="$1"
	shift
	TOTAL=$((TOTAL + 1))
	if ("$@"); then
		log_info "✓ $name"
	else
		FAILED=$((FAILED + 1))
		log_error "✗ $name"
	fi
}

test_syntax_and_help() {
	setup_installer_test_env
	bash -n "$INSTALLER_SCRIPT"
	local help_output
	help_output="$(print_usage)"
	assert_contains "$help_output" "RKE2 Installer"
	assert_contains "$help_output" "--secure-install"
	teardown_installer_test_env
}

test_validate_role_and_path_splitter() {
	setup_installer_test_env
	validate_role server
	validate_role agent
	if validate_role control-plane >/dev/null 2>&1; then
		teardown_installer_test_env
		return 1
	fi
	local path_output
	path_output="$(read_space_separated_paths "a b c")"
	assert_contains "$path_output" "a"
	assert_contains "$path_output" "b"
	assert_contains "$path_output" "c"
	teardown_installer_test_env
}

test_write_config_and_copy_and_token() {
	setup_installer_test_env

	write_config_from_flags server "abc" "" "true"
	[[ -f "$RKE2_CONFIG_FILE" ]]
	assert_contains "$(cat "$RKE2_CONFIG_FILE")" "token: \"abc\""
	assert_contains "$(cat "$RKE2_CONFIG_FILE")" "cluster-init: true"

	rm -f "$RKE2_CONFIG_FILE"
	write_config_from_flags agent "def" "https://server:9345" "false"
	assert_contains "$(cat "$RKE2_CONFIG_FILE")" "server: \"https://server:9345\""

	rm -f "$RKE2_CONFIG_FILE"
	if (write_config_from_flags agent "def" "" "false" >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	local source_cfg="$TEST_ROOT/source-config.yaml"
	echo "token: copied" >"$source_cfg"
	copy_config_if_provided "$source_cfg"
	assert_contains "$(cat "$RKE2_CONFIG_FILE")" "token: copied"

	echo "tok-from-file" >"$TEST_ROOT/token.txt"
	[[ "$(read_token "direct" "")" == "direct" ]]
	[[ "$(read_token "" "$TEST_ROOT/token.txt")" == "tok-from-file" ]]
	[[ "$(read_token "" "")" == "" ]]
	if (read_token "" "$TEST_ROOT/missing-token" >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	teardown_installer_test_env
}

test_disable_swap_and_prerequisites() {
	setup_installer_test_env

	echo "/swapfile none swap sw 0 0" >"$RKE2_FSTAB_FILE"
	is_swap_on() { return 0; }
	swapoff() { :; }
	disable_swap
	assert_contains "$(cat "$RKE2_FSTAB_FILE")" "# /swapfile none swap sw 0 0"

	is_service_running() { return 0; }
	check_prerequisites server
	is_service_running() { return 1; }
	command_exists() { [[ "$1" == "rke2" ]]; }
	df() {
		echo "Filesystem 1K-blocks Used Available Use% Mounted on"
		echo "/dev/root 10 1 1024 1% /"
	}
	free() {
		echo "              total        used        free      shared  buff/cache   available"
		echo "Mem:            10           5           1           0           4         128"
	}
	check_prerequisites agent >/tmp/installer-test.warn 2>&1
	assert_contains "$(cat /tmp/installer-test.warn)" "Low disk space available"
	assert_contains "$(cat /tmp/installer-test.warn)" "Low available memory"

	if (check_prerequisites bad-role >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	teardown_installer_test_env
}

test_install_and_enable_start() {
	setup_installer_test_env

	installed_version() { echo ""; }
	local curl_mode_file="$TEST_ROOT/curl-mode"
	local secure_script_run="$TEST_ROOT/secure-script-ran"

	curl() {
		local output_file=""
		while [[ $# -gt 0 ]]; do
			case "$1" in
			-o)
				output_file="$2"
				shift 2
				;;
			*)
				shift
				;;
			esac
		done

		if [[ -n "$output_file" ]]; then
			echo "#!/usr/bin/env bash" >"$output_file"
			echo "echo secure-script" >>"$output_file"
			echo "secure" >"$curl_mode_file"
			return 0
		fi
		echo "stream" >"$curl_mode_file"
		echo "#!/usr/bin/env bash"
	}
	sh() {
		if [[ $# -eq 0 || "${1:-}" == "-" ]]; then
			cat >/dev/null
		else
			echo "$1" >"$secure_script_run"
		fi
	}
	chmod() { :; }

	install_rke2 server stable "" "" "false"
	[[ "$(cat "$curl_mode_file")" == "stream" ]]
	[[ "${INSTALL_RKE2_TYPE:-}" == "server" ]]
	[[ "${INSTALL_RKE2_CHANNEL:-}" == "stable" ]]

	install_rke2 agent latest v1.2.3 "true" "true"
	[[ "$(cat "$curl_mode_file")" == "secure" ]]
	[[ "${INSTALL_RKE2_TYPE:-}" == "agent" ]]
	[[ "${INSTALL_RKE2_VERSION:-}" == "v1.2.3" ]]
	[[ -s "$secure_script_run" ]]

	# Cover skip path when already installed and no force/version.
	installed_version() { echo "v9.9.9"; }
	install_rke2 server stable "" "" "false"

	local restart_count=0
	systemctl() {
		case "$1" in
		enable) return 0 ;;
		restart)
			restart_count=$((restart_count + 1))
			return 0
			;;
		is-active) [[ "$restart_count" -ge 2 ]] && return 0 || return 1 ;;
		*) return 0 ;;
		esac
	}
	sleep() { :; }
	pgrep() { return 1; }

	enable_and_start server
	enable_and_start agent

	# Cover failure path.
	systemctl() {
		case "$1" in
		enable | restart) return 0 ;;
		is-active) return 1 ;;
		*) return 0 ;;
		esac
	}
	if (enable_and_start server >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	teardown_installer_test_env
}

test_status_info_uninstall_and_main() {
	setup_installer_test_env

	mkdir -p "$RKE2_CONFIG_DIR" "$(dirname "$RKE2_NODE_TOKEN_FILE")" "$RKE2_SYSTEMD_UNIT_DIR"
	touch "$RKE2_SYSTEMD_UNIT_DIR/rke2-server.service"
	echo "cfg" >"$RKE2_CONFIG_FILE"
	echo "kube" >"$RKE2_KUBECONFIG_FILE"
	echo "token" >"$RKE2_NODE_TOKEN_FILE"
	mkdir -p "$TEST_ROOT/var/lib/rancher/rke2" "$TEST_ROOT/opt/rke2" "$TEST_ROOT/var/log"
	echo "log" >"$TEST_ROOT/var/log/rke2.log"
	echo "log" >"$TEST_ROOT/var/log/rke2-server.log"

	systemctl() {
		case "$1" in
		status | list-unit-files | show | is-enabled | is-active) return 0 ;;
		*) return 0 ;;
		esac
	}
	command_exists() { [[ "$1" == "rke2" ]]; }
	rke2() { echo "rke2 version v1.2.3"; }
	stat() { echo 12; }
	du() { echo "1M $2"; }
	which() { echo "/usr/bin/rke2"; }
	hostname() { echo "test-host"; }
	uname() { [[ "$1" == "-m" ]] && echo "x86_64" || echo "6.0-test"; }
	grep() { /bin/grep "$@"; }

	local status_output info_output
	status_output="$(show_status server)"
	info_output="$(show_info server)"
	assert_contains "$status_output" "RKE2 server Status"
	assert_contains "$info_output" "RKE2 server Information"

	mkdir -p "$(dirname "$RKE2_SERVER_UNINSTALL_SCRIPT")" "$(dirname "$RKE2_AGENT_UNINSTALL_SCRIPT")"
	cat >"$RKE2_SERVER_UNINSTALL_SCRIPT" <<'EOF'
#!/usr/bin/env bash
echo server-uninstall >> "${RKE2_BACKUP_ROOT}/uninstall.log"
EOF
	cat >"$RKE2_AGENT_UNINSTALL_SCRIPT" <<'EOF'
#!/usr/bin/env bash
echo agent-uninstall >> "${RKE2_BACKUP_ROOT}/uninstall.log"
EOF
	chmod +x "$RKE2_SERVER_UNINSTALL_SCRIPT" "$RKE2_AGENT_UNINSTALL_SCRIPT"
	do_uninstall server
	do_uninstall agent
	assert_contains "$(cat "$RKE2_BACKUP_ROOT/uninstall.log")" "server-uninstall"
	assert_contains "$(cat "$RKE2_BACKUP_ROOT/uninstall.log")" "agent-uninstall"

	require_root() { :; }
	validate_system() { :; }
	check_prerequisites() { :; }
	is_swap_on() { return 1; }
	read_token() { echo "tkn"; }
	copy_config_if_provided() { :; }
	write_config_from_flags() { :; }
	install_rke2() { :; }
	enable_and_start() { :; }
	do_uninstall() { :; }
	show_status() { :; }
	show_info() { :; }
	validate_role() { [[ "$1" == "server" || "$1" == "agent" ]]; }

	main install --role server --secure-install
	main uninstall --role agent
	main status --role server
	main info --role agent

	if (main install --role invalid >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi
	if (main unknown --role server >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	teardown_installer_test_env
}

test_additional_error_paths_for_coverage() {
	setup_installer_test_env

	command_exists true
	if (validate_role invalid-role >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	id() { echo 1000; }
	if (require_root >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	command_exists() {
		[[ "$1" == "systemctl" ]] && return 1
		return 0
	}
	if (validate_system >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	command_exists() {
		[[ "$1" == "systemctl" ]] && return 0
		[[ "$1" == "curl" ]] && return 1
		return 0
	}
	if (validate_system >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	command_exists() { return 0; }
	uname() { echo "sparc64"; }
	if (validate_system >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	uname() { echo "x86_64"; }
	RKE2_OS_RELEASE_FILE="$TEST_ROOT/missing-os-release"
	validate_system >/tmp/installer-test.warn 2>&1
	assert_contains "$(cat /tmp/installer-test.warn)" "Could not detect OS"

	RKE2_OS_RELEASE_FILE="$TEST_ROOT/etc/os-release-unsupported"
	echo 'ID=mysteryos' >"$RKE2_OS_RELEASE_FILE"
	validate_system >/tmp/installer-test.warn 2>&1
	assert_contains "$(cat /tmp/installer-test.warn)" "may not be officially supported"
	swapon() { echo "swapfile"; }
	is_swap_on
	swapon() { return 1; }
	if is_swap_on; then
		teardown_installer_test_env
		return 1
	fi

	command_exists() { return 1; }
	[[ "$(installed_version)" == "" ]]
	command_exists() { [[ "$1" == "rke2" ]]; }
	rke2() { echo "rke2 version v1.2.3"; }
	[[ "$(installed_version)" == "v1.2.3" ]]

	systemctl() { return 0; }
	is_service_running server
	systemctl() { return 1; }
	if is_service_running server; then
		teardown_installer_test_env
		return 1
	fi

	echo "existing: true" >"$RKE2_CONFIG_FILE"
	write_config_from_flags server "" "" "false"
	assert_contains "$(cat "$RKE2_CONFIG_FILE")" "existing: true"

	if (copy_config_if_provided "$TEST_ROOT/does-not-exist.yaml" >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	installed_version() { echo ""; }
	if (install_rke2 control stable "" "" "false" >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	systemctl() {
		case "$1" in
		enable) return 1 ;;
		*) return 0 ;;
		esac
	}
	if (enable_and_start server >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	local svc_active=0
	systemctl() {
		case "$1" in
		enable | restart) return 0 ;;
		is-active)
			[[ "$svc_active" -eq 0 ]] && svc_active=1
			return 0
			;;
		*) return 0 ;;
		esac
	}
	sleep() { :; }
	pgrep() { return 0; }
	enable_and_start server

	rm -f "$RKE2_SYSTEMD_UNIT_DIR/rke2-server.service"
	[[ ! -f "$RKE2_SYSTEMD_UNIT_DIR/rke2-server.service" ]]
	if show_status server >/tmp/installer-test.out 2>/tmp/installer-test.err; then
		teardown_installer_test_env
		return 1
	fi
	show_status_missing="$(cat /tmp/installer-test.out)"
	assert_contains "$show_status_missing" "Service rke2-server is not installed."

	touch "$RKE2_SYSTEMD_UNIT_DIR/rke2-server.service"
	rm -f "$RKE2_CONFIG_FILE"
	command_exists() { [[ "$1" == "rke2" ]]; }
	rke2() { echo "rke2 version v1.2.3"; }
	stat() { echo 1; }
	status_missing_cfg="$(show_status server)"
	assert_contains "$status_missing_cfg" "No configuration file found"

	command_exists() { return 1; }
	systemctl() {
		case "$1" in
		list-unit-files)
			echo "rke2-server.service enabled"
			return 0
			;;
		is-enabled | is-active | show) return 1 ;;
		*) return 0 ;;
		esac
	}
	du() { return 0; }
	info_no_install="$(show_info server)"
	assert_contains "$info_no_install" "Installed: No"
	assert_contains "$info_no_install" "Service: rke2-server"

	rm -f "$RKE2_SERVER_UNINSTALL_SCRIPT" "$RKE2_AGENT_UNINSTALL_SCRIPT"
	do_uninstall server
	do_uninstall agent

	require_root() { :; }
	validate_system() { :; }
	check_prerequisites() { :; }
	validate_role() { [[ "$1" == "server" || "$1" == "agent" ]]; }
	disable_swap() { :; }
	is_swap_on() { return 1; }
	read_token() { echo "tok"; }
	write_config_from_flags() { :; }
	copy_config_if_provided() { :; }
	install_rke2() { :; }
	enable_and_start() { :; }
	show_status() { :; }
	show_info() { :; }
	do_uninstall() { :; }

	touch "$TEST_ROOT/config.yaml" "$TEST_ROOT/token.txt"
	main install --role server --channel custom --version v1.2.3 --config "$TEST_ROOT/config.yaml" --server-url https://srv --token x --token-file "$TEST_ROOT/token.txt" --cluster-init --auto-swapoff --force --secure-install
	is_swap_on() { return 0; }
	main install --role server
	read_token() { echo ""; }
	if (main install --role agent >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi
	read_token() { echo "tok"; }
	main install --role server --config "$TEST_ROOT/config.yaml"

	if (main install >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi
	if (main uninstall >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi
	if (main status >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi
	if (main info >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	(main install --role server -h >/tmp/installer-test.out 2>&1)
	if (main install --role server --bad-flag >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi
	if (main invalid-command --role server >/tmp/installer-test.err 2>&1); then
		teardown_installer_test_env
		return 1
	fi

	bash "$INSTALLER_SCRIPT" install -h >/tmp/installer-test.out 2>&1

	teardown_installer_test_env
}

test_example_files() {
	[[ -f "$SCRIPT_DIR/../examples/server-config.yaml" ]]
	[[ -f "$SCRIPT_DIR/../examples/agent-config.yaml" ]]
	[[ -f "$SCRIPT_DIR/../examples/server-config-extended-tokens.yaml" ]]
	assert_contains "$(cat "$SCRIPT_DIR/../examples/server-config.yaml")" "write-kubeconfig-mode"
	assert_contains "$(cat "$SCRIPT_DIR/../examples/agent-config.yaml")" "server:"
}

main() {
	log_info "Running installer unit tests..."
	run_test "syntax and help" test_syntax_and_help
	run_test "role validation and helpers" test_validate_role_and_path_splitter
	run_test "config and token operations" test_write_config_and_copy_and_token
	run_test "swap and prerequisite checks" test_disable_swap_and_prerequisites
	run_test "install and service startup paths" test_install_and_enable_start
	run_test "status info uninstall and main dispatch" test_status_info_uninstall_and_main
	run_test "extended error-path coverage" test_additional_error_paths_for_coverage
	run_test "example files validation" test_example_files

	if [[ "$FAILED" -ne 0 ]]; then
		log_error "$FAILED/$TOTAL tests failed"
		exit 1
	fi

	log_info "All $TOTAL installer tests passed"
}

main "$@"
