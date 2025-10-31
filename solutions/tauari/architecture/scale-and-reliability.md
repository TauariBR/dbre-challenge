# Scale and Reliability Plan

**Author:** Tauari  
**Date:** 2025-10-31  
**Context:** DBRE Challenge - Advanced Requirements

---

## Overview

This document provides a comprehensive plan for sustained growth, high availability, and disaster recovery for the betting platform. We cover scaling strategies from current state (4M bets) to multi-terabyte scale (4B+ bets), replication topology, RPO/RTO targets, and backup/recovery procedures.

---

## Current State Baseline

**Dataset:**
- Users: 200K records (~50MB)
- Events: 800K records (~200MB)
- Bets: 4M records (~2GB)
- Total database size: ~3GB
- Growth rate: ~1M bets/day (~500MB/day)

**Workload:**
- Write QPS: ~50 (bet placement)
- Read QPS: ~200 (dashboard, reports)
- Peak QPS: ~500 (live events)

**Performance:**
- All queries < 5ms ✅
- No replication lag (single instance)
- Backup time: ~5 minutes (pg_dump)

---

## Scaling Strategy by Phase

### Phase 1: Current State (0-10M bets, 0-5GB)

**Architecture:** Single PostgreSQL instance  
**Timeline:** Current - 3 months

**Components:**
```
┌──────────────────┐
│   Application    │
│                  │
└────────┬─────────┘
         │
         ↓
┌──────────────────┐
│   PostgreSQL     │
│   (Primary)      │
│   • 4 vCPU       │
│   • 16GB RAM     │
│   • 100GB SSD    │
└──────────────────┘
```

**Capacity:**
- Max bets: 10M (5GB)
- Max QPS: 500
- Acceptable until: Q2 2026

**Scaling Triggers:**
- Database size > 20GB
- QPS > 500
- p95 latency > 10ms

**Action Required:** None (current state is adequate)

---

### Phase 2: Growth (10M-100M bets, 5-50GB)

**Architecture:** Primary + Read Replicas  
**Timeline:** 3-12 months

**Components:**
```
┌──────────────────┐      ┌──────────────────┐
│   Application    │      │   Application    │
│   (Write)        │      │   (Read)         │
└────────┬─────────┘      └────────┬─────────┘
         │                         │
         │ Write                   │ Read
         ↓                         ↓
┌──────────────────┐      ┌──────────────────┐
│   PostgreSQL     │━━━━━▶│   PostgreSQL     │
│   (Primary)      │ Async │   (Replica 1)    │
│   • 8 vCPU       │ Repl  │   • 4 vCPU       │
│   • 32GB RAM     │       │   • 16GB RAM     │
│   • 500GB SSD    │       │   • 500GB SSD    │
└────────┬─────────┘      └──────────────────┘
         │
         │ Async Repl
         ↓
┌──────────────────┐
│   PostgreSQL     │
│   (Replica 2)    │
│   • 4 vCPU       │
│   • 16GB RAM     │
│   • 500GB SSD    │
└──────────────────┘
```

**Replication:**
- Streaming replication (asynchronous)
- Lag target: < 1 second
- Use replicas for:
  - Read-only queries (Queries 1, 2, 3, 4)
  - Analytical workloads
  - Backup source

**Read/Write Splitting:**
```python
# Application routing logic
class DatabaseRouter:
    def route(self, query):
        if query.is_write() or query.requires_consistency():
            return PRIMARY
        else:
            # Load balance across replicas
            return random.choice([REPLICA_1, REPLICA_2])
```

**Connection Pooling:**
```
pgBouncer (session mode)
- Primary pool: 100 connections
- Replica 1 pool: 50 connections
- Replica 2 pool: 50 connections
```

**Capacity:**
- Max bets: 100M (50GB)
- Max QPS: 2000 (500 write, 1500 read)
- Acceptable until: Q4 2026

**Migration Steps:**
1. Provision replica instances
2. Configure streaming replication
3. Deploy pgBouncer
4. Update application connection strings
5. Test failover procedure
6. Monitor replication lag

**Estimated Downtime:** Zero (online migration)

---

### Phase 3: Scale (100M-1B bets, 50-500GB)

