-- Which 5 products Generating the Highest Revenue?
-- Simple Ranking
SELECT
    P.product_id,
    P.product_name,
    COALESCE(SUM(F.sales),0) AS total_revenue
FROM gold.dim_products AS P
LEFT JOIN gold.fact_sales AS F
ON P.product_key = F.product_key
GROUP BY
    P.product_id,
    P.product_name
ORDER BY total_revenue DESC
LIMIT 5;

-- Complex but Flexibly Ranking Using Window Functions
SELECT
    product_id,
    product_name,
    total_revenue
FROM(
    SELECT
        P.product_id,
        P.product_name,
        COALESCE(SUM(F.sales),0) AS total_revenue,
        DENSE_RANK()
            OVER(ORDER BY COALESCE(SUM(F.sales),0) DESC) AS rnk
    FROM gold.dim_products AS P
    LEFT JOIN gold.fact_sales AS F ON
    P.product_key = F.product_key
    GROUP BY 
        P.product_id,
        P.product_name
) AS X
WHERE X.rnk <= 5;

-- What are the 5 worst-performing products in terms of sales?
SELECT
    P.product_id,
    P.product_name,
    COALESCE(SUM(F.sales),0) AS total_revenue
FROM gold.dim_products AS P
LEFT JOIN gold.fact_sales AS F
ON P.product_key = F.product_key
GROUP BY
    P.product_id,
    P.product_name
ORDER BY total_revenue ASC
LIMIT 5;