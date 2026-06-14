-- Test 1: Composite Key Uniqueness
-- Validates the ON CONFLICT (sls_ord_num, sls_prd_key) constraint.
SELECT sls_ord_num, sls_prd_key, COUNT(*) 
FROM silver.crm_sales_details 
GROUP BY sls_ord_num, sls_prd_key 
HAVING COUNT(*) > 1;

-- Test 2: Composite Key Null Check
-- Ensures neither part of the composite primary key is NULL.
SELECT * FROM silver.crm_sales_details 
WHERE sls_ord_num IS NULL 
   OR sls_prd_key IS NULL;

-- Test 3: Sales Equation Integrity
-- Confirms the recalculation logic worked: sales MUST equal quantity * absolute price.
SELECT * FROM silver.crm_sales_details 
WHERE sls_sales <> sls_quantity * ABS(sls_price);

-- Test 4: Invalid Price Check
-- Verifies the logic that corrects missing or non-positive prices.
SELECT * FROM silver.crm_sales_details 
WHERE sls_price IS NULL 
   OR sls_price <= 0;

-- Test 5: Logical Date Chronology
-- Sanity check to ensure order date is not after the ship date.
SELECT * FROM silver.crm_sales_details 
WHERE sls_order_dt > sls_ship_date;