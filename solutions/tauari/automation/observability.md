# Observability and Monitoring

**Author:** Tauari  
**Date:** 2025-10-31  
**Context:** DBRE Challenge - Advanced Requirements

---

## Overview

This document defines Service Level Indicators (SLIs), Service Level Objectives (SLOs), alerts, and monitoring strategy for the betting platform. We provide actionable metrics, alert thresholds, and automation scripts.

---

## Service Level Indicators (SLIs)

### Definition
SLIs are quantitative measures of service behavior that matter to users.

### Key SLIs for Betting Platform

| SLI | Metric | Measurement Method | Data Source |
| --- | ------ | ------------------ | ----------- |
| **Query Latency** | p95 latency per query | Histogram | Application logs + PostgreSQL |
| **Availability** | % of successful requests | Counter | Load balancer + Application |
| **Data Freshness** | Replication lag | Gauge | PostgreSQL stats |
| **Cache Hit Rate** | % of cache hits | Counter | Redis stats |
| **Error Rate** | % of failed requests | Counter | Application logs |
| **Transaction Success Rate** | % of successful transactions | Counter | PostgreSQL + Application |

---

## Service Level Objectives (SLOs)

### Definition
SLOs are target values for SLIs that define acceptable service quality.

### SLOs by Priority

#### Tier 1: Critical (User-Facing)

| Service | SLI | SLO Target | Measurement Window | Consequence if Violated |
| ------- | --- | ---------- | ------------------ | ---------------------- |
| **Query 1 (Active Bets)** | p95 latency | < 5ms | Rolling 1 hour | Dashboard lag, user complaints |
| **Bet Placement** | p95 latency | < 50ms | Rolling 1 hour | Lost revenue |
| **API Availability** | Uptime | 99.9% (43 min/month) | Monthly | SLA breach |
| **Transaction Success** | Success rate | > 99.99% | Rolling 24 hours | Financial loss |

#### Tier 2: Important (Operational)

| Service | SLI | SLO Target | Measurement Window | Consequence if Violated |
| ------- | --- | ---------- | ------------------ | ---------------------- |
| **Query 2-4** | p95 latency | < 10ms | Rolling 1 hour | Slow reports |
| **Replication Lag** | Lag time | < 1 second | Real-time | Stale reads |
| **Cache Hit Rate** | Hit ratio | > 80% | Rolling 5 minutes | Increased DB load |
| **Backup Success** | Success rate | 100% | Daily | RPO at risk |

#### Tier 3: Nice-to-Have (Analytics)

| Service | SLI | SLO Target | Measurement Window | Consequence if Violated |
| ------- | --- | ---------- | ------------------ | ---------------------- |
| **ClickHouse Queries** | p95 latency | < 500ms | Rolling 1 hour | Slow BI dashboards |
| **ETL Pipeline** | Lag time | < 1 hour | Real-time | Stale analytics |

---

## Error Budget

### Concept
Error budget = (1 - SLO) × Time Window

**Example for 99.9% availability SLO:**
- Monthly error budget = (1 - 0.999) × 43,200 minutes = **43.2 minutes**
- If we burn 43 minutes of downtime this month, we've exhausted our error budget

### Error Budget Policy

| Budget Remaining | Action |
| ---------------- | ------ |
| > 50% | ✅ Ship new features, aggressive changes |
| 25-50% | ⚠️ Slow down releases, increase testing |
| < 25% | 🚨 Feature freeze, focus on reliability |
| 0% | 🛑 Emergency: stop all changes, incident response |

**Tracking:**
```sql
-- Calculate monthly availability
SELECT 
    DATE_TRUNC('month', timestamp) as month,
    COUNT(*) as total_requests,
    COUNT(*) FILTER (WHERE status = 200) as successful_requests,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status = 200) / COUNT(*), 3) as availability_pct,
    ROUND((1 - (COUNT(*) FILTER (WHERE status = 200)::DECIMAL / COUNT(*))) * 43200, 2) as downtime_minutes
FROM request_logs
WHERE timestamp >= DATE_TRUNC('month', CURRENT_DATE)
GROUP BY month;
```

---

## Metrics Collection Architecture

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ Application  │  │ PostgreSQL   │  │    Redis     │
│ (API Nodes)  │  │ (Exporter)   │  │  (Exporter)  │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       │ /metrics        │ :9187           │ :9121
       ↓                 ↓                 ↓
