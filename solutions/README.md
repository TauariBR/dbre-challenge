# Solutions - DBRE Challenge

**Author:** Tauari  
**Date:** 2025-10-31  
**Status:** Complete ✅

---

## Overview

This directory contains the complete solution for the DBRE Challenge, including optimizations for 4 underperforming PostgreSQL queries. All queries achieved the < 5ms target with 99%+ improvement.

**Results Summary:**

| Query | Baseline | Optimized | Improvement | Status      |
| ----- | -------- | --------- | ----------- | ----------- |
| Q1    | 1008 ms  | 2.24 ms   | 99.78%      | ✅ **PASS** |
| Q2    | 290 ms   | 0.72 ms   | 99.75%      | ✅ **PASS** |
| Q3    | 536 ms   | 2.71 ms   | 99.49%      | ✅ **PASS** |
| Q4    | 72 ms    | 0.45 ms   | 99.38%      | ✅ **PASS** |

---

## Repository Structure

```
solutions/tauari/
├── sql/
│   ├── query1_baseline_explain.txt       # Query 1 - BEFORE evidence
│   ├── query1_optimized_explain.txt      # Query 1 - AFTER evidence
│   ├── query1_optimized.sql              # Query 1 - Clean solution
│   ├── query2_baseline_explain.txt       # Query 2 - BEFORE evidence
│   ├── query2_optimized_explain.txt      # Query 2 - AFTER evidence
│   ├── query2_optimized.sql              # Query 2 - Clean solution
│   ├── query3_baseline_explain.txt       # Query 3 - BEFORE evidence
│   ├── query3_optimized_explain.txt      # Query 3 - AFTER evidence
│   ├── query3_optimized.sql              # Query 3 - Clean solution
│   ├── query4_baseline_explain.txt       # Query 4 - BEFORE evidence
│   ├── query4_optimized_explain.txt      # Query 4 - AFTER evidence
│   ├── query4_optimized.sql              # Query 4 - Clean solution
│   └── optimizations.sql                 # Complete setup script (all indexes + MVs)
├── docs/
│   ├── diagnosis.md                      # Detailed diagnosis of all 4 queries
│   └── results.md                        # Complete performance analysis and benchmarks
└── (future: architecture/ and automation/ for advanced requirements)
```

---

## Quick Start - Reproduce Results

### Prerequisites

- Docker and Docker Compose installed
- WSL2 (if on Windows) or Linux/macOS
- PostgreSQL client (`psql`) installed
- At least 8GB RAM and 10GB disk space

### Step 1: Setup Environment

```bash
# Clone the repository (or your fork)
cd /path/to/dbre-challenge

# Start PostgreSQL and pgAdmin
make up

# Seed the database with test data (4M bets, 800K events, 200K users)
make seed
```

**Note:** The seed process takes ~2-5 minutes depending on hardware.

### Step 2: Verify Baseline (Optional)

To see the original slow performance:

```bash
# Test Query 1 baseline (expect ~1000ms)
make explain QUERY=ops/scripts/query1.sql

# Or benchmark all 4 queries (see ops/Makefile for bench target)
```

### Step 3: Apply Optimizations

Connect to PostgreSQL and run the complete optimization script:

```bash
# Connect to database
PGPASSWORD=app psql -h localhost -U app -d app

# Run optimizations (creates indexes and Materialized Views)
\i solutions/tauari/sql/optimizations.sql

# Exit
\q
```

**What this does:**
1. Creates covering/partial indexes for Query 1
2. Creates HASH index on users for O(1) lookups
3. Creates Materialized Views for Queries 2, 3, and 4
4. Sets up indexes on Materialized Views
5. Runs VACUUM ANALYZE and CLUSTER

**Time required:** 3-5 minutes

### Step 4: Verify Optimizations

Run the optimized queries with benchmarks:

```bash
# Query 1 (10 runs)
for i in {1..10}; do
PGPASSWORD=app psql -h localhost -U app -d app -c "
SET work_mem = '256MB';
SET random_page_cost = 0.1;
SET seq_page_cost = 0.1;
SET cpu_tuple_cost = 0.0001;
SET cpu_index_tuple_cost = 0.00001;
SET cpu_operator_cost = 0.000001;
SET effective_io_concurrency = 200;
SET effective_cache_size = '4GB';
" -c "\timing on" -c "$(cat ops/scripts/query1.sql)" 2>&1 | grep "Time:"
done
```

**Expected result:** Average ~2.24ms (excluding first cold run)

```bash
# Query 2 (10 runs)
for i in {1..10}; do
PGPASSWORD=app psql -h localhost -U app -d app -c "
SET work_mem = '256MB';
SET random_page_cost = 0.1;
SET seq_page_cost = 0.1;
SET cpu_tuple_cost = 0.0001;
SET cpu_index_tuple_cost = 0.00001;
SET cpu_operator_cost = 0.000001;
SET effective_io_concurrency = 200;
SET effective_cache_size = '4GB';
" -c "\timing on" -c "SELECT * FROM mv_daily_settlement WHERE bet_date >= CURRENT_DATE - INTERVAL '1 day' AND bet_date < CURRENT_DATE ORDER BY status;" 2>&1 | grep "Time:"
done
```

**Expected result:** Average ~0.72ms

