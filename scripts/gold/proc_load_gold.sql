-- ============================================================================
-- PROCEDURE : gold.load_gold_layer()
-- SCHEMA    : gold
-- LANGUAGE  : PL/pgSQL
--
-- PURPOSE
-- -------
-- Performs the Silver → Gold ETL pipeline.
-- The Gold layer is the final, analytics-ready Star Schema consumed by
-- dashboards, reports, and business intelligence tools.
--
-- This procedure reads from the cleansed Silver tables and populates:
--   • 2 Dimension tables  (dim_customers, dim_products)
--   • 1 Fact table        (fact_sales)
--
-- It must be run AFTER both bronze.load_bronze() and silver.load_silver_layer()
-- have completed successfully.
--
-- STAR SCHEMA STRUCTURE
-- ---------------------
--
--              ┌─────────────────┐
--              │  dim_customers  │◄──┐
--              └─────────────────┘   │
--                                    │
--   ┌─────────────────┐         ┌────┴──────────┐
--   │  dim_products   │◄────────┤  fact_sales   │
--   └─────────────────┘         └───────────────┘
--
-- SOURCE → TARGET MAP
-- -------------------
--   Silver tables joined                     →  Gold target
--   ─────────────────────────────────────────────────────────
--   silver.crm_cust_info                     ┐
--   + silver.erp_cust_az12  (birth date/gen) ├─→ gold.dim_customers
--   + silver.erp_loc_a101   (country)        ┘
--
--   silver.crm_prd_info                      ┐
--   + silver.erp_px_cat_g1v2 (category)      ├─→ gold.dim_products
--                                            ┘
--
--   silver.crm_sales_details                 ┐
--   + gold.dim_products  (product_number FK) ├─→ gold.fact_sales
--   + gold.dim_customers (customer_id FK)    ┘
--
-- TRANSFORMATIONS APPLIED (per target)
-- ------------------------------------
--   dim_customers
--     • Joins CRM customer info with ERP demographics (birth date, gender)
--       and ERP location (country) using cst_key = cid as the join key.
--     • Gender resolution: CRM gender takes precedence when it is not 'N/A';
--       falls back to the ERP gender (CA.gen) if CRM gender is 'N/A';
--       defaults to 'N/A' if both are absent (COALESCE).
--     • Quality gate: skip rows where cst_id IS NULL.
--
--   dim_products
--     • Joins CRM product info with ERP category hierarchy
--       using cat_id = id as the join key.
--     • Only CURRENT product versions are loaded:
--       prd_end_dt IS NULL means the record is the active/latest version
--       (open-ended SCD range; closed versions have a non-NULL end date).
--     • No additional value-level transformations — cleansing was already
--       done in the Silver layer.
--
--   fact_sales
--     • Joins Silver sales details to Gold dimension surrogate/natural keys:
--         sls_prd_key  → dim_products.product_number  (product FK)
--         sls_cust_id  → dim_customers.customer_id    (customer FK)
--     • Uses INNER JOIN on both dimensions so only sales with a matching
--       product and customer in Gold are loaded (referential integrity guard).
--     • All financial/date columns (sls_sales, sls_price, sls_order_dt, etc.)
--       are already cleansed in Silver; no further transformation is needed.
--
-- LOAD STRATEGY
-- -------------
--   dim_customers  →  ON CONFLICT (customer_id)      DO UPDATE  (SCD Type 1)
--   dim_products   →  ON CONFLICT (product_number)   DO UPDATE  (SCD Type 1)
--   fact_sales     →  ON CONFLICT (order_number,
--                                  product_key)      DO NOTHING (immutable facts)
--
--   Dimensions use SCD Type 1: if a customer or product changes in Silver,
--   the Gold dimension row is overwritten in-place (no history is kept).
--
--   Facts use DO NOTHING: a sales order line, once written, is never
--   changed or deleted.  Re-runs simply skip rows that already exist.
--
-- ERROR HANDLING
-- --------------
--   Each of the 3 targets is wrapped in its own BEGIN … EXCEPTION … END block.
--   A failure in one target is caught, logged, and reported via RAISE NOTICE —
--   the pipeline then continues to the next target rather than aborting.
--   Both success and failure outcomes are recorded in gold.etl_log.
--
-- LOGGING — gold.etl_log
-- ----------------------
--   Every step writes one row to gold.etl_log containing:
--     procedure_name, table_name, rows_affected,
--     step_start, step_end, duration_seconds,
--     status ('SUCCESS' / 'FAILED'),
--     error_message (NULL on success, SQLERRM on failure).
--
-- HOW TO USE
-- ----------
--   Prerequisites:
--     1. bronze.load_bronze()       must have run successfully.
--     2. silver.load_silver_layer() must have run successfully.
--     3. gold schema tables (dim_customers, dim_products, fact_sales, etl_log)
--        must already exist with the correct constraints.
--
--   Execute:
--     CALL gold.load_gold_layer();
--
--   Monitor progress (in psql):
--     \set VERBOSITY verbose
--     CALL gold.load_gold_layer();
--
--   Review the log after the run:
--     SELECT * FROM gold.etl_log ORDER BY step_start DESC;
--
--   Full pipeline (run in order):
--     CALL bronze.load_bronze();
--     CALL silver.load_silver_layer();
--     CALL gold.load_gold_layer();
--
-- REVISION HISTORY
-- ----------------
-- 2026-06-14  Initial version.
--             Fix: cst_gender corrected to cst_gndr in dim_customers SELECT.
--             Fix: product_key / customer_key references corrected to
--                  product_number / customer_id in fact_sales SELECT.
-- ============================================================================

