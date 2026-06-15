-- ============================================================================
-- FUNCTION  : gold.fn_product_report()
-- SCHEMA    : gold
-- LANGUAGE  : PL/pgSQL
--
-- PURPOSE
-- -------
-- Returns a comprehensive per-product report by joining the Gold Star Schema:
--   gold.dim_products   →  product profile (name, category, cost, line …)
--   gold.fact_sales     →  transactional aggregates (sales, orders, qty …)
--   gold.dim_customers  →  unique customer reach per product
--
-- OUTPUT COLUMNS
-- --------------
--   Profile        : product_key, product_number, product_name, category,
--                    sub_category, product_line, product_cost, maintenance,
--                    start_date
--   Sale dates     : first_sale_date, last_sale_date
--   Sales KPIs     : total_orders, total_quantity, total_sales,
--                    avg_selling_price, total_profit, profit_margin_pct
--   Customer reach : total_customers  (distinct customers who bought the product)
--   Segment        : product_segment  (High Performer / Mid Range / Low Performer)
--
-- PARAMETERS (all optional — omit or pass NULL for no filter)
-- ----------------------------------------------------------
--   p_category     VARCHAR  →  e.g. 'Bikes', 'Accessories'
--   p_start_date   DATE     →  earliest order_date to include
--   p_end_date     DATE     →  latest  order_date to include
--
-- PRODUCT SEGMENT THRESHOLDS
-- --------------------------
--   total_sales >= 50 000  →  'High Performer'
--   total_sales >= 10 000  →  'Mid Range'
--   total_sales <  10 000  →  'Low Performer'
--   total_sales  IS NULL   →  'No Sales'  (product in dim but never sold)
--
-- PROFITABILITY
-- -------------
--   total_profit     = total_sales - (product_cost * total_quantity)
--   profit_margin_pct = ROUND( total_profit / NULLIF(total_sales,0) * 100, 2 )
--
-- HOW TO USE
-- ----------
--   -- All products, no filters
--   SELECT * FROM gold.fn_product_report();
--
--   -- Filter by category only
--   SELECT * FROM gold.fn_product_report(p_category := 'Bikes');
--
--   -- Filter by date range only
--   SELECT * FROM gold.fn_product_report(
--       p_start_date := '2022-01-01',
--       p_end_date   := '2022-12-31'
--   );
--
--   -- Filter by category AND date range
--   SELECT * FROM gold.fn_product_report(
--       p_category   := 'Accessories',
--       p_start_date := '2021-01-01',
--       p_end_date   := '2023-12-31'
--   );
--
--   -- Useful slices on top of the function
--   SELECT * FROM gold.fn_product_report() WHERE product_segment = 'High Performer';
--   SELECT * FROM gold.fn_product_report() ORDER BY profit_margin_pct DESC LIMIT 10;
--   SELECT * FROM gold.fn_product_report() WHERE total_sales IS NULL;  -- never sold
-- ==================================================================================
CREATE OR REPLACE FUNCTION gold.fn_product_report(
    p_category    VARCHAR DEFAULT NULL,
    p_start_date  DATE    DEFAULT NULL,
    p_end_date    DATE    DEFAULT NULL
)
RETURNS TABLE(
    product_key           INT,
    product_number        VARCHAR,
    product_name          VARCHAR,
    category              VARCHAR,
    sub_category          VARCHAR,
    product_line          VARCHAR,
    product_cost          NUMERIC,
    maintenance           VARCHAR,
    start_date            DATE,
    first_sale_date       DATE,
    last_sale_date        DATE,
    total_orders          BIGINT,
    total_quantity        BIGINT,
    total_sales           NUMERIC,
    avg_selling_price     NUMERIC,
    total_profit          NUMERIC,
    profit_margin_pct     NUMERIC,
    total_customers       BIGINT,
    product_segment       TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
        SELECT
            DP.product_key,
            DP.product_number,
            DP.product_name,
            DP.category,
            DP.sub_category,
            DP.product_line,
            DP.product_cost,
            DP.maintenance,
            DP.start_date,
            MIN(FS.order_date) AS first_sale_date,
            MAX(FS.order_date) AS last_sale_date,
            COUNT(DISTINCT FS.order_number) AS total_orders,        
            SUM(FS.quantity) AS total_quantity,      
            SUM(FS.sales) AS total_sales,
            ROUND(
                SUM(FS.sales) / NULLIF(SUM(FS.quantity), 0), 2
            ) AS avg_selling_price,
            SUM(FS.sales) - (DP.product_cost * SUM(FS.quantity)) AS total_profit,         
            ROUND(
                (SUM(FS.sales) - (DP.product_cost * SUM(FS.quantity)))
                / NULLIF(SUM(FS.sales), 0) * 100, 2
            ) AS profit_margin_pct,
            COUNT(DISTINCT FS.customer_key) AS total_customers,
            CASE
                WHEN SUM(FS.sales) IS NULL  THEN 'No Sales'                
                WHEN SUM(FS.sales) >= 50000 THEN 'High Performer'
                WHEN SUM(FS.sales) >= 10000 THEN 'Mid Range'
                ELSE 'Low Performer'
            END AS product_segment
        FROM gold.dim_products AS DP
        LEFT JOIN gold.fact_sales AS FS
            ON  DP.product_key = FS.product_key
            AND (p_start_date IS NULL OR FS.order_date >= p_start_date)
            AND (p_end_date   IS NULL OR FS.order_date <= p_end_date)
        WHERE (p_category IS NULL OR DP.category = p_category)
        GROUP BY
            DP.product_key,
            DP.product_number,
            DP.product_name,
            DP.category,
            DP.sub_category,
            DP.product_line,
            DP.product_cost,
            DP.maintenance,
            DP.start_date
        ORDER BY total_sales DESC NULLS LAST;
END;
$$;