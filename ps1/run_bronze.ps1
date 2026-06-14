# =============================================================================
# run_bronze.ps1
# Calls bronze.load_bronze() — ingests raw CSVs into the Bronze landing zone.
#
# Usage:
#   .\run_bronze.ps1
#   .\run_bronze.ps1 -EnvFile "C:\path\to\.env"
# =============================================================================

[CmdletBinding()]
param(
    [string]$EnvFile = "$PSScriptRoot\.env"
)

# Load shared config
$env:DOTENV_PATH = $EnvFile
. "$PSScriptRoot\config.ps1"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
$STAGE   = "bronze"
$PROC    = "bronze.load_bronze()"
$LOG     = Get-LogPath -Stage $STAGE -Name "run_bronze"
$START   = Get-Date

Write-Banner -Title "BRONZE LOAD  —  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -LogFile $LOG

Write-Log "Stage      : Bronze (CSV → bronze schema)" "INFO" $LOG
Write-Log "Procedure  : CALL $PROC"                   "INFO" $LOG
Write-Log "Log file   : $LOG"                         "INFO" $LOG
Write-Log ""                                           "INFO" $LOG

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
Write-SectionBanner -Title "Executing Stored Procedure" -LogFile $LOG

$ok = Invoke-Psql -Sql "CALL $PROC;" -LogFile $LOG -Stage $STAGE

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
$ELAPSED = [math]::Round(((Get-Date) - $START).TotalSeconds, 2)

Write-Log "" "INFO" $LOG
if ($ok) {
    Write-Log "BRONZE LOAD SUCCEEDED in ${ELAPSED}s" "SUCCESS" $LOG
    exit 0
} else {
    Write-Log "BRONZE LOAD FAILED after ${ELAPSED}s  — check log: $LOG" "ERROR" $LOG
    exit 1
}