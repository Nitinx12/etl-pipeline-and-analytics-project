/*
===============================================================================
DDL Script: Create Silver Tables
===============================================================================
Script Purpose:
    This script creates tables in the 'silver' schema, dropping existing tables 
    if they already exist.
    Run this script to re-define the DDL structure of 'silver' Tables.
    *UPDATED: Includes Primary Keys for Upsert logic and standardized column names.*
===============================================================================
*/

-- CREATE SCHEMA IF NOT EXISTS silver;

-- ==========================================
-- 1. CRM CUSTOMER INFO
-- ==========================================
DROP TABLE IF EXISTS silver.crm_cust_info CASCADE;
CREATE TABLE silver.crm_cust_info (
    cst_id             INT PRIMARY KEY,
    cst_key            VARCHAR(50),
    cst_first_name     VARCHAR(50), 
    cst_last_name      VARCHAR(50),   
    cst_marital_status VARCHAR(50),
    cst_gndr           VARCHAR(50),
    cst_create_date    DATE,
    dwh_create_date    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================
-- 2. CRM PRODUCT INFO
-- ==========================================
DROP TABLE IF EXISTS silver.crm_prd_info CASCADE;
CREATE TABLE silver.crm_prd_info (
    prd_id             INT PRIMARY KEY,
    cat_id             VARCHAR(50),
    prd_key            VARCHAR(50),
    prd_nm             VARCHAR(50),
    prd_cost           INT,
    prd_line           VARCHAR(50),
    prd_start_dt       DATE,
    prd_end_dt         DATE,
    dwh_create_date    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================
-- 3. CRM SALES DETAILS
-- ==========================================
DROP TABLE IF EXISTS silver.crm_sales_details CASCADE;
CREATE TABLE silver.crm_sales_details (
    sls_ord_num        VARCHAR(50),
    sls_prd_key        VARCHAR(50),
    sls_cust_id        INT,
    sls_order_dt       DATE,
    sls_ship_date      DATE,            
    sls_due_date       DATE,           
    sls_sales          NUMERIC(15, 2),
    sls_quantity       INT,
    sls_price          NUMERIC(15, 2),
    dwh_create_date    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_slv_sales PRIMARY KEY (sls_ord_num, sls_prd_key)
);

-- ==========================================
-- 4. ERP LOCATION A101
-- ==========================================
DROP TABLE IF EXISTS silver.erp_loc_a101 CASCADE;
CREATE TABLE silver.erp_loc_a101 (
    cid                VARCHAR(50) PRIMARY KEY,
    cntry              VARCHAR(50),
    dwh_create_date    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================
-- 5. ERP CUSTOMER AZ12
-- ==========================================
DROP TABLE IF EXISTS silver.erp_cust_az12 CASCADE;
CREATE TABLE silver.erp_cust_az12 (
    cid                VARCHAR(50) PRIMARY KEY,
    bdate              DATE,
    gen                VARCHAR(50),
    dwh_create_date    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================
-- 6. ERP PX CATEGORY G1V2
-- ==========================================
DROP TABLE IF EXISTS silver.erp_px_cat_g1v2 CASCADE;
CREATE TABLE silver.erp_px_cat_g1v2 (
    id                 VARCHAR(50) PRIMARY KEY,
    cat                VARCHAR(50),
    subcate            VARCHAR(50),             
    maintenance        VARCHAR(50),
    dwh_create_date    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================
-- 7. ETL LOGGING TABLE
-- ==========================================
DROP TABLE IF EXISTS silver.etl_log CASCADE;
CREATE TABLE silver.etl_log (
    log_id             SERIAL PRIMARY KEY,
    procedure_name     VARCHAR(100),
    table_name         VARCHAR(100),
    rows_affected      INT,
    start_time         TIMESTAMP,
    end_time           TIMESTAMP,
    duration_seconds   NUMERIC,
    status             VARCHAR(20),
    error_message      TEXT
);