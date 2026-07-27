-- ================================================================
-- Script: 	01_setup_and_staging.sql
-- Purpose: Create project schemas and staging tables for raw data.
-- ================================================================

-- 1.1
-- Project schemas: separation of raw data, normalized (OLTP), 
-- and analytical (OLAP) models

CREATE SCHEMA staging; 	-- Raw data
CREATE SCHEMA oltp; 	-- For OLTP model
CREATE SCHEMA olap; 	-- For OLAP model

-- 1.2
-- Staging table: all columns are intentionally set to TEXT to guarantee 
-- error-free import of raw, unverified data without typing issues. 
-- Type casting (dates, numbers) is performed later during the normalization phase.

CREATE TABLE staging.pakistan_largest_ecommerce_dataset (
	item_id TEXT NULL,
	status TEXT NULL,
	created_at TEXT NULL,
	sku TEXT NULL,
	price TEXT NULL,
	qty_ordered TEXT NULL,
	grand_total TEXT NULL,
	increment_id TEXT NULL,
	category_name_1 TEXT NULL,
	sales_commission_code TEXT NULL,
	discount_amount TEXT NULL,
	payment_method TEXT NULL,
	"Working Date" TEXT NULL,
	"BI Status" TEXT NULL,
	" MV " TEXT NULL,
	"Year" TEXT NULL,
	"Month" TEXT NULL,
	"Customer Since" TEXT NULL,
	"M-Y" TEXT NULL,
	"FY" TEXT NULL,
	"Customer ID" TEXT NULL
);

-- 1.3 Optional Step
-- Data Loading:
-- Performed manually via DBeaver Data Transfer Wizard (Import Data).
-- Below is the SQL/CLI equivalent for reproducibility on any machine
-- (commented out as the file path is local and will vary).

-- NOTE: Uncomment (remove '--') from Option A OR Option B to execute.

-- Option A: Server-side COPY (Use if the CSV file is on the DB server or inside VM/Docker)
-- COPY staging.pakistan_largest_ecommerce_dataset 
-- FROM '/path/to/pakistan_largest_ecommerce_dataset.csv' 
-- WITH (FORMAT csv, HEADER true, NULL '');

-- Option B: Client-side \copy (run via native psql terminal - 
-- NOT supported in DBeaver SQL Editor, which uses JDBC and does not 
-- recognize psql meta-commands)
-- \copy staging.pakistan_largest_ecommerce_dataset
-- FROM '/path/to/pakistan_largest_ecommerce_dataset.csv' 
-- WITH (FORMAT csv, HEADER true, NULL '');