**Architecture:** Primary + Replicas + Redis + Partitioning  
**Timeline:** 12-24 months

**Components:**
```
┌──────────────────┐
│   Load Balancer  │
│   (HAProxy)      │
└────────┬─────────┘
         │
    ┌────┴────┐
    │         │
    ↓         ↓
┌────────┐  ┌────────┐
│  API   │  │  API   │
│  Node  │  │  Node  │
└───┬────┘  └───┬────┘
    │           │
    │  Write    │  Read
    ↓           ↓
┌─────────┐  ┌──────────┐
│  Redis  │  │ Replicas │
│ (Cache) │  │  (Pool)  │
└────┬────┘  └─────┬────┘
     │             │
     │ Cache Miss  │
     └──────┬──────┘
            ↓
   ┌──────────────────┐
   │   PostgreSQL     │
   │   (Primary)      │
   │   Partitioned    │
   │   • 16 vCPU      │
   │   • 64GB RAM     │
   │   • 2TB SSD      │
   └──────────────────┘
```

**Table Partitioning (bets table):**
```sql
-- Partition by month for manageability
CREATE TABLE bets (
    id BIGSERIAL,
    user_id BIGINT NOT NULL,
    event_id BIGINT NOT NULL,
    status TEXT NOT NULL,
    amount NUMERIC(12,2) NOT NULL,
    placed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
) PARTITION BY RANGE (placed_at);

-- Monthly partitions
CREATE TABLE bets_2025_01 PARTITION OF bets
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');

CREATE TABLE bets_2025_02 PARTITION OF bets
    FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');

-- ... create partitions for each month

-- Indexes on each partition
CREATE INDEX CONCURRENTLY ON bets_2025_01 (status, event_id)
    WHERE status = 'OPEN';
```

**Benefits of Partitioning:**
- ✅ Faster queries (partition pruning)
- ✅ Easier archival (DROP old partitions)
- ✅ Better VACUUM performance
- ✅ Index maintenance per partition

**Redis Integration:**
- Cache Query 1 results (TTL 5s)
- Session storage (TTL 1h)
- Real-time counters (Query 4)

**Capacity:**
- Max bets: 1B (500GB)
- Max QPS: 5000 (1000 write, 4000 read)
- Acceptable until: Q4 2027

---

### Phase 4: Multi-Terabyte Scale (1B+ bets, 500GB-5TB)

**Architecture:** Sharded PostgreSQL + Redis Cluster + ClickHouse  
**Timeline:** 24+ months

**Components:**
```
┌──────────────────┐
│   Load Balancer  │
└────────┬─────────┘
         │
    ┌────┴────┐
    │         │
    ↓         ↓
┌─────────┐ ┌─────────┐
│ API + │ │ API +   │
│ Shard │ │ Shard   │
│ Router│ │ Router  │
└───┬───┘ └───┬─────┘
    │         │
    │         │
    ↓         ↓
┌──────────────────────────────┐
│      Redis Cluster           │
│      (Cache + Routing)       │
└──────────┬───────────────────┘
           │
  ┌────────┼────────┐
  │        │        │
  ↓        ↓        ↓
┌──────┐ ┌──────┐ ┌──────┐
│Shard1│ │Shard2│ │Shard3│
│(PG)  │ │(PG)  │ │(PG)  │
│0-33% │ │33-66%│ │66-99%│
└──────┘ └──────┘ └──────┘
  │        │        │
  └────────┼────────┘
           │ CDC
           ↓
    ┌─────────────┐
    │ ClickHouse  │
    │ (Analytics) │
    └─────────────┘
```

**Sharding Strategy:**
- Shard key: `user_id` (ensures user data co-location)
- Shard count: 3-8 shards (expandable)
- Consistent hashing for routing

**Shard Routing Logic:**
```python
def get_shard(user_id):
    # Consistent hashing
    shard_count = 3
    shard_id = hashlib.md5(str(user_id).encode()).digest()[0] % shard_count
    return SHARDS[shard_id]

def place_bet(user_id, event_id, amount):
    shard = get_shard(user_id)
    shard.execute("INSERT INTO bets ...")
```

