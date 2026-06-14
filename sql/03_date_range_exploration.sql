/*
===============================================================================
Date Range Exploration
===============================================================================
Purpose:
    - Determine the temporal boundaries of key data points.
    - Understand the range of historical data.

PostgreSQL Functions Used:
    - MIN()
    - MAX()
    - AGE()
    - EXTRACT()
    - CURRENT_DATE
===============================================================================
*/

-- Determine the first and last order date and the total duration in months
SELECT
    MIN(order_date) AS first_order_date,
    MAX(order_date) AS last_order_date,
    (
        EXTRACT(YEAR FROM AGE(MAX(order_date), MIN(order_date))) * 12
        +
        EXTRACT(MONTH FROM AGE(MAX(order_date), MIN(order_date)))
    ) AS order_range_months
FROM gold.fact_sales;

-- Find the youngest and oldest customer based on birthdate
SELECT
    MIN(birth_date) AS oldest_birthdate,
    EXTRACT(YEAR FROM AGE(CURRENT_DATE, MIN(birth_date))) AS oldest_age,

    MAX(birth_date) AS youngest_birthdate,
    EXTRACT(YEAR FROM AGE(CURRENT_DATE, MAX(birth_date))) AS youngest_age
FROM gold.dim_customers;