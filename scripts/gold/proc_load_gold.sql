-- ============================================================================
-- PROCEDURE : gold.load_gold_layer()
-- SCHEMA    : gold
-- LANGUAGE  : PL/pgSQL
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
    -- Source  : silver.crm_cust_info   (primary)
    --           silver.erp_cust_az12   (LEFT JOIN — birth date & gender)
    --           silver.erp_loc_a101    (LEFT JOIN — country)
    -- Target  : gold.dim_customers
    -- Conflict: customer_id  →  DO UPDATE (SCD Type 1)
    --
    -- Surrogate key: customer_key generated via ROW_NUMBER() OVER (ORDER BY cst_id)
    --   • Deterministic and stable across runs when no new lower-ID customers appear.
    --   • On conflict the existing customer_key is preserved (not in SET list).
    --------------------------------------------------------------------------
    BEGIN
        v_step_start := clock_timestamp();

        INSERT INTO gold.dim_customers (
            customer_key,      -- FIX 3: surrogate key — explicitly generated
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
            ROW_NUMBER() OVER (ORDER BY CI.cst_id)  AS customer_key,
            CI.cst_id,
            CI.cst_key,
            CI.cst_first_name,                      
            CI.cst_last_name,                        
            LA.cntry,
            CI.cst_marital_status,
            CASE
                WHEN CI.cst_gndr <> 'N/A' THEN CI.cst_gndr
                ELSE COALESCE(CA.gen, 'N/A')
            END                                      AS gender,
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
            customer_number = EXCLUDED.customer_number,
            first_name      = EXCLUDED.first_name,
            last_name       = EXCLUDED.last_name,
            country         = EXCLUDED.country,
            marital_status  = EXCLUDED.marital_status,
            gender          = EXCLUDED.gender,
            birth_date      = EXCLUDED.birth_date;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_step_end := clock_timestamp();

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
    -- Source  : silver.crm_prd_info      (primary)
    --           silver.erp_px_cat_g1v2   (LEFT JOIN — category hierarchy)
    -- Target  : gold.dim_products
    -- Filter  : prd_end_dt IS NULL  → active / current product versions only
    -- Conflict: product_number  →  DO UPDATE (SCD Type 1)
    --
    -- Surrogate key: product_key generated via ROW_NUMBER() OVER (ORDER BY prd_id)
    --   • On conflict the existing product_key is preserved (not in SET list).
    --------------------------------------------------------------------------
    BEGIN
        v_step_start := clock_timestamp();

        INSERT INTO gold.dim_products (
            product_key,       
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
            ROW_NUMBER() OVER (ORDER BY pn.prd_id)  AS product_key,
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
    --           gold.dim_products         (INNER JOIN — resolves product_key)
    --           gold.dim_customers        (INNER JOIN — resolves customer_key)
    -- Target  : gold.fact_sales
    -- Conflict: (order_number, product_key)  →  DO NOTHING (immutable facts)
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
            pr.product_key,    
            cu.customer_key,   
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
    RAISE NOTICE '  SELECT * FROM gold.etl_log ORDER BY start_time DESC LIMIT 3;';
    RAISE NOTICE '=================================================================';

END;
$$;