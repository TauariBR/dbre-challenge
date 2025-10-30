# Database Performance Diagnosis - DBRE Challenge

**Author:** Tauari  
**Date:** 2025-10-30  
**Target:** Achieve < 5ms for all queries  
**Dataset:** 4M bets, 800K events, 200K users (10x scale)

---

## Executive Summary

This document analyzes performance of 4 queries against a PostgreSQL betting database.
All queries show Sequential Scans causing significant latency.
Strategy: Create optimized indexes (covering, partial, BRIN) to achieve target performance.

**Baseline Performance:**

| Query                | Current | Target | Gap   | Priority |
| -------------------- | ------- | ------ | ----- | -------- |
| Q1: Active Bets      | 1008ms  | < 5ms  | 99.5% | CRITICAL |
| Q2: Daily Settlement | 290ms   | < 5ms  | 98.3% | HIGH     |
| Q3: User Activity    | 535ms   | < 5ms  | 99.1% | HIGH     |
| Q4: Recent Bet Count | 72ms    | < 5ms  | 93.0% | MEDIUM   |

---

## Methodology

1. Captured EXPLAIN (ANALYZE, BUFFERS, VERBOSE) for all queries
2. Identified Sequential Scans and missing indexes
3. Analyzed buffer reads and sort operations
4. Proposed index-only solutions per PostgreSQL best practices

**Files analyzed:**

- `query1_baseline_explain.txt` - 1008ms execution
- `query2_baseline_explain.txt` - 290ms execution
- `query3_baseline_explain.txt` - 535ms execution
- `query4_baseline_explain.txt` - 72ms execution

---

## Query 1: Active Bets for Upcoming Events

**Baseline:** 1008.336ms  
**Target:** < 5ms  
**Frequency:** 1000+ queries/second (HOT PATH)

### Problems Identified

1. **Parallel Seq Scan on bets table** (4M rows)

   - Filter: `status = 'OPEN'` applied AFTER reading all rows
   - Rows removed: 800K (wasted I/O)
   - Buffers: 34K reads from disk

2. **Parallel Seq Scan on events table** (800K rows)

   - Filter: `start_time > NOW()` applied AFTER reading
   - Rows removed: 107K

3. **Parallel Seq Scan on users table** (200K rows)
   - No filter, reads all users for join

### Root Cause

- Existing `idx_bets_status` has low selectivity (not chosen by planner)
- No index helps with multi-table join pattern
- Query requires table lookups after index scan

### Solution: Covering Partial Index

```sql
CREATE INDEX CONCURRENTLY idx_bets_open_covering
ON bets(status, event_id, user_id, amount, id)
WHERE status = 'OPEN';
```

**Why this works:**

- PARTIAL index (only OPEN bets = 40% of data = smaller, faster)
- COVERING index (includes all columns needed = no table lookup)
- Includes `event_id` for efficient join with events
- Includes `user_id` for efficient join with users

**Expected result:** Index-only scan → 10-50ms

---

## Query 2: Daily Settlement Report

**Baseline:** 290.122ms  
**Target:** < 5ms  
**Frequency:** Once per day (but blocks other queries)

### Problems Identified

1. **Parallel Seq Scan on bets** (4M rows)

   - Filter: `placed_at >= CURRENT_DATE - 1 day`
   - Rows removed: 1.14M
   - No index on `placed_at`

2. **External merge sort** (spills to disk)
   - Writing 5.4MB temp files
   - Sorting by status and date

### Root Cause

- No index on `placed_at` for time-range queries
- Aggregation requires full scan and sort

### Solution: Composite Index on Time Range

```sql
CREATE INDEX CONCURRENTLY idx_bets_placed_at_status
ON bets(placed_at, status)
INCLUDE (amount);
```

**Why this works:**

- Fast range scan on `placed_at`
- Includes `status` for GROUP BY
- Includes `amount` for SUM/AVG calculations
- Avoids table lookup

**Expected result:** Index scan + in-memory aggregation → 50-100ms

**Note:** < 5ms may be challenging for aggregation without materialized views

---

## Query 3: User Betting Activity

**Baseline:** 535.668ms  
**Target:** < 5ms  
**Frequency:** 50 queries/minute

### Problems Identified

