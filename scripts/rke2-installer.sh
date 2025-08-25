#!/usr/bin/env bash

set -euo pipefail

PROGRAM_NAME="rke2-installer"

print_usage() {
  cat <<'EOF'
RKE2 Installer

Usage:
  rke2-installer.sh install --role <server|agent> [options]
  rke2-installer.sh uninstall --role <server|agent>
  rke2-installer.sh status --role <server|agent>
  rke2-installer.sh info --role <server|agent>

Installation options:
  --role <server|agent>    Node role
  --channel <channel>      Installation channel (default: stable)
  --version <vX.Y.Z>       Exact RKE2 version (optional)
  --config <path>          Path to config.yaml file to copy
  --server-url <url>       Server URL (for agent role)
  --token <token>          Cluster token (alternative to --token-file)
  --token-file <path>      Path to token file
  --cluster-init           Initialize cluster (first server)
  --auto-swapoff           Automatically disable swap if active
  --force                  Force reinstall/upgrade even if already installed

Examples:
  ./scripts/rke2-installer.sh install --role server --cluster-init
  ./scripts/rke2-installer.sh install --role agent --server-url https://rke2.example:9345 --token-file /root/token
  ./scripts/rke2-installer.sh uninstall --role server
  ./scripts/rke2-installer.sh status --role agent
  ./scripts/rke2-installer.sh info --role server
EOF
}

log_info()  { echo -e "[INFO]  $*"; }
log_warn()  { echo -e "[WARN]  $*"; }
log_error() { echo -e "[ERROR] $*" >&2; }

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    log_error "Run as root (sudo)."
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

validate_system() {
  # Check if systemd is available
  if ! command_exists systemctl; then
    log_error "systemd is required but not available on this system."
    exit 1
  fi

  # Check if curl is available
  if ! command_exists curl; then
    log_error "curl is required but not available. Please install curl first."
    exit 1
  fi

  # Check if we're on a supported architecture
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64|aarch64|arm64) ;;
    *) log_error "Unsupported architecture: $arch. Supported: x86_64, amd64, aarch64, arm64"; exit 1 ;;
  esac

  # Check if we're on a supported OS
  if [[ ! -f /etc/os-release ]]; then
    log_warn "Could not detect OS from /etc/os-release"
  else
    local os_name
    os_name="$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
    case "$os_name" in
      ubuntu|debian|centos|rhel|rocky|alma|fedora|amzn) ;;
      *) log_warn "OS $os_name may not be officially supported by RKE2" ;;
    esac
  fi
}

is_swap_on() {
  swapon --noheadings --show 2>/dev/null | grep -q . || return 1
}

disable_swap() {
  if is_swap_on; then
    log_info "Disabling swap (temporarily)..."
    swapoff -a || true
    if [[ -f /etc/fstab ]]; then
      log_info "Commenting swap entries in /etc/fstab (idempotently)."
      cp /etc/fstab /etc/fstab.backup.$(date +%s)
      sed -i 's/^\(.*\sswap\s\+\w\+.*\)$/# \1/g' /etc/fstab || true
    fi
  fi
}

ensure_config_dir() {
  mkdir -p /etc/rancher/rke2
}

write_config_from_flags() {
  local role="$1" token="$2" server_url="$3" cluster_init="$4"
  ensure_config_dir
  local cfg="/etc/rancher/rke2/config.yaml"

  if [[ -f "$cfg" ]]; then
    log_warn "File $cfg already exists – not overwriting."
    return 0
  fi

  log_info "Creating minimal $cfg based on flags."
  {
    if [[ -n "$token" ]]; then
      echo "token: \"$token\""
    fi
          if [[ "$role" == "agent" ]]; then
        if [[ -z "$server_url" ]]; then
          log_error "For agent role, --server-url is required."
          exit 1
        fi
        echo "server: \"$server_url\""
      fi
    if [[ "$role" == "server" && "$cluster_init" == "true" ]]; then
      echo "cluster-init: true"
    fi
    echo "write-kubeconfig-mode: \"0644\""
  } > "$cfg"
}

copy_config_if_provided() {
  local config_path="$1"
  if [[ -n "$config_path" ]]; then
    if [[ ! -f "$config_path" ]]; then
      log_error "Configuration file not found: $config_path"
      exit 1
    fi
    ensure_config_dir
    cp "$config_path" /etc/rancher/rke2/config.yaml
    log_info "Copied config to /etc/rancher/rke2/config.yaml"
  fi
}

