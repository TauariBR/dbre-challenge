# Polyglot Architecture Proposal

**Author:** Tauari  
**Date:** 2025-10-31  
**Context:** DBRE Challenge - Advanced Requirements

---

## Overview

This document proposes a polyglot architecture for the betting platform, describing the OLTP path, cache path, and analytics path. We define consistency and freshness expectations for each path and explain the trade-offs.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         APPLICATION LAYER                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
│  │ Web API      │  │ Admin Panel  │  │ BI/Analytics │             │
│  │ (Betting)    │  │ (Operations) │  │ (Reports)    │             │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘             │
└─────────┼──────────────────┼──────────────────┼────────────────────┘
          │                  │                  │
          │ Write            │ Read/Write       │ Read Only
          ↓                  ↓                  ↓
┌─────────────────────────────────────────────────────────────────────┐
│                          DATA ACCESS LAYER                           │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    OLTP PATH (Real-time)                      │  │
│  │  ┌────────────┐  Cache Check  ┌────────────┐                 │  │
│  │  │  Redis     │ ←──────────→  │ PostgreSQL │                 │  │
│  │  │  (Cache)   │    Cache-Aside│  (Primary) │                 │  │
│  │  │            │                │            │                 │  │
│  │  │ • Sessions │                │ • Users    │                 │  │
│  │  │ • Counters │                │ • Events   │                 │  │
│  │  │ • Hot Data │                │ • Bets     │                 │  │
│  │  └────────────┘                └──────┬─────┘                 │  │
│  │     TTL: 5s-1h                        │                       │  │
│  │     Consistency: Eventual             │ ACID Transactions    │  │
│  └───────────────────────────────────────┼───────────────────────┘  │
│                                          │                          │
│  ┌──────────────────────────────────────┼───────────────────────┐  │
│  │              ANALYTICS PATH (Batch)   │                       │  │
│  │                                       ↓ CDC/ETL               │  │
│  │                             ┌─────────────────┐               │  │
│  │                             │  ClickHouse     │               │  │
│  │                             │  (Analytics)    │               │  │
│  │                             │                 │               │  │
│  │                             │ • Historical    │               │  │
│  │                             │ • Aggregations  │               │  │
│  │                             │ • BI Reports    │               │  │
│  │                             └─────────────────┘               │  │
│  │                                Lag: 1-24 hours                │  │
│  │                                Consistency: Eventual          │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘

                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│                        MONITORING LAYER                              │
│  Prometheus + Grafana + PagerDuty                                   │
│  • Query Latency • Cache Hit Rate • Replication Lag • Errors       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Path 1: OLTP Path (Real-time Operations)

### Purpose
Handle real-time transactional workloads requiring strong consistency and low latency.

### Components

#### PostgreSQL (Primary OLTP Database)
**Role:** Source of truth for all transactional data

**Workloads:**
- Bet placement (writes)
- Bet settlement (writes)
- User account management (reads/writes)
- Event management (reads/writes)

**Consistency:** **Strong** (ACID transactions)
- Read-your-writes guaranteed
- Serializable isolation level for critical transactions
- Immediate consistency across all readers

**Latency SLA:**
- Writes: < 50ms (p95)
- Reads: < 5ms (p95) ✅ Achieved
- Complex queries: < 50ms (p95)

**Configuration:**
```sql
-- Optimizations applied
work_mem = '256MB';
effective_cache_size = '4GB';
random_page_cost = 0.1;  -- SSD optimized
max_connections = 200;
shared_buffers = '2GB';
```

**Indexes:**
- Covering indexes for hot queries
- HASH indexes for equality lookups
- Partial indexes for filtered queries
- Materialized Views for aggregations

---

#### Redis (Caching Layer)
**Role:** Accelerate read-heavy workloads and store ephemeral data

**Workloads:**
- Cache Query 1 results (Active Bets)
- User session storage
- Real-time counters (Query 4)
- Rate limiting

**Consistency:** **Eventual** (5 seconds - 1 hour)
- Cache-aside pattern: check cache → miss → query DB → populate cache
- TTL-based expiration
- Write-through invalidation for critical updates

