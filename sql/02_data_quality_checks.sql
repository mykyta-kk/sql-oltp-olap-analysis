-- ================================================================
-- Script: 	02_data_quality_checks.sql
-- Purpose: Perform data quality checks and identify anomalies in the raw data.
-- ================================================================

-- NOTE: Since the data was imported into TEXT columns (see script 01), missing values 
-- were loaded as empty strings ('') or literal '\N' (a common MySQL export artifact) 
-- instead of true SQL NULLs. A third pattern, '#N/A' (an Excel-style artifact), was also
-- found, but is narrowly confined to Customer ID / Customer Since (see 2.10) - unlike
-- '' and '\N', which appear broadly across many columns.
-- To ensure accurate checks, the following logic is used:
-- 1. WHERE [column_name] IS NOT NULL AND [column_name] != ''
-- 2. NULLIF(NULLIF(NULLIF([column_name], '\N'), ''), '#N/A')
--
-- A fourth, distinct convention appears in the ' MV ' column: '-' is used as a
-- placeholder for ZERO, not for NULL/missing. This is column-specific (see 2.11)
-- and should not be confused with the fake-NULL patterns above.

-- 2.1
-- Verify the actual number of populated rows:

-- Approach 1: filter using WHERE clause:

SELECT COUNT(*) AS total_rows, COUNT(pled.item_id) AS non_empty_rows 
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != '';

-- Approach 2: optimized query (shows both total and valid row counts in a single pass):

SELECT 
    COUNT(*) AS total_rows, 
    COUNT(NULLIF(pled.item_id, '')) AS non_empty_rows 
FROM staging.pakistan_largest_ecommerce_dataset pled;

-- Result: 
-- Approach 1 returns 584,524 for both columns because the WHERE clause filters out empty rows before counting.
-- Approach 2 reveals the full picture: 1,048,575 total rows in the raw file (likely padded Excel blanks), 
-- while accurately isolating the true number of non-empty records.
-- Conclusion: The actual number of valid records in the dataset is 584,524.

-- 2.2
-- Check for duplicate item records (Verify uniqueness of item_id):

SELECT pled.item_id, COUNT(*) 
FROM staging.pakistan_largest_ecommerce_dataset pled 
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
GROUP BY item_id 
HAVING COUNT(*) > 1;

-- Result: The query returns 0 rows, indicating no duplicate values were found.
-- Conclusion: All 'item_id' values among the valid records are strictly unique. 
-- This column can safely serve as a Primary Key for the dataset.

-- 2.3
-- Verify the consistency of 'Customer Since' dates per customer:

SELECT pled."Customer ID", COUNT(distinct pled."Customer Since" ) AS variants
FROM staging.pakistan_largest_ecommerce_dataset pled 
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
GROUP BY pled."Customer ID"  
HAVING COUNT(DISTINCT pled."Customer Since" ) > 1;

-- Result: The query returns 0 rows, meaning no customer has conflicting sign-up dates.
-- Conclusion: Each 'Customer ID' is consistently mapped to a single 'Customer Since' value.

-- 2.4
-- Check for sku category consistency (category_name_1).

-- Step A: Check if a single SKU is mapped to multiple categories:

SELECT pled.sku, COUNT(DISTINCT pled.category_name_1) AS variants
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
GROUP BY pled.sku
HAVING COUNT(DISTINCT pled.category_name_1) > 1;

-- Result: 27+ SKUs have conflicting categories.

-- Step B: Investigate a specific conflict to determine if it is a genuine data mismatch:

SELECT pled.sku, pled.category_name_1, COUNT(*)
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.sku = 'Huawei_P9Lite-Black'
GROUP BY pled.sku, pled.category_name_1;

-- Result: 'Mobiles & Tablets' (1) vs '\N' (88). This is not a true conflict, 
-- but rather a textual NULL artifact from the MySQL export.

-- Step C: Count the total number of fake '\N' NULLs in the category column:

SELECT COUNT(*) FILTER (WHERE pled.category_name_1 = '\N') AS fake_null
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != '';

-- Result: 7,850 rows contain the fake '\N' value.

-- Step D: Re-evaluate sku conflicts by excluding fake '\N', NULLs and empty strings:

SELECT pled.sku, COUNT(DISTINCT NULLIF(NULLIF(pled.category_name_1, '\N'), '')) AS real_variants
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
GROUP BY pled.sku
HAVING COUNT(DISTINCT NULLIF(NULLIF(pled.category_name_1, '\N'), '')) > 1;

-- Result: Only 2 SKUs (AJ-ajrak_AJA-005-Large/Medium) have real conflicts, 
-- likely due to unisex clothing spanning both Men's and Women's Fashion.
-- Conclusion: We will resolve category mappings using a majority rule 
-- (the most frequent non-empty category per SKU).

