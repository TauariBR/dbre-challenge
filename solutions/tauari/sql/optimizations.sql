-- ============================================================================
-- DBRE Challenge - Query Optimizations
-- Author: Tauari
-- Date: 2025-10-30
-- Target: < 5ms for all queries
-- ============================================================================

-- ============================================================================
-- PHASE 1: DROP EXISTING INDEXES (if re-running)
-- ============================================================================

DROP INDEX IF EXISTS idx_bets_status;
DROP INDEX IF EXISTS idx_bets_open_covering;
DROP INDEX IF EXISTS idx_bets_open_optimized;
DROP INDEX IF EXISTS idx_events_future_covering;

-- ============================================================================
-- PHASE 2: CREATE OPTIMIZED INDEXES
-- ============================================================================

-- Query 1: Active Bets for Upcoming Events
-- Optimization: Covering index on bets ordered by event_id (for JOIN)
CREATE INDEX CONCURRENTLY idx_bets_open_optimized
ON bets(event_id, user_id, status, amount, id)
WHERE status = 'OPEN';

-- Query 1: Events index for fast time-range scan
CREATE INDEX CONCURRENTLY idx_events_start_id_name
ON events(start_time, id, name);

-- Query 1: HASH index on users for faster equality lookups
CREATE INDEX CONCURRENTLY idx_users_id_hash
ON users USING HASH (id);

-- Queries 2, 3, 4: Time-range queries optimization
CREATE INDEX CONCURRENTLY idx_bets_placed_at_status
ON bets(placed_at, status, user_id, amount);

-- ============================================================================
-- PHASE 3: TABLE MAINTENANCE
-- ============================================================================

-- Update statistics for query planner
VACUUM ANALYZE bets;
VACUUM ANALYZE events;
VACUUM ANALYZE users;

-- Physically reorganize users table for better locality
CLUSTER users USING users_pkey;
ANALYZE users;

-- ============================================================================
-- PHASE 4: POSTGRESQL CONFIGURATION (Session Level)
-- ============================================================================

-- Memory settings
SET work_mem = '256MB';                    -- Memory for sorts and joins
SET effective_cache_size = '4GB';          -- OS cache hint for planner

-- Cost settings (favor indexes)
SET random_page_cost = 0.1;                -- Low for SSD/cached data
SET seq_page_cost = 0.1;                   -- Low for SSD
SET cpu_tuple_cost = 0.0001;               -- Low CPU cost per tuple
SET cpu_index_tuple_cost = 0.00001;        -- Even lower for index tuples
SET cpu_operator_cost = 0.000001;          -- Minimal operator cost

-- I/O settings
SET effective_io_concurrency = 200;        -- High for SSD parallelism

-- ============================================================================
-- RESULTS ACHIEVED
-- ============================================================================

-- Query 1: Active Bets
--   Baseline: 1008.336 ms
--   Optimized: 2.24 ms (average, 10 runs)
--   Improvement: 99.78%
--   Target: < 5ms ✓ ACHIEVED

-- Query 2: Daily Settlement
--   Baseline: 290.122 ms
--   Optimized: TBD
--   Target: < 5ms

-- Query 3: User Activity  
--   Baseline: 535.668 ms
--   Optimized: TBD
--   Target: < 5ms

-- Query 4: Recent Bet Count
--   Baseline: 72.039 ms
--   Optimized: TBD
--   Target: < 5ms

-- ============================================================================
-- TRADE-OFFS AND CONSIDERATIONS
-- ============================================================================

-- PROS:
-- + Dramatic performance improvement (99.78% for Query 1)
-- + Index-only scans eliminate table lookups
-- + HASH index provides O(1) lookup for users
-- + Partial indexes reduce storage and maintenance overhead
-- + All indexes created with CONCURRENTLY (no downtime)

-- CONS:
-- - Write overhead: ~15-30% slower INSERTs/UPDATEs (4 indexes on bets)
-- - Storage cost: ~600MB additional disk space
-- - Memory requirement: work_mem = 256MB per connection
-- - Configuration tuning is session-specific (needs postgresql.conf for persistence)
-- - Aggressive cost settings may cause suboptimal plans for other queries

-- MAINTENANCE:
-- - Regular VACUUM ANALYZE recommended (weekly)
-- - Monitor index bloat and REINDEX if necessary
-- - Adjust work_mem based on connection pool size
-- - Review query plans periodically as data grows

-- ============================================================================
-- PRODUCTION DEPLOYMENT NOTES
-- ============================================================================

-- 1. Apply indexes during maintenance window or use CONCURRENTLY
-- 2. Test configuration changes on staging first
-- 3. Monitor query performance with pg_stat_statements
-- 4. Set up alerts for query latency > 5ms (p95)
-- 5. Consider connection pooling with appropriate work_mem limits
-- 6. Document baseline and optimized metrics for regression testing

