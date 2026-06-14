-- Test 1: Primary Key Uniqueness
SELECT id, COUNT(*) 
FROM silver.erp_px_cat_g1v2 
GROUP BY id 
HAVING COUNT(*) > 1;

-- Test 2: Primary Key Null Check
-- Ensures no null primary keys were inserted into this reference table.
SELECT * FROM silver.erp_px_cat_g1v2 
WHERE id IS NULL;

-- Test 3: Category Completeness
-- A lookup table should not have missing high-level categories.
SELECT * FROM silver.erp_px_cat_g1v2 
WHERE cat IS NULL OR TRIM(cat) = '';

-- Test 4: Sub-Category Completeness
-- A lookup table should not have missing sub-categories.
SELECT * FROM silver.erp_px_cat_g1v2 
WHERE subcate IS NULL OR TRIM(subcate) = '';

-- Test 5: Maintenance Flag Completeness
-- Checks for missing data in the maintenance tracking column.
SELECT * FROM silver.erp_px_cat_g1v2 
WHERE maintenance IS NULL OR TRIM(maintenance) = '';