-- Step E: Generate a mapping list displaying each SKU with its most frequently used category:

WITH cat_counts AS (
  SELECT pled.sku, NULLIF(NULLIF(pled.category_name_1, '\N'), '') AS cat, COUNT(*) AS cnt
  FROM staging.pakistan_largest_ecommerce_dataset pled
  WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
    AND pled.sku IS NOT NULL AND pled.sku != ''
  GROUP BY pled.sku, NULLIF(NULLIF(pled.category_name_1, '\N'), '')
)
SELECT DISTINCT ON (sku) sku, cat AS category_name_1
FROM cat_counts
ORDER BY sku, (cat IS NOT NULL) DESC, cnt DESC;

-- Result: The query successfully outputs the full list of SKUs alongside 
-- their most frequent valid 'category_name_1'.

-- Step F: Check for missing (empty string) SKU where 'item_id' is present:

SELECT COUNT(*) 
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.sku = '' AND pled.item_id IS NOT NULL AND pled.item_id != '';

-- Result: 20 rows found (0.003% of 584,524) - below the materiality threshold.
-- Conclusion: No further investigation needed. Rule for Stage 2 (Normalization): 
-- Apply NULLIF(sku, '') when creating the 'order_items' table to ensure empty 
-- strings become true NULLs, preventing broken foreign key references to 'products'.

-- Step G: Control check. Count the total number of unique SKUs in the raw data:

SELECT COUNT(DISTINCT pled.sku) 
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.sku IS NOT NULL AND pled.sku != '';

-- Result: 84,889 unique SKUs.

-- Step H: Final validation to ensure no SKUs are lost or duplicated by the mapping logic:

WITH cat_counts AS (
  SELECT pled.sku, NULLIF(NULLIF(pled.category_name_1, '\N'), '') AS cat, COUNT(*) AS cnt
  FROM staging.pakistan_largest_ecommerce_dataset pled
  WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
    AND pled.sku IS NOT NULL AND pled.sku != ''
  GROUP BY pled.sku, NULLIF(NULLIF(pled.category_name_1, '\N'), '')
),
final_products AS (
  SELECT DISTINCT ON (sku) sku, cat AS category_name_1
  FROM cat_counts
  ORDER BY sku, (cat IS NOT NULL) DESC, cnt DESC
)
SELECT COUNT(*) FROM final_products;

-- Result: 84,889 rows returned.
-- Conclusion: The numbers match exactly - no SKUs are lost or duplicated 
-- during the category mapping process. The 'final_products' CTE is validated 
-- and ready to serve as the basis for CREATE TABLE oltp.products.

-- Step I: Determine safe VARCHAR length bounds for sku and category_name_1:

SELECT MAX(LENGTH(pled.sku)) AS max_sku_length, MAX(LENGTH(pled.category_name_1)) AS max_category_length
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND pled.sku IS NOT NULL AND pled.sku != '';

-- Result: max_sku_length = 69, max_category_length = 18.
-- Conclusion: To provide a comfortable buffer above the observed maximums and 
-- avoid any risk of silent truncation during future inserts, the data types for 
-- the OLTP schema will be set to: sku -> VARCHAR(100), category_name -> VARCHAR(50).

-- 2.5
-- Check for status consistency per order (Verify one status per increment_id):

SELECT pled.increment_id, COUNT(DISTINCT pled.status) AS status_variants
FROM staging.pakistan_largest_ecommerce_dataset pled 
WHERE pled.increment_id IS NOT NULL AND pled.increment_id != ''
GROUP BY pled.increment_id 
HAVING COUNT(DISTINCT pled.status) > 1;

-- Result: The query returns 0 rows, meaning no order has conflicting statuses.
-- Conclusion: Each order ('increment_id') is consistently mapped to a single 'status'.

-- 2.6
-- Check for payment method consistency per order (Verify one payment method per increment_id)

SELECT pled.increment_id, COUNT(DISTINCT pled.payment_method) AS payment_variants
FROM staging.pakistan_largest_ecommerce_dataset pled 
WHERE pled.increment_id IS NOT NULL AND pled.increment_id != ''
GROUP BY pled.increment_id 
HAVING COUNT(DISTINCT pled.payment_method ) > 1;

-- Result: The query returns 0 rows, meaning no order has conflicting payment methods.
-- Conclusion: Each order ('increment_id') is consistently mapped to a single 'payment_method'.

-- 2.7a
-- Check if 'grand_total' applies to the individual item or the entire order

-- Step A: Compare calculated item revenue vs. actual grand_total:

WITH calculated_orders AS (
    SELECT pled.item_id,
        CAST(pled.price AS NUMERIC) * CAST(pled.qty_ordered AS NUMERIC) - CAST(pled.discount_amount AS NUMERIC) AS calculated_total,
        CAST(pled.grand_total AS NUMERIC) AS actual_total
    FROM staging.pakistan_largest_ecommerce_dataset pled
    WHERE pled.item_id IS NOT NULL 
      AND pled.item_id != ''
)
SELECT 
    item_id,
    calculated_total,
    actual_total
FROM calculated_orders
WHERE calculated_total != actual_total
LIMIT 20;

-- Result: A mismatch exists between 'calculated_total' and 'actual_total' for multiple rows.

-- Step B: Deep dive into specific examples from the mismatch:

SELECT pled.item_id, pled.increment_id, pled.qty_ordered, pled.status, pled.discount_amount,
       CAST(pled.price AS NUMERIC) * CAST(pled.qty_ordered AS NUMERIC) - CAST(pled.discount_amount AS NUMERIC) AS calculated_total,
       CAST(pled.grand_total AS NUMERIC) AS actual_total
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IN ('233848', '233852', '233853', '233857');

-- Result: Items 233852 and 233853 (which belong to the same order) have different 
-- calculated totals (420 and 560), but share the exact same actual_total (980). 
-- Since 980 = 420 + 560, this confirms that 'grand_total' refers to the total 
-- order amount, not the individual item revenue.

-- Step C: Validate the hypothesis across the entire dataset:

SELECT pled.increment_id, COUNT(*) AS items_in_order, COUNT(DISTINCT pled.grand_total) AS distinct_totals
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
GROUP BY pled.increment_id
HAVING COUNT(*) > 1;

-- Result: 'distinct_totals' equals 1 for 100% of multi-item orders.

-- Step D: Direct proof - check for any violations of the hypothesis:

SELECT pled.increment_id
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
GROUP BY pled.increment_id
HAVING COUNT(*) > 1 AND COUNT(DISTINCT pled.grand_total) > 1;

-- Result: The query returns 0 rows, confirming there are absolutely no exceptions 
-- for any multi-item order across the entire dataset.
-- Conclusion: 'grand_total' represents the total value of the order, not the revenue 
-- generated by an individual item. It belongs at the 'orders' table level, not 'order_items'.
-- Revenue in 'order_items' must be calculated via: price * qty_ordered - discount_amount.

-- 2.7b
-- Investigate orders where grand_total = 0 to understand specific payment methods

-- Step A: Check zero-total transactions for specific customers to rule out 100% discounts:

SELECT pled.item_id, pled.status, pled.created_at, pled.price, pled.grand_total, pled.payment_method, pled."Customer ID"
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled."Customer ID" IN ('2824', '1474') AND pled.created_at IN ('8/24/2016', '8/4/2016');

-- Result: Rows with grand_total = 0 are exclusively linked to payment_method = 'customercredit'. 
-- Regular purchases ('cod') by the same clients have correct, non-zero grand totals. 
-- This disproves the theory of isolated 100% discounts or date-specific promotions.

-- Step B: Check the materiality of 'customercredit' and similar payment methods:

WITH payment_summary AS (
    SELECT pled.payment_method, COUNT(DISTINCT pled.increment_id) AS orders
    FROM staging.pakistan_largest_ecommerce_dataset pled
    WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
    GROUP BY pled.payment_method
)
SELECT payment_method, orders,
       ROUND(orders * 100.0 / SUM(orders) OVER (), 2) AS pct_of_orders
FROM payment_summary
ORDER BY orders DESC;

-- Result: customercredit (1.25%) and productcredit (0.02%) - totaling ~1.27%.
-- Conclusion: below the 5% materiality threshold. Clients and orders remain 
-- in the database, but revenue from rows with these payment methods is excluded 
-- from financial metrics. (marketingexpense/financesettlement handled separately, see 2.7c)

-- 2.7c
-- Identify and isolate internal or test customer accounts

-- Step A: Check customers using 'marketingexpense' or 'financesettlement':

SELECT pled.payment_method, pled.status, pled."Customer ID", pled.grand_total
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.payment_method IN ('marketingexpense', 'financesettlement')
  AND pled.item_id IS NOT NULL AND pled.item_id != '';

-- Result: Customer IDs 116 and 36353 display repetitive, identical rows, 
-- highly indicative of internal testing or corporate service accounts.

-- Step B: Profile the suspicious clients (116 and 36353):

SELECT pled."Customer ID", pled.payment_method, COUNT(DISTINCT pled.increment_id) AS orders
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled."Customer ID" IN ('116', '36353') AND item_id IS NOT NULL AND item_id != ''
GROUP BY pled."Customer ID", pled.payment_method
ORDER BY pled."Customer ID";

-- Result: Customer 116 has 100% internal orders ('marketingexpense'). 
-- Customer 36353 has a mixed history (1 standard 'cod' order + 4 internal).