┌────────────────────────────────────────────────────┐
│              Prometheus (Scraper)                   │
│  • Scrape interval: 15s                            │
│  • Retention: 30 days                              │
│  • Storage: 50GB SSD                               │
└────────────┬───────────────────────────────────────┘
             │
             ↓
┌────────────────────────────────────────────────────┐
│                   Grafana (Visualization)          │
│  • Real-time dashboards                            │
│  • Custom queries                                  │
│  • Alerting (backup to Prometheus)                │
└────────────────────────────────────────────────────┘
             │
             ↓
┌────────────────────────────────────────────────────┐
│              AlertManager (Routing)                │
│  • PagerDuty (P1: Immediate)                       │
│  • Slack (P2: Within 1 hour)                       │
│  • Email (P3: Within 24 hours)                     │
└────────────────────────────────────────────────────┘
```

---

## Key Metrics to Monitor

### Application Metrics

```python
# Python application with prometheus_client
from prometheus_client import Counter, Histogram, Gauge

# Request counters
http_requests_total = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['method', 'endpoint', 'status']
)

# Latency histogram
http_request_duration_seconds = Histogram(
    'http_request_duration_seconds',
    'HTTP request latency',
    ['method', 'endpoint']
)

# Query latency by query type
query_duration_seconds = Histogram(
    'query_duration_seconds',
    'Query execution time',
    ['query_name'],
    buckets=[0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0]
)

# Cache hit rate
cache_requests_total = Counter(
    'cache_requests_total',
    'Total cache requests',
    ['cache_name', 'result']  # result: hit/miss
)

# Example usage
@app.route('/api/active-bets')
def active_bets():
    with http_request_duration_seconds.labels('GET', '/api/active-bets').time():
        http_requests_total.labels('GET', '/api/active-bets', '200').inc()
        
        # Try cache
        cached = redis.get('active_bets')
        if cached:
            cache_requests_total.labels('active_bets', 'hit').inc()
            return cached
        
        cache_requests_total.labels('active_bets', 'miss').inc()
        
        # Query database
        with query_duration_seconds.labels('query1').time():
            result = db.execute(QUERY_1)
        
        redis.setex('active_bets', 5, result)
        return result
```

---

### PostgreSQL Metrics (via postgres_exporter)

**Key Metrics:**
```promql
# Queries per second
rate(pg_stat_database_xact_commit[1m])

# Active connections
pg_stat_activity_count{state="active"}

# Replication lag (bytes)
pg_replication_lag_bytes

# Transaction commit rate
rate(pg_stat_database_xact_commit[5m])

# Transaction rollback rate
rate(pg_stat_database_xact_rollback[5m])

# Buffer cache hit ratio
rate(pg_stat_database_blks_hit[5m]) / 
(rate(pg_stat_database_blks_hit[5m]) + rate(pg_stat_database_blks_read[5m]))

# Deadlocks
rate(pg_stat_database_deadlocks[5m])

# Slow queries (> 100ms)
pg_stat_statements_mean_exec_time_seconds{query="query1"} > 0.1
```

---

### Redis Metrics (via redis_exporter)

**Key Metrics:**
```promql
# Commands per second
rate(redis_commands_processed_total[1m])

# Cache hit rate
rate(redis_keyspace_hits_total[5m]) /
(rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m]))

# Memory usage
redis_memory_used_bytes / redis_memory_max_bytes

# Connected clients
redis_connected_clients

