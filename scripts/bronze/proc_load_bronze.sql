-- ============================================================================
-- PROCEDURE : bronze.load_bronze()
-- SCHEMA    : bronze
-- LANGUAGE  : PL/pgSQL
--
-- PURPOSE
-- -------
-- Loads raw source data from flat CSV files into the Bronze layer of the
-- data warehouse.  The Bronze layer is the landing zone — data is ingested
-- exactly as it arrives from the source systems (CRM and ERP) with minimal
-- transformation.  The only change applied at this stage is replacing any
-- pre-existing ingested_at timestamp from the CSV with a fresh
-- CURRENT_TIMESTAMP so every row carries an accurate load time.
--
-- The procedure handles two source system groups:
--   • CRM  — Customer, Product, and Sales data   (tables 1–3)
--   • ERP  — Customer, Location, and Category data (tables 4–6)
--
-- DESIGN PATTERN
-- --------------
-- Each table follows the same three-step pattern:
--   1. CREATE TEMP TABLE  — all columns declared as VARCHAR so PostgreSQL's
--                           COPY command accepts any raw string from the CSV
--                           without type-conversion errors (e.g. "11000.0"
--                           arriving for an INTEGER column).
--   2. COPY               — bulk-loads the CSV into the temp table as-is.
--                           No column list is specified so the number of
--                           columns always matches the CSV exactly.
--   3. INSERT … SELECT    — casts each column to its correct target type
--                           (::NUMERIC::INTEGER for float-string IDs, ::DATE
--                           for dates, ::NUMERIC for amounts) and inserts only
--                           rows that do not already exist in the Bronze table
--                           (idempotent / incremental load via NOT EXISTS).
--
-- IDEMPOTENCY
-- -----------
-- The procedure is safe to re-run.  A NOT EXISTS guard on each table's
-- natural key (cst_id, prd_id, sls_ord_num, cid, id) prevents duplicate
-- rows from being inserted on subsequent runs.
--
-- ERROR HANDLING
-- --------------
-- Any unhandled exception is caught by the EXCEPTION block, which logs the
-- error message and SQL state via RAISE NOTICE before re-raising so the
-- caller sees the original error.  All temp tables are session-scoped and are
-- dropped explicitly after each load step to avoid conflicts if the session
-- is reused.
--
-- LOGGING
-- -------
-- Progress and summary information is emitted via RAISE NOTICE at three
-- levels:
--   • Per-table  — rows inserted and duration for each of the 6 tables.
--   • Per-group  — subtotal rows and duration for CRM and ERP groups.
--   • Grand summary — full row breakdown and total elapsed time.
--
-- HOW TO USE
-- ----------
-- Prerequisites:
--   • The bronze schema and all six target tables must already exist.
--   • The CSV files must be accessible on the PostgreSQL server at the
--     paths listed in each COPY statement.
--   • The PostgreSQL superuser (or a role with the pg_read_server_files
--     privilege) must execute this procedure.
--
-- Execute:
--   CALL bronze.load_bronze();
--
-- View output:
--   In psql run:  \set VERBOSITY verbose
--   In pgAdmin / DBeaver the Messages / Notices tab shows all RAISE NOTICE
--   output after the call completes.
--
-- CSV FILE LOCATIONS (server-side paths)
-- ----------------------------------------
--   CRM:
--     C:\postgres_data\cust_info.csv       -> bronze.crm_cust_info
--     C:\postgres_data\prd_info.csv        -> bronze.crm_prd_info
--     C:\postgres_data\sales_details.csv   -> bronze.crm_sales_details
--   ERP:
--     C:\postgres_data\CUST_AZ12.csv       -> bronze.erp_cust_az12
--     C:\postgres_data\LOC_A101.csv        -> bronze.erp_loc_a101
--     C:\postgres_data\PX_CAT_G1V2.csv     -> bronze.erp_px_cat_g1v2
--
-- REVISION HISTORY
-- ----------------
-- 2026-06-14  Initial version created.
--             Fix: all staging columns declared VARCHAR to avoid COPY
--             type-conversion errors (22P02 / 22P04) on float-string IDs.
-- ============================================================================