-- Step C: Final Query - Isolate all clients with 100% internal orders:

WITH customer_orders AS (
    SELECT pled."Customer ID",
           COUNT(DISTINCT pled.increment_id) AS total_orders,
           COUNT(DISTINCT pled.increment_id) FILTER (
               WHERE pled.payment_method IN ('marketingexpense', 'financesettlement')
           ) AS internal_orders
    FROM staging.pakistan_largest_ecommerce_dataset pled
    WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
      AND pled."Customer ID" IS NOT NULL AND pled."Customer ID" != ''
    GROUP BY pled."Customer ID"
)
SELECT * FROM customer_orders
WHERE internal_orders = total_orders
ORDER BY total_orders DESC;

-- Result: Exactly 5 clients (116, 11019, 30508, 35173, 44300) have 100% internal transaction histories.
-- Conclusion: Completely exclude these 5 'Customer IDs' from all customers/RFM/cohort tables. 
-- For client 36353 (mixed history), the client remains in the database, but rows with 
-- internal payment methods will be filtered out during financial aggregations.

-- 2.8
-- Check date formats and column redundancy

-- Step A: Verify if 'created_at' and 'Working Date' contain identical data:

SELECT pled.created_at, pled."Working Date"
FROM staging.pakistan_largest_ecommerce_dataset pled  
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND pled.created_at != pled."Working Date" 
LIMIT 20;

-- Result: The query returns 0 rows, meaning 'created_at' and 'Working Date' are 100% identical.
-- Conclusion: The 'Working Date' column is fully redundant (likely a legacy BI artifact). 
-- It can be safely dropped during the normalization phase to avoid data duplication.

-- Step B: Verify the date format logic (MM/DD/YYYY vs DD/MM/YYYY):

SELECT pled.created_at
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND CAST(SPLIT_PART(pled.created_at, '/', 1) AS INT) > 12
LIMIT 5;

-- Result: The query returns 0 rows. No month value in the dataset exceeds 12.
-- Conclusion: The dates are consistently formatted in the US standard (MM/DD/YYYY).
-- This ensures they can be safely parsed and cast to the DATE type in the next stage.

-- Step C: Verify that 'created_at' is consistent within each order:

SELECT pled.increment_id, COUNT(DISTINCT pled.created_at) AS date_variants
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
GROUP BY pled.increment_id
HAVING COUNT(DISTINCT pled.created_at) > 1;

-- Result: 0 rows. 
-- Conclusion: The 'created_at' timestamp is perfectly consistent for all items 
-- within the same order. This confirms it is an order-level attribute and can 
-- be safely moved to the 'orders' table during normalization.

-- 2.9 
-- Check data type patterns and mandatory ID completeness

-- Step A: Verify if all 4 financial fields match a numeric pattern:

SELECT COUNT(*) AS bad_rows
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND (
    pled.price !~ '^-?[0-9]+(\.[0-9]+)?$' OR
    pled.qty_ordered !~ '^-?[0-9]+(\.[0-9]+)?$' OR
    pled.discount_amount !~ '^-?[0-9]+(\.[0-9]+)?$' OR
    pled.grand_total !~ '^-?[0-9]+(\.[0-9]+)?$'
  );

-- Result: 0. Safe to CAST all four fields to NUMERIC.

-- Step B: Check if 'qty_ordered' is always a valid integer:

SELECT COUNT(*) 
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND pled.qty_ordered !~ '^-?[0-9]+$';

-- Result: 0. 'qty_ordered' can be safely cast to INTEGER.

-- Step C: Check 'Customer ID' completeness (basic check, empty-string only):

SELECT COUNT(*) 
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND (pled."Customer ID" IS NULL OR pled."Customer ID" = '');

-- Result: 0. NOTE: this check does not catch the '#N/A' pattern - see 2.10, 
-- which revises this to require a nullable customer_id FK.

-- Step D: Check 'increment_id' completeness

SELECT COUNT(*)
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND (pled.increment_id IS NULL OR pled.increment_id = '');

-- Result: 0. Every item row belongs to a valid order.

-- Step E: Check for negative values in 'qty_ordered' (e.g., returns or reversals):

SELECT COUNT(*)
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND CAST(pled.qty_ordered AS INTEGER) < 0;

-- Result: 0. 
-- Conclusion: There are no negative quantities in the dataset, confirming 
-- this column represents strictly positive order volumes.

-- Step F: Evaluate ID columns for numeric-only patterns (BIGINT vs TEXT mapping):

