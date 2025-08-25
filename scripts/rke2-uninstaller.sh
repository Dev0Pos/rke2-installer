#!/usr/bin/env bash

set -euo pipefail

PROGRAM_NAME="rke2-uninstaller"

print_usage() {
  cat <<'EOF'
RKE2 Uninstaller

Usage:
  rke2-uninstaller.sh [options]

Options:
  --role <server|agent>    Node role (auto-detected if not specified)
  --force                  Skip confirmation prompts
  --dry-run               Show what would be done without executing
  --backup-dir <path>     Custom backup directory (default: /tmp/rke2-backup-*)
  --clean-data            Also remove data directories (WARNING: irreversible)
  -h, --help              Show this help

Examples:
  ./scripts/rke2-uninstaller.sh
  ./scripts/rke2-uninstaller.sh --role server --force
  ./scripts/rke2-uninstaller.sh --dry-run --clean-data
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

detect_role() {
  local server_installed=false
  local agent_installed=false
  
  if [[ -f "/usr/lib/systemd/system/rke2-server.service" ]]; then
    server_installed=true
  fi
  
  if [[ -f "/usr/lib/systemd/system/rke2-agent.service" ]]; then
    agent_installed=true
  fi
  
  if [[ "$server_installed" == "true" && "$agent_installed" == "true" ]]; then
    echo ""
  elif [[ "$server_installed" == "true" ]]; then
    echo "server"
  elif [[ "$agent_installed" == "true" ]]; then
    echo "agent"
  else
    echo ""
  fi
}

is_service_running() {
  local role="$1"
  local svc="rke2-$role"
  systemctl is-active --quiet "$svc" 2>/dev/null
}

create_backup() {
  local role="$1" backup_dir="$2"
  
  log_info "Creating backup in $backup_dir..."
  mkdir -p "$backup_dir"
  
  # Backup config files
  if [[ -f /etc/rancher/rke2/config.yaml ]]; then
    cp /etc/rancher/rke2/config.yaml "$backup_dir/"
    log_info "✓ Backed up config.yaml"
  fi
  
  # Backup kubeconfig for server
  if [[ "$role" == "server" && -f /etc/rancher/rke2/rke2.yaml ]]; then
    cp /etc/rancher/rke2/rke2.yaml "$backup_dir/"
    log_info "✓ Backed up rke2.yaml"
  fi
  
  # Backup token file if it exists
  if [[ -f /var/lib/rancher/rke2/server/node-token ]]; then
    cp /var/lib/rancher/rke2/server/node-token "$backup_dir/"
    log_info "✓ Backed up node-token"
  fi
  
  # Backup service files
  if [[ -f /usr/lib/systemd/system/rke2-$role.service ]]; then
    cp /usr/lib/systemd/system/rke2-$role.service "$backup_dir/"
    log_info "✓ Backed up service file"
  fi
  
  log_info "Backup completed: $backup_dir"
}

clean_data_directories() {
  local role="$1"
  
  log_warn "Removing RKE2 data directories (this will delete all cluster data)..."
  
  local dirs=("/var/lib/rancher/rke2" "/etc/rancher/rke2" "/opt/rke2")
  for dir in "${dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      log_info "Removing $dir..."
      rm -rf "$dir"
    fi
  done
  
  # Remove binaries
  if [[ -f /usr/bin/rke2 ]]; then
    log_info "Removing RKE2 binary..."
    rm -f /usr/bin/rke2
  fi
  
  # Remove uninstall scripts
  if [[ -f /usr/local/bin/rke2-uninstall.sh ]]; then
    rm -f /usr/local/bin/rke2-uninstall.sh
  fi
  if [[ -f /usr/local/bin/rke2-agent-uninstall.sh ]]; then
    rm -f /usr/local/bin/rke2-agent-uninstall.sh
  fi
  
  log_info "Data cleanup completed."
}

show_what_will_be_done() {
  local role="$1" backup_dir="$2" clean_data="$3"
  
  echo "=== DRY RUN - What would be done ==="
  echo
  
  echo "Role: $role"
  echo "Backup directory: $backup_dir"
  echo
  
  echo "Files that would be backed up:"
  if [[ -f /etc/rancher/rke2/config.yaml ]]; then
    echo "  ✓ /etc/rancher/rke2/config.yaml"
  fi
  if [[ "$role" == "server" && -f /etc/rancher/rke2/rke2.yaml ]]; then
    echo "  ✓ /etc/rancher/rke2/rke2.yaml"
  fi
  if [[ -f /var/lib/rancher/rke2/server/node-token ]]; then
    echo "  ✓ /var/lib/rancher/rke2/server/node-token"
  fi
  echo
  
  echo "Services that would be stopped:"
  echo "  - rke2-$role"
  echo
  
  if [[ "$clean_data" == "true" ]]; then
    echo "Data directories that would be removed:"
    echo "  - /var/lib/rancher/rke2"
    echo "  - /etc/rancher/rke2"
    echo "  - /opt/rke2"
    echo "  - /usr/bin/rke2"
    echo
  fi
  
  echo "=== End of dry run ==="
}

confirm_uninstall() {
  local role="$1" clean_data="$2"
  
  echo
  log_warn "WARNING: This will uninstall RKE2 $role from this system."
  
  if [[ "$clean_data" == "true" ]]; then
    log_error "WARNING: --clean-data flag is set. This will DELETE ALL CLUSTER DATA!"
    log_error "This action is IRREVERSIBLE!"
  fi
  
  echo
  read -p "Are you sure you want to continue? (yes/no): " -r
  echo
  
  if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    log_info "Uninstall cancelled."
    exit 0
  fi
}

do_uninstall() {
  local role="$1" backup_dir="$2" clean_data="$3"
  local svc="rke2-$role"
  
  # Stop service first
  if is_service_running "$role"; then
    log_info "Stopping $svc service..."
    systemctl stop "$svc" || true
  fi
  
  # Disable service
  if systemctl list-unit-files | grep -q "$svc"; then
    log_info "Disabling $svc service..."
    systemctl disable "$svc" || true
  fi
  
  # Run official uninstall script
  if [[ "$role" == "server" ]]; then
    if [[ -x /usr/local/bin/rke2-uninstall.sh ]]; then
      log_info "Running official RKE2 server uninstall script..."
      /usr/local/bin/rke2-uninstall.sh
    else
      log_warn "Official uninstall script not found, performing manual cleanup..."
    fi
  else
    if [[ -x /usr/local/bin/rke2-agent-uninstall.sh ]]; then
      log_info "Running official RKE2 agent uninstall script..."
      /usr/local/bin/rke2-agent-uninstall.sh
    else
      log_warn "Official uninstall script not found, performing manual cleanup..."
    fi
  fi
  
  # Clean data if requested
  if [[ "$clean_data" == "true" ]]; then
    clean_data_directories "$role"
  fi
  
  log_info "RKE2 $role uninstall completed."
  log_info "Backup available at: $backup_dir"
}

main() {
  local role="" force="false" dry_run="false" backup_dir="" clean_data="false"
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) role="$2"; shift 2;;
      --force) force="true"; shift;;
      --dry-run) dry_run="true"; shift;;
      --backup-dir) backup_dir="$2"; shift 2;;
      --clean-data) clean_data="true"; shift;;
      -h|--help) print_usage; exit 0;;
      *) log_error "Unknown option: $1"; print_usage; exit 1;;
    esac
  done
  
  # Auto-detect role if not specified
  if [[ -z "$role" ]]; then
    role="$(detect_role)"
    if [[ -z "$role" ]]; then
      log_warn "Both server and agent are installed. Please specify --role server|agent"
      log_error "Could not detect RKE2 role. Please specify --role server|agent"
      exit 1
    fi
    log_info "Auto-detected role: $role"
  fi
  
  # Validate role
  if [[ "$role" != "server" && "$role" != "agent" ]]; then
    log_error "Invalid role: $role. Must be 'server' or 'agent'"
    exit 1
  fi
  
  # Set default backup directory
  if [[ -z "$backup_dir" ]]; then
    backup_dir="/tmp/rke2-backup-$(date +%Y%m%d-%H%M%S)"
  fi
  
  # Check if RKE2 is installed
  if ! [[ -f "/usr/lib/systemd/system/rke2-$role.service" ]]; then
    log_error "RKE2 $role is not installed on this system."
    exit 1
  fi
  
  # Dry run mode
  if [[ "$dry_run" == "true" ]]; then
    show_what_will_be_done "$role" "$backup_dir" "$clean_data"
    exit 0
  fi
  
  # Require root for actual uninstall
  require_root
  
  # Create backup
  create_backup "$role" "$backup_dir"
  
  # Confirm unless --force is used
  if [[ "$force" != "true" ]]; then
    confirm_uninstall "$role" "$clean_data"
  fi
  
  # Perform uninstall
  do_uninstall "$role" "$backup_dir" "$clean_data"
  
  log_info "Uninstall completed successfully!"
}

main "$@"