**Cross-Shard Queries:**
- Use ClickHouse for analytics (federated queries)
- Cache aggregates in Redis
- Avoid cross-shard JOINs in OLTP

**Capacity:**
- Max bets: 10B+ (5TB+)
- Max QPS: 20,000+ (5000 write, 15000 read)
- Acceptable: Multi-year

---

## High Availability (HA) Architecture

### Objective
Minimize downtime and data loss during failures.

### HA Strategy by Component

#### PostgreSQL Primary HA

**Architecture:** Active-Passive with Automatic Failover

```
┌──────────────────┐
│   Application    │
│   (via VIP)      │
└────────┬─────────┘
         │
         ↓
┌──────────────────┐
│   Virtual IP     │
│   (managed by    │
│   Patroni)       │
└────────┬─────────┘
         │
    ┌────┴────┐
    │         │
    ↓         ↓
┌──────────┐ ┌──────────┐
│Primary   │━│Standby   │
│(Leader)  │━│(Sync)    │
│Active    │━│Ready     │
└──────────┘ └──────────┘
    │             │
    │ Async Repl  │
    ↓             ↓
┌──────────┐ ┌──────────┐
│Replica 1 │ │Replica 2 │
│(Async)   │ │(Async)   │
└──────────┘ └──────────┘
```

**Tooling:** Patroni + etcd + HAProxy

**Failover Process:**
1. Patroni detects primary failure (health check)
2. etcd coordinates failover election
3. Standby promoted to primary (< 30 seconds)
4. VIP switched to new primary
5. Applications reconnect automatically
6. Old primary rejoins as standby (when recovered)

**Configuration:**
```yaml
# patroni.yml
scope: betting-cluster
namespace: /db/
name: postgres-1

postgresql:
  use_pg_rewind: true
  parameters:
    max_connections: 200
    synchronous_commit: on
    synchronous_standby_names: 'postgres-2'  # Synchronous replication

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576  # 1MB
```

**Synchronous Replication:**
```sql
-- Primary configuration
ALTER SYSTEM SET synchronous_standby_names = 'postgres-2';
SELECT pg_reload_conf();

-- Verify replication status
SELECT
    application_name,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    replay_lsn,
    sync_priority
FROM pg_stat_replication;
```

**Health Checks:**
```bash
# Patroni health check (every 10s)
curl http://postgres-1:8008/health

# Expected response
{
  "state": "running",
  "role": "master",
  "server_version": 160010,
  "timeline": 1,
  "replication": [
    {
      "usename": "replicator",
      "application_name": "postgres-2",
      "sync_state": "sync",
      "state": "streaming"
    }
  ]
}
```

---

#### Redis HA

**Architecture:** Redis Sentinel (Phase 2) → Redis Cluster (Phase 3+)

**Redis Sentinel (Phase 2):**
```
┌─────────┐  ┌─────────┐  ┌─────────┐
│Sentinel1│  │Sentinel2│  │Sentinel3│
└────┬────┘  └────┬────┘  └────┬────┘
     │            │            │
     └────────────┼────────────┘
                  │ Monitor
                  ↓
     ┌────────────────────────┐
     │                        │
     ↓                        ↓
┌─────────┐             ┌─────────┐
│ Master  │━━━━━━━━━━━━▶│ Replica │
│ (RW)    │  Async Repl │ (RO)    │
└─────────┘             └─────────┘
```

**Failover:** Automatic (< 10 seconds)

**Redis Cluster (Phase 3+):**
```
┌──────────┐  ┌──────────┐  ┌──────────┐
│ Master 1 │  │ Master 2 │  │ Master 3 │
│ Hash 0-  │  │ Hash     │  │ Hash     │
│  5460    │  │ 5461-    │  │ 10923-   │
│          │  │  10922   │  │  16383   │
└────┬─────┘  └────┬─────┘  └────┬─────┘
     │            │             │
     ↓            ↓             ↓
┌─────────┐  ┌─────────┐  ┌─────────┐
│Replica 1│  │Replica 2│  │Replica 3│
└─────────┘  └─────────┘  └─────────┘
```