SELECT
    COUNT(*) FILTER (WHERE pled.item_id !~ '^[0-9]+$') AS item_id_non_numeric,
    COUNT(*) FILTER (WHERE pled.increment_id !~ '^[0-9]+$') AS increment_id_non_numeric,
    COUNT(*) FILTER (WHERE pled."Customer ID" !~ '^[0-9]+$' 
                       AND pled."Customer ID" NOT IN ('\N', '', '#N/A')) AS customer_id_non_numeric
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != '';

-- Result: item_id_non_numeric = 0, increment_id_non_numeric = 9, customer_id_non_numeric = 0.
-- Conclusion: 'item_id' and 'Customer ID' are strictly numeric (excluding known NULL artifacts) 
-- and can be safely cast to BIGINT. The 9 anomalies in 'increment_id' require inspection.

-- Step G: Inspect the 9 non-numeric 'increment_id' anomalies:

SELECT pled.increment_id
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND pled.increment_id !~ '^[0-9]+$';

-- Result: All 9 rows contain a '-1' suffix (e.g., '100542843-1').
-- Conclusion: This minor artifact (likely a system bug or a split-order suffix) 
-- affects a negligible number of rows and does not warrant deeper investigation.

-- Step H: Verify 'Customer ID' is consistent within each order (i.e., the FK is well-defined):

SELECT pled.increment_id, COUNT(DISTINCT pled."Customer ID") AS customer_variants
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
GROUP BY pled.increment_id
HAVING COUNT(DISTINCT pled."Customer ID") > 1;

-- Result: 0 rows. Every order maps to exactly one customer.
-- Conclusion: Like 'status', 'payment_method', and 'created_at', the 'Customer ID' 
-- is perfectly consistent within each order. This confirms it is strictly an order-level 
-- attribute, ensuring the 'orders.customer_id' foreign key relationship is unambiguously 
-- defined for normalization.
-- 
-- FINAL RULE FOR ID COLUMNS:
-- 1. 'item_id' -> CAST to BIGINT.
-- 2. 'Customer ID' -> CAST to BIGINT (after replacing '#N/A' with NULL).
-- 3. 'increment_id' -> Retain as VARCHAR/TEXT to safely preserve the '-1' suffix variants.

-- 2.10
-- Check 'Customer Since' formats and identify '#N/A' artifacts

-- Step A: Check 'Customer Since' date format:

SELECT DISTINCT pled."Customer Since"
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
ORDER BY pled."Customer Since"
LIMIT 20;

