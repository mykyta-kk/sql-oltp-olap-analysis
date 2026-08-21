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
**Status:** This is a system-level import nuance, not an isolated issue - it is likely present in other text fields beyond those already identified. *(Exhaustively re-checked in Section 12 - confirmed absent from `payment_method`/`sku`, with only an isolated 4-row leak into `status`.)*  

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
**Additional Validation:** Confirmed `created_at` is consistent across all items within the same order (0 exceptions) - validating it can be safely promoted to a single `orders.order_date` value without any aggregation rule.  

---
 
## 9. Preflight Validation: Numeric Safety and Key Completeness
*(SQL: `02_data_quality_checks.sql` → 2.9)*
 
**Purpose:** Before writing `CREATE TABLE` statements, verified that a bulk `CAST` of the four financial fields (`price`, `qty_ordered`, `discount_amount`, `grand_total`) to `NUMERIC` would not fail partway through on malformed values.  
**Result:** 0 rows fail a strict numeric-pattern check across all four fields.  
**Additional check:** `qty_ordered` also matches an integer-only pattern with 0 exceptions.  
**Conclusion:** All four fields can be safely cast - `qty_ordered` to `INTEGER`, the remaining three to `NUMERIC`.  
**Additional check - negative values:** Confirmed `qty_ordered` contains zero negative values - returns/reversals are not represented as negative quantities in this dataset, so no special handling is required for `gross_value`/revenue calculations.  
**Note:** An initial completeness check on `Customer ID` (empty string only) also returned 0 - this specific result is revised below (Section 10), as it did not account for the `#N/A` pattern. The `increment_id` completeness check remains valid, as Section 10 confirms `#N/A` does not appear in that field.  
**ID Column Format Check:** Tested whether `item_id`, `increment_id`, and `Customer ID` are strictly numeric (a prerequisite for using `BIGINT` instead of `TEXT`). `item_id` and `Customer ID` (excluding known NULL artifacts) matched with zero exceptions. `increment_id` returned 9 non-numeric rows, all sharing a `-1` suffix (e.g. `100542843-1`) - materiality 9/408,782 ≈ 0.002%, not investigated further.  
**Rule:**
- `item_id` → `BIGINT`
- `Customer ID` → `BIGINT` (after the triple `NULLIF` conversion described in Section 10)
- `increment_id` → remains `TEXT`/`VARCHAR` to preserve the `-1` suffix variants
 
---
 
## 10. Customer Identity Fields: Date Format and a Third Fake-NULL Pattern (`#N/A`)
*(SQL: `02_data_quality_checks.sql` → 2.10)*
 
