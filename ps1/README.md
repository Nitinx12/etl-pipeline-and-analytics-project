# PowerShell Pipeline Scripts

Automates the full Medallion ETL pipeline via three stored procedures.

## Files

| Script | Purpose |
|---|---|
| `config.ps1` | Shared config, `.env` loader, `Invoke-Psql`, logger — dot-sourced by all scripts |
| `run_bronze.ps1` | Calls `bronze.load_bronze()` |
| `run_silver.ps1` | Calls `silver.load_silver_layer()` |
| `run_gold.ps1` | Calls `gold.load_gold_layer()` |
| `run_pipeline.ps1` | Runs all three layers in order (master orchestrator) |

## Setup

**1. Place your `.env` next to the scripts (or pass `-EnvFile` explicitly)**
```
POSTGRES_HOST=XXXXX
POSTGRES_PORT=5432
POSTGRES_DATABASE=Datawarehouse
POSTGRES_USERNAME=XXXXX
POSTGRES_PASSWORD=XXXXX
```

**2. Ensure `psql` is on your PATH**
```powershell
$env:PATH += ";C:\Program Files\PostgreSQL\16\bin"
```

**3. Allow script execution (run once as Admin)**
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

## Usage

```powershell
# Full pipeline (recommended)
.\run_pipeline.ps1

# Individual layers
.\run_bronze.ps1
.\run_silver.ps1
.\run_gold.ps1

# Resume from a specific layer
.\run_pipeline.ps1 -StartFrom silver
.\run_pipeline.ps1 -StartFrom gold

# Custom .env path
.\run_pipeline.ps1 -EnvFile "D:\myproject\.env"

# Dry run — prints plan, executes nothing
.\run_pipeline.ps1 -DryRun

# Skip dependency checks on individual scripts
.\run_silver.ps1 -SkipBronzeCheck
.\run_gold.ps1   -SkipSilverCheck
```

## Logs

```
logs/
├── bronze/   run_bronze_2026-06-14_10-30.log
├── silver/   run_silver_2026-06-14_10-31.log
├── gold/     run_gold_2026-06-14_10-32.log
└── pipeline/ run_pipeline_2026-06-14_10-30.log
```

All RAISE NOTICE output from PostgreSQL is captured into both the console and the log file.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | SQL / connection error |
| `2` | Dependency check failed (Bronze/Silver not populated) |