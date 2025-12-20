#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo "$1"; }
log_success() { echo -e "${GREEN}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}" >&2; }

log_info "Uninstalling file-monitor..."

# Stop and disable service
if systemctl is-active --quiet file-monitor; then
    log_info "Stopping file-monitor service..."
    systemctl stop file-monitor
fi

log_info "Disabling file-monitor service..."
systemctl disable file-monitor 2>/dev/null || true

# Remove systemd unit
if [ -f /etc/systemd/system/file-monitor.service ]; then
    rm -f /etc/systemd/system/file-monitor.service
    log_info "Removed systemd unit."
fi

# Reload systemd
systemctl daemon-reload
systemctl reset-failed file-monitor 2>/dev/null || true

# Remove binary
if [ -f /usr/local/bin/file-monitor.sh ]; then
    rm -f /usr/local/bin/file-monitor.sh
    log_info "Removed binary."
fi

# Remove config
if [ -f /etc/file-monitor.conf ]; then
    rm -f /etc/file-monitor.conf
    log_info "Removed config file."
fi

# Remove logrotate config
if [ -f /etc/logrotate.d/file-monitor ]; then
    rm -f /etc/logrotate.d/file-monitor
    log_info "Removed logrotate config."
fi

# Remove audit rules
RULE_FILE="/etc/audit/rules.d/file-monitor.rules"
if [ -f "$RULE_FILE" ]; then
    rm -f "$RULE_FILE"
    log_info "Removed audit rules file."

    # Reload audit rules
    if command -v augenrules >/dev/null 2>&1; then
        augenrules --load >/dev/null 2>&1 || true
    fi

    # Remove in-kernel rules
    if command -v auditctl >/dev/null 2>&1; then
        auditctl -D -k file-monitor >/dev/null 2>&1 || true
    fi
fi

# Prompt: remove data?
read -p "Remove log and cache data? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ -d /var/log/file-monitor ]; then
        rm -rf /var/log/file-monitor
        log_info "Removed log directory."
    fi
    if [ -d /var/cache/file-monitor ]; then
        rm -rf /var/cache/file-monitor
        log_info "Removed cache directory."
    fi
else
    log_info "Data directories preserved (/var/log/file-monitor, /var/cache/file-monitor)."
fi

log_success "✅ file-monitor uninstalled successfully!"