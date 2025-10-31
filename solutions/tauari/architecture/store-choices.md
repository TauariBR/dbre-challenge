clear
# Store Choices and Data Architecture

**Author:** Tauari  
**Date:** 2025-10-31  
**Context:** DBRE Challenge - Advanced Requirements

---

## Overview

This document evaluates when to keep data in PostgreSQL versus introducing complementary stores (Redis, analytical databases) for the betting platform. We analyze data model fit, latency targets, operational complexity, and consistency trade-offs.

---

## Current State Analysis

### PostgreSQL as Primary Store

**Current Usage:**

- Users (200K records, ~50MB)
- Events (800K records, ~200MB)
- Bets (4M records, ~2GB, growing ~1M/day)

**Strengths:**

- ✅ ACID transactions (critical for betting)
- ✅ Complex queries with JOINs
- ✅ Strong consistency guarantees
- ✅ Mature replication and backup tools
- ✅ Rich indexing capabilities

**Limitations:**

- ⚠️ Read-heavy workloads can bottleneck (Query 1: 1000+ qps)
- ⚠️ Aggregation queries CPU-intensive (Queries 2, 3, 4)
- ⚠️ Materialized Views require refresh overhead
- ⚠️ Vertical scaling limits

---

## Store Selection Framework

### Decision Matrix

| Use Case              | PostgreSQL | Redis      | Analytical Store | Rationale                                 |
| --------------------- | ---------- | ---------- | ---------------- | ----------------------------------------- |
| **Bet Placement**     | ✅ Primary | ❌ No      | ❌ No            | Requires ACID, complex validation         |
| **Active Bets Query** | ✅ Primary | ⚠️ Cache   | ❌ No            | Real-time, high frequency, cache can help |
| **User Session**      | ⚠️ Store   | ✅ Primary | ❌ No            | Ephemeral, high read/write, TTL           |
| **Recent Bet Counts** | ⚠️ Source  | ✅ Primary | ❌ No            | High frequency (8 qps), simple data       |
| **Daily Settlement**  | ✅ Source  | ⚠️ Cache   | ✅ Primary       | Complex aggregation, historical analysis  |
| **User Analytics**    | ✅ Source  | ❌ No      | ✅ Primary       | Complex analytics, historical trends      |
| **Event Catalog**     | ✅ Primary | ⚠️ Cache   | ❌ No            | Moderate change rate, high read           |

**Legend:**

- ✅ Primary: Best fit for this use case
- ⚠️ Secondary: Complementary role (cache/replica)
- ❌ No: Not suitable

---

## Store-Specific Analysis

### 1. PostgreSQL (Primary OLTP)

**When to Use:**

- Transactional workloads requiring ACID
- Complex queries with JOINs across multiple tables
- Strong consistency requirements
- Data that needs immediate durability

**Our Use Cases:**

- ✅ Bet placement and settlement (write-heavy, transactional)
- ✅ User account management
- ✅ Event lifecycle management
- ✅ Referential integrity enforcement

**Optimization Strategies Applied:**

- Covering indexes for hot queries
- HASH indexes for equality lookups
- Partial indexes to reduce storage
- Materialized Views for aggregations
- PostgreSQL configuration tuning

**Latency Targets Met:**

- Query 1: 2.24ms (< 5ms target) ✅
- All queries: < 5ms ✅

**Trade-offs:**

- ✅ Strong consistency, no data loss risk
- ✅ Single source of truth
- ⚠️ Requires careful index management
- ⚠️ Materialized Views need refresh strategy

---

### 2. Redis (Caching Layer)

**When to Use:**

- Sub-millisecond latency requirements
- High-frequency reads (1000+ qps)
- Session data with TTL
- Leaderboards and counters
- Data that can tolerate eventual consistency

**Proposed Use Cases for Our System:**

#### A. Query Result Caching (Query 1: Active Bets)

**Pattern:** Cache-Aside (Lazy Loading)

```
Application → Check Redis → If HIT: return cached result
                          → If MISS: Query PostgreSQL → Cache result → return
```

**Configuration:**

```redis
Key: active_bets:limit_100
Value: JSON array of bet records
TTL: 5 seconds (align with dashboard refresh rate)
Eviction: LRU
```

**Benefits:**

- ✅ Offload 90%+ reads from PostgreSQL
- ✅ < 1ms latency for cache hits
- ✅ Handles 1000+ qps easily

**Trade-offs:**

- ⚠️ 5-second staleness acceptable for dashboard
- ⚠️ Cache invalidation on bet placement (write-through)
- ⚠️ Additional operational complexity

#### B. Session Storage (User Authentication)

**Pattern:** Redis as Primary Store

```redis
Key: session:{session_id}
Value: HASH {user_id, name, roles, ...}
TTL: 3600 seconds (1 hour)
```

