
/*
=============================================================
Create Database and Schemas
=============================================================
Script Purpose:
    Creates a database named 'datawarehouse' after dropping it
    if it already exists. Then creates three schemas:
    bronze, silver, and gold.

WARNING:
    Running this script will delete the existing database
    and all its data permanently.
*/

-- Drop database if exists
DROP DATABASE IF EXISTS Datawarehouse;


-- Create database
CREATE DATABASE Datawarehouse;

-- Create Schemas
CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;