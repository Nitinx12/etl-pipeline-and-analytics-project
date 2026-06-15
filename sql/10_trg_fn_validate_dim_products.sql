CREATE OR REPLACE FUNCTION gold.trg_fn_validate_dim_products()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    -- ────────────────────────────────────────
    -- SHARED VALIDATIONS (INSERT & UPDATE)
    -- ────────────────────────────────────────

    -- ① product_name cannot be NULL or blank
    IF NEW.product_name IS NULL OR TRIM(NEW.product_name) = '' THEN
        RAISE EXCEPTION
            'Validation failed: product_name cannot be NULL or empty';
    END IF;

    -- ② product_number cannot be NULL or blank
    IF NEW.product_number IS NULL OR TRIM(NEW.product_number) = '' THEN
        RAISE EXCEPTION
            'Validation failed: product_number cannot be NULL or empty';
    END IF;

    -- ③ product_cost cannot be NULL
    IF NEW.product_cost IS NULL THEN
        RAISE EXCEPTION
            'Validation failed: product_cost cannot be NULL';
    END IF;

    -- ④ product_cost cannot be negative
    IF NEW.product_cost < 0 THEN
        RAISE EXCEPTION
            'Validation failed: product_cost cannot be negative, got %',
            NEW.product_cost;
    END IF;

    -- ⑤ category cannot be NULL or blank
    IF NEW.category IS NULL OR TRIM(NEW.category) = '' THEN
        RAISE EXCEPTION
            'Validation failed: category cannot be NULL or empty';
    END IF;

    -- ⑥ start_date cannot be NULL
    IF NEW.start_date IS NULL THEN
        RAISE EXCEPTION
            'Validation failed: start_date cannot be NULL';
    END IF;

    -- ⑦ start_date cannot be in the future
    IF NEW.start_date > CURRENT_DATE THEN
        RAISE EXCEPTION
            'Validation failed: start_date (%) cannot be in the future',
            NEW.start_date;
    END IF;

    -- ────────────────────────────────────────
    -- UPDATE-ONLY VALIDATIONS
    -- ────────────────────────────────────────

    IF TG_OP = 'UPDATE' THEN

        -- ⑧ product_key is immutable — block any PK change
        IF NEW.product_key <> OLD.product_key THEN
            RAISE EXCEPTION
                'Validation failed: product_key is immutable and cannot be changed (% → %)',
                OLD.product_key, NEW.product_key;
        END IF;

        -- ⑨ warn if product_cost changes by more than 50%
        IF OLD.product_cost IS NOT NULL
           AND OLD.product_cost > 0
           AND ABS(NEW.product_cost - OLD.product_cost) / OLD.product_cost > 0.5 THEN
            RAISE WARNING
                'Large cost change detected on product % — % → %',
                NEW.product_number, OLD.product_cost, NEW.product_cost;
        END IF;

    END IF;

    -- ────────────────────────────────────────
    -- ALL CHECKS PASSED
    -- ────────────────────────────────────────
    RAISE NOTICE
        'dim_products validation passed | operation: % | product: %',
        TG_OP, NEW.product_number;

    RETURN NEW;

END;
$$;


-- ══════════════════════════════════════════
-- STEP 2 — Attach Trigger to Table
-- ══════════════════════════════════════════

CREATE OR REPLACE TRIGGER trg_validate_dim_products
    BEFORE INSERT OR UPDATE
    ON gold.dim_products
    FOR EACH ROW
    EXECUTE FUNCTION gold.trg_fn_validate_dim_products();


-- Blocked — negative cost
INSERT INTO gold.dim_products (product_name, product_number, product_cost, category, start_date)
VALUES ('Road Bike', 'RB-001', -50, 'Bikes', '2022-01-01');
-- ERROR: Validation failed: product_cost cannot be negative, got -50

-- Blocked — future start_date
INSERT INTO gold.dim_products (product_name, product_number, product_cost, category, start_date)
VALUES ('Road Bike', 'RB-001', 500, 'Bikes', '2099-01-01');
-- ERROR: Validation failed: start_date (2099-01-01) cannot be in the future

-- Blocked — trying to change primary key
UPDATE gold.dim_products SET product_key = 999 WHERE product_key = 1;
-- ERROR: Validation failed: product_key is immutable and cannot be changed (1 → 999)

-- Allowed with warning — big price jump
UPDATE gold.dim_products SET product_cost = 1000 WHERE product_cost = 100;
-- WARNING: Large cost change detected on product RB-001 — 100 → 1000

-- Passes all checks
INSERT INTO gold.dim_products (product_name, product_number, product_cost, category, start_date)
VALUES ('Road Bike', 'RB-001', 500, 'Bikes', '2022-01-01');
-- NOTICE: dim_products validation passed | operation: INSERT | product: RB-001