CREATE OR REPLACE PROCEDURE bronze.load_bronze()
LANGUAGE plpgsql
AS $$
DECLARE
    -- Timestamps
    v_proc_start        TIMESTAMP;
    v_proc_end          TIMESTAMP;
    v_table_start       TIMESTAMP;
    v_table_end         TIMESTAMP;

    -- CRM group timing
    v_crm_start         TIMESTAMP;
    v_crm_end           TIMESTAMP;

    -- ERP group timing
    v_erp_start         TIMESTAMP;
    v_erp_end           TIMESTAMP;

    -- Per-table row counters
    v_rows_crm_cust     INT := 0;
    v_rows_crm_prd      INT := 0;
    v_rows_crm_sales    INT := 0;
    v_rows_erp_cust     INT := 0;
    v_rows_erp_loc      INT := 0;
    v_rows_erp_cat      INT := 0;

    -- Group & total counters
    v_total_crm         INT := 0;
    v_total_erp         INT := 0;
    v_grand_total       INT := 0;
BEGIN

    v_proc_start := clock_timestamp();

    RAISE NOTICE '========================================';
    RAISE NOTICE 'Loading Bronze Layer';
    RAISE NOTICE 'Started at: %', TO_CHAR(v_proc_start, 'YYYY-MM-DD HH24:MI:SS');
    RAISE NOTICE '========================================';

    -- =========================================================================
    --  CRM TABLES
    -- =========================================================================

    v_crm_start := clock_timestamp();

    RAISE NOTICE '';
    RAISE NOTICE '----------------------------------------';
    RAISE NOTICE 'CRM SOURCE TABLES';
    RAISE NOTICE '----------------------------------------';

    ----------------------------------------------------------------------------
    -- [1/6] CRM CUSTOMER INFO
    -- All columns VARCHAR in staging so COPY accepts any raw value from the CSV.
    -- Numeric casts happen in INSERT SELECT; ingested_at is overwritten there too.
    ----------------------------------------------------------------------------

    v_table_start := clock_timestamp();

    CREATE TEMP TABLE stg_crm_cust_info (
        cst_id             VARCHAR(50),
        cst_key            VARCHAR(50),
        cst_first_name     VARCHAR(50),
        cst_last_name      VARCHAR(50),
        cst_marital_status VARCHAR(50),
        cst_gndr           VARCHAR(50),
        cst_create_date    VARCHAR(50),
        ingested_at        VARCHAR(50)   -- CSV already has this column; we discard it
    );

    -- No column list: COPY reads ALL 8 columns from the CSV as-is
    COPY stg_crm_cust_info
    FROM 'C:\postgres_data\cust_info.csv'
    DELIMITER ',' CSV HEADER;

    INSERT INTO bronze.crm_cust_info (
        cst_id,
        cst_key,
        cst_first_name,
        cst_last_name,
        cst_marital_status,
        cst_gndr,
        cst_create_date,
        ingested_at
    )
    SELECT
        cst_id::NUMERIC::INTEGER,
        cst_key,
        cst_first_name,
        cst_last_name,
        cst_marital_status,
        cst_gndr,
        cst_create_date::DATE,
        CURRENT_TIMESTAMP          -- fresh audit timestamp, not the CSV value
    FROM stg_crm_cust_info s
    WHERE NOT EXISTS (
        SELECT 1
        FROM bronze.crm_cust_info b
        WHERE b.cst_id = s.cst_id::NUMERIC::INTEGER
    );

    GET DIAGNOSTICS v_rows_crm_cust = ROW_COUNT;
    DROP TABLE stg_crm_cust_info;

    v_table_end := clock_timestamp();
    RAISE NOTICE '[1/6] bronze.crm_cust_info';
    RAISE NOTICE '      Rows Inserted : %', v_rows_crm_cust;
    RAISE NOTICE '      Duration      : %', v_table_end - v_table_start;
    RAISE NOTICE '';

    ----------------------------------------------------------------------------
    -- [2/6] CRM PRODUCT INFO
    ----------------------------------------------------------------------------

    v_table_start := clock_timestamp();

    CREATE TEMP TABLE stg_crm_prd_info (
        prd_id       VARCHAR(50),
        prd_key      VARCHAR(50),
        prd_nm       VARCHAR(50),
        prd_cost     VARCHAR(50),
        prd_line     VARCHAR(50),
        prd_start_dt VARCHAR(50),
        prd_end_dt   VARCHAR(50),
        ingested_at  VARCHAR(50)
    );

    COPY stg_crm_prd_info
    FROM 'C:\postgres_data\prd_info.csv'
    DELIMITER ',' CSV HEADER;

    INSERT INTO bronze.crm_prd_info (
        prd_id,
        prd_key,
        prd_nm,
        prd_cost,
        prd_line,
        prd_start_dt,
        prd_end_dt,
        ingested_at
    )
    SELECT
        prd_id::NUMERIC::INTEGER,
        prd_key,
        prd_nm,
        prd_cost::NUMERIC,
        prd_line,
        prd_start_dt::DATE,
        prd_end_dt::DATE,
        CURRENT_TIMESTAMP
    FROM stg_crm_prd_info s
    WHERE NOT EXISTS (
        SELECT 1
        FROM bronze.crm_prd_info b
        WHERE b.prd_id = s.prd_id::NUMERIC::INTEGER
    );

    GET DIAGNOSTICS v_rows_crm_prd = ROW_COUNT;
    DROP TABLE stg_crm_prd_info;

    v_table_end := clock_timestamp();
    RAISE NOTICE '[2/6] bronze.crm_prd_info';
    RAISE NOTICE '      Rows Inserted : %', v_rows_crm_prd;
    RAISE NOTICE '      Duration      : %', v_table_end - v_table_start;
    RAISE NOTICE '';

    ----------------------------------------------------------------------------
    -- [3/6] CRM SALES DETAILS
    ----------------------------------------------------------------------------

    v_table_start := clock_timestamp();

    CREATE TEMP TABLE stg_crm_sales_details (
        sls_ord_num   VARCHAR(50),
        sls_prd_key   VARCHAR(50),
        sls_cust_id   VARCHAR(50),
        sls_order_dt  VARCHAR(50),
        sls_ship_date VARCHAR(50),
        sls_due_date  VARCHAR(50),
        sls_sales     VARCHAR(50),
        sls_quantity  VARCHAR(50),
        sls_price     VARCHAR(50),
        ingested_at   VARCHAR(50)
    );

    COPY stg_crm_sales_details
    FROM 'C:\postgres_data\sales_details.csv'
    DELIMITER ',' CSV HEADER;

    INSERT INTO bronze.crm_sales_details (
        sls_ord_num,
        sls_prd_key,
        sls_cust_id,
        sls_order_dt,
        sls_ship_date,
        sls_due_date,
        sls_sales,
        sls_quantity,
        sls_price,
        ingested_at
    )
    SELECT
        sls_ord_num,
        sls_prd_key,
        sls_cust_id::NUMERIC::INTEGER,
        sls_order_dt::NUMERIC::INTEGER,
        sls_ship_date::NUMERIC::INTEGER,
        sls_due_date::NUMERIC::INTEGER,
        sls_sales::NUMERIC,
        sls_quantity::NUMERIC::INTEGER,
        sls_price::NUMERIC,
        CURRENT_TIMESTAMP
    FROM stg_crm_sales_details s
    WHERE NOT EXISTS (
        SELECT 1
        FROM bronze.crm_sales_details b
        WHERE b.sls_ord_num = s.sls_ord_num
    );

    GET DIAGNOSTICS v_rows_crm_sales = ROW_COUNT;
    DROP TABLE stg_crm_sales_details;

    v_table_end := clock_timestamp();
    RAISE NOTICE '[3/6] bronze.crm_sales_details';
    RAISE NOTICE '      Rows Inserted : %', v_rows_crm_sales;
    RAISE NOTICE '      Duration      : %', v_table_end - v_table_start;
    RAISE NOTICE '';

    -- CRM group totals
    v_crm_end   := clock_timestamp();
    v_total_crm := v_rows_crm_cust + v_rows_crm_prd + v_rows_crm_sales;

    RAISE NOTICE '>> CRM Group Summary';
    RAISE NOTICE '   Total Rows Inserted : %', v_total_crm;
    RAISE NOTICE '   Total CRM Duration  : %', v_crm_end - v_crm_start;
    RAISE NOTICE '';

    -- =========================================================================
    --  ERP TABLES
    -- =========================================================================

    v_erp_start := clock_timestamp();

    RAISE NOTICE '----------------------------------------';
    RAISE NOTICE 'ERP SOURCE TABLES';
    RAISE NOTICE '----------------------------------------';

    ----------------------------------------------------------------------------
    -- [4/6] ERP CUSTOMER
    ----------------------------------------------------------------------------

    v_table_start := clock_timestamp();

    CREATE TEMP TABLE stg_erp_cust_az12 (
        cid         VARCHAR(50),
        bdate       VARCHAR(50),
        gen         VARCHAR(50),
        ingested_at VARCHAR(50)
    );

    COPY stg_erp_cust_az12
    FROM 'C:\postgres_data\CUST_AZ12.csv'
    DELIMITER ',' CSV HEADER;

    INSERT INTO bronze.erp_cust_az12 (cid, bdate, gen, ingested_at)
    SELECT
        cid,
        bdate::DATE,
        gen,
        CURRENT_TIMESTAMP
    FROM stg_erp_cust_az12 s
    WHERE NOT EXISTS (
        SELECT 1 FROM bronze.erp_cust_az12 b WHERE b.cid = s.cid
    );

    GET DIAGNOSTICS v_rows_erp_cust = ROW_COUNT;
    DROP TABLE stg_erp_cust_az12;

    v_table_end := clock_timestamp();
    RAISE NOTICE '[4/6] bronze.erp_cust_az12';
    RAISE NOTICE '      Rows Inserted : %', v_rows_erp_cust;
    RAISE NOTICE '      Duration      : %', v_table_end - v_table_start;
    RAISE NOTICE '';

    ----------------------------------------------------------------------------
    -- [5/6] ERP LOCATION
    ----------------------------------------------------------------------------

    v_table_start := clock_timestamp();

    CREATE TEMP TABLE stg_erp_loc_a101 (
        cid         VARCHAR(50),
        cntry       VARCHAR(50),
        ingested_at VARCHAR(50)
    );

    COPY stg_erp_loc_a101
    FROM 'C:\postgres_data\LOC_A101.csv'
    DELIMITER ',' CSV HEADER;

    INSERT INTO bronze.erp_loc_a101 (cid, cntry, ingested_at)
    SELECT
        cid,
        cntry,
        CURRENT_TIMESTAMP
    FROM stg_erp_loc_a101 s
    WHERE NOT EXISTS (
        SELECT 1 FROM bronze.erp_loc_a101 b WHERE b.cid = s.cid
    );

    GET DIAGNOSTICS v_rows_erp_loc = ROW_COUNT;
    DROP TABLE stg_erp_loc_a101;

    v_table_end := clock_timestamp();
    RAISE NOTICE '[5/6] bronze.erp_loc_a101';
    RAISE NOTICE '      Rows Inserted : %', v_rows_erp_loc;
    RAISE NOTICE '      Duration      : %', v_table_end - v_table_start;
    RAISE NOTICE '';

    ----------------------------------------------------------------------------
    -- [6/6] ERP PRODUCT CATEGORY
    ----------------------------------------------------------------------------

    v_table_start := clock_timestamp();

    CREATE TEMP TABLE stg_erp_px_cat_g1v2 (
        id          VARCHAR(50),
        cat         VARCHAR(50),
        subcat      VARCHAR(50),
        maintenance VARCHAR(50),
        ingested_at VARCHAR(50)
    );

    COPY stg_erp_px_cat_g1v2
    FROM 'C:\postgres_data\PX_CAT_G1V2.csv'
    DELIMITER ',' CSV HEADER;

    INSERT INTO bronze.erp_px_cat_g1v2 (id, cat, subcat, maintenance, ingested_at)
    SELECT
        id,
        cat,
        subcat,
        maintenance,
        CURRENT_TIMESTAMP
    FROM stg_erp_px_cat_g1v2 s
    WHERE NOT EXISTS (
        SELECT 1 FROM bronze.erp_px_cat_g1v2 b WHERE b.id = s.id
    );

    GET DIAGNOSTICS v_rows_erp_cat = ROW_COUNT;
    DROP TABLE stg_erp_px_cat_g1v2;

    v_table_end := clock_timestamp();
    RAISE NOTICE '[6/6] bronze.erp_px_cat_g1v2';
    RAISE NOTICE '      Rows Inserted : %', v_rows_erp_cat;
    RAISE NOTICE '      Duration      : %', v_table_end - v_table_start;
    RAISE NOTICE '';

    -- ERP group totals
    v_erp_end   := clock_timestamp();
    v_total_erp := v_rows_erp_cust + v_rows_erp_loc + v_rows_erp_cat;

    RAISE NOTICE '>> ERP Group Summary';
    RAISE NOTICE '   Total Rows Inserted : %', v_total_erp;
    RAISE NOTICE '   Total ERP Duration  : %', v_erp_end - v_erp_start;
    RAISE NOTICE '';

    -- =========================================================================
    --  GRAND SUMMARY
    -- =========================================================================

    v_proc_end    := clock_timestamp();
    v_grand_total := v_total_crm + v_total_erp;

    RAISE NOTICE '========================================';
    RAISE NOTICE 'BRONZE LOAD COMPLETE - FINAL SUMMARY';
    RAISE NOTICE '========================================';
    RAISE NOTICE '';
    RAISE NOTICE '  Table                    Rows Inserted';
    RAISE NOTICE '  crm_cust_info            %', v_rows_crm_cust;
    RAISE NOTICE '  crm_prd_info             %', v_rows_crm_prd;
    RAISE NOTICE '  crm_sales_details        %', v_rows_crm_sales;
    RAISE NOTICE '  CRM Sub-total            %', v_total_crm;
    RAISE NOTICE '';
    RAISE NOTICE '  erp_cust_az12            %', v_rows_erp_cust;
    RAISE NOTICE '  erp_loc_a101             %', v_rows_erp_loc;
    RAISE NOTICE '  erp_px_cat_g1v2          %', v_rows_erp_cat;
    RAISE NOTICE '  ERP Sub-total            %', v_total_erp;
    RAISE NOTICE '';
    RAISE NOTICE '  Grand Total              %', v_grand_total;
    RAISE NOTICE '';
    RAISE NOTICE '  CRM Load Time   : %', v_crm_end - v_crm_start;
    RAISE NOTICE '  ERP Load Time   : %', v_erp_end - v_erp_start;
    RAISE NOTICE '  Total Duration  : %', v_proc_end - v_proc_start;
    RAISE NOTICE '  Completed at    : %', TO_CHAR(v_proc_end, 'YYYY-MM-DD HH24:MI:SS');
    RAISE NOTICE '========================================';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '========================================';
        RAISE NOTICE 'BRONZE LOAD FAILED';
        RAISE NOTICE 'Error   : %', SQLERRM;
        RAISE NOTICE 'State   : %', SQLSTATE;
        RAISE NOTICE '========================================';
        RAISE;
END;
$$;