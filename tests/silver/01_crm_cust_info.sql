-- Test 1: Primary Key Uniqueness
-- Ensures the ROW_NUMBER() deduplication logic successfully kept only one record per cst_id.
SELECT cst_id, COUNT(*) 
FROM silver.crm_cust_info 
GROUP BY cst_id 
HAVING COUNT(*) > 1;

-- Test 2: Primary Key Null Check
-- Ensures the WHERE cst_id IS NOT NULL quality gate worked.
SELECT * FROM silver.crm_cust_info 
WHERE cst_id IS NULL;

-- Test 3: Marital Status Domain Check
-- Confirms the CASE statement properly restricted values to the defined set.
SELECT * FROM silver.crm_cust_info 
WHERE cst_marital_status NOT IN ('Single', 'Married', 'N/A');

-- Test 4: Gender Domain Check
-- Confirms the CASE statement properly restricted values to the defined set.
SELECT * FROM silver.crm_cust_info 
WHERE cst_gndr NOT IN ('Female', 'Male', 'N/A');

-- Test 5: Whitespace Cleansing Verification
-- Checks if the TRIM() function successfully removed trailing/leading spaces.
SELECT * FROM silver.crm_cust_info 
WHERE cst_first_name <> TRIM(cst_first_name) 
   OR cst_last_name <> TRIM(cst_last_name);