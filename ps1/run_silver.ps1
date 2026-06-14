# =============================================================================
# run_silver.ps1
# Calls silver.load_silver_layer() — cleanses & upserts Bronze → Silver.
#
# Usage:
#   .\run_silver.ps1
#   .\run_silver.ps1 -EnvFile "C:\path\to\.env"
#   .\run_silver.ps1 -SkipBronzeCheck     # skip dependency validation
# =============================================================================

[CmdletBinding()]
param(
    [string]$EnvFile        = "$PSScriptRoot\.env",
    [switch]$SkipBronzeCheck
)

# Load shared config
$env:DOTENV_PATH = $EnvFile
. "$PSScriptRoot\config.ps1"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
$STAGE   = "silver"
$PROC    = "silver.load_silver_layer()"
$LOG     = Get-LogPath -Stage $STAGE -Name "run_silver"
$START   = Get-Date

Write-Banner -Title "SILVER LOAD  —  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -LogFile $LOG

Write-Log "Stage      : Silver (Bronze → Silver, upsert + transforms)" "INFO" $LOG
Write-Log "Procedure  : CALL $PROC"                                     "INFO" $LOG
Write-Log "Log file   : $LOG"                                           "INFO" $LOG
Write-Log ""                                                             "INFO" $LOG

# ---------------------------------------------------------------------------
# Dependency check — confirm Bronze has data before running Silver
# ---------------------------------------------------------------------------
if (-not $SkipBronzeCheck) {
    Write-SectionBanner -Title "Pre-flight: Bronze Dependency Check" -LogFile $LOG

    $checkSql = @"
SELECT
  (SELECT COUNT(*) FROM bronze.crm_cust_info)      AS crm_cust,
  (SELECT COUNT(*) FROM bronze.crm_prd_info)       AS crm_prd,
  (SELECT COUNT(*) FROM bronze.crm_sales_details)  AS crm_sales,
  (SELECT COUNT(*) FROM bronze.erp_cust_az12)      AS erp_cust,
  (SELECT COUNT(*) FROM bronze.erp_loc_a101)       AS erp_loc,
  (SELECT COUNT(*) FROM bronze.erp_px_cat_g1v2)    AS erp_cat;
"@

    $checkOk = Invoke-Psql -Sql $checkSql -LogFile $LOG -Stage $STAGE
    if (-not $checkOk) {
        Write-Log "Bronze dependency check failed — is Bronze populated? Run run_bronze.ps1 first." "ERROR" $LOG
        Write-Log "To skip this check, re-run with -SkipBronzeCheck." "WARN" $LOG
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
# Post-run: tail the ETL log table
# ---------------------------------------------------------------------------
if ($ok) {
    Write-Log "" "INFO" $LOG
    Write-SectionBanner -Title "ETL Log (last 6 rows)" -LogFile $LOG
    $tailSql = "SELECT table_name, rows_affected, duration_seconds, status, error_message FROM silver.etl_log ORDER BY step_start DESC LIMIT 6;"
    Invoke-Psql -Sql $tailSql -LogFile $LOG -Stage $STAGE | Out-Null
}

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
$ELAPSED = [math]::Round(((Get-Date) - $START).TotalSeconds, 2)

Write-Log "" "INFO" $LOG
if ($ok) {
    Write-Log "SILVER LOAD SUCCEEDED in ${ELAPSED}s" "SUCCESS" $LOG
    exit 0
} else {
    Write-Log "SILVER LOAD FAILED after ${ELAPSED}s  — check log: $LOG" "ERROR" $LOG
    exit 1
}