**Freshness SLA:**
| Data Type | TTL | Acceptable Staleness | Invalidation Strategy |
| --------- | --- | -------------------- | --------------------- |
| Active Bets (Q1) | 5s | 5 seconds | TTL + Invalidate on bet placement/settlement |
| User Sessions | 1h | 1 hour | TTL only |
| Bet Counts (Q4) | 10s | 10 seconds | Real-time INCR/DECR + TTL |
| Event Catalog | 60s | 1 minute | TTL + Invalidate on event update |

**Latency SLA:**
- Cache hits: < 1ms (p95)
- Cache misses: < 6ms (< 5ms DB + < 1ms cache write)

**Configuration:**
```redis
# Redis configuration
maxmemory 4gb
maxmemory-policy allkeys-lru
timeout 300
tcp-keepalive 60
```

**Cache Patterns:**

**1. Cache-Aside (Lazy Loading) - Query 1**
```python
def get_active_bets():
    cache_key = "active_bets:limit_100"
    
    # Try cache first
    cached = redis.get(cache_key)
    if cached:
        return json.loads(cached)
    
    # Cache miss - query database
    result = db.execute(QUERY_1)
    
    # Populate cache
    redis.setex(cache_key, 5, json.dumps(result))
    
    return result
```

**2. Write-Through Invalidation**
```python
def place_bet(user_id, event_id, amount):
    # Write to database (ACID)
    db.execute("INSERT INTO bets ...")
    db.commit()
    
    # Invalidate cache
    redis.delete("active_bets:limit_100")
    redis.incr(f"bet_count:{status}")
```

**3. Real-time Counters - Query 4**
```python
def get_bet_counts():
    # Real-time from Redis
    counts = {
        "OPEN": redis.get("bet_count:OPEN"),
        "SETTLED": redis.get("bet_count:SETTLED"),
        "CANCELLED": redis.get("bet_count:CANCELLED"),
        "CASHED_OUT": redis.get("bet_count:CASHED_OUT")
    }
    return counts

def on_bet_placed(bet):
    redis.incr(f"bet_count:{bet.status}")

def on_bet_settled(bet):
    redis.decr("bet_count:OPEN")
    redis.incr("bet_count:SETTLED")
```

---

### OLTP Path Data Flow

**Write Path (Bet Placement):**
```
1. API receives bet request
   ↓
2. Validate user balance (PostgreSQL read)
   ↓
3. BEGIN TRANSACTION
   ↓
4. INSERT INTO bets (PostgreSQL write)
   ↓
5. UPDATE user balance (PostgreSQL write)
   ↓
6. COMMIT TRANSACTION
   ↓
7. Invalidate cache keys (Redis)
   ↓
8. Increment counters (Redis)
   ↓
9. Publish event to CDC (Debezium)
```

**Read Path (Active Bets Query):**
```
1. API receives query request
   ↓
2. Check Redis cache (GET active_bets:limit_100)
   ↓
   Cache HIT → Return cached result (< 1ms)
   ↓
   Cache MISS:
   3. Query PostgreSQL with optimized indexes
   ↓
4. Store result in Redis (TTL 5s)
   ↓
5. Return result (< 6ms total)
```

---

## Path 2: Analytics Path (Batch Processing)

### Purpose
Support historical analysis, business intelligence, and complex aggregations without impacting OLTP performance.

### Components

#### ClickHouse (Analytical Database)
**Role:** Data warehouse for historical analytics

**Workloads:**
- Historical bet analysis (multi-year queries)
- User cohort analysis
- Revenue forecasting
- Complex BI dashboards
- Audit and compliance reports

**Consistency:** **Eventual** (1-24 hours lag)
- Acceptable for analytical workloads
- No impact on real-time operations
- Point-in-time consistency within analytical queries

**Freshness SLA:**
| Data Type | Refresh Frequency | Acceptable Lag | Use Case |
| --------- | ----------------- | -------------- | -------- |
| Real-time Dashboard | 5 minutes | 5 minutes | Operational monitoring |
| Daily Reports | 1 hour | 1 hour | Finance, operations |
| Historical Analysis | 24 hours | 24 hours | BI, data science |
| Compliance Audit | On-demand | N/A | Regulatory |

**Latency SLA:**
- Simple aggregations: < 100ms (p95)
- Complex multi-table queries: < 500ms (p95)
- Historical scans (years): < 5s (p95)