# Evicted keys
rate(redis_evicted_keys_total[5m])
```

---

## Alert Rules

### Prometheus Alerting Rules

```yaml
# /etc/prometheus/alerts.yml
groups:
  - name: database
    interval: 30s
    rules:
      # Critical: Query latency violation
      - alert: QueryLatencyHigh
        expr: histogram_quantile(0.95, rate(query_duration_seconds_bucket[5m])) > 0.005
        for: 5m
        labels:
          severity: critical
          team: dbre
        annotations:
          summary: "Query {{ $labels.query_name }} p95 latency > 5ms"
          description: "p95 latency is {{ $value }}s (SLO: 0.005s)"
          runbook: "https://wiki.company.com/runbooks/query-latency"
      
      # Critical: Primary database down
      - alert: PostgreSQLDown
        expr: pg_up{instance="postgres-primary"} == 0
        for: 30s
        labels:
          severity: critical
          team: dbre
        annotations:
          summary: "PostgreSQL primary is DOWN"
          description: "Primary database {{ $labels.instance }} is unreachable"
          runbook: "https://wiki.company.com/runbooks/postgres-down"
      
      # Warning: Replication lag
      - alert: ReplicationLagHigh
        expr: pg_replication_lag_bytes > 10485760  # 10MB
        for: 2m
        labels:
          severity: warning
          team: dbre
        annotations:
          summary: "Replication lag > 10MB on {{ $labels.instance }}"
          description: "Lag: {{ $value }} bytes (SLO: < 1MB)"
          runbook: "https://wiki.company.com/runbooks/replication-lag"
      
      # Critical: Backup failure
      - alert: BackupFailed
        expr: time() - backup_last_success_timestamp > 90000  # 25 hours
        for: 1h
        labels:
          severity: critical
          team: dbre
        annotations:
          summary: "PostgreSQL backup has not succeeded in 24+ hours"
          description: "Last successful backup: {{ $value | humanizeDuration }} ago"
          runbook: "https://wiki.company.com/runbooks/backup-failed"
      
      # Warning: Connection pool exhaustion
      - alert: ConnectionPoolNearLimit
        expr: pg_stat_activity_count{state="active"} / pg_settings_max_connections > 0.8
        for: 5m
        labels:
          severity: warning
          team: dbre
        annotations:
          summary: "PostgreSQL connections > 80% of max"
          description: "{{ $value }}% of max connections in use"
      
      # Warning: Disk space low
      - alert: DiskSpaceLow
        expr: (node_filesystem_avail_bytes{mountpoint="/var/lib/postgresql"} / 
               node_filesystem_size_bytes{mountpoint="/var/lib/postgresql"}) < 0.15
        for: 10m
        labels:
          severity: warning
          team: dbre
        annotations:
          summary: "Disk space < 15% on {{ $labels.instance }}"
          description: "Only {{ $value | humanizePercentage }} remaining"
      
  - name: cache
    interval: 30s
    rules:
      # Warning: Cache hit rate low
      - alert: CacheHitRateLow
        expr: |
          rate(cache_requests_total{result="hit"}[5m]) /
          rate(cache_requests_total[5m]) < 0.8
        for: 10m
        labels:
          severity: warning
          team: dbre
        annotations:
          summary: "Cache hit rate < 80% for {{ $labels.cache_name }}"
          description: "Hit rate: {{ $value | humanizePercentage }} (SLO: > 80%)"
      
      # Critical: Redis down
      - alert: RedisDown
        expr: redis_up == 0
        for: 1m
        labels:
          severity: critical
          team: dbre
        annotations:
          summary: "Redis {{ $labels.instance }} is DOWN"
          description: "Cache unavailable, traffic failing over to PostgreSQL"
      
      # Warning: Redis memory high
      - alert: RedisMemoryHigh
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9
        for: 5m
        labels:
          severity: warning
          team: dbre
        annotations:
          summary: "Redis memory usage > 90%"
          description: "Memory: {{ $value | humanizePercentage }} (evictions may occur)"
  
  - name: application
    interval: 30s
    rules:
      # Critical: High error rate
      - alert: ErrorRateHigh
        expr: |
          rate(http_requests_total{status=~"5.."}[5m]) /
          rate(http_requests_total[5m]) > 0.01
        for: 2m
        labels:
          severity: critical
          team: backend
        annotations:
          summary: "Error rate > 1% on {{ $labels.endpoint }}"
          description: "Error rate: {{ $value | humanizePercentage }}"
      
      # Critical: API availability SLO breach
      - alert: AvailabilitySLOBreach
        expr: |
          (
            sum(rate(http_requests_total{status="200"}[1h])) /
            sum(rate(http_requests_total[1h]))
          ) < 0.999
        for: 5m
        labels:
          severity: critical
          team: backend
        annotations:
          summary: "API availability < 99.9% (SLO breach)"
          description: "Availability: {{ $value | humanizePercentage }}"
          runbook: "https://wiki.company.com/runbooks/availability-slo"
```

---

### AlertManager Configuration

```yaml
# /etc/alertmanager/config.yml
global:
  resolve_timeout: 5m
  pagerduty_url: 'https://events.pagerduty.com/v2/enqueue'

