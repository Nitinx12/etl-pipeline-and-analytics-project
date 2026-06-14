-- ============================================================================
-- PROCEDURE : silver.load_silver_layer()
-- SCHEMA    : silver
-- LANGUAGE  : PL/pgSQL
--
-- PURPOSE
-- -------
-- Performs the Bronze → Silver ETL (Extract, Transform, Load) pipeline.
-- The Silver layer is the cleansed, standardised, and deduplicated version
-- of the raw Bronze data.  It is the trusted, query-ready layer consumed by
-- the Gold (reporting / analytics) layer.
--
-- This procedure processes 6 tables across 2 source systems (CRM and ERP),
-- applying data-quality rules to each before upserting into Silver.
--
-- SOURCE → TARGET MAP
-- -------------------
--   bronze.crm_cust_info      →  silver.crm_cust_info
--   bronze.crm_prd_info       →  silver.crm_prd_info
--   bronze.crm_sales_details  →  silver.crm_sales_details
--   bronze.erp_cust_az12      →  silver.erp_cust_az12
--   bronze.erp_loc_a101       →  silver.erp_loc_a101
--   bronze.erp_px_cat_g1v2    →  silver.erp_px_cat_g1v2
--
-- TRANSFORMATIONS APPLIED (per table)
-- ------------------------------------
--   crm_cust_info
--     • TRIM whitespace from name columns.
--     • Expand single-char codes → readable labels:
--         cst_marital_status : 'S' → 'Single'  | 'M' → 'Married' | else 'N/A'
--         cst_gndr           : 'F' → 'Female'  | 'M' → 'Male'    | else 'N/A'
--     • Deduplicate by cst_id keeping the row with the latest cst_create_date
--       (ROW_NUMBER PARTITION BY cst_id ORDER BY cst_create_date DESC).
--     • Filter out rows where cst_id IS NULL.
--
--   crm_prd_info
--     • Split prd_key: first 5 chars → cat_id (hyphens replaced with '_'),
--                      chars 7 onward → cleaned prd_key.
--     • Expand prd_line codes: 'M'→'Mountain', 'R'→'Road',
--                              'S'→'Other Sales', 'T'→'Touring', else 'N/A'.
--     • Derive prd_end_dt using LEAD() over prd_start_dt per prd_key (SCD logic:
--       a product version ends one day before the next version starts).
--     • Default NULL prd_cost to 0.
--     • Filter out rows where prd_id IS NULL.
--
--   crm_sales_details
--     • Convert integer date stamps (YYYYMMDD) to DATE; treat 0 or wrong-length
--       values as NULL.
--     • Recalculate sls_sales when it is NULL, ≤ 0, or inconsistent with
--       sls_quantity × ABS(sls_price).
--     • Recalculate sls_price when it is NULL or ≤ 0 using sls_sales / quantity.
--     • Filter out rows where sls_ord_num OR sls_prd_key IS NULL.
--
--   erp_cust_az12
--     • Strip leading 'NAS' prefix from cid where present.
--     • Nullify future birth dates (bdate > CURRENT_DATE).
--     • Expand gen codes: 'F'/'FEMALE' → 'Female', 'M'/'MALE' → 'Male',
--       else 'N/A'.
--     • Filter out rows where cid IS NULL.
--
--   erp_loc_a101
--     • Remove hyphens from cid.
--     • Standardise country codes: 'DE' → 'Germany',
--                                  'US'/'USA' → 'United States',
--                                  '' / NULL → 'N/A', else TRIM as-is.
--     • Filter out rows where cid IS NULL.
--
--   erp_px_cat_g1v2
--     • Pass-through with NULL id filter only; no further transformation needed.
--
-- LOAD STRATEGY — UPSERT (ON CONFLICT DO UPDATE)
-- -----------------------------------------------
-- Each table uses INSERT … ON CONFLICT DO UPDATE (a.k.a. UPSERT).
-- This means:
--   • New rows are inserted.
--   • Existing rows (matched by primary key) are updated to the latest values.
--   • The table is NEVER truncated, so historical rows not present in the
--     current Bronze batch are preserved.
-- Conflict keys:
--   crm_cust_info      → (cst_id)
--   crm_prd_info       → (prd_id)
--   crm_sales_details  → (sls_ord_num, sls_prd_key)
--   erp_cust_az12      → (cid)
--   erp_loc_a101       → (cid)
--   erp_px_cat_g1v2    → (id)
--
-- ERROR HANDLING
-- --------------
-- Each table is wrapped in its own BEGIN … EXCEPTION … END block.
-- A failure in one table is caught, logged, and reported — then the pipeline
-- continues to the next table rather than aborting the whole run.
-- Both success and failure outcomes are recorded in silver.etl_log.
--
-- LOGGING — silver.etl_log
-- -------------------------
-- Every table step writes one row to silver.etl_log containing:
--   procedure_name, table_name, rows_affected,
--   step_start, step_end, duration_seconds, status ('SUCCESS'/'FAILED'),
--   error_message (NULL on success, SQLERRM on failure).
--
-- HOW TO USE
-- ----------
-- Prerequisites:
--   • bronze schema tables must be populated (run bronze.load_bronze() first).
--   • silver schema tables and silver.etl_log must already exist.
--   • Primary key / unique constraints on the conflict columns must be in place.
--
-- Execute:
--   CALL silver.load_silver_layer();
--
-- Monitor progress (in psql):
--   \set VERBOSITY verbose
--   CALL silver.load_silver_layer();
--
-- Review the log after the run:
--   SELECT * FROM silver.etl_log ORDER BY step_start DESC;
--
-- REVISION HISTORY
-- ----------------
-- 2026-06-14  Initial version.  Incremental upsert replacing prior TRUNCATE
--             approach.  Per-table exception handling added.  etl_log wired in.
-- ============================================================================