read_token() {
  local token="${1:-}" token_file="${2:-}"
  if [[ -n "$token" ]]; then
    echo "$token"
    return 0
  fi
  if [[ -n "$token_file" ]]; then
    if [[ ! -f "$token_file" ]]; then
      log_error "--token-file points to non-existent file: $token_file"
      exit 1
    fi
    cat "$token_file"
    return 0
  fi
  echo ""
}

installed_version() {
  if command_exists rke2; then
    rke2 --version 2>/dev/null | awk '{print $3}' || true
  else
    echo ""
  fi
}

is_service_running() {
  local role="$1"
  local svc="rke2-$role"
  systemctl is-active --quiet "$svc" 2>/dev/null
}

check_prerequisites() {
  local role="$1"
  
  # Check if RKE2 is already running
  if is_service_running "$role"; then
    log_info "RKE2 $role service is already running."
    return 0
  fi

  # Check if RKE2 is installed but not running
  if command_exists rke2; then
    log_warn "RKE2 is installed but service is not running. Will attempt to start."
  fi

  # Check available disk space (at least 1GB)
  local available_space
  available_space="$(df / | awk 'NR==2 {print $4}')"
  if [[ "$available_space" -lt 1048576 ]]; then  # 1GB in KB
    log_warn "Low disk space available: $(($available_space / 1024))MB. RKE2 requires at least 1GB."
  fi

  # Check available memory (at least 512MB)
  local available_mem
  available_mem="$(free -m | awk 'NR==2 {print $7}')"
  if [[ "$available_mem" -lt 512 ]]; then
    log_warn "Low available memory: ${available_mem}MB. RKE2 requires at least 512MB."
  fi
}

install_rke2() {
  local role="$1" channel="$2" version="$3" force="$4"

  local current_ver
  current_ver="$(installed_version)"
  if [[ -n "$current_ver" && -z "$force" && -z "$version" ]]; then
    log_info "RKE2 already installed (version: $current_ver). Use --force or --version to update."
    return 0
  fi

  export INSTALL_RKE2_CHANNEL="$channel"
  if [[ -n "$version" ]]; then
    export INSTALL_RKE2_VERSION="$version"
  fi
  case "$role" in
    server) export INSTALL_RKE2_TYPE="server" ;;
    agent)  export INSTALL_RKE2_TYPE="agent"  ;;
    *) log_error "Unknown role: $role"; exit 1 ;;
  esac

  log_info "Installing RKE2 (channel=$channel version=${version:-n/a} role=$role)..."
  curl -sfL https://get.rke2.io | sh -
}

enable_and_start() {
  local role="$1"
  local svc
  if [[ "$role" == "server" ]]; then
    svc="rke2-server"
  else
    svc="rke2-agent"
  fi
  
  # Enable service
  systemctl enable "$svc" || {
    log_error "Failed to enable $svc service"
    exit 1
  }
  
  # Start service with retry logic
  local max_attempts=3
  local attempt=1
  
  while [[ $attempt -le $max_attempts ]]; do
    log_info "Starting $svc service (attempt $attempt/$max_attempts)..."
    systemctl restart "$svc"
    
    # Wait longer for first startup (especially for etcd initialization)
    if [[ $attempt -eq 1 ]]; then
      log_info "Waiting up to 2 minutes for first startup (etcd initialization)..."
      sleep 120
    else
      log_info "Waiting 30 seconds for service to start..."
      sleep 30
    fi
    
    if systemctl is-active --quiet "$svc"; then
      log_info "Service $svc is running successfully."
      
      # Additional check for server role - wait for etcd to be ready
      if [[ "$svc" == "rke2-server" ]]; then
        log_info "Waiting for etcd to be ready..."
        local etcd_ready=false
        for i in {1..30}; do
          if pgrep -f "etcd --config-file" >/dev/null 2>&1; then
            log_info "etcd process is running."
            etcd_ready=true
            break
          fi
          sleep 2
        done
        
        if [[ "$etcd_ready" == "false" ]]; then
          log_warn "etcd process not detected, but service is active. Continuing..."
        fi
      fi
      
      return 0
    else
      log_warn "Service $svc failed to start on attempt $attempt"
      if [[ $attempt -lt $max_attempts ]]; then
        log_info "Retrying in 30 seconds..."
        sleep 30
      fi
    fi
    ((attempt++))
  done
  
  log_error "Service $svc failed to start after $max_attempts attempts. Check: journalctl -u $svc -e"
  exit 1
}

