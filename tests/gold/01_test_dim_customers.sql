-- Test 1: Primary Key Uniqueness
-- Checks if any customer_id has been duplicated during the upsert.
SELECT customer_id, COUNT(*) 
FROM gold.dim_customers 
GROUP BY customer_id 
HAVING COUNT(*) > 1;

-- Test 2: Primary Key Null Check
-- Ensures the upstream quality gate (WHERE CI.cst_id IS NOT NULL) worked correctly.
SELECT * FROM gold.dim_customers 
WHERE customer_id IS NULL;

-- Test 3: Gender Fallback Validation
-- Ensures the COALESCE logic worked and no NULL genders slipped through.
SELECT * FROM gold.dim_customers 
WHERE gender IS NULL;

-- Test 4: Birth Date Logic
-- Validates that no birth dates are in the future (sanity check on the Silver cleanse).
SELECT * FROM gold.dim_customers 
WHERE birth_date > CURRENT_DATE;

-- Test 5: Logical Chronology Check
-- Ensures a customer's birth date is not after their system creation date.
SELECT * FROM gold.dim_customers 
WHERE birth_date > create_date;