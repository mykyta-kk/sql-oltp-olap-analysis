-- ================================================================
-- Script: 	04_indexes_oltp.sql
-- Purpose: Creating indexes for the OLTP schema
-- ================================================================

-- 4.1
-- Baseline Benchmark: customer order-lookup query BEFORE indexes:

EXPLAIN (ANALYZE, BUFFERS)
SELECT o.increment_id, o.order_date, oi.sku, oi.price, oi.qty_ordered
FROM oltp.orders o
JOIN oltp.order_items oi ON o.increment_id = oi.increment_id
WHERE o.customer_id = 1474;

-- Result: Execution Time: 106.459 ms, Parallel Seq Scan, Rows Removed by Filter: 135701, Workers Launched: 2.

-- 4.2
-- Create indexes:

CREATE INDEX idx_orders_customer_date ON oltp.orders(customer_id, order_date);
CREATE INDEX idx_orders_order_date ON oltp.orders(order_date);
CREATE INDEX idx_order_items_increment_id ON oltp.order_items(increment_id);
CREATE INDEX idx_order_items_sku ON oltp.order_items(sku);

-- 4.3
-- Post-Index Benchmark: re-run the identical query AFTER indexes

EXPLAIN (ANALYZE, BUFFERS)
SELECT o.increment_id, o.order_date, oi.sku, oi.price, oi.qty_ordered
FROM oltp.orders o
JOIN oltp.order_items oi ON o.increment_id = oi.increment_id
WHERE o.customer_id = 1474;

-- Result: Execution Time: 2.206 ms, Nested Loop with Index Scan on both tables,
-- no Rows Removed by Filter, no parallel workers used.
--
-- Analysis: Execution time dropped from 106.459 ms to 2.206 ms (~98% reduction, 
-- ~48x faster). Buffer accesses dropped from 10,632 to 179 pages (~59x fewer). 
-- The plan changed from Parallel Hash Join (Parallel Seq Scan on both tables, 
-- 2 workers launched, 135,701 rows read and discarded by the filter) to Nested 
-- Loop (Index Scan on both tables via idx_orders_customer_date and 
-- idx_order_items_increment_id, zero wasted rows, no parallelism required).
--
-- Minor trade-off: Planning Time increased from 0.704 ms to 3.443 ms (negligible 
-- next to the execution-time savings).