show_status() {
  local role="$1"
  local svc="rke2-$role"
  
  echo "=== RKE2 $role Status ==="
  echo
  
  # Check if service exists
  if ! [[ -f "/usr/lib/systemd/system/$svc.service" ]]; then
    echo "Service $svc is not installed."
    return 1
  fi
  
  # Show service status
  echo "Service Status:"
  systemctl status "$svc" --no-pager -l || true
  echo
  
  # Show version if available
  if command_exists rke2; then
    echo "RKE2 Version:"
    rke2 --version 2>/dev/null || echo "Could not determine version"
    echo
  fi
  
  # Show config file info
  if [[ -f /etc/rancher/rke2/config.yaml ]]; then
    echo "Configuration file: /etc/rancher/rke2/config.yaml"
    echo "Config file size: $(stat -c%s /etc/rancher/rke2/config.yaml) bytes"
  else
    echo "No configuration file found at /etc/rancher/rke2/config.yaml"
  fi
  echo
  
  # Show kubeconfig info for server
  if [[ "$role" == "server" && -f /etc/rancher/rke2/rke2.yaml ]]; then
    echo "Kubeconfig: /etc/rancher/rke2/rke2.yaml"
    echo "Kubeconfig size: $(stat -c%s /etc/rancher/rke2/rke2.yaml) bytes"
  fi
}