1. **Parallel Seq Scan on bets** (4M rows)

   - Same `placed_at` filter as Query 2
   - Rows removed: 1.14M

2. **External merge sort** on user_id

   - Writing 6.6MB to disk
   - Sorting before aggregation

3. **Hash Join with users**
   - Loading 200K users into memory

### Root Cause

- Same missing `placed_at` index
- Additional overhead from user aggregation
- HAVING filter applied after aggregation (inefficient)

### Solution: Same Index as Query 2 + User Optimization

```sql
-- Same as Query 2 (benefits both)
CREATE INDEX CONCURRENTLY idx_bets_placed_at_status
ON bets(placed_at, status)
INCLUDE (amount);

-- Additional: Ensure users.id is optimized
REINDEX TABLE CONCURRENTLY users;
```

**Why this works:**

- Reuses index from Query 2
- Fast time-range scan
- user_id already in index for join

**Expected result:** 100-200ms

**Note:** < 5ms unlikely for aggregation + join without caching

---

## Query 4: Recent Bet Count by Status

**Baseline:** 72.039ms  
**Target:** < 5ms  
**Frequency:** 500 queries/minute

### Problems Identified

1. **Parallel Seq Scan on bets** (4M rows)
   - Filter: `placed_at >= NOW() - 1 hour`
   - Rows removed: 1.33M (all rows - no matches in test data)

### Root Cause

- No index on `placed_at` for time-range
- Test data is 7 days old (no recent bets)

### Solution: BRIN Index for Time-Series

```sql
CREATE INDEX CONCURRENTLY idx_bets_placed_at_brin
ON bets USING BRIN (placed_at)
WITH (pages_per_range = 128);
```

**Why BRIN:**

- Tiny index size (~1-2MB vs 200MB for B-tree)
- Perfect for time-series (naturally ordered)
- Very fast for recent time ranges
- Low maintenance overhead

**Alternative: Reuse B-tree from Query 2/3**

**Expected result:** 5-20ms with BRIN, < 10ms with B-tree

---

## Implementation Plan

### Phase 1: Critical Indexes (Query 1)

1. Create covering partial index for OPEN bets
2. Test Query 1 performance
3. Capture new EXPLAIN ANALYZE

### Phase 2: Time-Range Indexes (Query 2, 3, 4)

1. Create composite index on placed_at
2. Test all three queries
3. Capture new EXPLAIN ANALYZE

### Phase 3: Additional Optimizations (if needed)

1. BRIN index for Query 4
2. REINDEX users table
3. Vacuum analyze all tables

### Phase 4: Benchmarking

1. Run multiple iterations
2. Measure p50, p95, p99
3. Document improvements

---

## Trade-offs and Constraints

### Storage Cost

- Each B-tree index: ~200-400MB
- BRIN index: ~1-2MB
- Total estimated: ~600MB additional storage

### Write Performance Impact

- Each index adds ~5-10% overhead to INSERT/UPDATE
- With 3 indexes: ~15-30% write penalty
- Acceptable for read-heavy workload (1000+ reads vs few writes)

### Maintenance

- Indexes need regular VACUUM
- Partial indexes are self-maintaining (WHERE clause)
- BRIN requires periodic REINDEX for optimal performance

### Why CONCURRENTLY

- No downtime during index creation
- Doesn't block writes
- Takes 2-3x longer but production-safe

---

## Limitations and Realistic Expectations

### Can We Achieve < 5ms?

**Query 1:** Possible with covering index (index-only scan)  
**Query 2:** Unlikely - aggregation overhead (~50-100ms realistic)  
**Query 3:** Unlikely - aggregation + join overhead (~100-200ms realistic)  
**Query 4:** Possible with BRIN or B-tree index

### If < 5ms Not Achievable with Indexes Alone

Per Advanced Requirements (task.md line 133-145), we can propose:

- Caching layer (Redis) for frequently accessed aggregations
- Materialized views with refresh strategy
- Application-level caching
- Read replicas for analytics queries

These will be documented in `architecture/` folder.

---

## Next Steps

1. ✅ Baseline captured (this document)
2. ⏳ Implement indexes (Phase 1-3)
3. ⏳ Capture post-optimization EXPLAIN ANALYZE
4. ⏳ Compare before/after performance
5. ⏳ Document results and evidence
