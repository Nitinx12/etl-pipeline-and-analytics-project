-- Test 1: Primary Key Uniqueness
-- Checks for duplicates on the upsert conflict key.
SELECT prd_id, COUNT(*) 
FROM silver.crm_prd_info 
GROUP BY prd_id 
HAVING COUNT(*) > 1;

-- Test 2: Primary Key Null Check
-- Ensures no null primary keys were inserted.
SELECT * FROM silver.crm_prd_info 
WHERE prd_id IS NULL;

-- Test 3: Product Line Domain Check
-- Confirms the abbreviation expansion worked correctly.
SELECT * FROM silver.crm_prd_info 
WHERE prd_line NOT IN ('Mountain', 'Road', 'Other Sales', 'Touring', 'N/A');

-- Test 4: Null Cost Default Check
-- Verifies the COALESCE(prd_cost, 0) logic caught any NULL values.
SELECT * FROM silver.crm_prd_info 
WHERE prd_cost IS NULL;

-- Test 5: SCD Date Chronology Check
-- Validates the LEAD() window function logic: a product's start date cannot be after its end date.
SELECT * FROM silver.crm_prd_info 
WHERE prd_start_dt > prd_end_dt;