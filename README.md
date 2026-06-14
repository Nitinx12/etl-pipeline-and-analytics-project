
```
ETL Pipeline and Analytics Project
├─ .python-version
├─ datasets
│  ├─ source_crm
│  │  ├─ cust_info.csv
│  │  ├─ prd_info.csv
│  │  └─ sales_details.csv
│  └─ source_erp
│     ├─ CUST_AZ12.csv
│     ├─ LOC_A101.csv
│     └─ PX_CAT_G1V2.csv
├─ docs
├─ logs
├─ main.py
├─ ps1
│  ├─ config.ps1
│  ├─ logs
│  │  └─ pipeline
│  │     └─ run_pipeline_2026-06-14_14-35.log
│  ├─ README.md
│  ├─ run_bronze.ps1
│  ├─ run_gold.ps1
│  ├─ run_pipeline.ps1
│  └─ run_silver.ps1
├─ pyproject.toml
├─ README.md
├─ reports
├─ scripts
│  ├─ 00_setup_database.sql
│  ├─ bronze
│  │  ├─ ddl_bronze.sql
│  │  └─ proc_load_bronze.sql
│  ├─ gold
│  │  ├─ ddl_gold.sql
│  │  └─ proc_load_gold.sql
│  └─ silver
│     ├─ ddl_silver.sql
│     └─ proc_load_silver.sql
├─ sql
├─ tests
├─ utils
│  ├─ connection.py
│  ├─ engine.py
│  └─ logger.py
└─ uv.lock

```