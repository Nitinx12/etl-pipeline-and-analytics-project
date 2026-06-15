CREATE OR REPLACE FUNCTION gold.fn_sales_report(
    p_country     VARCHAR DEFAULT NULL,
    p_category    VARCHAR DEFAULT NULL,
    p_start_date  DATE    DEFAULT NULL,
    p_end_date    DATE    DEFAULT NULL
)
RETURNS TABLE(
    order_number        VARCHAR,
    order_date          DATE,
    customer_key        INT,
    customer_name       VARCHAR,
    country             VARCHAR,
    product_name        VARCHAR,
    category            VARCHAR,
    quantity            INT,
    unit_cost           NUMERIC,
    unit_price          NUMERIC,
    total_cost          NUMERIC,
    total_sales         NUMERIC,
    total_profit        NUMERIC,
    profit_margin_pct   NUMERIC,
    markup_ratio        NUMERIC,
    days_since_order    INT,
    order_recency       VARCHAR,
    profit_tier         VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN

    -- ① start_date cannot be after end_date
    IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL
       AND p_start_date > p_end_date THEN
        RAISE EXCEPTION
            'Invalid date range: p_start_date (%) cannot be after p_end_date (%)',
            p_start_date, p_end_date;
    END IF;

    -- ② end_date cannot be in the future
    IF p_end_date IS NOT NULL AND p_end_date > CURRENT_DATE THEN
        RAISE EXCEPTION
            'Invalid date: p_end_date (%) cannot be in the future',
            p_end_date;
    END IF;

    -- ③ warn if range exceeds 5 years — may return huge results
    IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL
       AND (p_end_date - p_start_date) > 1825 THEN
        RAISE WARNING
            'Date range exceeds 5 years — this query may return a very large result set';
    END IF;

    -- ④ log execution parameters for debugging
    RAISE NOTICE
        'Executing fn_sales_report | country: % | category: % | from: % | to: %',
        COALESCE(p_country::TEXT,    'ALL'),
        COALESCE(p_category::TEXT,   'ALL'),
        COALESCE(p_start_date::TEXT, 'ALL'),
        COALESCE(p_end_date::TEXT,   'ALL');

    RETURN QUERY
        SELECT
            FS.order_number,
            FS.order_date,
            DC.customer_key,
            CONCAT(DC.first_name, ' ', DC.last_name) :: VARCHAR AS customer_name,
            DC.country,
            DP.product_name,
            DP.category,
            FS.quantity,
            DP.product_cost AS unit_cost,
            ROUND(FS.sales / NULLIF(FS.quantity, 0), 2) AS unit_price,
            ROUND(DP.product_cost * FS.quantity,2) AS total_cost,
            FS.sales AS total_sales,
            FS.sales - (DP.product_cost * FS.quantity) AS total_profit,
            ROUND(
                (FS.sales - (DP.product_cost * FS.quantity))
                / NULLIF(FS.sales, 0) * 100, 2
            ) AS profit_margin_pct,
            ROUND(
                (FS.sales / NULLIF(FS.quantity,       0))
                / NULLIF(DP.product_cost,             0), 2
            ) AS markup_ratio,
            (CURRENT_DATE - FS.order_date) :: INT AS days_since_order,
            CASE
                WHEN (CURRENT_DATE - FS.order_date) <= 30  THEN 'This Month'
                WHEN (CURRENT_DATE - FS.order_date) <= 90  THEN 'Last Quarter'
                WHEN (CURRENT_DATE - FS.order_date) <= 365 THEN 'This Year'
                ELSE 'Older'
            END :: VARCHAR AS order_recency,
            CASE
                WHEN (FS.sales - (DP.product_cost * FS.quantity)) IS NULL   THEN 'Unknown'
                WHEN (FS.sales - (DP.product_cost * FS.quantity)) >  0      THEN 'Profitable'
                WHEN (FS.sales - (DP.product_cost * FS.quantity)) =  0      THEN 'Break Even'
                ELSE 'Loss'
            END :: VARCHAR AS profit_tier
        FROM gold.fact_sales AS FS
        LEFT JOIN gold.dim_customers AS DC ON 
		FS.customer_key = DC.customer_key
        LEFT JOIN gold.dim_products AS DP ON 
		FS.product_key = DP.product_key
        WHERE
            (p_country    IS NULL OR DC.country    = p_country)
            AND (p_category   IS NULL OR DP.category   = p_category)
            AND (p_start_date IS NULL OR FS.order_date >= p_start_date)
            AND (p_end_date   IS NULL OR FS.order_date <= p_end_date)
        ORDER BY FS.order_date DESC, FS.order_number;

END;
$$;