route:
  receiver: 'default'
  group_by: ['alertname', 'cluster']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  
  routes:
    # Critical alerts to PagerDuty
    - match:
        severity: critical
      receiver: 'pagerduty-critical'
      continue: true
    
    # Critical alerts also to Slack
    - match:
        severity: critical
      receiver: 'slack-critical'
    
    # Warning alerts to Slack
    - match:
        severity: warning
      receiver: 'slack-warnings'

receivers:
  - name: 'default'
    email_configs:
      - to: 'dbre-team@company.com'
  
  - name: 'pagerduty-critical'
    pagerduty_configs:
      - service_key: '<PAGERDUTY_SERVICE_KEY>'
        description: '{{ .GroupLabels.alertname }} - {{ .CommonAnnotations.summary }}'
        details:
          firing: '{{ .Alerts.Firing | len }}'
          resolved: '{{ .Alerts.Resolved | len }}'
  
  - name: 'slack-critical'
    slack_configs:
      - api_url: '<SLACK_WEBHOOK_URL>'
        channel: '#alerts-critical'
        title: '🚨 CRITICAL: {{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
        color: 'danger'
  
  - name: 'slack-warnings'
    slack_configs:
      - api_url: '<SLACK_WEBHOOK_URL>'
        channel: '#alerts-warnings'
        title: '⚠️ WARNING: {{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
        color: 'warning'

inhibit_rules:
  # Inhibit warning if critical is firing
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'instance']
```

---

## Dashboards

### Grafana Dashboard: Database Overview

**Panels:**

1. **Query Latency (p50, p95, p99)**
   ```promql
   histogram_quantile(0.95, rate(query_duration_seconds_bucket[5m]))
   ```

2. **Queries per Second**
   ```promql
   sum(rate(pg_stat_database_xact_commit[1m]))
   ```

3. **Active Connections**
   ```promql
   pg_stat_activity_count{state="active"}
   ```

4. **Replication Lag**
   ```promql
   pg_replication_lag_bytes
   ```

5. **Cache Hit Ratio**
   ```promql
   rate(pg_stat_database_blks_hit[5m]) / 
   (rate(pg_stat_database_blks_hit[5m]) + rate(pg_stat_database_blks_read[5m]))
   ```

6. **Transaction Rate (Commit vs Rollback)**
   ```promql
   rate(pg_stat_database_xact_commit[5m])
   rate(pg_stat_database_xact_rollback[5m])
   ```

**Dashboard JSON:** See `../automation/grafana-dashboard-database.json`

---

### Grafana Dashboard: Application Overview

**Panels:**

1. **Request Rate**
   ```promql
   sum(rate(http_requests_total[1m])) by (endpoint)
   ```

2. **Error Rate**
   ```promql
   sum(rate(http_requests_total{status=~"5.."}[5m])) / 
   sum(rate(http_requests_total[5m]))
   ```

3. **Latency Heatmap**
   ```promql
   sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
   ```

4. **Cache Hit Rate**
   ```promql
   sum(rate(cache_requests_total{result="hit"}[5m])) /
   sum(rate(cache_requests_total[5m]))
   ```

**Dashboard JSON:** See `../automation/grafana-dashboard-application.json`

---

## Automation Scripts

See automation directory for:

1. **`monitoring-setup.sh`** - Install Prometheus, Grafana, exporters
2. **`health-checks.sh`** - Automated health checks
3. **`backup-automation.sh`** - Automated backup with verification
4. **`alert-test.sh`** - Test alert routing
5. **`infrastructure.tf`** - Terraform IaC for monitoring stack

---

## On-Call Runbooks

### Runbook: Query Latency High

**Alert:** QueryLatencyHigh  
**Severity:** Critical  
**SLO Impact:** Yes (p95 > 5ms)

**Diagnosis:**
```bash
# Check current query performance
psql -c "SELECT query, mean_exec_time, calls 
FROM pg_stat_statements 
ORDER BY mean_exec_time DESC LIMIT 10;"

# Check active queries
psql -c "SELECT pid, query, state, wait_event_type, query_start 
FROM pg_stat_activity 
WHERE state = 'active' 
ORDER BY query_start;"