**Benefits:**
- ✅ Horizontal scaling
- ✅ Automatic sharding
- ✅ Automatic failover
- ✅ No single point of failure

---

## RPO and RTO Targets

### Definitions
- **RPO (Recovery Point Objective):** Maximum acceptable data loss
- **RTO (Recovery Time Objective):** Maximum acceptable downtime

### Targets by Criticality

| System Component | Criticality | RPO | RTO | Mechanism |
| ---------------- | ----------- | --- | --- | --------- |
| **PostgreSQL Primary** | Critical | 0 seconds | 30 seconds | Synchronous replication + Patroni |
| **PostgreSQL Replica** | High | 1 second | 5 minutes | Streaming replication |
| **Redis Cache** | Medium | N/A (ephemeral) | 1 minute | Sentinel failover |
| **ClickHouse** | Low | 1 hour | 30 minutes | Backup + replay |
| **Application** | High | N/A (stateless) | 2 minutes | Load balancer + auto-scaling |

---

### PostgreSQL: RPO = 0, RTO = 30 seconds

**Mechanism:**
1. **Synchronous Replication** ensures zero data loss
2. **Patroni** automates failover in < 30 seconds
3. **WAL archiving** to S3 for disaster recovery

**Configuration:**
```sql
-- Enable synchronous replication
ALTER SYSTEM SET synchronous_commit = 'on';
ALTER SYSTEM SET synchronous_standby_names = 'postgres-2';

-- WAL archiving to S3
ALTER SYSTEM SET archive_mode = 'on';
ALTER SYSTEM SET archive_command = 'aws s3 cp %p s3://betting-wal/%f';
```

**Failover Test:**
```bash
# Simulate primary failure
sudo systemctl stop postgresql-16

# Verify automatic failover
curl http://postgres-2:8008/health
# Expected: "role": "master"

# Verify application reconnects
psql "host=betting-cluster port=5432 user=app"
```

**Disaster Recovery (DC failure):**
```bash
# Restore from S3 backup + WAL replay
aws s3 sync s3://betting-backups/latest /var/lib/postgresql/data
aws s3 sync s3://betting-wal /var/lib/postgresql/wal

# Start PostgreSQL with recovery.conf
postgresql start --recovery-target-timeline=latest
```

---

### Redis: RPO = N/A (ephemeral), RTO = 1 minute

**Mechanism:**
- Cache data is ephemeral (can be rebuilt)
- Sentinel failover: 10-30 seconds
- Application circuit breaker falls back to PostgreSQL

**Failover Test:**
```bash
# Simulate Redis master failure
redis-cli -h redis-master SHUTDOWN

# Verify Sentinel failover
redis-cli -h sentinel-1 SENTINEL masters
# Expected: New master promoted

# Verify application continues (fallback to PG)
curl http://api/active-bets
# Should return results (slower but functional)
```

---

## Backup Strategy

### Backup Types

#### 1. Continuous WAL Archiving (RPO: 0 seconds)

**Purpose:** Point-in-time recovery

**Mechanism:**
```bash
# PostgreSQL configuration
archive_mode = on
archive_command = 'aws s3 cp %p s3://betting-wal/$(date +\%Y-\%m-\%d)/%f'
archive_timeout = 300  # 5 minutes
```

**Retention:** 7 days

**Storage:** AWS S3 (Standard)

**Cost:** ~$50/month (assuming 100GB WAL/day)

---

#### 2. Daily Full Backup (RPO: 24 hours)

**Purpose:** Disaster recovery, compliance

**Mechanism:**
```bash
#!/bin/bash
# backup-daily.sh

BACKUP_DATE=$(date +%Y-%m-%d)
BACKUP_PATH="/backups/postgresql-${BACKUP_DATE}.dump"

# Backup from replica (no impact on primary)
pg_dump -h postgres-replica-1 \
        -U backup_user \
        -F custom \
        -Z 9 \
        -f "${BACKUP_PATH}" \
        app

# Upload to S3 with encryption
aws s3 cp "${BACKUP_PATH}" \
    s3://betting-backups/daily/${BACKUP_DATE}.dump \
    --sse AES256

# Verify backup integrity
pg_restore --list "${BACKUP_PATH}" > /dev/null

# Cleanup local backup
rm "${BACKUP_PATH}"
```