CREATE OR REPLACE PROCEDURE silver.load_silver_layer()
LANGUAGE plpgsql
AS $$
DECLARE
    -- Pipeline-level timestamps (total wall-clock time for the whole run)
    v_pipeline_start TIMESTAMP;
    v_pipeline_end   TIMESTAMP;

    -- Step-level timestamps (wall-clock time for each individual table)
    v_step_start     TIMESTAMP;
    v_step_end       TIMESTAMP;

    -- Row counter reused for each table (INSERT … ON CONFLICT returns affected rows)
    v_rows           INT;
BEGIN
    v_pipeline_start := clock_timestamp();

    RAISE NOTICE '=================================================================';
    RAISE NOTICE 'SILVER PIPELINE STARTED';
    RAISE NOTICE 'Started at : %', TO_CHAR(v_pipeline_start, 'YYYY-MM-DD HH24:MI:SS');
    RAISE NOTICE '=================================================================';
    RAISE NOTICE '';

    -- ==========================================================================
    --  CRM TABLES
    --  Source: CRM system  |  3 tables
    -- ==========================================================================

    RAISE NOTICE '-----------------------------------------------------------------';
    RAISE NOTICE 'CRM SOURCE TABLES (1 of 2 groups)';
    RAISE NOTICE '-----------------------------------------------------------------';

    --------------------------------------------------------------------------
    -- [1/6] CRM CUSTOMER INFO
    --
    -- Source  : bronze.crm_cust_info
    -- Target  : silver.crm_cust_info
    -- Key     : cst_id (conflict key for upsert)
    --
    -- Transforms applied:
    --   • TRIM cst_first_name and cst_last_name (removes leading/trailing spaces)
    --   • Expand cst_marital_status codes:
    --       'S' → 'Single'  |  'M' → 'Married'  |  anything else → 'N/A'
    --   • Expand cst_gndr codes:
    --       'F' → 'Female'  |  'M' → 'Male'      |  anything else → 'N/A'
    --   • Deduplicate: for customers with multiple rows (e.g. re-loads),
    --     keep only the row with the most recent cst_create_date using
    --     ROW_NUMBER() PARTITION BY cst_id ORDER BY cst_create_date DESC.
    --   • Quality gate: skip rows where cst_id IS NULL.
    --------------------------------------------------------------------------
    BEGIN
        v_step_start := clock_timestamp();

        INSERT INTO silver.crm_cust_info (
            cst_id,
            cst_key,
            cst_first_name,
            cst_last_name,
            cst_marital_status,
            cst_gndr,
            cst_create_date
        )
        SELECT
            cst_id,
            cst_key,
            TRIM(cst_first_name),                               -- remove padding spaces
            TRIM(cst_last_name),
            CASE
                WHEN UPPER(TRIM(cst_marital_status)) = 'S' THEN 'Single'
                WHEN UPPER(TRIM(cst_marital_status)) = 'M' THEN 'Married'
                ELSE 'N/A'                                      -- unknown / blank codes
            END,
            CASE
                WHEN UPPER(TRIM(cst_gndr)) = 'F' THEN 'Female'
                WHEN UPPER(TRIM(cst_gndr)) = 'M' THEN 'Male'
                ELSE 'N/A'
            END,
            cst_create_date::DATE
        FROM (
            -- Dedup subquery: rank rows per customer by most-recent create date
            SELECT *,
                ROW_NUMBER() OVER (
                    PARTITION BY cst_id
                    ORDER BY cst_create_date DESC
                ) AS rnk
            FROM bronze.crm_cust_info
            WHERE cst_id IS NOT NULL                            -- quality gate: skip NULL PKs
        ) X
        WHERE rnk = 1                                           -- keep only the latest record
        ON CONFLICT (cst_id)
        DO UPDATE SET
            cst_key            = EXCLUDED.cst_key,
            cst_first_name     = EXCLUDED.cst_first_name,
            cst_last_name      = EXCLUDED.cst_last_name,
            cst_marital_status = EXCLUDED.cst_marital_status,
            cst_gndr           = EXCLUDED.cst_gndr,
            cst_create_date    = EXCLUDED.cst_create_date;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_step_end := clock_timestamp();

        -- Log success
        INSERT INTO silver.etl_log
        VALUES (DEFAULT, 'load_silver_layer', 'crm_cust_info',
                v_rows, v_step_start, v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'SUCCESS', NULL);

        RAISE NOTICE '[1/6] silver.crm_cust_info';
        RAISE NOTICE '      Rows Upserted : %', v_rows;
        RAISE NOTICE '      Duration      : % seconds',
                     ROUND(EXTRACT(EPOCH FROM v_step_end - v_step_start)::NUMERIC, 3);
        RAISE NOTICE '';

    EXCEPTION WHEN OTHERS THEN
        -- Log failure and continue to next table (pipeline does NOT abort)
        v_step_end := clock_timestamp();
        INSERT INTO silver.etl_log
        VALUES (DEFAULT, 'load_silver_layer', 'crm_cust_info',
                0, v_step_start, v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'FAILED', SQLERRM);

        RAISE NOTICE '[1/6] silver.crm_cust_info  *** FAILED ***';
        RAISE NOTICE '      Error : %', SQLERRM;
        RAISE NOTICE '';
    END;

    --------------------------------------------------------------------------
    -- [2/6] CRM PRODUCT INFO
    --
    -- Source  : bronze.crm_prd_info
    -- Target  : silver.crm_prd_info
    -- Key     : prd_id (conflict key for upsert)
    --
    -- Transforms applied:
    --   • Split prd_key into two derived columns:
    --       cat_id  : first 5 chars of prd_key with hyphens replaced by '_'
    --                 e.g. 'AC-HE-HL-U509-R' → 'AC_HE'
    --       prd_key : characters from position 7 onward (the product portion)
    --                 e.g. 'AC-HE-HL-U509-R' → 'HL-U509-R'
    --   • Expand prd_line codes:
    --       'M' → 'Mountain'  |  'R' → 'Road'  |  'S' → 'Other Sales'
    --       'T' → 'Touring'   |  anything else  → 'N/A'
    --   • Derive prd_end_dt with LEAD() window function:
    --       A product version ends one day before the next version of the same
    --       product starts (Slowly Changing Dimension type-2 style date range).
    --       The last/current version gets NULL as prd_end_dt (open-ended).
    --   • Default NULL prd_cost to 0 (COALESCE).
    --   • Quality gate: skip rows where prd_id IS NULL.
    --------------------------------------------------------------------------
    BEGIN
        v_step_start := clock_timestamp();

        INSERT INTO silver.crm_prd_info (
            prd_id,
            prd_key,
            cat_id,
            prd_nm,
            prd_cost,
            prd_line,
            prd_start_dt,
            prd_end_dt
        )
        SELECT
            prd_id,
            -- Extract the product-specific suffix (from char 7 onward)
            SUBSTRING(prd_key FROM 7)                           AS prd_key,
            -- Extract and normalise the category prefix (first 5 chars)
            REPLACE(SUBSTRING(prd_key FROM 1 FOR 5), '-', '_') AS cat_id,
            prd_nm,
            COALESCE(prd_cost, 0),                              -- treat NULL cost as 0
            CASE
                WHEN UPPER(TRIM(prd_line)) = 'M' THEN 'Mountain'
                WHEN UPPER(TRIM(prd_line)) = 'R' THEN 'Road'
                WHEN UPPER(TRIM(prd_line)) = 'S' THEN 'Other Sales'
                WHEN UPPER(TRIM(prd_line)) = 'T' THEN 'Touring'
                ELSE 'N/A'
            END                                                 AS prd_line,
            prd_start_dt::DATE,
            -- SCD end-date: one day before the NEXT version's start date
            -- NULL for the latest / current version (open-ended range)
            CAST(
                LEAD(prd_start_dt) OVER (
                    PARTITION BY prd_key
                    ORDER BY prd_start_dt
                ) - 1
            AS DATE)                                            AS prd_end_dt
        FROM bronze.crm_prd_info
        WHERE prd_id IS NOT NULL                                -- quality gate: skip NULL PKs
        ON CONFLICT (prd_id)
        DO UPDATE SET
            prd_key      = EXCLUDED.prd_key,
            cat_id       = EXCLUDED.cat_id,
            prd_nm       = EXCLUDED.prd_nm,
            prd_cost     = EXCLUDED.prd_cost,
            prd_line     = EXCLUDED.prd_line,
            prd_start_dt = EXCLUDED.prd_start_dt,
            prd_end_dt   = EXCLUDED.prd_end_dt;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_step_end := clock_timestamp();

        INSERT INTO silver.etl_log
        VALUES (DEFAULT, 'load_silver_layer', 'crm_prd_info',
                v_rows, v_step_start, v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'SUCCESS', NULL);

        RAISE NOTICE '[2/6] silver.crm_prd_info';
        RAISE NOTICE '      Rows Upserted : %', v_rows;
        RAISE NOTICE '      Duration      : % seconds',
                     ROUND(EXTRACT(EPOCH FROM v_step_end - v_step_start)::NUMERIC, 3);
        RAISE NOTICE '';

    EXCEPTION WHEN OTHERS THEN
        v_step_end := clock_timestamp();
        INSERT INTO silver.etl_log
        VALUES (DEFAULT, 'load_silver_layer', 'crm_prd_info',
                0, v_step_start, v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'FAILED', SQLERRM);

        RAISE NOTICE '[2/6] silver.crm_prd_info  *** FAILED ***';
        RAISE NOTICE '      Error : %', SQLERRM;
        RAISE NOTICE '';
    END;

    --------------------------------------------------------------------------
    -- [3/6] CRM SALES DETAILS
    --
    -- Source  : bronze.crm_sales_details
    -- Target  : silver.crm_sales_details
    -- Key     : (sls_ord_num, sls_prd_key) composite conflict key
    --
    -- Transforms applied:
    --   • Date conversion for sls_order_dt, sls_ship_date, sls_due_date:
    --       Stored in Bronze as INTEGER in YYYYMMDD format.
    --       If the value is 0 or not exactly 8 digits → NULL (invalid date).
    --       Otherwise → TO_DATE(value::TEXT, 'YYYYMMDD').
    --   • Sales integrity fix (sls_sales):
    --       If sls_sales is NULL, ≤ 0, or does not equal sls_quantity × |price|,
    --       recalculate as sls_quantity × ABS(sls_price).
    --       This corrects sign errors and missing values in the source data.
    --   • Price integrity fix (sls_price):
    --       If sls_price is NULL or ≤ 0, derive it as sls_sales / sls_quantity
    --       (using NULLIF to avoid division-by-zero).
    --       Otherwise keep the original value.
    --   • Quality gate: skip rows where sls_ord_num OR sls_prd_key IS NULL.
    --------------------------------------------------------------------------
    BEGIN
        v_step_start := clock_timestamp();

        INSERT INTO silver.crm_sales_details (
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            sls_order_dt,
            sls_ship_date,
            sls_due_date,
            sls_sales,
            sls_quantity,
            sls_price
        )
        SELECT
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            -- Convert YYYYMMDD integer to DATE; treat 0 or malformed values as NULL
            CASE
                WHEN sls_order_dt = 0
                  OR LENGTH(sls_order_dt::TEXT) <> 8 THEN NULL
                ELSE TO_DATE(sls_order_dt::TEXT, 'YYYYMMDD')
            END                                                 AS sls_order_dt,
            CASE
                WHEN sls_ship_date = 0
                  OR LENGTH(sls_ship_date::TEXT) <> 8 THEN NULL
                ELSE TO_DATE(sls_ship_date::TEXT, 'YYYYMMDD')
            END                                                 AS sls_ship_date,
            CASE
                WHEN sls_due_date = 0
                  OR LENGTH(sls_due_date::TEXT) <> 8 THEN NULL
                ELSE TO_DATE(sls_due_date::TEXT, 'YYYYMMDD')
            END                                                 AS sls_due_date,
            -- Recalculate sls_sales if it is missing, zero, negative, or inconsistent
            CASE
                WHEN sls_price IS NULL
                  OR sls_sales <= 0
                  OR sls_sales <> sls_quantity * ABS(sls_price)
                THEN sls_quantity * ABS(sls_price)
                ELSE sls_sales
            END                                                 AS sls_sales,
            sls_quantity,
            -- Recalculate sls_price if it is missing or non-positive
            CASE
                WHEN sls_price IS NULL OR sls_price <= 0
                THEN sls_sales / NULLIF(sls_quantity, 0)        -- avoid division-by-zero
                ELSE sls_price
            END                                                 AS sls_price
        FROM bronze.crm_sales_details
        WHERE sls_ord_num  IS NOT NULL                          -- quality gate: both
          AND sls_prd_key  IS NOT NULL                          --   key parts must exist
        ON CONFLICT (sls_ord_num, sls_prd_key)
        DO UPDATE SET
            sls_cust_id   = EXCLUDED.sls_cust_id,
            sls_order_dt  = EXCLUDED.sls_order_dt,
            sls_ship_date = EXCLUDED.sls_ship_date,
            sls_due_date  = EXCLUDED.sls_due_date,
            sls_sales     = EXCLUDED.sls_sales,
            sls_quantity  = EXCLUDED.sls_quantity,
            sls_price     = EXCLUDED.sls_price;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_step_end := clock_timestamp();

        INSERT INTO silver.etl_log
        VALUES (DEFAULT, 'load_silver_layer', 'crm_sales_details',
                v_rows, v_step_start, v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'SUCCESS', NULL);

        RAISE NOTICE '[3/6] silver.crm_sales_details';
        RAISE NOTICE '      Rows Upserted : %', v_rows;
        RAISE NOTICE '      Duration      : % seconds',
                     ROUND(EXTRACT(EPOCH FROM v_step_end - v_step_start)::NUMERIC, 3);
        RAISE NOTICE '';

    EXCEPTION WHEN OTHERS THEN
        v_step_end := clock_timestamp();
        INSERT INTO silver.etl_log
        VALUES (DEFAULT, 'load_silver_layer', 'crm_sales_details',
                0, v_step_start, v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'FAILED', SQLERRM);

        RAISE NOTICE '[3/6] silver.crm_sales_details  *** FAILED ***';
        RAISE NOTICE '      Error : %', SQLERRM;
        RAISE NOTICE '';
    END;

    -- ==========================================================================
    --  ERP TABLES
    --  Source: ERP system  |  3 tables
    -- ==========================================================================

    RAISE NOTICE '-----------------------------------------------------------------';
    RAISE NOTICE 'ERP SOURCE TABLES (2 of 2 groups)';
    RAISE NOTICE '-----------------------------------------------------------------';

    --------------------------------------------------------------------------
    -- [4/6] ERP CUSTOMER AZ12
    --
    -- Source  : bronze.erp_cust_az12
    -- Target  : silver.erp_cust_az12
    -- Key     : cid (conflict key for upsert)
    --
    -- Transforms applied:
    --   • Strip 'NAS' prefix from cid where present (legacy ERP formatting):
    --       'NAS-AW00011000' → 'AW00011000'
    --   • Nullify future birth dates: bdate > CURRENT_DATE → NULL
    --       (data entry error; a customer cannot be born in the future).
    --   • Expand gen codes (multiple spellings handled):
    --       'F' or 'FEMALE' → 'Female'
    --       'M' or 'MALE'   → 'Male'
    --       anything else   → 'N/A'
    --   • Quality gate: skip rows where cid IS NULL.
    --------------------------------------------------------------------------
    BEGIN
        v_step_start := clock_timestamp();

        INSERT INTO silver.erp_cust_az12 (cid, bdate, gen)
        SELECT
            -- Remove 'NAS' prefix if present (ERP legacy formatting artefact)
            CASE
                WHEN cid LIKE 'NAS%' THEN SUBSTRING(cid FROM 4)
                ELSE cid
            END                                                 AS cid,
            -- Future dates are impossible for birth dates — set to NULL
            CASE
                WHEN bdate > CURRENT_DATE THEN NULL
                ELSE bdate
            END                                                 AS bdate,
            -- Standardise gender regardless of abbreviation or full word in source
            CASE
                WHEN UPPER(TRIM(gen)) IN ('F', 'FEMALE') THEN 'Female'
                WHEN UPPER(TRIM(gen)) IN ('M', 'MALE')   THEN 'Male'
                ELSE 'N/A'
            END                                                 AS gen
        FROM bronze.erp_cust_az12
        WHERE cid IS NOT NULL                                   -- quality gate: skip NULL PKs
        ON CONFLICT (cid)
        DO UPDATE SET
            bdate = EXCLUDED.bdate,
            gen   = EXCLUDED.gen;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_step_end := clock_timestamp();

        INSERT INTO silver.etl_log
        VALUES (DEFAULT, 'load_silver_layer', 'erp_cust_az12',
                v_rows, v_step_start, v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'SUCCESS', NULL);

        RAISE NOTICE '[4/6] silver.erp_cust_az12';
        RAISE NOTICE '      Rows Upserted : %', v_rows;
        RAISE NOTICE '      Duration      : % seconds',
                     ROUND(EXTRACT(EPOCH FROM v_step_end - v_step_start)::NUMERIC, 3);
        RAISE NOTICE '';

    EXCEPTION WHEN OTHERS THEN
        v_step_end := clock_timestamp();
        INSERT INTO silver.etl_log
        VALUES (DEFAULT, 'load_silver_layer', 'erp_cust_az12',
                0, v_step_start, v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'FAILED', SQLERRM);

        RAISE NOTICE '[4/6] silver.erp_cust_az12  *** FAILED ***';
        RAISE NOTICE '      Error : %', SQLERRM;
        RAISE NOTICE '';
    END;

    --------------------------------------------------------------------------
    -- [5/6] ERP LOCATION A101
    --
    -- Source  : bronze.erp_loc_a101
    -- Target  : silver.erp_loc_a101
    -- Key     : cid (conflict key for upsert)
    --
    -- Transforms applied:
    --   • Remove hyphens from cid to normalise the key format:
    --       'AW-00011000' → 'AW00011000'  (matches CRM customer ID format)
    --   • Standardise country values:
    --       'DE'        → 'Germany'
    --       'US'/'USA'  → 'United States'
    --       '' / NULL   → 'N/A'
    --       anything else → TRIM(cntry) as-is  (already a full name)
    --   • Quality gate: skip rows where cid IS NULL.
    --------------------------------------------------------------------------
    BEGIN
        v_step_start := clock_timestamp();

        INSERT INTO silver.erp_loc_a101 (cid, cntry)
        SELECT
            -- Normalise cid: strip hyphens so it joins cleanly with CRM keys
            REPLACE(cid, '-', '')                               AS cid,
            CASE
                WHEN TRIM(cntry) = 'DE'              THEN 'Germany'
                WHEN TRIM(cntry) IN ('US', 'USA')    THEN 'United States'
                WHEN TRIM(cntry) = '' OR cntry IS NULL THEN 'N/A'
                ELSE TRIM(cntry)                                -- keep recognised full names
            END                                                 AS cntry
        FROM bronze.erp_loc_a101
        WHERE cid IS NOT NULL                                   -- quality gate: skip NULL PKs
        ON CONFLICT (cid)
        DO UPDATE SET
            cntry = EXCLUDED.cntry;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_step_end := clock_timestamp();

        INSERT INTO silver.etl_log
        VALUES (DEFAULT, 'load_silver_layer', 'erp_loc_a101',
                v_rows, v_step_start, v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'SUCCESS', NULL);

        RAISE NOTICE '[5/6] silver.erp_loc_a101';
        RAISE NOTICE '      Rows Upserted : %', v_rows;
        RAISE NOTICE '      Duration      : % seconds',
                     ROUND(EXTRACT(EPOCH FROM v_step_end - v_step_start)::NUMERIC, 3);
        RAISE NOTICE '';

    EXCEPTION WHEN OTHERS THEN
        v_step_end := clock_timestamp();
        INSERT INTO silver.etl_log
        VALUES (DEFAULT, 'load_silver_layer', 'erp_loc_a101',
                0, v_step_start, v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'FAILED', SQLERRM);

        RAISE NOTICE '[5/6] silver.erp_loc_a101  *** FAILED ***';
        RAISE NOTICE '      Error : %', SQLERRM;
        RAISE NOTICE '';
    END;

    --------------------------------------------------------------------------
    -- [6/6] ERP PRODUCT CATEGORY G1V2
    --
    -- Source  : bronze.erp_px_cat_g1v2
    -- Target  : silver.erp_px_cat_g1v2
    -- Key     : id (conflict key for upsert)
    --
    -- Transforms applied:
    --   • Pass-through: no value-level transformation is required for this
    --     reference/lookup table.  The only action is the NULL id filter.
    --   • Quality gate: skip rows where id IS NULL.
    --
    -- Note: the Silver target column is named 'subcate' (not 'subcat') to
    -- match the existing DDL; the source Bronze column is 'subcat'.
    --------------------------------------------------------------------------
    BEGIN
        v_step_start := clock_timestamp();

        INSERT INTO silver.erp_px_cat_g1v2 (id, cat, subcate, maintenance)
        SELECT
            id,
            cat,
            subcat,         -- Bronze column 'subcat' maps to Silver column 'subcate'
            maintenance
        FROM bronze.erp_px_cat_g1v2
        WHERE id IS NOT NULL                                    -- quality gate: skip NULL PKs
        ON CONFLICT (id)
        DO UPDATE SET
            cat         = EXCLUDED.cat,
            subcate     = EXCLUDED.subcate,
            maintenance = EXCLUDED.maintenance;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_step_end := clock_timestamp();

        INSERT INTO silver.etl_log
        VALUES (DEFAULT, 'load_silver_layer', 'erp_px_cat_g1v2',
                v_rows, v_step_start, v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'SUCCESS', NULL);

        RAISE NOTICE '[6/6] silver.erp_px_cat_g1v2';
        RAISE NOTICE '      Rows Upserted : %', v_rows;
        RAISE NOTICE '      Duration      : % seconds',
                     ROUND(EXTRACT(EPOCH FROM v_step_end - v_step_start)::NUMERIC, 3);
        RAISE NOTICE '';

    EXCEPTION WHEN OTHERS THEN
        v_step_end := clock_timestamp();
        INSERT INTO silver.etl_log
        VALUES (DEFAULT, 'load_silver_layer', 'erp_px_cat_g1v2',
                0, v_step_start, v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'FAILED', SQLERRM);

        RAISE NOTICE '[6/6] silver.erp_px_cat_g1v2  *** FAILED ***';
        RAISE NOTICE '      Error : %', SQLERRM;
        RAISE NOTICE '';
    END;

    -- ==========================================================================
    --  PIPELINE COMPLETE
    -- ==========================================================================

    v_pipeline_end := clock_timestamp();

    RAISE NOTICE '=================================================================';
    RAISE NOTICE 'SILVER PIPELINE COMPLETE';
    RAISE NOTICE 'Total Duration : % seconds',
                 ROUND(EXTRACT(EPOCH FROM v_pipeline_end - v_pipeline_start)::NUMERIC, 3);
    RAISE NOTICE 'Completed at   : %', TO_CHAR(v_pipeline_end, 'YYYY-MM-DD HH24:MI:SS');
    RAISE NOTICE '=================================================================';
    RAISE NOTICE 'Review the run:';
    RAISE NOTICE '  SELECT * FROM silver.etl_log ORDER BY step_start DESC LIMIT 6;';
    RAISE NOTICE '=================================================================';

END;
$$;