# Check for locks
psql -c "SELECT * FROM pg_locks WHERE NOT granted;"
```

**Mitigation:**
1. Check for slow queries (> 5ms)
2. Verify indexes are being used (`EXPLAIN ANALYZE`)
3. Check for table bloat (`pg_stat_user_tables`)
4. Consider increasing `work_mem` temporarily
5. If persistent, add to optimization backlog

---

### Runbook: PostgreSQL Down

**Alert:** PostgreSQLDown  
**Severity:** Critical  
**SLO Impact:** Yes (availability)

**Immediate Actions:**
```bash
# 1. Verify Patroni failover status
patroni-ctl -c /etc/patroni.yml list

# 2. Check PostgreSQL logs
tail -100 /var/log/postgresql/postgresql-16-main.log

# 3. If primary is down, verify automatic failover
# Patroni should promote replica within 30 seconds

# 4. Verify application can connect
psql -h betting-cluster -U app -c "SELECT 1;"

# 5. Page on-call DBA if failover failed
```

**Post-Incident:**
1. Root cause analysis
2. Rebuild failed node
3. Update incident log
4. Review RPO/RTO achievement

---

### Runbook: Backup Failed

**Alert:** BackupFailed  
**Severity:** Critical  
**SLO Impact:** Yes (RPO at risk)

**Diagnosis:**
```bash
# Check backup logs
tail -100 /var/log/postgresql/backup.log

# Check S3 connectivity
aws s3 ls s3://betting-backups/daily/

# Check disk space on backup source
df -h /var/lib/postgresql

# Check backup script status
systemctl status postgresql-backup.timer
```

**Mitigation:**
1. Fix underlying issue (disk space, S3 access, etc.)
2. Run manual backup immediately
3. Verify backup integrity
4. Update incident log

---

## Compliance and Audit

### Metrics Retention

| Metric Type | Retention Period | Storage | Purpose |
| ----------- | ---------------- | ------- | ------- |
| Raw metrics | 30 days | Prometheus | Real-time monitoring |
| Aggregated metrics | 1 year | PostgreSQL | Trend analysis |
| Audit logs | 7 years | S3 Glacier | Compliance |
| Backup verification | 90 days | S3 Standard | Disaster recovery |

### Monthly SLO Report

```sql
-- Generate monthly SLO report
SELECT 
    DATE_TRUNC('month', timestamp) as month,
    
    -- Availability SLO
    ROUND(100.0 * COUNT(*) FILTER (WHERE status = 200) / COUNT(*), 3) as availability_pct,
    CASE 
        WHEN ROUND(100.0 * COUNT(*) FILTER (WHERE status = 200) / COUNT(*), 3) >= 99.9 
        THEN 'PASS' 
        ELSE 'FAIL' 
    END as availability_slo,
    
    -- Query Latency SLO (Query 1)
    percentile_cont(0.95) WITHIN GROUP (ORDER BY query1_latency_ms) as query1_p95_ms,
    CASE 
        WHEN percentile_cont(0.95) WITHIN GROUP (ORDER BY query1_latency_ms) < 5 
        THEN 'PASS' 
        ELSE 'FAIL' 
    END as query1_slo,
    
    -- Error budget consumed
    ROUND((1 - (COUNT(*) FILTER (WHERE status = 200)::DECIMAL / COUNT(*))) * 43200, 2) as downtime_minutes,
    ROUND(100.0 * (1 - (COUNT(*) FILTER (WHERE status = 200)::DECIMAL / COUNT(*))) / 0.001, 2) as error_budget_pct

FROM metrics
WHERE timestamp >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')
  AND timestamp < DATE_TRUNC('month', CURRENT_DATE)
GROUP BY month;
```

---

## Continuous Improvement

### Weekly Review
- Review top 10 slowest queries
- Analyze alert noise (false positives)
- Update SLO targets based on performance

### Monthly Review
- SLO achievement report
- Error budget analysis
- Capacity planning based on growth trends
- Review and update runbooks

### Quarterly Review
- Architecture review (scaling needs)
- DR drill execution
- Update monitoring stack (Prometheus, Grafana upgrades)
- Team training on new tools

---

**Related Scripts:**
- `monitoring-setup.sh` - Automated monitoring stack deployment
- `health-checks.sh` - Automated health verification
- `backup-automation.sh` - Backup with verification
- `infrastructure.tf` - IaC for monitoring infrastructure