```bash
# Query 3 (10 runs)
for i in {1..10}; do
PGPASSWORD=app psql -h localhost -U app -d app -c "
SET work_mem = '256MB';
SET random_page_cost = 0.1;
SET seq_page_cost = 0.1;
SET cpu_tuple_cost = 0.0001;
SET cpu_index_tuple_cost = 0.00001;
SET cpu_operator_cost = 0.000001;
SET effective_io_concurrency = 200;
SET effective_cache_size = '4GB';
" -c "\timing on" -c "SELECT user_id, user_name, bet_count, total_wagered, avg_bet FROM mv_user_daily_activity WHERE bet_date >= CURRENT_DATE - INTERVAL '1 day' AND bet_date < CURRENT_DATE ORDER BY total_wagered DESC LIMIT 20;" 2>&1 | grep "Time:"
done
```

**Expected result:** Average ~2.71ms

```bash
# Query 4 (10 runs)
for i in {1..10}; do
PGPASSWORD=app psql -h localhost -U app -d app -c "
SET work_mem = '256MB';
SET random_page_cost = 0.1;
SET seq_page_cost = 0.1;
SET cpu_tuple_cost = 0.0001;
SET cpu_index_tuple_cost = 0.00001;
SET cpu_operator_cost = 0.000001;
SET effective_io_concurrency = 200;
SET effective_cache_size = '4GB';
" -c "\timing on" -c "SELECT status, count FROM mv_recent_bet_counts;" 2>&1 | grep "Time:"
done
```

**Expected result:** Average ~0.45ms

---

## Optimization Strategies Used

### Query 1: Active Bets for Upcoming Events
**Strategy:** Index-based optimization
- Covering partial index on `bets` (event_id, user_id, status, amount, id) WHERE status = 'OPEN'
- Covering index on `events` (start_time, id, name)
- HASH index on `users` (id) for O(1) lookups
- PostgreSQL config tuning (work_mem, page costs, cpu costs)

**Trade-offs:**
- ✅ 450x faster (1008ms → 2.24ms)
- ⚠️ 15-20% slower INSERTs/UPDATEs on bets
- ⚠️ ~200MB additional storage

### Query 2: Daily Settlement Report
**Strategy:** Materialized View
- Pre-aggregates daily settlements for 30-day window
- Index on (bet_date, status)

**Trade-offs:**
- ✅ 400x faster (290ms → 0.72ms)
- ⚠️ Requires daily REFRESH (~300ms)
- ⚠️ Data freshness up to 24 hours

### Query 3: User Betting Activity
**Strategy:** Materialized View
- Pre-aggregates user activity by day for 30-day window
- Index on (bet_date, user_id)

**Trade-offs:**
- ✅ 197x faster (536ms → 2.71ms)
- ⚠️ Requires daily REFRESH (~500ms)
- ⚠️ ~100MB storage for pre-aggregated data

### Query 4: Recent Bet Count by Status
**Strategy:** Materialized View with high refresh frequency
- Pre-aggregates bet counts by status for 2-hour window
- Unique index on status

**Trade-offs:**
- ✅ 160x faster (72ms → 0.45ms)
- ⚠️ Requires frequent REFRESH (every 5-10 minutes)
- ⚠️ Data freshness up to 10 minutes

---

## Maintenance Requirements

### Daily Maintenance
```sql
-- Refresh Materialized Views for Queries 2 and 3
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_settlement;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_user_daily_activity;
```

### Frequent Maintenance (every 5-10 minutes)
```sql
-- Refresh Materialized View for Query 4
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_recent_bet_counts;
```

### Weekly Maintenance
```sql
-- Update statistics and clean up
VACUUM ANALYZE bets;
VACUUM ANALYZE events;
VACUUM ANALYZE users;

-- Monitor index bloat and reindex if necessary
REINDEX TABLE CONCURRENTLY bets;
```

---

## Key Findings

1. **Query 1** was bottlenecked by Parallel Seq Scans on 3 large tables (4M, 800K, 200K rows). Covering indexes and HASH index eliminated table lookups.

2. **Queries 2, 3, and 4** were CPU-bound by heavy aggregations (GROUP BY, COUNT, SUM, AVG) on hundreds of thousands of rows. Materialized Views pre-compute results.

3. **PostgreSQL configuration tuning** (work_mem, page costs, cpu costs) was critical for Query 1 to prefer index scans over sequential scans.

4. All optimizations maintain ACID properties and use `CONCURRENTLY` options to avoid blocking writes.

---

## Testing Environment

- **PostgreSQL:** 16.10 (Docker)
- **OS:** WSL2 Ubuntu 22.04 / Windows 10
- **Hardware:** SSD storage, 8GB+ RAM
- **Dataset:** 10x production scale
  - 200,000 users
  - 800,000 events
  - 4,000,000 bets

---

## Documentation

- **`docs/diagnosis.md`**: Detailed diagnosis of all 4 queries with execution plans, problems identified, and optimization hypotheses.
- **`docs/results.md`**: Complete performance analysis with before/after metrics, benchmarks, trade-offs, and methodology.
- **`sql/query*_optimized.sql`**: Clean, commented versions of optimized queries for easy review.
- **`sql/optimizations.sql`**: Single reproducible script with all indexes, MVs, and configuration.

---

## Clean Up

To stop and remove all containers:

```bash
make down
```

---

## Author Notes

All optimizations were done within the constraints of the challenge:
- No modifications to `ops/` directory
- Schema adjustments documented and justified
- All benchmarks run consistently with same configuration
- Trade-offs explicitly documented

For questions or clarifications, please review the commit history showing the iterative optimization process.

**Total time invested:** ~6 hours (diagnosis, optimization, testing, documentation)
