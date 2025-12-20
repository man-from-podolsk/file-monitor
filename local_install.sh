#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo "$1"; }
log_success() { echo -e "${GREEN}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}" >&2; }

# Определяем директорию, где лежит скрипт
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info "Installing file-monitor from local files..."

# Проверяем наличие всех необходимых файлов
missing_files=()
[[ -f "$SCRIPT_DIR/script/file-monitor.sh" ]] || missing_files+=("file-monitor.sh")
[[ -f "$SCRIPT_DIR/systemd/file-monitor.service" ]] || missing_files+=("systemd/file-monitor.service")
[[ -f "$SCRIPT_DIR/config/file-monitor.conf" ]] || missing_files+=("config/file-monitor.conf")
[[ -f "$SCRIPT_DIR/logrotate/file-monitor" ]] || missing_files+=("logrotate/file-monitor")

if [ ${#missing_files[@]} -gt 0 ]; then
    log_error "Error: Missing required files:"
    for f in "${missing_files[@]}"; do
        echo "  - $f"
    done
    log_error "Please ensure all files are present in the same directory as this script."
    exit 1
fi

# Detect OS using /etc/os-release
if [ ! -f /etc/os-release ]; then
    log_error "Error: /etc/os-release not found. Unsupported OS."
    exit 1
fi

OS_ID=$(grep -E "^ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
log_info "Detected OS: $OS_ID"

# Validate supported OS
case "$OS_ID" in
    debian|ubuntu)
        PKG_MGR="apt"
        ;;
    rhel|centos|almalinux|rocky)
        if command -v dnf >/dev/null 2>&1; then
            PKG_MGR="dnf"
        else
            PKG_MGR="yum"
        fi
        ;;
    sles|opensuse*)
        PKG_MGR="zypper"
        ;;
    *)
        log_error "Error: Unsupported OS '$OS_ID'. Supported: Debian, Ubuntu, RHEL, CentOS, AlmaLinux, Rocky Linux, SLES, openSUSE."
        exit 1
        ;;
esac

log_info "Using package manager: $PKG_MGR"

# Install auditd/audit depending on OS
log_info "Installing audit subsystem..."
case "$PKG_MGR" in
    apt)
        apt update -qq
        apt install -y auditd
        ;;
    dnf|yum)
        ${PKG_MGR} install -y audit
        ;;
    zypper)
        zypper --non-interactive install audit
        ;;
    *)
        log_error "Error: Unknown package manager '$PKG_MGR'"
        exit 1
        ;;
esac

log_success "Audit subsystem installed successfully."

# Copy files from local directory
log_info "Copying local files..."
install -Dm755 "$SCRIPT_DIR/script/file-monitor.sh" /usr/bin/file-monitor.sh
install -Dm644 "$SCRIPT_DIR/systemd/file-monitor.service" /etc/systemd/system/file-monitor.service
install -Dm644 "$SCRIPT_DIR/config/file-monitor.conf" /etc/file-monitor.conf
install -Dm644 "$SCRIPT_DIR/logrotate/file-monitor" /etc/logrotate.d/file-monitor

log_success "Files copied successfully."

# Create directories
log_info "Creating required directories..."
mkdir -p /var/cache/file-monitor /var/log/file-monitor
chmod 755 /var/cache/file-monitor /var/log/file-monitor

log_success "Directories created."

# Ensure auditd is running
log_info "Ensuring auditd is active..."
if ! systemctl is-active --quiet auditd; then
    log_info "Starting and enabling auditd..."
    systemctl enable --now auditd
fi

# Reload systemd and enable file-monitor
log_info "Reloading systemd and enabling file-monitor service..."
systemctl daemon-reload
systemctl enable file-monitor

log_info "Starting file-monitor service..."
systemctl start file-monitor

# Verify that the service is active
if systemctl is-active --quiet file-monitor; then
    log_success "✅ file-monitor installed and started successfully!"
    log_info "Log file: /var/log/file-monitor/file-monitor.log"
else
    log_error "❌ Error: file-monitor service failed to start."
    log_info "Check status with: systemctl status file-monitor"
    exit 1
fi