**Schema Design (Denormalized):**
```sql
CREATE TABLE bets_analytics (
    -- Fact table (denormalized for fast queries)
    bet_id UInt64,
    bet_status Enum8('OPEN', 'SETTLED', 'CASHED_OUT', 'CANCELLED'),
    bet_amount Decimal(12, 2),
    placed_at DateTime,
    settled_at Nullable(DateTime),
    
    -- User dimension (denormalized)
    user_id UInt64,
    user_name String,
    user_created_at DateTime,
    
    -- Event dimension (denormalized)
    event_id UInt64,
    event_name String,
    event_category String,
    event_start_time DateTime,
    event_status Enum8('SCHEDULED', 'LIVE', 'FINISHED'),
    
    -- Indexes for fast queries
    INDEX idx_placed_at placed_at TYPE minmax GRANULARITY 3,
    INDEX idx_user_id user_id TYPE bloom_filter GRANULARITY 1
    
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(placed_at)  -- Monthly partitions
ORDER BY (placed_at, user_id, event_id)
SETTINGS index_granularity = 8192;
```

**Query Examples:**
```sql
-- Monthly revenue by event category
SELECT 
    toStartOfMonth(placed_at) as month,
    event_category,
    COUNT(*) as bet_count,
    SUM(bet_amount) as total_wagered,
    SUM(IF(bet_status = 'SETTLED', bet_amount, 0)) as settled_amount
FROM bets_analytics
WHERE placed_at >= '2024-01-01'
GROUP BY month, event_category
ORDER BY month DESC, total_wagered DESC;

-- User cohort retention analysis
SELECT 
    toStartOfMonth(user_created_at) as cohort_month,
    COUNT(DISTINCT user_id) as users,
    COUNT(DISTINCT IF(placed_at >= user_created_at + INTERVAL 30 DAY, user_id, NULL)) as retained_30d
FROM bets_analytics
GROUP BY cohort_month
ORDER BY cohort_month DESC;
```

---

#### CDC Pipeline (Change Data Capture)
**Role:** Replicate data from PostgreSQL to ClickHouse in near real-time

**Technology:** Debezium + Kafka

**Data Flow:**
```
PostgreSQL WAL (Write-Ahead Log)
   ↓
Debezium Connector (captures changes)
   ↓
Apache Kafka (message bus)
   ↓
ClickHouse Kafka Engine (consumes messages)
   ↓
ClickHouse tables (materialized)
```

**Configuration:**
```yaml
# Debezium PostgreSQL Connector
connector.class: io.debezium.connector.postgresql.PostgresConnector
database.hostname: postgres-primary
database.port: 5432
database.user: replicator
database.dbname: app
table.include.list: public.users,public.events,public.bets
publication.name: debezium_publication
slot.name: debezium_slot

# Kafka topic routing
transforms: route
transforms.route.type: io.debezium.transforms.ByLogicalTableRouter
transforms.route.topic.regex: (.*)
transforms.route.topic.replacement: $1
```

**Debezium Event Example:**
```json
{
  "before": null,
  "after": {
    "id": 1234567,
    "user_id": 5678,
    "event_id": 91011,
    "status": "OPEN",
    "amount": 100.00,
    "placed_at": "2025-10-31T10:30:00Z"
  },
  "source": {
    "version": "2.4.0",
    "connector": "postgresql",
    "name": "postgres-primary",
    "ts_ms": 1730370600000,
    "db": "app",
    "table": "bets"
  },
  "op": "c",  // create
  "ts_ms": 1730370600123
}
```

**Monitoring:**
- Replication lag (target: < 5 minutes)
- Kafka message backlog
- ClickHouse insert rate
- Data consistency checks (row counts, checksums)

---

### Analytics Path Data Flow

**ETL Pipeline:**
```
1. PostgreSQL transaction commits
   ↓
2. WAL entry created
   ↓
3. Debezium captures change
   ↓
4. Publish to Kafka topic (bets, users, events)
   ↓
5. ClickHouse Kafka Engine consumes message
   ↓
6. Transform and denormalize (JOIN user, event data)
   ↓
7. INSERT into bets_analytics table
   ↓
8. Data available for queries (lag: 1-5 minutes)
```

**Data Quality Checks:**
```sql
-- Daily reconciliation job
SELECT 
    COUNT(*) as pg_count,
    (SELECT COUNT(*) FROM clickhouse.bets_analytics WHERE placed_at >= CURRENT_DATE - 1) as ch_count,
    ABS(pg_count - ch_count) as diff
FROM bets
WHERE placed_at >= CURRENT_DATE - 1;

-- Alert if diff > 1000
```

