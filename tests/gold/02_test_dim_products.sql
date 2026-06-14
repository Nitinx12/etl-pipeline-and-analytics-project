-- Test 1: Primary Key Uniqueness
-- Checks if any product_number has been duplicated.
SELECT product_number, COUNT(*) 
FROM gold.dim_products 
GROUP BY product_number 
HAVING COUNT(*) > 1;

-- Test 2: Active Version Integrity (One active record per product_id)
-- Since historical records are filtered out, there should only be one active product_id.
SELECT product_id, COUNT(*) 
FROM gold.dim_products 
GROUP BY product_id 
HAVING COUNT(*) > 1;

-- Test 3: Primary Key Null Check
-- Ensures no null primary keys were inserted.
SELECT * FROM gold.dim_products 
WHERE product_number IS NULL;

-- Test 4: Negative Cost Validation
-- Ensures the product cost is zero or greater.
SELECT * FROM gold.dim_products 
WHERE product_cost < 0;

-- Test 5: Essential Attribute Completeness
-- Ensures every product has a valid name (not null and not empty string).
SELECT * FROM gold.dim_products 
WHERE product_name IS NULL OR TRIM(product_name) = '';