**Benefits:**

- ✅ Fast session validation (< 1ms)
- ✅ Automatic TTL expiration
- ✅ Offload from PostgreSQL

#### C. Recent Bet Counts (Query 4)

**Pattern:** Redis Streams + Counters

```redis
Key: bet_count:{status}
Value: Counter (INCR/DECR on bet events)
Refresh: Real-time via event streaming
```

**Benefits:**

- ✅ Real-time counts (no refresh lag)
- ✅ < 0.5ms latency
- ✅ Handles 500 qpm easily

**Trade-offs:**

- ⚠️ Requires event-driven architecture
- ⚠️ Eventual consistency (lag < 100ms)

**When NOT to Use Redis:**

- ❌ Primary storage for financial data (use PostgreSQL)
- ❌ Complex queries with JOINs (not Redis strength)
- ❌ Data requiring strong consistency

---

### 3. Analytical Store (ClickHouse / TimescaleDB)

**When to Use:**

- Historical data analysis (years of data)
- Complex analytical queries (multi-dimensional aggregations)
- Time-series data
- Data warehouse/BI workloads
- Write-once, read-many patterns

**Proposed Use Cases:**

#### A. Daily Settlement Reports (Query 2)

**Current:** Materialized View in PostgreSQL (0.72ms)  
**Alternative:** Replicate to ClickHouse for historical analysis

**Benefits:**

- ✅ Query years of historical data efficiently
- ✅ Complex aggregations (GROUP BY multiple dimensions)
- ✅ Columnar storage = 10x compression
- ✅ Offload analytics from OLTP database

**Trade-offs:**

- ⚠️ Eventual consistency (minutes lag acceptable)
- ⚠️ Additional infrastructure
- ⚠️ Data replication complexity

#### B. User Betting Analytics (Query 3)

**Pattern:** Batch ETL (daily) to analytical store

```
PostgreSQL (OLTP) → CDC/ETL → ClickHouse (OLAP)
                                  ↓
                          Dashboards, BI tools
```

**Query Examples in ClickHouse:**

```sql
-- Monthly user cohort analysis
SELECT
    toStartOfMonth(placed_at) as month,
    user_id,
    COUNT(*) as bet_count,
    SUM(amount) as total_wagered
FROM bets
WHERE placed_at >= '2024-01-01'
GROUP BY month, user_id
ORDER BY total_wagered DESC;

-- Multi-dimensional analysis
SELECT
    DATE(placed_at) as date,
    status,
    event_category,
    COUNT(*) as count,
    AVG(amount) as avg_amount
FROM bets
JOIN events ON bets.event_id = events.id
GROUP BY date, status, event_category
WITH ROLLUP;
```

**When NOT to Use Analytical Store:**

- ❌ Real-time operational queries (< 100ms)
- ❌ Transactional workloads
- ❌ Small datasets (< 1TB)

---

## Data Model Fit Analysis

### PostgreSQL (Relational)

**Best Fit:**

- ✅ Normalized data with foreign keys (users, events, bets)
- ✅ Complex relationships and constraints
- ✅ ACID transactions

**Our Schema:**

```sql
users (id, name, created_at)
  ↓ 1:N
bets (id, user_id, event_id, status, amount, placed_at)
  ↓ N:1
events (id, name, start_time, status)
```

**Verdict:** Excellent fit ✅

### Redis (Key-Value / Data Structures)

**Best Fit:**

- ✅ Simple key-value pairs
- ✅ Counters and leaderboards (SORTED SETS)
- ✅ Session data (HASH)
- ✅ Real-time streams (STREAMS)

**Our Use Cases:**

```redis
session:{session_id} → HASH {user_id, name}
active_bets:cache → JSON (serialized query result)
bet_count:{status} → STRING (counter)
recent_bets → STREAM (event log)
```

**Verdict:** Good fit for caching and sessions ✅

### ClickHouse (Columnar Analytical)

**Best Fit:**

- ✅ Append-only/immutable data
- ✅ Time-series data (bets.placed_at)
- ✅ Wide tables with many columns
- ✅ Aggregation-heavy queries

**Our Schema (denormalized for analytics):**

```sql
CREATE TABLE bets_analytics (
    bet_id UInt64,
    user_id UInt64,
    user_name String,
    event_id UInt64,
    event_name String,
    event_category String,
    status Enum8('OPEN', 'SETTLED', 'CASHED_OUT', 'CANCELLED'),
    amount Decimal(12, 2),
    placed_at DateTime,
    settled_at Nullable(DateTime),
    -- Denormalized for fast queries
    INDEX idx_placed_at placed_at TYPE minmax GRANULARITY 3
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(placed_at)
ORDER BY (placed_at, user_id);
```

**Verdict:** Excellent fit for historical analytics ✅

---

