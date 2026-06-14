-- Test 1: Primary Key Uniqueness
-- Checks for duplicate customer IDs in the ERP demographics table.
SELECT cid, COUNT(*) 
FROM silver.erp_cust_az12 
GROUP BY cid 
HAVING COUNT(*) > 1;

-- Test 2: Primary Key Null Check
-- Verifies the upstream WHERE cid IS NOT NULL gate.
SELECT * FROM silver.erp_cust_az12 
WHERE cid IS NULL;

-- Test 3: NAS Prefix Cleansing Check
-- Ensures the 'NAS' prefix was stripped from all legacy customer IDs.
SELECT * FROM silver.erp_cust_az12 
WHERE cid LIKE 'NAS%';

-- Test 4: Future Birth Date Cleansing
-- Verifies that impossible future birth dates were successfully set to NULL.
SELECT * FROM silver.erp_cust_az12 
WHERE bdate > CURRENT_DATE;

-- Test 5: Gender Domain Check
-- Confirms standardisation of 'MALE'/'F' to 'Male'/'Female'/'N/A'.
SELECT * FROM silver.erp_cust_az12 
WHERE gen NOT IN ('Female', 'Male', 'N/A');