#!/bin/bash
################################################################################
# PostgreSQL Health Checks Script
# Author: Tauari
# Date: 2025-10-31
# Purpose: Automated health checks for PostgreSQL, Redis, and application
################################################################################

set -euo pipefail

# Configuration
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-app}"
POSTGRES_DB="${POSTGRES_DB:-app}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
ALERT_THRESHOLD_LATENCY_MS=5
ALERT_THRESHOLD_REPLICATION_LAG_MB=10

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Send alert to Slack
send_alert() {
    local severity=$1
    local message=$2
    
    if [ -n "$SLACK_WEBHOOK" ]; then
        local color="warning"
        local icon="⚠️"
        
        if [ "$severity" = "critical" ]; then
            color="danger"
            icon="🚨"
        fi
        
        curl -X POST "$SLACK_WEBHOOK" \
            -H 'Content-Type: application/json' \
            -d "{
                \"attachments\": [{
                    \"color\": \"$color\",
                    \"title\": \"$icon Health Check Alert\",
                    \"text\": \"$message\",
                    \"ts\": $(date +%s)
                }]
            }" &> /dev/null
    fi
}

# PostgreSQL health checks
check_postgres() {
    log_info "Checking PostgreSQL health..."
    
    # Check if PostgreSQL is up
    if ! pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" &> /dev/null; then
        log_error "PostgreSQL is DOWN"
        send_alert "critical" "PostgreSQL on $POSTGRES_HOST:$POSTGRES_PORT is DOWN"
        return 1
    fi
    
    log_info "✓ PostgreSQL is UP"
    
    # Check active connections
    local active_connections=$(PGPASSWORD="$PGPASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';")
    log_info "Active connections: $active_connections"
    
    # Check max connections
    local max_connections=$(PGPASSWORD="$PGPASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT setting FROM pg_settings WHERE name = 'max_connections';")
    local connection_pct=$((active_connections * 100 / max_connections))
    
    if [ $connection_pct -gt 80 ]; then
        log_warn "Connection pool usage: ${connection_pct}% (${active_connections}/${max_connections})"
        send_alert "warning" "PostgreSQL connection pool > 80%: ${connection_pct}%"
    else
        log_info "✓ Connection pool usage: ${connection_pct}% (${active_connections}/${max_connections})"
    fi
    
    # Check replication lag (if replica)
    local is_in_recovery=$(PGPASSWORD="$PGPASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT pg_is_in_recovery();")
    
    if [ "$is_in_recovery" = " t" ]; then
        local lag_bytes=$(PGPASSWORD="$PGPASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());")
        local lag_mb=$((lag_bytes / 1024 / 1024))
        
        if [ $lag_mb -gt $ALERT_THRESHOLD_REPLICATION_LAG_MB ]; then
            log_warn "Replication lag: ${lag_mb}MB"
            send_alert "warning" "Replication lag > ${ALERT_THRESHOLD_REPLICATION_LAG_MB}MB: ${lag_mb}MB"
        else
            log_info "✓ Replication lag: ${lag_mb}MB"
        fi
    fi
    
    # Check query performance
    log_info "Checking query performance..."
    
    local query1_latency=$(PGPASSWORD="$PGPASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "\timing on" -c "$(cat ops/scripts/query1.sql)" 2>&1 | grep "Time:" | awk '{print $2}' | cut -d'.' -f1)
    
    if [ -n "$query1_latency" ]; then
        if [ $query1_latency -gt $ALERT_THRESHOLD_LATENCY_MS ]; then
            log_warn "Query 1 latency: ${query1_latency}ms (SLO: < ${ALERT_THRESHOLD_LATENCY_MS}ms)"
            send_alert "warning" "Query 1 latency > ${ALERT_THRESHOLD_LATENCY_MS}ms: ${query1_latency}ms"
        else
            log_info "✓ Query 1 latency: ${query1_latency}ms"
        fi
    fi
    
    # Check database size
    local db_size=$(PGPASSWORD="$PGPASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT pg_size_pretty(pg_database_size('$POSTGRES_DB'));")
    log_info "Database size: $db_size"
    
    # Check for long-running queries
    local long_queries=$(PGPASSWORD="$PGPASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND now() - query_start > interval '1 minute';")
    
    if [ $long_queries -gt 0 ]; then
        log_warn "Long-running queries detected: $long_queries"
    else
        log_info "✓ No long-running queries"
    fi
    
    return 0
}

# Redis health checks
check_redis() {
    log_info "Checking Redis health..."
    
    # Check if Redis is up
    if ! redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" PING &> /dev/null; then
        log_error "Redis is DOWN"
        send_alert "critical" "Redis on $REDIS_HOST:$REDIS_PORT is DOWN"
        return 1
    fi
    
    log_info "✓ Redis is UP"
    
    # Check memory usage
    local used_memory=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INFO memory | grep "used_memory_human:" | cut -d':' -f2 | tr -d '\r')
    local maxmemory=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INFO memory | grep "maxmemory_human:" | cut -d':' -f2 | tr -d '\r')
    log_info "Redis memory: $used_memory / $maxmemory"
    
    # Check connected clients
    local connected_clients=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INFO clients | grep "connected_clients:" | cut -d':' -f2 | tr -d '\r')
    log_info "Connected clients: $connected_clients"
    
    # Check hit rate
    local keyspace_hits=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INFO stats | grep "keyspace_hits:" | cut -d':' -f2 | tr -d '\r')
    local keyspace_misses=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INFO stats | grep "keyspace_misses:" | cut -d':' -f2 | tr -d '\r')
    
    if [ $((keyspace_hits + keyspace_misses)) -gt 0 ]; then
        local hit_rate=$((keyspace_hits * 100 / (keyspace_hits + keyspace_misses)))
        
        if [ $hit_rate -lt 80 ]; then
            log_warn "Cache hit rate: ${hit_rate}% (target: > 80%)"
            send_alert "warning" "Redis cache hit rate < 80%: ${hit_rate}%"
        else
            log_info "✓ Cache hit rate: ${hit_rate}%"
        fi
    fi
    
    return 0
}

