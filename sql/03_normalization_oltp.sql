-- ================================================================
-- Script: 	03_normalization_oltp.sql
-- Purpose: 3NF normalization and building the OLTP tables with PK/FK constraints
-- ================================================================

-- IMPORTANT EXECUTION NOTICE: 
-- This script must be executed strictly in sequential order (block by block). 
-- The schema generation relies on a precise execution chain: 
-- 1) Create Table -> 2) Define Primary Key (PK) -> 3) Define Foreign Keys (FK) -> [Repeat for the next table].
-- Skipping a block, missing a constraint, or executing out of order will cause 
-- dependency errors (e.g., attempting to reference a missing PK) and break the schema.
--
-- IDE TIP: It is highly recommended to use the "Execute Script" command (Alt+X in DBeaver, 
-- or the equivalent shortcut in your SQL client) to run the entire file sequentially 
-- top-to-bottom. Avoid executing statements manually one by one (e.g., using Ctrl+Enter), 
-- as human error may lead to accidentally skipping a crucial constraint block.

-- NOTE: This script implements the data cleaning and transformation rules 
-- derived from the exploration phase (02_data_quality_checks.sql). 
-- For full context and justification of these rules, please refer to 
-- that script or the 'findings.md' document.
--
-- The 3NF normalization process creates 4 distinct OLTP tables:
-- 'customers', 'products', 'orders', and 'order_items'.
-- The complete ER-diagram is available in the README.md (Architecture section).

-- 3.1 
-- Create the 'customers' table and constraints

-- Step A: Create the base table:

CREATE TABLE oltp.customers AS
SELECT DISTINCT
    CAST(NULLIF(NULLIF(NULLIF(pled."Customer ID", '\N'), ''), '#N/A') AS BIGINT) AS customer_id,
    TO_DATE(NULLIF(NULLIF(NULLIF(pled."Customer Since", '\N'), ''), '#N/A'), 'YYYY-MM') AS customer_since
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND NULLIF(NULLIF(NULLIF(pled."Customer ID", '\N'), ''), '#N/A') IS NOT NULL
  AND pled."Customer ID" NOT IN ('116', '11019', '30508', '35173', '44300')
  AND EXISTS (
      SELECT 1 FROM staging.pakistan_largest_ecommerce_dataset pled2
      WHERE pled2.increment_id = pled.increment_id
        AND pled2.item_id IS NOT NULL AND pled2.item_id != ''
        AND (pled2.sku NOT ILIKE '%test%' 
             OR pled2.sku IN ('SKMT_Blood Test', 'Aladdin_Test Star Cricket Ball - Red & White', 'sst_Vous Deteste-Regular fit-Medium'))
  );

-- Step B: Define Primary Key (PK):

ALTER TABLE oltp.customers ADD PRIMARY KEY (customer_id);

-- 3.2 
-- Create the 'products' table and constraints

-- Step A: Create the base table:

CREATE TABLE oltp.products AS
WITH cat_counts AS (
  SELECT pled.sku, NULLIF(NULLIF(pled.category_name_1, '\N'), '') AS cat, COUNT(*) AS cnt
  FROM staging.pakistan_largest_ecommerce_dataset pled
  WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
    AND pled.sku IS NOT NULL AND pled.sku != ''
    AND (
      pled.sku NOT ILIKE '%test%' 
      OR pled.sku IN (
        'SKMT_Blood Test', 'Aladdin_Test Star Cricket Ball - Red & White', 'sst_Vous Deteste-Regular fit-Medium')
      )
  GROUP BY pled.sku, NULLIF(NULLIF(pled.category_name_1, '\N'), '')
),
final_products AS (
  SELECT DISTINCT ON (sku) sku, cat AS category_name_1
  FROM cat_counts
  ORDER BY sku, (cat IS NOT NULL) DESC, cnt DESC
)
SELECT
    CAST(sku AS VARCHAR(100)) AS sku,
    CAST(category_name_1 AS VARCHAR(50)) AS category_name
FROM final_products;

-- Step B: Define Primary Key (PK):

ALTER TABLE oltp.products ADD PRIMARY KEY (sku);

-- 3.3 
-- Create the 'orders' table and constraints

-- Step A: Create the base table:

CREATE TABLE oltp.orders AS
SELECT DISTINCT
    CAST(pled.increment_id AS VARCHAR(50)) AS increment_id,
    CAST(NULLIF(NULLIF(NULLIF(pled."Customer ID", '\N'), ''), '#N/A') AS BIGINT) AS customer_id,
    TO_DATE(pled.created_at, 'MM/DD/YYYY') AS order_date,
    CAST(pled.payment_method AS VARCHAR(50)) AS payment_method,
    CAST(NULLIF(pled.status, '\N') AS VARCHAR(20)) AS status,
    CAST(pled.grand_total AS NUMERIC) AS grand_total
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND pled."Customer ID" NOT IN ('116', '11019', '30508', '35173', '44300')
  AND EXISTS (
      SELECT 1 FROM staging.pakistan_largest_ecommerce_dataset pled2
      WHERE pled2.increment_id = pled.increment_id
        AND pled2.item_id IS NOT NULL AND pled2.item_id != ''
        AND (pled2.sku NOT ILIKE '%test%' 
             OR pled2.sku IN ('SKMT_Blood Test', 'Aladdin_Test Star Cricket Ball - Red & White', 'sst_Vous Deteste-Regular fit-Medium'))
  );

-- Step B: Define Primary Key and Foreign Key (PK/FK):