show_info() {
  local role="$1"
  local svc="rke2-$role"
  
  echo "=== RKE2 $role Information ==="
  echo
  
  # System information
  echo "System Information:"
  echo "  OS: $(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo 'Unknown')"
  echo "  Architecture: $(uname -m)"
  echo "  Kernel: $(uname -r)"
  echo "  Hostname: $(hostname)"
  echo
  
  # RKE2 installation info
  echo "RKE2 Installation:"
  if command_exists rke2; then
    echo "  Installed: Yes"
    echo "  Version: $(rke2 --version 2>/dev/null | awk '{print $3}' || echo 'Unknown')"
    echo "  Binary: $(which rke2)"
  else
    echo "  Installed: No"
  fi
  echo
  
  # Service information
  echo "Service Information:"
  if systemctl list-unit-files | grep -q "$svc"; then
    echo "  Service: $svc"
    echo "  Enabled: $(systemctl is-enabled "$svc" 2>/dev/null || echo 'Unknown')"
    echo "  Active: $(systemctl is-active "$svc" 2>/dev/null || echo 'Unknown')"
    echo "  Unit file: $(systemctl show "$svc" --property=FragmentPath --value 2>/dev/null || echo 'Unknown')"
  else
    echo "  Service: Not installed"
  fi
  echo
  
  # Configuration information
  echo "Configuration:"
  if [[ -f /etc/rancher/rke2/config.yaml ]]; then
    echo "  Config file: /etc/rancher/rke2/config.yaml"
    echo "  Config size: $(stat -c%s /etc/rancher/rke2/config.yaml) bytes"
    echo "  Config modified: $(stat -c%y /etc/rancher/rke2/config.yaml)"
  else
    echo "  Config file: Not found"
  fi
  echo
  
  # Data directories
  echo "Data Directories:"
  local data_dirs=("/var/lib/rancher/rke2" "/etc/rancher/rke2" "/opt/rke2")
  for dir in "${data_dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      echo "  $dir: $(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
    else
      echo "  $dir: Not found"
    fi
  done
  echo
  
  # Network information
  echo "Network Information:"
  if [[ "$role" == "server" ]]; then
    echo "  API Server: https://localhost:6443"
    echo "  Node Port: 9345"
  fi
  echo "  Default CNI: Canal (Flannel + Calico)"
  echo
  
  # Log files
  echo "Log Files:"
  local log_files=("/var/log/rke2.log" "/var/log/rke2-server.log" "/var/log/rke2-agent.log")
  for log_file in "${log_files[@]}"; do
    if [[ -f "$log_file" ]]; then
      echo "  $log_file: $(stat -c%s "$log_file") bytes"
    fi
  done
}

do_uninstall() {
  local role="$1"
  
  # Create backup before uninstalling
  local backup_dir="/tmp/rke2-backup-$(date +%Y%m%d-%H%M%S)"
  log_info "Creating backup in $backup_dir before uninstalling..."
  mkdir -p "$backup_dir"
  
  # Backup config files
  if [[ -f /etc/rancher/rke2/config.yaml ]]; then
    cp /etc/rancher/rke2/config.yaml "$backup_dir/"
    log_info "Backed up config.yaml"
  fi
  
  # Backup kubeconfig for server
  if [[ "$role" == "server" && -f /etc/rancher/rke2/rke2.yaml ]]; then
    cp /etc/rancher/rke2/rke2.yaml "$backup_dir/"
    log_info "Backed up rke2.yaml"
  fi
  
  # Backup token file if it exists
  if [[ -f /var/lib/rancher/rke2/server/node-token ]]; then
    cp /var/lib/rancher/rke2/server/node-token "$backup_dir/"
    log_info "Backed up node-token"
  fi
  
  log_info "Backup completed: $backup_dir"
  
  # Perform uninstall
  if [[ "$role" == "server" ]]; then
    if [[ -x /usr/local/bin/rke2-uninstall.sh ]]; then
      log_info "Running RKE2 server uninstall script..."
      /usr/local/bin/rke2-uninstall.sh
    else
      log_warn "Missing /usr/local/bin/rke2-uninstall.sh – looks like RKE2 server is not installed."
    fi
  else
    if [[ -x /usr/local/bin/rke2-agent-uninstall.sh ]]; then
      log_info "Running RKE2 agent uninstall script..."
      /usr/local/bin/rke2-agent-uninstall.sh
    else
      log_warn "Missing /usr/local/bin/rke2-agent-uninstall.sh – looks like RKE2 agent is not installed."
    fi
  fi
  
  log_info "Uninstall completed. Backup available at: $backup_dir"
}

main() {
  if [[ $# -lt 1 ]]; then
    print_usage; exit 1
  fi

  local cmd="$1"; shift

  local role="" channel="stable" version="" config_path="" server_url="" token="" token_file="" cluster_init="false" auto_swapoff="false" force=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) role="$2"; shift 2;;
      --channel) channel="$2"; shift 2;;
      --version) version="$2"; shift 2;;
      --config) config_path="$2"; shift 2;;
      --server-url) server_url="$2"; shift 2;;
      --token) token="$2"; shift 2;;
      --token-file) token_file="$2"; shift 2;;
      --cluster-init) cluster_init="true"; shift;;
      --auto-swapoff) auto_swapoff="true"; shift;;
      --force) force="true"; shift;;
      -h|--help) print_usage; exit 0;;
      *) log_error "Unknown flag: $1"; print_usage; exit 1;;
    esac
  done

  case "$cmd" in
    install)
      require_root
      validate_system
      
      if [[ -z "$role" ]]; then
        log_error "Provide --role server|agent"
        exit 1
      fi
      
      check_prerequisites "$role"
      
      if [[ "$auto_swapoff" == "true" ]]; then
        disable_swap
      else
        if is_swap_on; then
          log_warn "Swap is active. Recommended: --auto-swapoff or disable manually."
        fi
      fi

      # Configuration
      local tok
      tok="$(read_token "$token" "$token_file")"
      if [[ "$role" == "agent" ]]; then
        if [[ -z "$tok" ]]; then
          log_error "For agent role, --token or --token-file is required."
          exit 1
        fi
      fi

      if [[ -n "$config_path" ]]; then
        copy_config_if_provided "$config_path"
      else
        write_config_from_flags "$role" "$tok" "$server_url" "$cluster_init"
      fi

      install_rke2 "$role" "$channel" "$version" "$force"
      enable_and_start "$role"
      if [[ "$role" == "server" ]]; then
        log_info "Kubeconfig: /etc/rancher/rke2/rke2.yaml (set KUBECONFIG or copy to ~/.kube/config)"
      fi
      ;;
    uninstall)
      require_root
      if [[ -z "$role" ]]; then
        log_error "Provide --role server|agent"
        exit 1
      fi
      do_uninstall "$role"
      ;;
    status)
      if [[ -z "$role" ]]; then
        log_error "Provide --role server|agent"
        exit 1
      fi
      show_status "$role"
      ;;
    info)
      if [[ -z "$role" ]]; then
        log_error "Provide --role server|agent"
        exit 1
      fi
      show_info "$role"
      ;;
          *)
      log_error "Unknown command: $cmd"
      print_usage
      exit 1
      ;;
  esac
}

main "$@"


