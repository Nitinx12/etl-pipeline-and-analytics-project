/*
===============================================================================
DDL Script: Create Gold Layer (Star Schema)
===============================================================================
Script Purpose:
    This script creates the final 'gold' schema and the required dimension
    and fact tables for the data warehouse. This layer represents the 
    presentation tier, structured as a Star Schema, and is optimized for 
    business analytics and reporting.

Actions Performed:
    - Creates the 'gold' schema if it does not exist.
    - Drops existing tables (if any) to ensure a clean build.
    - Creates Dimension Tables (dim_customers, dim_products) with:
        • A SERIAL surrogate key (customer_key / product_key) as PRIMARY KEY.
        • A UNIQUE natural key (customer_id / product_number) for ON CONFLICT.
    - Creates Fact Table (fact_sales) with:
        • product_key  INT  → FK to dim_products.product_key  (surrogate)
        • customer_key INT  → FK to dim_customers.customer_key (surrogate)
        • Composite UNIQUE constraint for idempotent upsert.
    - Creates ETL Log Table (etl_log).
    - Establishes Foreign Key constraints.

Fixes vs original:
    dim_customers : Added  customer_key SERIAL PRIMARY KEY  (surrogate).
                    Changed customer_id from PK  →  UNIQUE NOT NULL (natural key).
    dim_products  : Added  product_key  SERIAL PRIMARY KEY  (surrogate).
                    product_number remains UNIQUE NOT NULL  (natural key).
    fact_sales    : product_key changed VARCHAR(50) → INT  (now points to
                    surrogate, not to product_number string).
                    FK fk_customer now references dim_customers.customer_key.
                    FK fk_product  now references dim_products.product_key.
===============================================================================
*/

-- Create schema if it doesn't exist
CREATE SCHEMA IF NOT EXISTS gold;

-- ==========================================
-- TABLE: gold.dim_customers
-- ==========================================
DROP TABLE IF EXISTS gold.dim_customers CASCADE;
CREATE TABLE gold.dim_customers (
    customer_key    SERIAL       PRIMARY KEY,          -- Surrogate key (auto-generated)
    customer_id     INT          NOT NULL UNIQUE,      -- Natural key  (ON CONFLICT target)
    customer_number VARCHAR(50),
    first_name      VARCHAR(50),
    last_name       VARCHAR(50),
    country         VARCHAR(50),
    marital_status  VARCHAR(50),
    gender          VARCHAR(10),
    birth_date      DATE,
    create_date     DATE
);

-- ==========================================
-- TABLE: gold.dim_products
-- ==========================================
DROP TABLE IF EXISTS gold.dim_products CASCADE;
CREATE TABLE gold.dim_products (
    product_key     SERIAL       PRIMARY KEY,          -- Surrogate key (auto-generated)
    product_number  VARCHAR(50)  NOT NULL UNIQUE,      -- Natural key  (ON CONFLICT target)
    product_id      INT,
    product_name    VARCHAR(100),
    category_id     VARCHAR(50),
    category        VARCHAR(50),
    sub_category    VARCHAR(50),
    maintenance     VARCHAR(50),
    product_cost    NUMERIC(10, 2),
    product_line    VARCHAR(50),
    start_date      DATE
);

-- ==========================================
-- TABLE: gold.fact_sales
-- ==========================================
DROP TABLE IF EXISTS gold.fact_sales CASCADE;
CREATE TABLE gold.fact_sales (
    order_number    VARCHAR(50),
    product_key     INT,                               -- FK → dim_products.product_key  (surrogate INT)
    customer_key    INT,                               -- FK → dim_customers.customer_key (surrogate INT)
    order_date      DATE,
    ship_date       DATE,
    due_date        DATE,
    sales           NUMERIC(15, 2),
    quantity        INT,
    price           NUMERIC(10, 2),
    CONSTRAINT uq_fact_sales_order_product UNIQUE (order_number, product_key)
);

-- ==========================================
-- TABLE: gold.etl_log
-- ==========================================
DROP TABLE IF EXISTS gold.etl_log CASCADE;
CREATE TABLE gold.etl_log (
    log_id          SERIAL       PRIMARY KEY,
    procedure_name  VARCHAR(100),
    table_name      VARCHAR(100),
    rows_affected   INT,
    start_time      TIMESTAMP,
    end_time        TIMESTAMP,
    duration_seconds NUMERIC,
    status          VARCHAR(20),
    error_message   TEXT
);

-- ==========================================
-- FOREIGN KEY CONSTRAINTS
-- ==========================================
ALTER TABLE gold.fact_sales
    ADD CONSTRAINT fk_customer FOREIGN KEY (customer_key) REFERENCES gold.dim_customers (customer_key),
    ADD CONSTRAINT fk_product  FOREIGN KEY (product_key)  REFERENCES gold.dim_products  (product_key);