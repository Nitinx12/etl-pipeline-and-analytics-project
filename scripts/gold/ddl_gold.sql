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
    - Creates Dimension Tables (dim_customers, dim_products) with primary 
      and unique keys required for idempotent Upsert (ON CONFLICT) logic.
    - Creates Fact Table (fact_sales) with composite unique constraints to 
      prevent duplicate transaction records.
    - Creates an ETL Log Table (etl_log) to track pipeline execution history,
      durations, and potential errors.
    - Establishes Foreign Key constraints to enforce referential integrity 
      between the fact and dimension tables.

Usage Example:
    Execute this script once to initialize or reset the data warehouse 
    environment before running the ETL pipelines.
===============================================================================
*/

-- Create schema if it doesn't exist
CREATE SCHEMA IF NOT EXISTS gold;

-- ==========================================
-- TABLE: gold.dim_customers
-- ==========================================
DROP TABLE IF EXISTS gold.dim_customers CASCADE;
CREATE TABLE gold.dim_customers (
    customer_id INT PRIMARY KEY, -- Primary key satisfies the ON CONFLICT requirement
    customer_number VARCHAR(50),
    first_name VARCHAR(50),
    last_name VARCHAR(50),
    country VARCHAR(50),
    marital_status VARCHAR(50),
    gender VARCHAR(10),
    birth_date DATE,
    create_date DATE 
);

-- ==========================================
-- TABLE: gold.dim_products
-- ==========================================
DROP TABLE IF EXISTS gold.dim_products CASCADE;
CREATE TABLE gold.dim_products (
    product_number VARCHAR(50) UNIQUE, -- UNIQUE constraint added for ON CONFLICT
    product_id INT, 
    product_name VARCHAR(100),
    category_id VARCHAR(50), -- Updated to VARCHAR(50) based on source data
    category VARCHAR(50),
    sub_category VARCHAR(50),
    maintenance VARCHAR(50),
    product_cost NUMERIC(10, 2),
    product_line VARCHAR(50),
    start_date DATE
);

-- ==========================================
-- TABLE: gold.fact_sales
-- ==========================================
DROP TABLE IF EXISTS gold.fact_sales CASCADE;
CREATE TABLE gold.fact_sales (
    order_number VARCHAR(50),
    product_key VARCHAR(50),
    customer_key INT,
    order_date DATE,
    ship_date DATE,
    due_date DATE,
    sales NUMERIC(15, 2),
    quantity INT,
    price NUMERIC(10, 2),
    -- Composite constraint added for ON CONFLICT (order_number, product_key)
    CONSTRAINT uq_fact_sales_order_product UNIQUE (order_number, product_key) 
);

-- ==========================================
-- TABLE: gold.etl_log
-- ==========================================
DROP TABLE IF EXISTS gold.etl_log CASCADE;
CREATE TABLE gold.etl_log (
    log_id SERIAL PRIMARY KEY, -- 'DEFAULT' in your procedure implies an auto-incrementing ID
    procedure_name VARCHAR(100),
    table_name VARCHAR(100),
    rows_affected INT,
    start_time TIMESTAMP,
    end_time TIMESTAMP,
    duration_seconds NUMERIC,
    status VARCHAR(20),
    error_message TEXT
);

-- ==========================================
-- FOREIGN KEY CONSTRAINTS
-- ==========================================
ALTER TABLE gold.fact_sales
ADD CONSTRAINT fk_customer FOREIGN KEY (customer_key) REFERENCES gold.dim_customers (customer_id),
ADD CONSTRAINT fk_product FOREIGN KEY (product_key) REFERENCES gold.dim_products (product_number);