**Finding:** `Customer Since` uses a distinct date format - `YYYY-MM` (e.g. `2016-8`), unlike `created_at`'s `MM/DD/YYYY`. It requires a separate parsing rule.  
**Additional Finding:** 11 rows contain the literal text `#N/A` in `Customer Since`. Investigation showed all 11 of these rows **also** have `Customer ID = '#N/A'` - not a coincidence, but a third distinct fake-NULL pattern (an Excel-style artifact, unlike MySQL's `\N`).  
**Materiality:** 11 / 584,524 = 0.0019% - well below threshold; the root cause (why these 11 specific transactions lack a resolved customer identity) was not investigated further.  
**Scope check:** Confirmed `#N/A` does not appear in `increment_id`, `sku`, `category_name_1`, `payment_method`, or `status` - the pattern is confined to the customer identity fields.  
**Format Validation (exhaustive):** Excluding the 11 `#N/A` rows, confirmed the `YYYY-MM` pattern holds with zero exceptions across the entire table - not just the initial sample.  
**Revision:** This overturns the preliminary Section 9 conclusion - `orders.customer_id` **cannot** be treated as guaranteed non-empty. It must be a **nullable** foreign key.  
**Rule:**
- `orders.customer_id` → nullable FK
- Apply a triple `NULLIF` when populating customer fields: `NULLIF(NULLIF(NULLIF("Customer ID", '\N'), ''), '#N/A')`
- Cast `Customer Since` using a `YYYY-MM` pattern, not `MM/DD/YYYY`

**Final Check:** Confirmed `\N` (the MySQL artifact from Section 2) does not appear in either `Customer ID` or `Customer Since` - `#N/A` is the sole missing-value placeholder in the customer identity domain.  

---
 
## 11. `MV` Column: A Rounded Duplicate, Not an Independent Metric
*(SQL: `02_data_quality_checks.sql` → 2.11)*
 
**Initial Finding:** The `" MV "` column (note: literal leading/trailing spaces in the column name) could not be directly cast to `NUMERIC` - it uses a thousands-separator comma and padding spaces (e.g. `" 1,350 "`).  
**Investigation:** After cleaning (`TRIM` + comma removal), one non-numeric pattern remained: the literal character `-`, found in 2,232 rows (0.38% of 584,524). Sample inspection showed these rows consistently have `price = 0` - `-` functions as a placeholder for zero in this column specifically (a fourth fake-value pattern, distinct from `''`, `\N`, and `#N/A`, and specific to this one column).  
**Hypothesis Testing:** Initially compared cleaned `MV` against `price * qty_ordered` directly - 8,334 rows (1.43%) did not match. Closer inspection of the mismatches showed `price` consistently carries more decimal precision than `MV` (e.g. `price = 1349.1` vs `MV = 1,349`).  
**Final Test:** Compared cleaned `MV` against `ROUND(price * qty_ordered)` - **0 mismatches** across the entire dataset.  
**Conclusion:** `MV` is not an independent metric - it is a **rounded, integer-precision duplicate** of `price * qty_ordered`, and is strictly less precise than computing the value directly.  
**Rule:** **Do not import `MV`.** Compute `order_items.gross_value = price * qty_ordered` directly from the already-validated `price`/`qty_ordered` fields. This also resolves the `-` placeholder automatically (rows with `price = 0` naturally yield `gross_value = 0`), without any special-case logic.
 
---

## 12. Test/QA Data Contamination in `sku`
*(SQL: `02_data_quality_checks.sql` → 2.12)*
 
**Context:** First noticed incidentally while sampling rows during the `MV` investigation (Section 11, Step C) - one sampled row had `sku = 'test-product'`. This prompted a systematic `\N` scope-check on `status`/`payment_method`/`sku` (closing the open question from Section 2) - `payment_method` and `sku` returned 0, but `status` returned 4 rows, all sharing the same `test-product`/`test-product-3` SKUs, confirming the pattern and triggering the full investigation below.  
**Finding:** A broad scan (`sku ILIKE '%test%'`) returned 28 distinct SKU values. Manual review confirmed 3 are genuine products where "test" appears incidentally within a real name (`SKMT_Blood Test`, `Aladdin_Test Star Cricket Ball - Red & White`, `sst_Vous Deteste-Regular fit-Medium`). The remaining 25 values (e.g. `test-product`, `test-product-3`, `test_tcsconnect`, `test bundle product...`, `AhadTest...`) are internal QA/test artifacts.  
**Materiality (item level):** 1,777 rows (0.30% of 584,524) match the confirmed test pattern.  
**Deeper Finding:** For 68 distinct `Customer ID`s, **100%** of their order history (201 orders total) consists exclusively of these test SKUs - these are not real customers who happened to receive a test item, but accounts used entirely for internal testing.  
**Materiality (order/customer level):** 201 / 408,782 orders ≈ 0.049%; 68 / 115,327 customers ≈ 0.059% - well below threshold; the internal process behind these test accounts was not investigated further.  
**Rule (three-level cascade):**
- `order_items` → exclude rows where `sku` matches the confirmed test pattern (25 values, excluding the 3 genuine products above)
- `orders` → exclude any `increment_id` left with zero items after the rule above
- `customers` → exclude the 68 `Customer ID`s left with zero orders after the rule above

---
 
## 13. `discount_amount`: Sign Convention and Order-vs-Item Level Ambiguity
*(SQL: `02_data_quality_checks.sql` → 2.13)*
 
**Finding - Inverted Sign Convention:** 3 rows have a negative `discount_amount`. Investigation showed `price + discount_amount = grand_total` for all 3 (e.g. `5995 + (-599.5) = 5395.5`) - not malformed data, but an inverted sign convention on a small subset. Rule: use `ABS(discount_amount)` in the revenue formula to neutralize both conventions.  
**Finding - Discount Exceeds Gross Value:** 9,713 rows have `ABS(discount_amount)` exceeding `price * qty_ordered`, which would produce negative net revenue under the standard per-item formula.  
**Investigation:** Tested two competing hypotheses against the 7,750 orders where `discount_amount` is identical across every item in a multi-item order (and non-zero):
- **Hypothesis 1 (order-level, mirrors `grand_total`'s behavior in Section 5):** discount applied once per order → `SUM(price*qty) - discount = grand_total`. Matched **5,137** orders.
- **Hypothesis 2 (genuinely per-item):** discount summed across items → `SUM(price*qty) - SUM(discount) = grand_total`. Matched **1,263** orders.
- **Residual:** **1,350** orders match neither formula. Sample inspection showed no consistent pattern - some rows even have `grand_total` exceeding gross value, suggesting unmodeled charges (e.g. shipping) are mixed into the field.

**Materiality (all relative to 408,782 total orders):**
- Order-level duplication: 5,137 ≈ 1.26%
- Standard per-item formula already correct: 1,263 ≈ 0.31%
- Unexplained residual: 1,350 ≈ 0.33%

All three groups are individually and collectively below the materiality threshold.
 
**Decision:** Retain the standard per-item formula (`price * qty_ordered - ABS(discount_amount)`) as-is for `order_items` - do not special-case any of the three groups. Order-level aggregates (AOV, monthly revenue trends) are **unaffected**, since they are derived directly from `orders.grand_total`, not from summing `order_items`. Only category/SKU-level revenue breakdowns carry a small, bounded, and now-documented margin of error for this subset of orders.  
 
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
| `customer_since` | No changes needed, zero conflicts found (one value per customer) |
| `customer_id` / `customer_since` | Nullable FK; triple `NULLIF(..., '\N'), '', '#N/A')`; `Customer Since` uses `YYYY-MM` format |
| Numeric fields | `price`, `discount_amount`, `grand_total` → `NUMERIC`; `qty_ordered` → `INTEGER` (validated safe to CAST, 0 malformed rows, 0 negative values) |
| ID column types | `item_id`, `Customer ID` → `BIGINT`; `increment_id` → `TEXT` (9 rows have a non-numeric `-1` suffix) |
| `MV` / gross value | Do not import `MV` - compute `order_items.gross_value = price * qty_ordered` directly |
| `discount_amount` | Use `ABS(discount_amount)` in the revenue formula; ~1.9% of multi-item orders (order-level duplication + unexplained residual) carry a small, documented item-level revenue discrepancy - order-level aggregates are unaffected |
| Test/QA data | Exclude `sku` matching the confirmed test pattern; cascades to exclude 201 orders and 68 fully-test customers |
| Service accounts | Exclude Customer IDs: 116, 11019, 30508, 35173, 44300 |
| customercredit / productcredit | Keep client/order, exclude the amount from financial metrics |
| Dates | Cast using: `TO_DATE(created_at, 'MM/DD/YYYY')` |
| `Working Date` | Do not transfer to OLTP - 100% duplicate of `created_at` |
 
---

## Side Business Insight (For the Marketing Section)

The distribution of payment methods reveals a heavy dominance of **Cash on Delivery (44.63%)** across all orders, significantly ahead of any electronic payment method (Payaxis at 16.61%, Easypay at 14.75%). This reflects a low level of trust in cashless transactions within the market during the data collection period (2016-2018) - providing a ready-made contextual insight for the report's section on customer payment behavior.