**Schedule:** Daily at 02:00 UTC (cron)

**Retention:** 30 days (S3 Lifecycle Policy)

**Storage:** AWS S3 (Glacier for > 30 days)

**Cost:** ~$200/month (assuming 50GB backup/day)

---

#### 3. Weekly Verified Backup (RPO: 7 days)

**Purpose:** Ensure backups are restorable

**Mechanism:**
```bash
#!/bin/bash
# backup-verify.sh

LATEST_BACKUP=$(aws s3 ls s3://betting-backups/daily/ | sort | tail -1 | awk '{print $4}')

# Download backup
aws s3 cp "s3://betting-backups/daily/${LATEST_BACKUP}" /tmp/

# Restore to test instance
pg_restore -h postgres-test \
           -U postgres \
           -d test_db \
           -c -F custom \
           /tmp/${LATEST_BACKUP}

# Verify data integrity
TEST_COUNT=$(psql -h postgres-test -U postgres -d test_db -t -c "SELECT COUNT(*) FROM bets")

# Alert if test fails
if [ $TEST_COUNT -lt 1000000 ]; then
    echo "ALERT: Backup verification failed!" | mail -s "Backup Alert" dba@company.com
    exit 1
fi

echo "Backup verification successful: ${TEST_COUNT} bets"
```

**Schedule:** Weekly on Sunday

**Retention:** Last 4 verifications logged

---

### Backup Monitoring

**Metrics to Track:**
- Backup success rate (target: 100%)
- Backup duration (target: < 1 hour)
- Backup size trend
- WAL archive lag (target: < 5 minutes)
- Last successful backup age (alert if > 25 hours)

**Alerts:**
```yaml
# Prometheus alert rules
groups:
  - name: backup
    rules:
      - alert: BackupFailed
        expr: backup_last_success_timestamp < (time() - 86400)
        for: 1h
        annotations:
          summary: "PostgreSQL backup has not succeeded in 24 hours"

      - alert: WALArchiveLag
        expr: pg_wal_archive_lag_seconds > 600
        for: 10m
        annotations:
          summary: "WAL archiving is lagging by > 10 minutes"
```

---

## Recovery Procedures

### Scenario 1: Single Table Corruption

**RPO:** < 1 hour  
**RTO:** < 15 minutes

**Procedure:**
```bash
# 1. Identify corrupted table
SELECT * FROM bets WHERE id = 12345;
# ERROR: invalid page in block 1234 of relation "bets"

# 2. Restore single table from backup
pg_restore -h postgres-replica-1 \
           -U postgres \
           -d app \
           -t bets \
           --data-only \
           /backups/latest.dump

# 3. Verify data integrity
SELECT COUNT(*) FROM bets;

# 4. Resume operations
```

---

### Scenario 2: Complete Database Failure

**RPO:** 0 seconds (with sync replication)  
**RTO:** 30 seconds (with Patroni failover)

**Procedure:**
```bash
# 1. Verify primary failure
pg_isready -h postgres-primary

# 2. Patroni automatically promotes standby
# (no manual intervention required)

# 3. Verify new primary
psql -h betting-cluster -U app -c "SELECT pg_is_in_recovery();"
# Expected: f (not in recovery = primary)

# 4. Monitor application reconnections
# (handled automatically by connection pooling)

# 5. Restore failed node as new replica
patroni-ctl reinit betting-cluster postgres-1
```

---

### Scenario 3: Disaster Recovery (Data Center Failure)

**RPO:** 0 seconds (with cross-region WAL archiving)  
**RTO:** 2 hours (manual DR activation)

**Procedure:**
```bash
# 1. Provision new PostgreSQL instance in DR region
# (use Terraform/IaC for quick provisioning)

# 2. Restore base backup from S3
aws s3 cp s3://betting-backups/daily/latest.dump /tmp/
pg_restore -h postgres-dr -U postgres -d app -F custom /tmp/latest.dump

# 3. Replay WAL files from S3
aws s3 sync s3://betting-wal /var/lib/postgresql/wal
postgresql-16-main start --recovery-target-timeline=latest

# 4. Verify data integrity
psql -h postgres-dr -U postgres -c "SELECT COUNT(*) FROM bets;"

# 5. Update DNS/Load Balancer to DR region

# 6. Resume operations in DR region
```