---

## Consistency and Freshness by Use Case

| Use Case | Path | Store | Consistency | Freshness | Justification |
| -------- | ---- | ----- | ----------- | --------- | ------------- |
| **Bet Placement** | OLTP | PostgreSQL | Strong | Real-time | Financial transaction |
| **Active Bets Dashboard** | OLTP | Redis → PG | Eventual | 5 seconds | High read frequency, tolerable staleness |
| **User Session** | OLTP | Redis | Eventual | 1 hour | Ephemeral data, TTL-based |
| **Recent Bet Counts** | OLTP | Redis | Eventual | 10 seconds | Monitoring, near real-time |
| **Daily Settlement** | OLTP | PG (MV) | Strong | 1 hour | Financial report, refresh-based |
| **User Analytics** | Analytics | ClickHouse | Eventual | 1-24 hours | Historical analysis |
| **Revenue Forecast** | Analytics | ClickHouse | Eventual | 24 hours | Strategic planning |
| **Compliance Audit** | Analytics | ClickHouse | Point-in-time | On-demand | Regulatory requirement |

---

## Trade-offs Analysis

### Polyglot Benefits
- ✅ Right tool for the job (OLTP vs OLAP)
- ✅ Scalability (horizontal scaling for Redis, ClickHouse)
- ✅ Performance isolation (analytics doesn't impact OLTP)
- ✅ Cost optimization (cheaper storage for cold data)

### Polyglot Costs
- ⚠️ Operational complexity (3 databases to manage)
- ⚠️ Data consistency challenges (eventual consistency)
- ⚠️ Multiple failure modes (cache miss, replication lag)
- ⚠️ Development overhead (different query languages, tooling)

### When to Adopt Polyglot

**Keep PostgreSQL Only (Current State):**
- ✅ < 1000 QPS
- ✅ < 1TB data
- ✅ All queries < 50ms
- ✅ Team size < 5 engineers

**Add Redis:**
- ⚠️ QPS > 1000
- ⚠️ p95 latency > 5ms for hot queries
- ⚠️ Need < 1ms response time

**Add ClickHouse:**
- ⚠️ Data > 1TB
- ⚠️ Analytical queries > 1s
- ⚠️ BI/data science workload

---

## Failure Scenarios and Mitigation

### Scenario 1: Redis Cache Failure
**Impact:** Increased load on PostgreSQL, latency degradation

**Mitigation:**
```python
def get_active_bets_with_fallback():
    try:
        # Try cache first
        cached = redis.get("active_bets:limit_100")
        if cached:
            return json.loads(cached)
    except RedisError:
        # Log error but continue to DB
        logger.error("Redis unavailable, falling back to PostgreSQL")
    
    # Always fall back to PostgreSQL
    return db.execute(QUERY_1)
```

**Circuit Breaker:**
- Open circuit after 5 consecutive failures
- Route all traffic to PostgreSQL
- Retry Redis every 30 seconds

### Scenario 2: Replication Lag Spike
**Impact:** Stale data in ClickHouse, analytics inaccuracy

**Mitigation:**
- Monitor lag with alerting (threshold: > 15 minutes)
- Display "Data as of [timestamp]" in dashboards
- Use PostgreSQL for time-sensitive reports

### Scenario 3: PostgreSQL Primary Failure
**Impact:** Total system outage for writes

**Mitigation:**
- Automatic failover to replica (see `scale-and-reliability.md`)
- Redis cache serves stale reads temporarily
- Queue writes for replay after recovery

---

## Deployment Recommendation

### Phase 1 (Current): PostgreSQL Only ✅
**When:** < 100 QPS, < 100GB data  
**Status:** COMPLETE

### Phase 2: PostgreSQL + Redis
**When:** 100-1000 QPS, 100GB-1TB data  
**Trigger:** Query 1 QPS > 500 OR p95 > 10ms  
**Estimated Time:** 2 weeks (setup + testing)

### Phase 3: PostgreSQL + Redis + ClickHouse
**When:** > 1000 QPS, > 1TB data  
**Trigger:** Analytics queries > 1s OR data > 1TB  
**Estimated Time:** 4 weeks (CDC pipeline + testing)

---

**Next Document:** See `scale-and-reliability.md` for scaling strategy, HA, and backup/recovery plans.

