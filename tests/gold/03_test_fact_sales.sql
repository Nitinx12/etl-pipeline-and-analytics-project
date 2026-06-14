-- Test 1: Composite Key Uniqueness
-- Verifies the ON CONFLICT (order_number, product_key) DO NOTHING constraint.
SELECT order_number, product_key, COUNT(*) 
FROM gold.fact_sales 
GROUP BY order_number, product_key 
HAVING COUNT(*) > 1;

-- Test 2: Referential Integrity (Products)
-- Confirms that every product_key in the fact table exists in the dimension table.
-- (This should return 0 if the INNER JOIN in your proc worked properly).
SELECT fs.product_key 
FROM gold.fact_sales fs 
LEFT JOIN gold.dim_products dp 
    ON fs.product_key = dp.product_number 
WHERE dp.product_number IS NULL;

-- Test 3: Referential Integrity (Customers)
-- Confirms that every customer_key in the fact table exists in the dimension table.
SELECT fs.customer_key 
FROM gold.fact_sales fs 
LEFT JOIN gold.dim_customers dc 
    ON fs.customer_key = dc.customer_id 
WHERE dc.customer_id IS NULL;

-- Test 4: Logical Chronology Check
-- Validates that the order_date happens before or on the ship_date.
SELECT * FROM gold.fact_sales 
WHERE order_date > ship_date;

-- Test 5: Financial Metrics Validation
-- Checks for invalid negative metrics (sales, quantity, or price cannot be strictly negative).
SELECT * FROM gold.fact_sales 
WHERE sales < 0 
   OR quantity <= 0 
   OR price < 0;