# Disk space checks
check_disk_space() {
    log_info "Checking disk space..."
    
    local pg_data_usage=$(df -h /var/lib/postgresql 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    
    if [ -n "$pg_data_usage" ]; then
        if [ $pg_data_usage -gt 85 ]; then
            log_warn "PostgreSQL data disk usage: ${pg_data_usage}%"
            send_alert "warning" "PostgreSQL data disk > 85%: ${pg_data_usage}%"
        else
            log_info "✓ PostgreSQL data disk usage: ${pg_data_usage}%"
        fi
    fi
    
    return 0
}

# Backup verification
check_backup() {
    log_info "Checking backup status..."
    
    local backup_file="/backups/postgresql-$(date +%Y-%m-%d).dump"
    
    if [ -f "$backup_file" ]; then
        local backup_age=$(($(date +%s) - $(stat -c %Y "$backup_file")))
        local backup_age_hours=$((backup_age / 3600))
        
        if [ $backup_age_hours -gt 25 ]; then
            log_warn "Latest backup is ${backup_age_hours} hours old"
            send_alert "warning" "Latest backup is ${backup_age_hours} hours old (expected: < 25 hours)"
        else
            log_info "✓ Latest backup: ${backup_age_hours} hours old"
        fi
        
        # Check backup size
        local backup_size=$(du -h "$backup_file" | cut -f1)
        log_info "Backup size: $backup_size"
    else
        log_error "No backup found for today"
        send_alert "critical" "No backup found for $(date +%Y-%m-%d)"
    fi
    
    return 0
}

# Main execution
main() {
    log_info "Starting health checks..."
    echo "========================================"
    
    local exit_code=0
    
    # Run all checks
    check_postgres || exit_code=1
    echo "----------------------------------------"
    
    check_redis || exit_code=1
    echo "----------------------------------------"
    
    check_disk_space || exit_code=1
    echo "----------------------------------------"
    
    check_backup || exit_code=1
    echo "========================================"
    
    if [ $exit_code -eq 0 ]; then
        log_info "All health checks PASSED ✅"
    else
        log_error "Some health checks FAILED ❌"
    fi
    
    return $exit_code
}

# Run main function
main "$@"

