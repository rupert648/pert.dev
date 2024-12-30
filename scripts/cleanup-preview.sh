#!/bin/bash

# cleanup.sh - Cleanup PR Preview
set -euo pipefail

# Logging setup
LOG_FILE="/tmp/cleanup-$(date +%Y%m%d-%H%M%S).log"
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

log() {
    local level=$1
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

log_info() { log "INFO" "$@"; }
log_error() { log "ERROR" "$@"; }
log_success() { log "SUCCESS" "$@"; }

# Remove Cloudflare DNS record
cleanup_dns() {
    local preview_id=$1
    
    log_info "Removing DNS record for ${preview_id}.pert.dev"
    
    # Get record ID
    local existing_record=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${preview_id}.pert.dev" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    if ! echo "$existing_record" | grep -q "\"count\":0"; then
        local record_id=$(echo "$existing_record" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
        
        # Delete record
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json"
    fi
}

# Remove Caddy config and preview files
cleanup_preview() {
    local preview_id=$1
    
    log_info "Removing Caddy config and preview files"
    
    # Remove Caddy config
    ssh "$USER@$HOST" "sudo rm -f /etc/caddy/conf.d/${preview_id}.conf"
    
    # Reload Caddy
    ssh "$USER@$HOST" "sudo systemctl reload caddy"
    
    # Remove preview files
    ssh "$USER@$HOST" "sudo rm -rf /etc/zola/previews/${preview_id}"
}

main() {
    if [ -z "${PREVIEW_ID:-}" ]; then
        log_error "PREVIEW_ID environment variable is not set"
        exit 1
    fi
    
    log_info "Starting cleanup for preview: $PREVIEW_ID"
    
    cleanup_dns "$PREVIEW_ID"
    cleanup_preview "$PREVIEW_ID"
    
    log_success "Cleanup completed for $PREVIEW_ID"
}

main
