# =============================================================================
# run_gold.ps1
# Calls gold.load_gold_layer() — builds the Star Schema (dim + fact tables).
#
# Usage:
#   .\run_gold.ps1
#   .\run_gold.ps1 -EnvFile "C:\path\to\.env"
#   .\run_gold.ps1 -SkipSilverCheck     # skip dependency validation
# =============================================================================

[CmdletBinding()]
param(
    [string]$EnvFile       = "$PSScriptRoot\.env",
    [switch]$SkipSilverCheck
)

# Load shared config
$env:DOTENV_PATH = $EnvFile
. "$PSScriptRoot\config.ps1"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
$STAGE   = "gold"
$PROC    = "gold.load_gold_layer()"
$LOG     = Get-LogPath -Stage $STAGE -Name "run_gold"
$START   = Get-Date

Write-Banner -Title "GOLD LOAD  —  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -LogFile $LOG

Write-Log "Stage      : Gold (Silver → dim_customers, dim_products, fact_sales)" "INFO" $LOG
Write-Log "Procedure  : CALL $PROC"                                              "INFO" $LOG
Write-Log "Log file   : $LOG"                                                    "INFO" $LOG
Write-Log ""                                                                      "INFO" $LOG

# ---------------------------------------------------------------------------
# Dependency check — confirm Silver has data before running Gold
# ---------------------------------------------------------------------------
if (-not $SkipSilverCheck) {
    Write-SectionBanner -Title "Pre-flight: Silver Dependency Check" -LogFile $LOG

    $checkSql = @"
SELECT
  (SELECT COUNT(*) FROM silver.crm_cust_info)     AS s_crm_cust,
  (SELECT COUNT(*) FROM silver.crm_prd_info)      AS s_crm_prd,
  (SELECT COUNT(*) FROM silver.crm_sales_details) AS s_crm_sales;
"@

    $checkOk = Invoke-Psql -Sql $checkSql -LogFile $LOG -Stage $STAGE
    if (-not $checkOk) {
        Write-Log "Silver dependency check failed — is Silver populated? Run run_silver.ps1 first." "ERROR" $LOG
        Write-Log "To skip this check, re-run with -SkipSilverCheck." "WARN" $LOG
        exit 2
    }
    Write-Log "" "INFO" $LOG
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
Write-SectionBanner -Title "Executing Stored Procedure" -LogFile $LOG

$ok = Invoke-Psql -Sql "CALL $PROC;" -LogFile $LOG -Stage $STAGE

# ---------------------------------------------------------------------------
# Post-run: tail the ETL log table + Star Schema row counts
# ---------------------------------------------------------------------------
if ($ok) {
    Write-Log "" "INFO" $LOG
    Write-SectionBanner -Title "ETL Log (last 3 rows)" -LogFile $LOG
    $tailSql = "SELECT table_name, rows_affected, duration_seconds, status, error_message FROM gold.etl_log ORDER BY step_start DESC LIMIT 3;"
    Invoke-Psql -Sql $tailSql -LogFile $LOG -Stage $STAGE | Out-Null

    Write-Log "" "INFO" $LOG
    Write-SectionBanner -Title "Star Schema Row Counts" -LogFile $LOG
    $countSql = @"
SELECT
  'dim_customers' AS target,  COUNT(*) AS rows FROM gold.dim_customers
UNION ALL
SELECT 'dim_products',  COUNT(*) FROM gold.dim_products
UNION ALL
SELECT 'fact_sales',    COUNT(*) FROM gold.fact_sales
ORDER BY target;
"@
    Invoke-Psql -Sql $countSql -LogFile $LOG -Stage $STAGE | Out-Null
}

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
$ELAPSED = [math]::Round(((Get-Date) - $START).TotalSeconds, 2)

Write-Log "" "INFO" $LOG
if ($ok) {
    Write-Log "GOLD LOAD SUCCEEDED in ${ELAPSED}s" "SUCCESS" $LOG
    exit 0
} else {
    Write-Log "GOLD LOAD FAILED after ${ELAPSED}s  — check log: $LOG" "ERROR" $LOG
    exit 1
}