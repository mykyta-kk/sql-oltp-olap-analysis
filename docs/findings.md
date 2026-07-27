# Stage 1: Data Quality Audit - Summary of Findings

**Source:** Pakistan's Largest E-Commerce Dataset (raw version, `staging` table, all columns as TEXT).  
**Total Volume:** 1,048,575 rows in the raw file → **584,524 actual rows** after filtering.  

*Full SQL for each check: `sql/02_data_quality_checks.sql`.*  
*Staging table creation: `sql/01_setup_and_staging.sql`.*

---

## 1. Basic Data Hygiene
*(SQL: `02_data_quality_checks.sql` → 2.1)*

**Finding:** `COUNT(*)` and `COUNT(item_id)` initially returned the same number (1,048,575) - which looked like an error.  
**Root Cause:** Blank rows at the end of the file were loaded as empty strings `''` instead of true `NULL`s. The `COUNT(column)` function only ignores true `NULL`s, so these empty rows were counted as "non-empty".  
**Rule:** Consistently apply `WHERE item_id IS NOT NULL AND item_id != ''` across all queries.  
**Actual Volume:** 584,524 rows (item-level).   

---

## 2. MySQL Export Artifact (`\N`)
*(SQL: `02_data_quality_checks.sql` → 2.4 (Step C))*

**Finding:** The literal text string `\N` (two characters) appears in text columns (e.g., `category_name_1`, `sales_commission_code`) instead of a true `NULL`. Cause: This is a standard MySQL method of representing NULLs during CSV exports, which was not converted during the PostgreSQL import.  
**Volume:** 7,850 rows containing `\N` in `category_name_1` (~1.3% of actual rows).  
**Rule:** Apply `NULLIF(column, '\N')` to all text columns when building the final tables.  
**Status:** This is a system-level import nuance, not an isolated issue - it is likely present in other text fields beyond those already identified.  

---

## 3. Product Category (`category_name_1`) - Ambiguity
*(SQL: `02_data_quality_checks.sql` → 2.4)*

**Initial Finding:** Dozens of SKUs were mapped to 2 "different" categories.  
**After fixing the `\N` artifact:** Only **2 SKUs** with genuine conflicts remained (`AJ-ajrak_AJA-005-Large`, `AJ-ajrak_AJA-005-Medium`) - likely unisex clothing appearing in both Men's and Women's Fashion.  
**Additionally:** A significant portion of SKUs has no category at all (only `\N` or empty). Probable explanation: the category was assigned once when the product was initially added to the catalog, rather than being recorded during every transaction export (a source system limitation, unconfirmed).  
**Rule:** Apply a majority rule (the most frequent non-empty category value per SKU) - using `DISTINCT ON (sku) ... ORDER BY sku, COUNT(*) DESC` *(see 2.4 Step E)*.  

**Additional Finding - Empty `sku` with a populated `item_id`:** 20 rows (0.003% of 584,524) have `sku = ''`, even though the transaction row (`item_id`) is valid *(see 2.4 Step F)*.  
**Issue:** If left unhandled, such rows will become "broken" references in the `order_items` table (a Foreign Key pointing nowhere, since there is no empty `sku` in the `products` table).  
**Rule:** Use `NULLIF(sku, '')` when creating `order_items` - the empty string converts to a true SQL `NULL` (which is valid and handled correctly by the FK), preventing a broken reference.  
**Materiality:** 0.003% - well below the threshold; additional investigation into the root cause was deemed unnecessary.  

---

## 4. Granularity Level of Status and Payment Method
*(SQL: `02_data_quality_checks.sql` → 2.5, 2.6)*

**Checked:** Whether `status` and `payment_method` are always unique within a single order (`increment_id`).  
**Result:** Yes, in both cases, with zero exceptions.  
**Conclusion:** Both fields belong to the `orders` table level, not `order_items`.  

---

## 5. `grand_total` Belongs to the Order Level, Not the Item Level (Key Finding)
*(SQL: `02_data_quality_checks.sql` → 2.7a)*

**Observation:** For items within the same `increment_id`, the `grand_total` is identical across all positions, although the calculated value of an individual item (`price * qty_ordered - discount_amount`) differs.  
**Confirmed across the entire dataset:** `COUNT(DISTINCT grand_total)` = 1 for 100% of multi-item orders.  
**Conclusion:** `grand_total` represents the total sum for the entire order and was duplicated across each item row during the export.  
**Rule:**  
- Move `grand_total` to the `orders` level.
- In `order_items`, calculate item revenue via the formula: `price * qty_ordered - discount_amount`.