---

## Migration Plan to Each Phase

### Migration to Phase 2 (Add Read Replicas)

**Estimated Downtime:** Zero

**Steps:**
1. Provision replica instances (same spec as primary)
2. Configure streaming replication:
   ```sql
   -- On primary
   CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'secure_password';
   
   -- On replica (recovery.conf)
   standby_mode = 'on'
   primary_conninfo = 'host=postgres-primary port=5432 user=replicator password=...'
   ```
3. Start replica and verify replication:
   ```sql
   SELECT * FROM pg_stat_replication;
   ```
4. Deploy pgBouncer for connection pooling
5. Update application to route reads to replicas
6. Monitor replication lag and performance

**Rollback Plan:** Route all traffic back to primary

---

### Migration to Phase 3 (Add Partitioning)

**Estimated Downtime:** 4 hours (maintenance window)

**Steps:**
1. Create new partitioned table:
   ```sql
   CREATE TABLE bets_new (...) PARTITION BY RANGE (placed_at);
   ```
2. Create monthly partitions for last 12 months
3. Migrate data in batches (off-peak hours):
   ```sql
   INSERT INTO bets_new SELECT * FROM bets WHERE placed_at >= '2024-01-01' AND placed_at < '2024-02-01';
   ```
4. Verify data integrity:
   ```sql
   SELECT COUNT(*) FROM bets;
   SELECT COUNT(*) FROM bets_new;
   ```
5. During maintenance window:
   ```sql
   BEGIN;
   ALTER TABLE bets RENAME TO bets_old;
   ALTER TABLE bets_new RENAME TO bets;
   COMMIT;
   ```
6. Update application (no code changes required)
7. Monitor performance
8. Drop old table after verification (7 days):
   ```sql
   DROP TABLE bets_old;
   ```

**Rollback Plan:** Rename tables back

---

## Monitoring and Verification

### Health Checks

```bash
# PostgreSQL health
pg_isready -h postgres-primary && echo "OK" || echo "FAIL"

# Replication lag
psql -h postgres-primary -c "SELECT client_addr, state, sync_state, 
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes 
FROM pg_stat_replication;"

# Patroni cluster status
patroni-ctl -c /etc/patroni.yml list

# Redis health
redis-cli PING

# Backup verification
ls -lh /backups/postgresql-$(date +%Y-%m-%d).dump
```

---

## Cost Estimation by Phase

| Phase | Infrastructure | Backup Storage | Total/Month |
| ----- | -------------- | -------------- | ----------- |
| Phase 1 (Current) | $200 (1 instance) | $50 | $250 |
| Phase 2 (Replicas) | $600 (1 primary + 2 replicas) | $100 | $700 |
| Phase 3 (Redis + Partitioning) | $1200 (PG + Redis cluster) | $200 | $1400 |
| Phase 4 (Sharded + ClickHouse) | $3000 (3 shards + Redis + CH) | $400 | $3400 |

**Note:** Assumes AWS managed services (RDS, ElastiCache, etc.)

---

## Conclusion

This scale and reliability plan provides a clear path from current state (4M bets) to multi-terabyte scale (4B+ bets), with well-defined RPO/RTO targets, HA architecture, and comprehensive backup/recovery procedures.

**Key Takeaways:**
- ✅ Zero-downtime migrations at each phase
- ✅ RPO = 0 for critical data (synchronous replication)
- ✅ RTO < 30 seconds for automatic failover
- ✅ Verified backups with point-in-time recovery
- ✅ Clear scaling triggers and capacity planning

**Next Steps:**
1. Implement monitoring (see `automation/observability.md`)
2. Set up alerting for health metrics
3. Schedule quarterly DR drills
4. Document runbooks for common scenarios

---

**Related Documents:**
- `store-choices.md` - Data store selection criteria
- `polyglot-architecture.md` - Multi-store architecture design
- `../automation/observability.md` - Monitoring and alerting setup

