#!/bin/bash
################################################################################
# PostgreSQL Backup Automation Script
# Author: Tauari
# Date: 2025-10-31
# Purpose: Automated backup with verification and S3 upload
################################################################################

set -euo pipefail

# Configuration
BACKUP_DIR="${BACKUP_DIR:-/backups}"
POSTGRES_HOST="${POSTGRES_HOST:-postgres-replica-1}"  # Backup from replica
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-backup_user}"
POSTGRES_DB="${POSTGRES_DB:-app}"
S3_BUCKET="${S3_BUCKET:-s3://betting-backups}"
RETENTION_DAYS=30
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Send notification
send_notification() {
    local status=$1
    local message=$2
    
    if [ -n "$SLACK_WEBHOOK" ]; then
        local color="good"
        local icon="✅"
        
        if [ "$status" = "failure" ]; then
            color="danger"
            icon="❌"
        fi
        
        curl -X POST "$SLACK_WEBHOOK" \
            -H 'Content-Type: application/json' \
            -d "{
                \"attachments\": [{
                    \"color\": \"$color\",
                    \"title\": \"$icon Backup $status\",
                    \"text\": \"$message\",
                    \"ts\": $(date +%s)
                }]
            }" &> /dev/null
    fi
}

# Create backup
create_backup() {
    local backup_date=$(date +%Y-%m-%d_%H%M%S)
    local backup_file="$BACKUP_DIR/postgresql-${backup_date}.dump"
    
    log_info "Starting backup to $backup_file"
    
    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"
    
    # Run pg_dump
    PGPASSWORD="$PGPASSWORD" pg_dump \
        -h "$POSTGRES_HOST" \
        -p "$POSTGRES_PORT" \
        -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" \
        -F custom \
        -Z 9 \
        -f "$backup_file" \
        --verbose \
        2>&1 | tee "$BACKUP_DIR/backup-${backup_date}.log"
    
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Backup failed"
        send_notification "failure" "PostgreSQL backup failed on $(hostname)"
        return 1
    fi
    
    log_info "✓ Backup created successfully"
    
    # Get backup size
    local backup_size=$(du -h "$backup_file" | cut -f1)
    log_info "Backup size: $backup_size"
    
    # Verify backup integrity
    log_info "Verifying backup integrity..."
    
    if pg_restore --list "$backup_file" > /dev/null 2>&1; then
        log_info "✓ Backup integrity verified"
    else
        log_error "Backup integrity check failed"
        send_notification "failure" "Backup integrity check failed"
        return 1
    fi
    
    echo "$backup_file"
    return 0
}

# Upload to S3
upload_to_s3() {
    local backup_file=$1
    local backup_date=$(date +%Y-%m-%d)
    local s3_path="$S3_BUCKET/daily/${backup_date}.dump"
    
    log_info "Uploading to S3: $s3_path"
    
    aws s3 cp "$backup_file" "$s3_path" \
        --sse AES256 \
        --storage-class STANDARD \
        --metadata "backup-date=${backup_date},hostname=$(hostname)"
    
    if [ $? -ne 0 ]; then
        log_error "S3 upload failed"
        send_notification "failure" "S3 upload failed for backup $backup_date"
        return 1
    fi
    
    log_info "✓ Uploaded to S3"
    
    # Verify S3 upload
    local s3_size=$(aws s3 ls "$s3_path" | awk '{print $3}')
    local local_size=$(stat -c %s "$backup_file")
    
    if [ "$s3_size" -eq "$local_size" ]; then
        log_info "✓ S3 upload verified (${s3_size} bytes)"
    else
        log_error "S3 upload size mismatch"
        return 1
    fi
    
    return 0
}

# Clean up old backups
cleanup_old_backups() {
    log_info "Cleaning up backups older than $RETENTION_DAYS days..."
    
    # Local cleanup
    find "$BACKUP_DIR" -name "postgresql-*.dump" -mtime +$RETENTION_DAYS -delete
    find "$BACKUP_DIR" -name "backup-*.log" -mtime +$RETENTION_DAYS -delete
    
    log_info "✓ Local cleanup complete"
    
    # S3 lifecycle policy handles S3 cleanup
    # (should be configured separately)
    
    return 0
}

# Update backup metrics
update_metrics() {
    local status=$1
    local backup_size=$2
    
    # Write metrics for Prometheus node_exporter textfile collector
    local metrics_file="/var/lib/node_exporter/textfile_collector/backup.prom"
    
    cat > "$metrics_file" <<EOF
# HELP backup_last_success_timestamp Timestamp of last successful backup
# TYPE backup_last_success_timestamp gauge
backup_last_success_timestamp $(date +%s)

# HELP backup_size_bytes Size of last backup in bytes
# TYPE backup_size_bytes gauge
backup_size_bytes $backup_size

# HELP backup_status Status of last backup (1=success, 0=failure)
# TYPE backup_status gauge
backup_status $status
EOF
    
    log_info "✓ Metrics updated"
    
    return 0
}

# Main execution
main() {
    log_info "==================================="
    log_info "PostgreSQL Backup Script"
    log_info "==================================="
    log_info "Host: $POSTGRES_HOST"
    log_info "Database: $POSTGRES_DB"
    log_info "Backup directory: $BACKUP_DIR"
    log_info "S3 bucket: $S3_BUCKET"
    log_info "==================================="
    
    local start_time=$(date +%s)
    
    # Create backup
    local backup_file=$(create_backup)
    if [ $? -ne 0 ]; then
        update_metrics 0 0
        exit 1
    fi
    
    # Get backup size
    local backup_size=$(stat -c %s "$backup_file")
    
    # Upload to S3
    if ! upload_to_s3 "$backup_file"; then
        update_metrics 0 $backup_size
        exit 1
    fi
    
    # Clean up old backups
    cleanup_old_backups
    
    # Update metrics
    update_metrics 1 $backup_size
    
    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "==================================="
    log_info "Backup completed successfully ✅"
    log_info "Duration: ${duration} seconds"
    log_info "Size: $(du -h "$backup_file" | cut -f1)"
    log_info "==================================="
    
    # Send success notification
    send_notification "success" "PostgreSQL backup completed in ${duration}s ($(du -h "$backup_file" | cut -f1))"
    
    # Remove local backup after successful S3 upload
    # (optional, comment out to keep local copy)
    # rm "$backup_file"
    
    return 0
}

# Run main function
main "$@"