---

## 6. The `grand_total = 0` Anomaly (`customercredit` / `productcredit`)
*(SQL: `02_data_quality_checks.sql` → 2.7b)*

**Observation:** A subset of orders with a `complete` status had a `grand_total = 0`.  
**Root Cause:** This is systematically linked to the `customercredit` and `productcredit` payment methods (likely an internal bonus/credit system; the exact mechanism cannot be derived purely from the data).  
**Materiality:** `customercredit` - 1.25% of orders, `productcredit` - 0.02%. Combined total ~1.27%.  
**Rule:** The client and order records remain in the database; however, the order amount (`grand_total`) must be excluded from financial metrics (e.g., AOV, Revenue) for rows utilizing these payment methods.  

---

## 7. Service/Internal Accounts Disguised as Customers
*(SQL: `02_data_quality_checks.sql` → 2.7c)*

**Observation:** Payment methods like `marketingexpense` (42 orders, 0.01%) and `financesettlement` (10 orders, ~0%) appeared to be internal accounting operations rather than genuine client purchases.  
**Validation:** Identified specific customers for whom **100% of orders** were processed exclusively through these payment methods:  

| Customer ID | Total Orders | Internal Orders |
| :--- | :--- | :--- |
| 116 | 38 | 38 |
| 11019 | 1 | 1 |
| 30508 | 1 | 1 |
| 35173 | 1 | 1 |
| 44300 | 1 | 1 |

**Control Case:** Customer ID 36353 has 1 standard order (`cod`) + 4 `financesettlement` orders → This is a real client with a mixed internal history, not a dedicated service account.  
**Rule:**
- Clients with 100% internal orders (the 5 IDs above) → **Exclude completely** from `customers`, RFM, and cohort analysis.
- Clients with a mixed history (e.g., 36353) → Remain in the database; only specific rows with these internal payment methods are excluded from financial aggregations.

---

## 8. Date Formatting and the Redundant `Working Date` Column
*(SQL: `02_data_quality_checks.sql` → 2.8)*

**Checked (exhaustive check, not sampled):** Executed `SELECT ... WHERE created_at != "Working Date"` across the entire table.  
**Result:** 0 rows returned - `created_at` and `Working Date` are **100% identical** for all 584,524 records.  
**Conclusion:** `Working Date` is a completely redundant column (highly likely a legacy artifact from the seller's internal BI system).  
**Rule:** **Do not transfer** the `Working Date` column to the `oltp` schema during normalization - a single `order_date` (derived from `created_at`) is sufficient.  
**Date Format Check:** Verified if the first number in `created_at` ever exceeds 12 (confirming it represents the month, not the day) - 0 rows violated this format.  
**Conversion Rule:** Cast using `TO_DATE(created_at, 'MM/DD/YYYY')`.  

---

## Summary Table of Rules for CREATE TABLE

| Scope | Rule |
| :--- | :--- |
| Row filter | Apply universally: `WHERE item_id IS NOT NULL AND item_id != ''` |
| Text NULLs | Apply to all text columns: `NULLIF(column, '\N')` |
| `status` | → Move to `orders` |
| `payment_method` | → Move to `orders` |
| `grand_total` | → Move to `orders` |
| Item revenue | In `order_items`: `price * qty_ordered - discount_amount` |
| `category_name_1` | Apply `DISTINCT ON (sku)`, majority non-empty value |
| `sku` in order_items | Apply `NULLIF(sku, '')` - 20 rows (0.003%) with empty SKUs become NULL, preventing a broken FK |
| `customer_since` | No changes needed, zero conflicts found |
| Service accounts | Exclude Customer IDs: 116, 11019, 30508, 35173, 44300 |
| customercredit / productcredit | Keep client/order, exclude the amount from financial metrics |
| Dates | Cast using: `TO_DATE(created_at, 'MM/DD/YYYY')` |
| `Working Date` | Do not transfer to OLTP - 100% duplicate of `created_at` |

---

## Side Business Insight (For the Marketing Section)

The distribution of payment methods reveals a heavy dominance of **Cash on Delivery (44.63%)** across all orders, significantly ahead of any electronic payment method (Payaxis at 16.61%, Easypay at 14.75%). This reflects a low level of trust in cashless transactions within the market during the data collection period (2016-2018) - providing a ready-made contextual insight for the report's section on customer payment behavior.