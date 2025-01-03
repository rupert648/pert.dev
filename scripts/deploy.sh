#!/bin/bash

# deploy.sh

# Set strict error handling
set -euo pipefail

# Logging setup
LOG_FILE="/tmp/deploy-$(date +%Y%m%d-%H%M%S).log"
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

log() {
    local level=$1
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

log_info() {
    log "INFO" "$@"
}

log_error() {
    log "ERROR" "$@"
}

log_success() {
    log "SUCCESS" "$@"
}

# Function to deploy a single service
deploy_service() {
    local service=$1
    local src=$2
    local dest=$3
    
    log_info "Starting deployment for service: $service"
    log_info "Source file: $src"
    log_info "Destination: $dest"
    
    if [ ! -f "$src" ]; then
        log_error "Source file does not exist: $src"
        return 1
    fi
    
    # Create backup of existing file
    if ssh "$USER@$HOST" "[ -f $dest ]"; then
        local backup_name="${dest}.backup-$(date +%Y%m%d-%H%M%S)"
        log_info "Creating backup: $backup_name"
        ssh "$USER@$HOST" "sudo cp $dest $backup_name"
    fi
    
    # Copy new file
    log_info "Copying $src to $dest"
    scp "$src" "$USER@$HOST:~/temp_file" || {
        log_error "Failed to copy file to remote host"
        return 1
    }
    
    # Move file to destination with sudo
    log_info "Moving file to final destination"
    ssh "$USER@$HOST" "sudo mv ~/temp_file $dest" || {
        log_error "Failed to move file to destination"
        return 1
    }
    
    # Restart service
    log_info "Restarting service: $service"
    if ssh "$USER@$HOST" "sudo systemctl restart $service"; then
        log_success "Successfully restarted $service"
    else
        log_error "Failed to restart $service"
        return 1
    fi
    
    # Verify service status
    log_info "Verifying service status"
    if ssh "$USER@$HOST" "sudo systemctl is-active $service"; then
        log_success "Service $service is running"
    else
        log_error "Service $service failed to start"
        return 1
    fi
    
    log_success "Completed deployment for $service"
}

# Function to deploy Zola site
deploy_zola() {
    log_info "Starting Zola site deployment"
    
    if [ ! -d "blog/public" ]; then
        log_error "Zola public directory not found"
        return 1
    fi
    
    # Create backup of existing site
    log_info "Creating backup of existing site"
    ssh "$USER@$HOST" "sudo tar czf /etc/zola/backup-$(date +%Y%m%d-%H%M%S).tar.gz -C /etc/zola public/" || {
        log_error "Failed to create backup of existing site"
        return 1
    }
    
    # Clear existing files
    log_info "Clearing existing files"
    ssh "$USER@$HOST" "sudo rm -rf /etc/zola/public/*"
    
    # Copy new files
    log_info "Copying new files"
    scp -r blog/public/* "$USER@$HOST:/etc/zola/public/" || {
        log_error "Failed to copy new files"
        return 1
    }
    
    log_success "Completed Zola site deployment"
}

deploy_backend() {
    log_info "Starting backend deployment"
    
    if [ ! -d "services/backend/target/release" ]; then
        log_error "Backend release build not found"
        return 1
    fi
    
    # Create backup of existing build
    if ssh "$USER@$HOST" "[ -d /opt/backend/release ]"; then
        local backup_name="/opt/backend/release.backup-$(date +%Y%m%d-%H%M%S)"
        log_info "Creating backup: $backup_name"
        ssh "$USER@$HOST" "sudo cp -r /opt/backend/release $backup_name"
    fi
    
    log_info "Ensuring directory exists"
    ssh "$USER@$HOST" "sudo mkdir -p /opt/backend/target/release"
    
    log_info "Copying release build"
    scp -C -c aes128-gcm@openssh.com -r services/backend/target/release/* "$USER@$HOST:~/backend_temp/" || {
        log_error "Failed to copy backend build to remote host"
        return 1
    }
    
    log_info "Moving build to final destination"
    ssh "$USER@$HOST" "sudo rm -rf /opt/backend/target/release/* && \
                       sudo mv ~/backend_temp/* /opt/backend/target/release/ && \
                       sudo chown -R backend:backend /opt/backend" || {
        log_error "Failed to move build to destination"
        return 1
    }
    
    log_info "Restarting backend service"
    if ssh "$USER@$HOST" "sudo systemctl restart backend"; then
        log_success "Successfully restarted backend service"
    else
        log_error "Failed to restart backend service"
        return 1
    fi
    
    log_info "Verifying backend service status"
    if ssh "$USER@$HOST" "sudo systemctl is-active backend"; then
        log_success "Backend service is running"
    else
        log_error "Backend service failed to start"
        return 1
    fi
    
    log_success "Completed backend deployment"
}

# Main deployment logic
main() {
    local changed_files="$1"
    
    log_info "Starting deployment process"
    log_info "Changed files:"
    echo "$changed_files" | tr ' ' '\n' | while read -r file; do
        log_info "  - $file"
    done
    
    echo "$changed_files" | tr ' ' '\n' | while read -r file; do
        case "$file" in
            "services/glance/glance.yml")
                deploy_service "glance" "$file" "/etc/glance.yml"
                ;;
            "services/premiership-rugby-extension/premiership-rugby-extension.js")
                deploy_service "premiership-rugby-extension" "$file" "/opt/premiership-rugby-extension/premiership-ruby-extension.js"
                ;;
            "services/f1-standings-extension/f1-standings-extension.js")
                deploy_service "f1-standings-extension" "$file" "/opt/f1-standings-extension/f1-standings-extension.js"
                ;;
        esac
    done

    # Deploy backend site if services/backend changed
    if echo "$changed_files" | grep -q "services/backend"; then
        deploy_backend
    fi
    
    # Deploy Zola site if blog files changed
    if echo "$changed_files" | grep -q "blog/"; then
        deploy_zola
    fi
    
    log_success "Deployment process completed"
    log_info "Deployment log saved to: $LOG_FILE"
}

# Run main function with changed files
main "$CHANGED_FILES"