## Latency Targets by Store

| Query Pattern                  | PostgreSQL | Redis    | ClickHouse   | Target Met |
| ------------------------------ | ---------- | -------- | ------------ | ---------- |
| Active Bets (real-time)        | 2.24ms ✅  | 0.5ms ✅ | N/A          | < 5ms ✅   |
| Daily Settlement (operational) | 0.72ms ✅  | N/A      | N/A          | < 5ms ✅   |
| User Activity (analytics)      | 2.71ms ✅  | N/A      | 50-200ms     | < 5ms ✅   |
| Recent Counts (monitoring)     | 0.45ms ✅  | 0.3ms ✅ | N/A          | < 5ms ✅   |
| Historical Analysis (BI)       | > 1s ⚠️    | N/A      | 100-500ms ✅ | < 1s ✅    |

---

## Operational Complexity Analysis

### Single Store (PostgreSQL Only) - Current State

**Complexity Score:** ⭐⭐ (Low)

**Pros:**

- ✅ Single source of truth
- ✅ No data synchronization
- ✅ Simple backup/restore
- ✅ Mature operational tools

**Cons:**

- ⚠️ All workloads compete for resources
- ⚠️ Scaling requires vertical or read replicas
- ⚠️ Analytics can impact OLTP performance

### Polyglot (PostgreSQL + Redis)

**Complexity Score:** ⭐⭐⭐ (Medium)

**Additional Operational Overhead:**

- Cache invalidation logic
- Redis cluster management (Sentinel/Cluster)
- Monitoring for cache hit rate
- Dual failure scenarios

**Mitigation:**

- Use managed Redis (ElastiCache, Redis Cloud)
- Implement circuit breakers (fail open to PostgreSQL)
- Monitor cache hit rate > 80%

### Polyglot (PostgreSQL + Redis + ClickHouse)

**Complexity Score:** ⭐⭐⭐⭐ (High)

**Additional Operational Overhead:**

- CDC/ETL pipeline management
- Data consistency verification
- Three different backup strategies
- Complex monitoring

**Mitigation:**

- Use managed ClickHouse (Aiven, ClickHouse Cloud)
- Automate ETL with Debezium or Airbyte
- Accept eventual consistency for analytics

---

## Recommendations by Scale

### Phase 1: Current (4M bets, < 100 qps)

**Stack:** PostgreSQL only ✅
**Rationale:**

- All queries < 5ms achieved with indexes + MVs
- Operational simplicity
- Cost-effective

**Status:** COMPLETE ✅

### Phase 2: Growth (40M bets, 100-1000 qps)

**Add:** Redis for caching
**Use Cases:**

- Cache Query 1 results (active bets)
- Session storage
- Real-time counters (Query 4)

**Expected Benefits:**

- 10x read capacity for hot queries
- < 1ms latency for cached queries
- Offload 70-90% reads from PostgreSQL

### Phase 3: Scale (400M+ bets, 1000+ qps)

**Add:** ClickHouse for analytics
**Use Cases:**

- Historical analytics (> 3 months old)
- Complex BI queries
- Data warehouse

**Expected Benefits:**

- Offload analytics from OLTP
- Query years of data efficiently
- Support business intelligence workload

---

## Consistency and Freshness Expectations

### Strong Consistency (PostgreSQL)

**Use Cases:**

- Bet placement and settlement
- User balances
- Event status updates

**Guarantee:** Immediate, linearizable reads after write
**Implementation:** PostgreSQL ACID transactions

### Eventual Consistency (Redis Cache)

**Use Cases:**

- Query result caching
- Session data

**Freshness SLA:**

- Active Bets: 5 seconds (TTL)
- Session: 1 hour (TTL)

**Implementation:**

- Cache-aside pattern with TTL
- Invalidate on write (write-through)

### Eventual Consistency (ClickHouse Analytics)

**Use Cases:**

- Historical reports
- BI dashboards

**Freshness SLA:**

- Daily reports: 1 hour lag
- Historical analysis: 24 hour lag

**Implementation:**

- CDC with Debezium
- Batch ETL (hourly/daily)

---

## Conclusion

**Current Recommendation:** Keep PostgreSQL as the only store for now.

**Rationale:**

- ✅ All latency targets met (< 5ms)
- ✅ Operational simplicity
- ✅ Strong consistency guarantees
- ✅ Cost-effective

**Future Additions:**

1. **Redis** when read QPS > 1000 or latency < 1ms required
2. **ClickHouse** when analytical queries span > 1TB data

**Decision Criteria:**

- Add Redis if: p95 latency > 5ms OR QPS > 1000
- Add ClickHouse if: Analytics queries > 1s OR data > 1TB

---

**Next Document:** See `polyglot-architecture.md` for detailed architecture proposal when scaling beyond PostgreSQL.