-- Result: The format is YYYY-MM (differs from created_at's MM/DD/YYYY).

-- Step B: Identify non-standard or invalid date values

SELECT pled."Customer Since", COUNT(*)
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL 
  AND pled.item_id != ''
  AND pled."Customer Since" NOT LIKE '%-%'
GROUP BY pled."Customer Since"
ORDER BY pled."Customer Since";

-- Result: '#N/A' - 11 rows.

-- Step C: Check correlation with 'Customer ID'

SELECT *
FROM staging.pakistan_largest_ecommerce_dataset pled 
WHERE pled."Customer Since" = '#N/A';

-- Result: All 11 rows also have 'Customer ID' = '#N/A'. 
-- This is an Excel-style NULL artifact (distinct from MySQL's '\N'), 
-- likely representing guest checkouts or unresolved customer identities.
-- Materiality: 11 / 584,524 = 0.0019% - well below the threshold, 
-- so the root cause was not investigated further.

-- Step D: Check if the '#N/A' artifact appears in other critical columns

SELECT
    COUNT(*) FILTER (WHERE pled.increment_id = '#N/A') AS increment_fake,
    COUNT(*) FILTER (WHERE pled.sku = '#N/A') AS sku_fake,
    COUNT(*) FILTER (WHERE pled.category_name_1 = '#N/A') AS category_fake,
    COUNT(*) FILTER (WHERE pled.payment_method = '#N/A') AS payment_fake,
    COUNT(*) FILTER (WHERE pled.status = '#N/A') AS status_fake
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != '';

-- Result: 0 for all columns.
-- Conclusion: The '#N/A' artifact is strictly isolated to the customer fields 
-- ('Customer ID' and 'Customer Since'). The core order and product data is completely 
-- clean from this specific Excel-style error.

-- Step E: Validate the YYYY-MM format across the entire dataset:

SELECT COUNT(*)
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND pled."Customer Since" != '#N/A'
  AND pled."Customer Since" !~ '^[0-9]{4}-[0-9]{1,2}$';

-- Result: 0. 
-- Conclusion: Excluding the 11 '#N/A' artifacts, the YYYY-MM date format 
-- is perfectly consistent across all records.

-- Step F: Final check for '\N' contamination in customer fields:

SELECT
    COUNT(*) FILTER (WHERE pled."Customer ID" = '\N') AS customer_id_backslash_n,
    COUNT(*) FILTER (WHERE pled."Customer Since" = '\N') AS customer_since_backslash_n
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != '';

-- Result: customer_id_backslash_n = 0, customer_since_backslash_n = 0.
-- Conclusion: The '\N' artifact is completely absent from both customer identity fields. 
-- This confirms that '#N/A' is the sole missing-value placeholder used in this domain,
-- and it should be converted to standard SQL NULLs during normalization.

-- 2.11
-- Validate ' MV ' as a standalone gross-value metric (item-level, pre-discount)

-- Step A: Initial attempt to compare ' MV ' with calculated revenue:

-- SELECT COUNT(*) AS mismatch_count
-- FROM staging.pakistan_largest_ecommerce_dataset pled
-- WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
--   AND CAST(pled." MV " AS NUMERIC) != (CAST(pled.price AS NUMERIC) * CAST(pled.qty_ordered AS NUMERIC));

-- Result: ERROR - invalid input syntax for type numeric: " 1,350 "
-- Conclusion: Direct casting fails because the ' MV ' column contains padding spaces 
-- and thousands-separator commas. It requires TRIM() and comma removal (REPLACE) 
-- before any mathematical operations can be performed.

-- Step B: Check for any non-numeric patterns after cleaning:

SELECT DISTINCT pled." MV "
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND TRIM(REPLACE(pled." MV ", ',', '')) !~ '^-?[0-9]+(\.[0-9]+)?$';

-- Result: Only one non-numeric value found: '-'.

-- Step C: Investigate the '-' pattern:

SELECT pled.item_id, pled.price, pled.qty_ordered, pled.discount_amount, pled." MV ", pled.status, pled.sku 
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND TRIM(pled." MV ") = '-'
LIMIT 12;

-- Result: All sampled rows have price = 0. The '-' behaves as an Excel-style
-- placeholder for zero in this column (a fourth fake-NULL pattern,
-- distinct from '', '\N', and '#N/A').
--
-- Note: This sample also revealed test items (e.g., SKU 'test-product'). 
-- See Section 2.12 for further investigation of these test records.

-- Step D: Materiality of the '-' pattern:

SELECT COUNT(*)
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND TRIM(pled." MV ") = '-';

-- Result: 2,232 rows (0.38% of 584,524). Below the materiality threshold -
-- root cause not investigated further.

-- Step E: Re-attempt the revenue comparison on cleaned data:

SELECT COUNT(*)
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND TRIM(pled." MV ") != '-'
  AND REPLACE(TRIM(pled." MV "), ',', '')::NUMERIC 
      != CAST(pled.price AS NUMERIC) * CAST(pled.qty_ordered AS NUMERIC);

-- Result: 8,334 rows differ (1.43%). 
-- Conclusion: A direct comparison shows mismatches. Further inspection of 
-- these specific rows is required to understand the root cause of the discrepancy.

-- Step F: Inspect the mismatched rows to identify the pattern:

SELECT pled." MV ", pled.price, pled.qty_ordered 
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND TRIM(pled." MV ") != '-'
  AND REPLACE(TRIM(pled." MV "), ',', '')::NUMERIC 
      != CAST(pled.price AS NUMERIC) * CAST(pled.qty_ordered AS NUMERIC)
LIMIT 20;

-- Result: Sample inspection shows 'price' consistently carries more decimal 
-- precision than ' MV ' (e.g., price = 1349.1 vs MV = 1,349). 
-- Hypothesis: ' MV ' is simply a rounded version of the calculated gross value.

-- Step G: Test the rounding hypothesis:

SELECT COUNT(*)
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND TRIM(pled." MV ") != '-'
  AND REPLACE(TRIM(pled." MV "), ',', '')::NUMERIC 
      != ROUND(CAST(pled.price AS NUMERIC) * CAST(pled.qty_ordered AS NUMERIC));

-- Result: 0. 
-- Conclusion: This confirms ' MV ' is a rounded (integer-precision) duplicate of 
-- (price * qty_ordered), not an independent metric.
-- FINAL RULE FOR ' MV ': Do NOT import the ' MV ' column into the OLTP schema. 
-- Compute gross_value directly via (price * qty_ordered) - it is more precise 
-- and naturally resolves the '-' placeholder issue (where price = 0) without 
-- requiring special-case logic.

-- 2.12
-- Investigate '\N' artifacts and 'test' data contamination 

-- Step A: Systematic scan for the '\N' pattern in remaining text columns:

SELECT
    COUNT(*) FILTER (WHERE pled.status = '\N') AS status_fake_null,
    COUNT(*) FILTER (WHERE pled.payment_method = '\N') AS payment_fake_null,
    COUNT(*) FILTER (WHERE pled.sku = '\N') AS sku_fake_null
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != '';

-- Result: 'payment_method' and 'sku' return 0. 'status' returns 4 rows.
-- Conclusion: The '\N' artifact is strictly isolated to 'category_name_1' (Section 2.4), 
-- with only this minor 4-row leak into the 'status' column.

-- Step B: Investigate the 4 rows where 'status' = '\N':

SELECT *
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND pled.status = '\N';

-- Result: All 4 rows share sku IN ('test-product-3', 'test-product') and
-- 'Customer ID' = 1423.
-- Conclusion: These SKUs match the incidental finding from Section 2.11. 
-- This strongly suggests these records are artifacts from internal system testing, 
-- requiring a broader and more detailed investigation.

-- Step C: Broad scan for the 'test' substring in 'sku':

SELECT pled.sku, COUNT(*) AS row_count
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND pled.sku ILIKE '%test%'
GROUP BY pled.sku
ORDER BY row_count DESC;

-- Result: 28 distinct SKUs found. 
-- Conclusion: Manual review identified 3 genuine products ('SKMT_Blood Test', 
-- 'Aladdin_Test Star Cricket Ball - Red & White', 'sst_Vous Deteste-Regular fit-Medium'). 
-- The remaining 25 are purely internal QA/test artifacts.

-- Step D: Assess the materiality of confirmed test SKUs:

SELECT COUNT(*)
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND pled.sku ILIKE '%test%'
  AND pled.sku NOT IN (
	'SKMT_Blood Test', 
	'Aladdin_Test Star Cricket Ball - Red & White', 
	'sst_Vous Deteste-Regular fit-Medium'
	);

-- Result: 1,777 rows (0.30% of 584,524 total rows).

-- Step E: Establish baseline totals for orders and customers:

SELECT 
    COUNT(DISTINCT pled.increment_id) AS total_orders,
    COUNT(DISTINCT pled."Customer ID") AS total_customers
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != '';

-- Result: total_orders = 408,782, total_customers = 115,327.
-- Conclusion: These baselines establish the total population size needed to 
-- accurately calculate the materiality of test-contaminated entities below.

-- Step F: Identify customers whose ENTIRE order history consists of test data:

WITH customer_test_ratio AS (
  SELECT pled."Customer ID",
         COUNT(DISTINCT pled.increment_id) AS total_orders,
         COUNT(DISTINCT pled.increment_id) FILTER (
           WHERE pled.sku NOT ILIKE '%test%' 
              OR pled.sku IN ('SKMT_Blood Test', 'Aladdin_Test Star Cricket Ball - Red & White', 'sst_Vous Deteste-Regular fit-Medium')
         ) AS non_test_orders
  FROM staging.pakistan_largest_ecommerce_dataset pled
  WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  GROUP BY pled."Customer ID"
)
SELECT COUNT(*) AS fully_test_customers, SUM(total_orders) AS orders_affected
FROM customer_test_ratio 
WHERE non_test_orders = 0;

-- Result: 68 customers and 201 orders are comprised entirely of test SKUs.
-- Conclusion: Order materiality (201 / 408,782 ≈ 0.049%) and customer materiality
-- (68 / 115,327 ≈ 0.059%) are both well below the threshold.
-- The root cause is clearly internal QA testing, requiring no further investigation.
--
-- FINAL EXCLUSION RULES FOR ETL:
-- 1. order_items: Exclude rows where 'sku' matches the confirmed test pattern.
--    (Note: This automatically filters out the 4 status = '\N' rows found in Step B, 
--    so no separate NULLIF rule is required for the 'status' column).
-- 2. orders: Exclude any 'increment_id' left with zero items after applying Rule 1.
-- 3. customers: Exclude the 68 'Customer ID's left with zero orders after applying Rule 2.

-- 2.13
-- Investigate 'discount_amount': sign convention and order-vs-item level ambiguity

-- Step A: Check for negative values in price and discount fields:

SELECT
    COUNT(*) FILTER (WHERE CAST(pled.price AS NUMERIC) < 0) AS negative_price,
    COUNT(*) FILTER (WHERE CAST(pled.discount_amount AS NUMERIC) < 0) AS negative_discount
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != '';

-- Result: negative_price = 0, negative_discount = 3.

-- Step B: Investigate the 3 rows where 'discount_amount' < 0:

SELECT * 
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND CAST(pled.discount_amount AS NUMERIC) < 0;

-- Result: For all 3 rows, price + discount_amount = grand_total (e.g., 5995 + (-599.5) = 5395.5).
-- Conclusion: This indicates an inverted sign convention, not malformed data. 
-- Rule: Use ABS(discount_amount) in the revenue formula to neutralize both sign conventions.

-- Step C: Check if the discount exceeds gross value (which would yield negative net revenue):

SELECT COUNT(*)
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND ABS(CAST(pled.discount_amount AS NUMERIC)) > (CAST(pled.price AS NUMERIC) * CAST(pled.qty_ordered AS INTEGER));

-- Result: 9,713 rows.
-- Conclusion: Net revenue would be negative for these rows, requiring hypothesis testing 
-- on how discounts are distributed across items.

-- Step D: Test Hypothesis 1 - 'discount_amount' is duplicated once per order:

WITH duplicated_discount_orders AS (
    SELECT 
        pled.increment_id,
        SUM(CAST(pled.price AS NUMERIC) * CAST(pled.qty_ordered AS INTEGER)) AS sum_gross,
        MAX(ABS(CAST(pled.discount_amount AS NUMERIC))) AS shared_discount,
        MAX(CAST(pled.grand_total AS NUMERIC)) AS order_grand_total
    FROM staging.pakistan_largest_ecommerce_dataset pled
    WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
    GROUP BY pled.increment_id
    HAVING COUNT(*) > 1 
       AND COUNT(DISTINCT pled.discount_amount) = 1 
       AND MAX(ABS(CAST(pled.discount_amount AS NUMERIC))) != 0
)
SELECT 
    COUNT(*) AS total_candidates,
    COUNT(*) FILTER (WHERE ABS((sum_gross - shared_discount) - order_grand_total) <= 0.01) AS matches_hypothesis,
    COUNT(*) FILTER (WHERE ABS((sum_gross - shared_discount) - order_grand_total) > 0.01) AS mismatches
FROM duplicated_discount_orders;

-- Result: total_candidates = 7,750. matches_hypothesis = 5,137. mismatches = 2,613.

-- Step E: Test Hypothesis 2 - 'discount_amount' is genuinely per-item:

WITH duplicated_discount_orders AS (
    SELECT 
        pled.increment_id,
        SUM(CAST(pled.price AS NUMERIC) * CAST(pled.qty_ordered AS INTEGER)) AS sum_gross,
        SUM(ABS(CAST(pled.discount_amount AS NUMERIC))) AS summed_discount,
        MAX(CAST(pled.grand_total AS NUMERIC)) AS order_grand_total
    FROM staging.pakistan_largest_ecommerce_dataset pled
    WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
    GROUP BY pled.increment_id
    HAVING COUNT(*) > 1 
       AND COUNT(DISTINCT pled.discount_amount) = 1 
       AND MAX(ABS(CAST(pled.discount_amount AS NUMERIC))) != 0
)
SELECT COUNT(*) AS matches_summed_hypothesis
FROM duplicated_discount_orders 
WHERE ABS((sum_gross - summed_discount) - order_grand_total) <= 0.01;

-- Result: 1,263 match the "summed" hypothesis.

-- Step F: Inspect the true residual (matches neither hypothesis):

WITH duplicated_discount_orders AS (
    SELECT 
        pled.increment_id,
        SUM(CAST(pled.price AS NUMERIC) * CAST(pled.qty_ordered AS INTEGER)) AS sum_gross,
        MAX(ABS(CAST(pled.discount_amount AS NUMERIC))) AS shared_discount,
        SUM(ABS(CAST(pled.discount_amount AS NUMERIC))) AS summed_discount,
        MAX(CAST(pled.grand_total AS NUMERIC)) AS order_grand_total
    FROM staging.pakistan_largest_ecommerce_dataset pled
    WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
    GROUP BY pled.increment_id
    HAVING COUNT(*) > 1 
       AND COUNT(DISTINCT pled.discount_amount) = 1 
       AND MAX(ABS(CAST(pled.discount_amount AS NUMERIC))) != 0
)
SELECT 
    increment_id, 
    sum_gross, 
    shared_discount, 
    summed_discount, 
    order_grand_total
FROM duplicated_discount_orders 
WHERE ABS((sum_gross - shared_discount) - order_grand_total) > 0.01
  AND ABS((sum_gross - summed_discount) - order_grand_total) > 0.01
LIMIT 20;

-- Result: 1,350 orders have no consistent formula. Some show grand_total > gross value, 
-- suggesting unmodeled charges (e.g., shipping) are mixed into the grand_total field.
--
-- FINAL RULE FOR 'discount_amount':
-- Materiality breakdown:
-- 1.26% (5,137 / 408,782) - Discount applied once at order level.
-- 0.31% (1,263 / 408,782) - Standard per-item formula is correct.
-- 0.33% (1,350 / 408,782) - No consistent pattern.
--
-- Conclusion: All conflicting groups are well below the materiality threshold. 
-- Retain the standard per-item formula (price * qty_ordered - ABS(discount_amount)) 
-- as-is for the 'order_items' table. Order-level aggregates (AOV, revenue trends) 
-- remain unaffected because they will use 'orders.grand_total' directly. 
-- Category/SKU-level metrics will carry a minor, acceptable margin of error.