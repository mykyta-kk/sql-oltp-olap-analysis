-- ================================================================
-- Script: 	02_data_quality_checks.sql
-- Purpose: Perform data quality checks and identify anomalies in the raw data.
-- ================================================================

-- NOTE: Since the data was imported into TEXT columns (see script 01), missing values 
-- were loaded as empty strings ('') or literal '\N' (a common MySQL export artifact) 
-- instead of true SQL NULLs. To ensure accurate checks, the following logic is used:
-- 1. WHERE [column_name] IS NOT NULL AND [column_name] != ''
-- 2. NULLIF(NULLIF([column_name], '\N'), '')

-- 2.1
-- Verify the actual number of populated rows:

-- Approach 1: filter using WHERE clause.
SELECT COUNT(*) AS total_rows, COUNT(pled.item_id) AS non_empty_rows 
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != '';

-- Approach 2: optimized query (shows both total and valid row counts in a single pass).
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

-- Step 1: Compare calculated item revenue vs. actual grand_total:

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

-- Step 2: Deep dive into specific examples from the mismatch:

SELECT pled.item_id, pled.increment_id, pled.qty_ordered, pled.status, pled.discount_amount,
       CAST(pled.price AS NUMERIC) * CAST(pled.qty_ordered AS NUMERIC) - CAST(pled.discount_amount AS NUMERIC) AS calculated_total,
       CAST(pled.grand_total AS NUMERIC) AS actual_total
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IN ('233848', '233852', '233853', '233857');

-- Result: Items 233852 and 233853 (which belong to the same order) have different 
-- calculated totals (420 and 560), but share the exact same actual_total (980). 
-- Since 980 = 420 + 560, this confirms that 'grand_total' refers to the total 
-- order amount, not the individual item revenue.

-- Step 3: Validate the hypothesis across the entire dataset:

SELECT pled.increment_id, COUNT(*) AS items_in_order, COUNT(DISTINCT pled.grand_total) AS distinct_totals
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
GROUP BY pled.increment_id
HAVING COUNT(*) > 1;

-- Result: 'distinct_totals' equals 1 for 100% of multi-item orders.

-- Step 4: Direct proof - check for any violations of the hypothesis:

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

-- Step 1: Check zero-total transactions for specific customers to rule out 100% discounts:

SELECT pled.item_id, pled.status, pled.created_at, pled.price, pled.grand_total, pled.payment_method, pled."Customer ID"
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled."Customer ID" IN ('2824', '1474') AND pled.created_at IN ('8/24/2016', '8/4/2016');

-- Result: Rows with grand_total = 0 are exclusively linked to payment_method = 'customercredit'. 
-- Regular purchases ('cod') by the same clients have correct, non-zero grand totals. 
-- This disproves the theory of isolated 100% discounts or date-specific promotions.

-- Step 2: Check the materiality of 'customercredit' and similar payment methods:

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

-- Step 1: Check customers using 'marketingexpense' or 'financesettlement':

SELECT pled.payment_method, pled.status, pled."Customer ID", pled.grand_total
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.payment_method IN ('marketingexpense', 'financesettlement')
  AND pled.item_id IS NOT NULL AND pled.item_id != '';

-- Result: Customer IDs 116 and 36353 display repetitive, identical rows, 
-- highly indicative of internal testing or corporate service accounts.

-- Step 2: Profile the suspicious clients (116 and 36353):

SELECT pled."Customer ID", pled.payment_method, COUNT(DISTINCT pled.increment_id) AS orders
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled."Customer ID" IN ('116', '36353') AND item_id IS NOT NULL AND item_id != ''
GROUP BY pled."Customer ID", pled.payment_method
ORDER BY pled."Customer ID";

-- Result: Customer 116 has 100% internal orders ('marketingexpense'). 
-- Customer 36353 has a mixed history (1 standard 'cod' order + 4 internal).

-- Step 3: Final Query - Isolate all clients with 100% internal orders:

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

-- Step 1: Verify if 'created_at' and 'Working Date' contain identical data:

SELECT pled.created_at, pled."Working Date"
FROM staging.pakistan_largest_ecommerce_dataset pled  
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND pled.created_at != pled."Working Date" 
LIMIT 20;

-- Result: The query returns 0 rows, meaning 'created_at' and 'Working Date' are 100% identical.
-- Conclusion: The 'Working Date' column is fully redundant (likely a legacy BI artifact). 
-- It can be safely dropped during the normalization phase to avoid data duplication.

-- Step 2: Verify the date format logic (MM/DD/YYYY vs DD/MM/YYYY):

SELECT pled.created_at
FROM staging.pakistan_largest_ecommerce_dataset pled
WHERE pled.item_id IS NOT NULL AND pled.item_id != ''
  AND CAST(SPLIT_PART(pled.created_at, '/', 1) AS INT) > 12
LIMIT 5;

-- Result: The query returns 0 rows. No month value in the dataset exceeds 12.
-- Conclusion: The dates are consistently formatted in the US standard (MM/DD/YYYY).
-- This ensures they can be safely parsed and cast to the DATE type in the next stage.