ALTER TABLE oltp.orders ADD PRIMARY KEY (increment_id);
ALTER TABLE oltp.orders ADD FOREIGN KEY (customer_id) REFERENCES oltp.customers(customer_id);

-- 3.4 
-- Create the 'order_items' table and constraints

-- Step A: Create the base table:

CREATE TABLE oltp.order_items AS
WITH cat_counts AS (
  SELECT pled.sku, NULLIF(NULLIF(pled.category_name_1, '\N'), '') AS cat, COUNT(*) AS cnt
  FROM staging.pakistan_largest_ecommerce_dataset pled
  WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
    AND pled.sku IS NOT NULL AND pled.sku != ''
    AND (pled.sku NOT ILIKE '%test%' 
         OR pled.sku IN ('SKMT_Blood Test', 'Aladdin_Test Star Cricket Ball - Red & White', 'sst_Vous Deteste-Regular fit-Medium'))
  GROUP BY pled.sku, NULLIF(NULLIF(pled.category_name_1, '\N'), '')
),
final_products AS (
  SELECT DISTINCT ON (sku) sku, cat AS category_name_1
  FROM cat_counts
  ORDER BY sku, (cat IS NOT NULL) DESC, cnt DESC
)
SELECT
    CAST(pled.item_id AS BIGINT) AS item_id,
    CAST(pled.increment_id AS VARCHAR(50)) AS increment_id,
    CAST(fp.sku AS VARCHAR(100)) AS sku,
    CAST(pled.price AS NUMERIC) AS price,
    CAST(pled.qty_ordered AS INTEGER) AS qty_ordered,
    ABS(CAST(pled.discount_amount AS NUMERIC)) AS discount_amount,
    CAST(pled.price AS NUMERIC) * CAST(pled.qty_ordered AS INTEGER) AS gross_value
FROM staging.pakistan_largest_ecommerce_dataset pled
LEFT JOIN final_products fp ON NULLIF(pled.sku, '') = fp.sku
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND (pled.sku NOT ILIKE '%test%' 
       OR pled.sku IN ('SKMT_Blood Test', 'Aladdin_Test Star Cricket Ball - Red & White', 'sst_Vous Deteste-Regular fit-Medium'))
  AND EXISTS (SELECT 1 FROM oltp.orders o WHERE o.increment_id = pled.increment_id);

-- Step B: Define Primary Key and Foreign Keys (PK/FK):

ALTER TABLE oltp.order_items ADD PRIMARY KEY (item_id);
ALTER TABLE oltp.order_items ADD FOREIGN KEY (increment_id) REFERENCES oltp.orders(increment_id);
ALTER TABLE oltp.order_items ADD FOREIGN KEY (sku) REFERENCES oltp.products(sku);

-- 3.5 
-- Post-Migration Validation: Sanity-check row counts against Stage 1 findings

-- Step A: Validate row counts for all newly created OLTP tables:

SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM oltp.customers
UNION ALL
SELECT 'products', COUNT(*) AS row_count FROM oltp.products
UNION ALL
SELECT 'orders', COUNT(*) AS row_count FROM oltp.orders
UNION ALL
SELECT 'order_items', COUNT(*) AS row_count FROM oltp.order_items;

-- Result: customers = 115,253; products = 84,864; orders = 407,141; order_items = 582,704.
-- Conclusion: The 'customers' and 'products' row counts match the expected totals exactly. 
-- However, there is a discrepancy in the 'orders' count. The baseline projection was 
-- 408,539 (calculated as: 408,782 total - 42 service account orders - 201 orders from 
-- fully-test customers), but the actual inserted count is 407,141.

-- Step B: Investigate the 'orders' discrepancy (verify isolated test-only orders):

WITH test_only_orders AS (
    SELECT pled.increment_id
    FROM staging.pakistan_largest_ecommerce_dataset pled
    WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
    GROUP BY pled.increment_id
    HAVING COUNT(*) FILTER (
        WHERE pled.sku NOT ILIKE '%test%' 
            OR pled.sku IN ('SKMT_Blood Test', 'Aladdin_Test Star Cricket Ball - Red & White', 'sst_Vous Deteste-Regular fit-Medium')
    ) = 0
)
SELECT COUNT(*) AS total_test_only_orders 
FROM test_only_orders;

-- Result: 1,599 orders are comprised entirely of test-related SKUs.
-- Conclusion: This population includes the 201 orders tied to the 68 fully-test customers 
-- (identified in Section 2.12), plus 1,398 isolated test orders placed by otherwise normal 
-- customers. The difference exactly resolves the discrepancy (408,539 - 1,398 = 407,141). 
-- No code changes are required: the EXISTS clause correctly filters these out, confirming 
-- that the ETL pipeline logic behaves exactly as intended.

-- Step C: Investigate the 'order_items' discrepancy (validate missing items)

SELECT COUNT(*) AS service_account_items
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND pled."Customer ID" IN ('116', '11019', '30508', '35173', '44300');

-- Result: 43 rows. The baseline projection for 'order_items' was 582,747 
-- (584,524 total staging rows - 1,777 test SKUs), while the actual inserted 
-- count is 582,704 - a gap of exactly 43 rows, fully resolved by this query.
-- Conclusion: These are genuine (non-test) item rows correctly dropped because 
-- their parent service-account orders (Section 7) are excluded from oltp.orders, 
-- removed via the EXISTS cascade rather than the SKU filter. This confirms full 
-- row-count reconciliation across all four OLTP tables.