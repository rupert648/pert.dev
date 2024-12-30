#!/bin/bash

# preview.sh - PR Preview Deployment Script
set -euo pipefail

# Logging setup
LOG_FILE="/tmp/preview-$(date +%Y%m%d-%H%M%S).log"
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

# Create/update Cloudflare DNS record
setup_dns() {
    local preview_id=$1
    local server_ip="172.236.23.67"
    
    log_info "Setting up DNS for ${preview_id}.pert.dev"
    
    # Check if record exists
    local existing_record=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${preview_id}.pert.dev" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    if echo "$existing_record" | grep -q "\"count\":0"; then
        # Create new record
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\": \"A\",
                \"name\": \"${preview_id}\",
                \"content\": \"${server_ip}\",
                \"ttl\": 1,
                \"proxied\": true
            }"
    else
        # Update existing record
        local record_id=$(echo "$existing_record" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\": \"A\",
                \"name\": \"${preview_id}\",
                \"content\": \"${server_ip}\",
                \"ttl\": 1,
                \"proxied\": true
            }"
    fi
}

# Configure Caddy for the preview
setup_caddy() {
    local preview_id=$1
    local config_content="${preview_id}.pert.dev {
    root * /etc/zola/previews/${preview_id}
    file_server
}"
    
    log_info "Configuring Caddy for preview"
    
    # Add/update site configuration
    echo "$config_content" | ssh "$USER@$HOST" "sudo tee /etc/caddy/conf.d/${preview_id}.conf"
    
    # Reload Caddy
    ssh "$USER@$HOST" "sudo systemctl reload caddy"
}

# Deploy the preview files
deploy_files() {
    local preview_id=$1
    
    log_info "Deploying files for preview: $preview_id"
    
    # Ensure preview directory exists
    ssh "$USER@$HOST" "sudo mkdir -p /etc/zola/previews/${preview_id}"
    
    # Create temp directory for transfer
    ssh "$USER@$HOST" "mkdir -p /tmp/${preview_id}"
    
    # Copy built files
    scp -r blog/public/* "$USER@$HOST:/tmp/${preview_id}/"
    
    # Move files to final location
    ssh "$USER@$HOST" "sudo rm -rf /etc/zola/previews/${preview_id}/* && \
                       sudo mv /tmp/${preview_id}/* /etc/zola/previews/${preview_id}/ && \
                       rm -rf /tmp/${preview_id}"
}

main() {
    if [ -z "${PREVIEW_ID:-}" ]; then
        log_error "PREVIEW_ID environment variable is not set"
        exit 1
    fi
    
    log_info "Starting preview deployment: $PREVIEW_ID"
    
    setup_dns "$PREVIEW_ID"
    deploy_files "$PREVIEW_ID"
    setup_caddy "$PREVIEW_ID"
    
    log_success "Preview deployment completed"
    log_info "Preview available at: https://${PREVIEW_ID}.pert.dev"
}

main
