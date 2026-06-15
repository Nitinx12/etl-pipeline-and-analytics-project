-- ============================================================================
-- FUNCTION  : gold.fn_customer_report()
-- SCHEMA    : gold
-- LANGUAGE  : PL/pgSQL
--
-- PURPOSE
-- -------
-- Returns a comprehensive per-customer report by joining the Gold Star Schema:
--   gold.dim_customers  →  customer profile (name, country, gender, age …)
--   gold.fact_sales     →  transactional aggregates (sales, orders, qty …)
--   gold.dim_products   →  product category enrichment
--
-- OUTPUT COLUMNS
-- --------------
--   Profile     : customer_key, customer_number, full_name, country,
--                 gender, age, marital_status
--   Order dates : first_order_date, last_order_date, customer_tenure_days
--   Sales KPIs  : total_orders, total_quantity, total_sales, avg_order_value
--   Categories  : categories_bought  (comma-separated distinct categories)
--   Segment     : customer_segment   (VIP / Regular / New / No Sales)
--
-- PARAMETERS (all optional — omit or pass NULL for no filter)
-- ----------------------------------------------------------
--   p_country      VARCHAR  →  e.g. 'United States', 'Germany'
--   p_start_date   DATE     →  earliest order_date to include
--   p_end_date     DATE     →  latest  order_date to include
--
-- CUSTOMER SEGMENT THRESHOLDS
-- ---------------------------
--   total_sales >= 10 000  →  'VIP'
--   total_sales >=  1 000  →  'Regular'
--   total_sales <   1 000  →  'New'
--   total_sales  IS NULL   →  'No Sales'  (customer in dim but no orders)
--
-- HOW TO USE
-- ----------
--   -- All customers, no filters
--   SELECT * FROM gold.fn_customer_report();
--
--   -- Filter by country only
--   SELECT * FROM gold.fn_customer_report(p_country := 'United States');
--
--   -- Filter by date range only
--   SELECT * FROM gold.fn_customer_report(
--       p_start_date := '2022-01-01',
--       p_end_date   := '2022-12-31'
--   );
--
--   -- Filter by country AND date range
--   SELECT * FROM gold.fn_customer_report(
--       p_country    := 'Germany',
--       p_start_date := '2021-01-01',
--       p_end_date   := '2023-12-31'
--   );
--
--   -- Useful slices on top of the function
--   SELECT * FROM gold.fn_customer_report() WHERE customer_segment = 'VIP';
--   SELECT * FROM gold.fn_customer_report() ORDER BY total_sales DESC LIMIT 10;
-- ============================================================================

CREATE OR REPLACE FUNCTION gold.fn_customer_report(
    p_country       VARCHAR DEFAULT NULL,
    p_start_date    DATE    DEFAULT NULL,
    p_end_date      DATE    DEFAULT NULL
)
RETURNS TABLE(
    customer_key            INT,
    customer_number         VARCHAR,
    customer_name           VARCHAR,
    country                 VARCHAR,
    gender                  VARCHAR,
    age                     INT,
    marital_status          VARCHAR,
    first_order_date        DATE,
    last_order_date         DATE,
    customer_tenure_days    INT,
    total_orders            BIGINT,
    total_quantity          BIGINT,
    total_sales             NUMERIC,
    avg_order_value         NUMERIC,
    categories_bought       VARCHAR,
    customer_segment        VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN

    RETURN QUERY

    SELECT
        DC.customer_key,
        DC.customer_number,
        CONCAT(DC.first_name, ' ', DC.last_name) :: VARCHAR                 AS customer_name,
        DC.country,
        DC.gender,
        CASE
            WHEN DC.birth_date IS NOT NULL
            THEN EXTRACT(YEAR FROM AGE(CURRENT_DATE, DC.birth_date)) :: INT
        END                                                                  AS age,
        DC.marital_status,
        MIN(FS.order_date)                                                   AS first_order_date,
        MAX(FS.order_date)                                                   AS last_order_date,
        (MAX(FS.order_date) - MIN(FS.order_date)) :: INT                    AS customer_tenure_days,
        COUNT(DISTINCT FS.order_number)                                      AS total_orders,
        SUM(FS.quantity)                                                     AS total_quantity,
        SUM(FS.sales)                                                        AS total_sales,
        ROUND(
            SUM(FS.sales) / NULLIF(COUNT(DISTINCT FS.order_number), 0)
        )                                                                    AS avg_order_value,
        STRING_AGG(DISTINCT DP.category, ', ' ORDER BY DP.category) :: VARCHAR  AS categories_bought,
        CASE
            WHEN SUM(FS.sales) IS NULL   THEN 'No Sales'
            WHEN SUM(FS.sales) >= 10000  THEN 'VIP'
            WHEN SUM(FS.sales) >= 1000   THEN 'Regular'
            ELSE 'New'
        END :: VARCHAR                                                       AS customer_segment
    FROM gold.dim_customers AS DC
    LEFT JOIN gold.fact_sales AS FS
        ON  DC.customer_key = FS.customer_key
        AND (p_start_date IS NULL OR FS.order_date >= p_start_date)
        AND (p_end_date   IS NULL OR FS.order_date <= p_end_date)
    LEFT JOIN gold.dim_products AS DP
        ON  FS.product_key = DP.product_key
    WHERE p_country IS NULL OR DC.country = p_country
    GROUP BY
        DC.customer_key,
        DC.customer_number,
        DC.first_name,
        DC.last_name,
        DC.country,
        DC.gender,
        DC.birth_date,
        DC.marital_status
    ORDER BY total_sales DESC NULLS LAST;

END;
$$;