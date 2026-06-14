-- Test 1: Primary Key Uniqueness
SELECT cid, COUNT(*) 
FROM silver.erp_loc_a101 
GROUP BY cid 
HAVING COUNT(*) > 1;

-- Test 2: Primary Key Null Check
SELECT * FROM silver.erp_loc_a101 
WHERE cid IS NULL;

-- Test 3: Hyphen Cleansing Verification
-- Ensures REPLACE(cid, '-', '') successfully removed all hyphens.
SELECT * FROM silver.erp_loc_a101 
WHERE cid LIKE '%-%';

-- Test 4: Country Standardisation Check
-- Confirms the legacy country codes were successfully expanded to full names.
SELECT * FROM silver.erp_loc_a101 
WHERE cntry IN ('DE', 'US', 'USA', '');

-- Test 5: Country Whitespace Check
-- Verifies the TRIM(cntry) logic caught stray spaces on unmapped countries.
SELECT * FROM silver.erp_loc_a101 
WHERE cntry <> TRIM(cntry);