CREATE OR REPLACE PROCEDURE gold.load_gold_layer()
LANGUAGE plpgsql
AS $$
DECLARE
    v_pipeline_start TIMESTAMP;
    v_pipeline_end   TIMESTAMP;
    v_step_start     TIMESTAMP;
    v_step_end       TIMESTAMP;
    v_rows           INT;

BEGIN
    v_pipeline_start := clock_timestamp();

    RAISE NOTICE '=================================================================';
    RAISE NOTICE 'GOLD PIPELINE STARTED';
    RAISE NOTICE 'Started at : %', TO_CHAR(v_pipeline_start, 'YYYY-MM-DD HH24:MI:SS');
    RAISE NOTICE '=================================================================';
    RAISE NOTICE '';

    -- ==========================================================================
    --  DIMENSION TABLES
    --  Must be loaded BEFORE fact_sales so that FK lookups succeed.
    -- ==========================================================================

    RAISE NOTICE '-----------------------------------------------------------------';
    RAISE NOTICE 'DIMENSION TABLES (1 of 2 groups)';
    RAISE NOTICE '-----------------------------------------------------------------';

    --------------------------------------------------------------------------
    -- [1/3] DIM_CUSTOMERS
    --
    -- Source  : silver.crm_cust_info   (primary — one row per customer)
    --           silver.erp_cust_az12   (LEFT JOIN — adds birth date & gender)
    --           silver.erp_loc_a101    (LEFT JOIN — adds country)
    -- Target  : gold.dim_customers
    -- Join key: silver.crm_cust_info.cst_key = erp_cust_az12.cid
    --                                         = erp_loc_a101.cid
    -- Conflict: customer_id  →  DO UPDATE (SCD Type 1 overwrite)
    --
    -- Transforms applied:
    --   • Gender resolution (two-source priority logic):
    --       If CRM gender (cst_gndr) is not 'N/A' → use CRM value (more trusted).
    --       If CRM gender IS 'N/A'                → fall back to ERP gender (CA.gen).
    --       If both are absent                    → default to 'N/A' via COALESCE.
    --   • Country comes exclusively from ERP location (erp_loc_a101); already
    --     standardised ('DE' → 'Germany' etc.) by the Silver layer.
    --   • Birth date comes exclusively from ERP demographics (erp_cust_az12);
    --     future dates were already nullified by the Silver layer.
    --   • Quality gate: skip rows where cst_id IS NULL.
    --   • create_date is NOT updated on conflict — it records the original
    --     customer creation date and must not be overwritten on re-loads.
    --------------------------------------------------------------------------
    BEGIN
        v_step_start := clock_timestamp();

        INSERT INTO gold.dim_customers (
            customer_id,       
            customer_number,   
            first_name,
            last_name,
            country,            
            marital_status,
            gender,             
            birth_date,         
            create_date         
        )
        SELECT
            CI.cst_id,
            CI.cst_key,
            CI.cst_first_name,
            CI.cst_last_name,
            LA.cntry,                               
            CI.cst_marital_status,
            CASE
                WHEN CI.cst_gndr <> 'N/A' THEN CI.cst_gndr
                ELSE COALESCE(CA.gen, 'N/A')
            END                                     AS gender,
            CA.bdate,                              
            CI.cst_create_date
        FROM silver.crm_cust_info AS CI
        LEFT JOIN silver.erp_cust_az12 AS CA
            ON CI.cst_key = CA.cid
        LEFT JOIN silver.erp_loc_a101 AS LA
            ON CI.cst_key = LA.cid
        WHERE CI.cst_id IS NOT NULL               
        ON CONFLICT (customer_id)
        DO UPDATE SET
            first_name     = EXCLUDED.first_name,
            last_name      = EXCLUDED.last_name,
            country        = EXCLUDED.country,
            marital_status = EXCLUDED.marital_status,
            gender         = EXCLUDED.gender,
            birth_date     = EXCLUDED.birth_date;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_step_end := clock_timestamp();

        -- Log success
        INSERT INTO gold.etl_log
        VALUES (DEFAULT, 
				'load_gold_layer', 
				'dim_customers',
                v_rows, 
				v_step_start, 
				v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'SUCCESS', 
				NULL);

        RAISE NOTICE '[1/3] gold.dim_customers';
        RAISE NOTICE '      Rows Upserted : %', v_rows;
        RAISE NOTICE '      Duration      : % seconds',
                     ROUND(EXTRACT(EPOCH FROM v_step_end - v_step_start)::NUMERIC, 3);
        RAISE NOTICE '';

    EXCEPTION WHEN OTHERS THEN
        v_step_end := clock_timestamp();
        INSERT INTO gold.etl_log
        VALUES (DEFAULT, 
				'load_gold_layer', 
				'dim_customers',
                0, 
				v_step_start, 
				v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'FAILED', 
				SQLERRM);

        RAISE NOTICE '[1/3] gold.dim_customers  *** FAILED ***';
        RAISE NOTICE '      Error : %', SQLERRM;
        RAISE NOTICE '';
    END;

    --------------------------------------------------------------------------
    -- [2/3] DIM_PRODUCTS
    --
    -- Source  : silver.crm_prd_info      (primary — product master)
    --           silver.erp_px_cat_g1v2   (LEFT JOIN — adds category hierarchy)
    -- Target  : gold.dim_products
    -- Join key: silver.crm_prd_info.cat_id = erp_px_cat_g1v2.id
    -- Conflict: product_number  →  DO UPDATE (SCD Type 1 overwrite)
    --
    -- Transforms applied:
    --   • Active-version filter: WHERE prd_end_dt IS NULL
    --       Only the current/active product version is loaded into the dimension.
    --       Products with a non-NULL prd_end_dt are historical versions
    --       (derived by the Silver LEAD() window function) and are excluded.
    --   • Category enrichment: cat, subcate, maintenance come from ERP category
    --       table; CRM product record contributes all other attributes.
    --   • All cleansing (prd_line expansion, cost defaulting, key splitting)
    --       was already applied in the Silver layer — no further transformation here.
    --   • start_date is NOT updated on conflict — it records when the current
    --       product version became active.
    --------------------------------------------------------------------------
    BEGIN
        v_step_start := clock_timestamp();

        INSERT INTO gold.dim_products (
            product_number,    
            product_id,         
            product_name,
            category_id,        
            category,          
            sub_category,      
            maintenance,        
            product_cost,
            product_line,       
            start_date         
        )
        SELECT
            pn.prd_key,         
            pn.prd_id,
            pn.prd_nm,
            pn.cat_id,          
            pc.cat,            
            pc.subcate,         
            pc.maintenance,
            pn.prd_cost,
            pn.prd_line,        
            pn.prd_start_dt
        FROM silver.crm_prd_info AS pn
        LEFT JOIN silver.erp_px_cat_g1v2 AS pc
            ON pc.id = pn.cat_id
        WHERE pn.prd_end_dt IS NULL
        ON CONFLICT (product_number)
        DO UPDATE SET
            product_name  = EXCLUDED.product_name,
            category      = EXCLUDED.category,
            sub_category  = EXCLUDED.sub_category,
            maintenance   = EXCLUDED.maintenance,
            product_cost  = EXCLUDED.product_cost,
            product_line  = EXCLUDED.product_line;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_step_end := clock_timestamp();

        -- Log success
        INSERT INTO gold.etl_log
        VALUES (DEFAULT, 
				'load_gold_layer', 
				'dim_products',
                v_rows, 
				v_step_start, 
				v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'SUCCESS', 
				NULL);

        RAISE NOTICE '[2/3] gold.dim_products';
        RAISE NOTICE '      Rows Upserted : %', v_rows;
        RAISE NOTICE '      Duration      : % seconds',
                     ROUND(EXTRACT(EPOCH FROM v_step_end - v_step_start)::NUMERIC, 3);
        RAISE NOTICE '';

    EXCEPTION WHEN OTHERS THEN
        v_step_end := clock_timestamp();
        INSERT INTO gold.etl_log
        VALUES (DEFAULT, 
				'load_gold_layer', 
				'dim_products',
                0, 
				v_step_start, 
				v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'FAILED', 
				SQLERRM);

        RAISE NOTICE '[2/3] gold.dim_products  *** FAILED ***';
        RAISE NOTICE '      Error : %', SQLERRM;
        RAISE NOTICE '';
    END;

    -- ==========================================================================
    --  FACT TABLE
    --  Loaded AFTER dimensions so FK lookups resolve correctly.
    -- ==========================================================================

    RAISE NOTICE '-----------------------------------------------------------------';
    RAISE NOTICE 'FACT TABLE (2 of 2 groups)';
    RAISE NOTICE '-----------------------------------------------------------------';

    --------------------------------------------------------------------------
    -- [3/3] FACT_SALES
    --
    -- Source  : silver.crm_sales_details  (one row per order line)
    --           gold.dim_products         (INNER JOIN — resolves product FK)
    --           gold.dim_customers        (INNER JOIN — resolves customer FK)
    -- Target  : gold.fact_sales
    -- Conflict: (order_number, product_key)  →  DO NOTHING (immutable facts)
    --
    -- Join logic:
    --   silver.crm_sales_details.sls_prd_key  →  gold.dim_products.product_number
    --   silver.crm_sales_details.sls_cust_id  →  gold.dim_customers.customer_id
    --
    --   Both joins are INNER JOINs:
    --     • Only sales lines with a matching product in dim_products are loaded.
    --     • Only sales lines with a matching customer in dim_customers are loaded.
    --     • This enforces referential integrity — orphaned sales lines
    --       (whose product or customer was filtered out upstream) are silently
    --       excluded from Gold.
    --
    -- Load strategy — DO NOTHING (not DO UPDATE):
    --   Sales facts are immutable once written.  If a row with the same
    --   (order_number, product_key) already exists, it is skipped entirely.
    --   This prevents re-runs from overwriting historical sales figures.
    --   (Contrast with dimensions which use DO UPDATE / SCD Type 1.)
    --
    -- Transforms applied:
    --   • None — all financial figures (sls_sales, sls_price) and date
    --     conversions (sls_order_dt → DATE) were already applied in Silver.
    --   • product_key in the fact table is sourced from dim_products.product_number
    --     (not the raw Silver key) to ensure it matches the dimension's PK.
    --   • customer_key is sourced from dim_customers.customer_id for the same reason.
    --------------------------------------------------------------------------
    BEGIN
        v_step_start := clock_timestamp();

        INSERT INTO gold.fact_sales (
            order_number,
            product_key,   
            customer_key,   
            order_date,
            ship_date,
            due_date,
            sales,
            quantity,
            price
        )
        SELECT
            sd.sls_ord_num,
            pr.product_number,
            cu.customer_id,     
            sd.sls_order_dt,
            sd.sls_ship_date,
            sd.sls_due_date,
            sd.sls_sales,
            sd.sls_quantity,
            sd.sls_price
        FROM silver.crm_sales_details AS sd
        INNER JOIN gold.dim_products AS pr
            ON sd.sls_prd_key = pr.product_number
        INNER JOIN gold.dim_customers AS cu
            ON sd.sls_cust_id = cu.customer_id
        ON CONFLICT (order_number, product_key)
        DO NOTHING;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_step_end := clock_timestamp();

        -- Log success
        INSERT INTO gold.etl_log
        VALUES (DEFAULT, 
				'load_gold_layer', 
				'fact_sales',
                v_rows, 
				v_step_start, 
				v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'SUCCESS', 
				NULL);

        RAISE NOTICE '[3/3] gold.fact_sales';
        RAISE NOTICE '      Rows Inserted : %', v_rows;
        RAISE NOTICE '      Duration      : % seconds',
                     ROUND(EXTRACT(EPOCH FROM v_step_end - v_step_start)::NUMERIC, 3);
        RAISE NOTICE '';

    EXCEPTION WHEN OTHERS THEN
        -- Log failure
        v_step_end := clock_timestamp();
        INSERT INTO gold.etl_log
        VALUES (DEFAULT, 
				'load_gold_layer', 
				'fact_sales',
                0, 
				v_step_start, 
				v_step_end,
                EXTRACT(EPOCH FROM v_step_end - v_step_start),
                'FAILED', 
				SQLERRM);

        RAISE NOTICE '[3/3] gold.fact_sales  *** FAILED ***';
        RAISE NOTICE '      Error : %', SQLERRM;
        RAISE NOTICE '';
    END;

    -- ==========================================================================
    --  PIPELINE COMPLETE
    -- ==========================================================================

    v_pipeline_end := clock_timestamp();

    RAISE NOTICE '=================================================================';
    RAISE NOTICE 'GOLD PIPELINE COMPLETE';
    RAISE NOTICE 'Total Duration : % seconds',
                 ROUND(EXTRACT(EPOCH FROM v_pipeline_end - v_pipeline_start)::NUMERIC, 3);
    RAISE NOTICE 'Completed at   : %', TO_CHAR(v_pipeline_end, 'YYYY-MM-DD HH24:MI:SS');
    RAISE NOTICE '=================================================================';
    RAISE NOTICE 'Review the run:';
    RAISE NOTICE '  SELECT * FROM gold.etl_log ORDER BY step_start DESC LIMIT 3;';
    RAISE NOTICE '=================================================================';

END;
$$;