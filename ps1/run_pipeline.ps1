# =============================================================================
# run_pipeline.ps1  —  Full Medallion Pipeline Orchestrator
#
# Runs all three layers in order:
#   Bronze  →  silver  →  Gold
#
# Usage:
#   .\run_pipeline.ps1
#   .\run_pipeline.ps1 -EnvFile "C:\path\to\.env"
#   .\run_pipeline.ps1 -StartFrom silver      # resume from a specific layer
#   .\run_pipeline.ps1 -StartFrom gold
#   .\run_pipeline.ps1 -DryRun                # print plan only, no execution
#
# Exit codes:
#   0  — all layers succeeded
#   1  — one or more layers failed
# =============================================================================

[CmdletBinding()]
param(
    [string]$EnvFile   = "$PSScriptRoot\.env",

    [ValidateSet("bronze","silver","gold")]
    [string]$StartFrom = "bronze",

    [switch]$DryRun
)

# Load shared config
$env:DOTENV_PATH = $EnvFile
. "$PSScriptRoot\config.ps1"

# ---------------------------------------------------------------------------
# Pipeline setup
# ---------------------------------------------------------------------------
$STAGE     = "pipeline"
$LOG       = Get-LogPath -Stage $STAGE -Name "run_pipeline"
$RUN_START = Get-Date

$LAYERS = [ordered]@{
    bronze = @{ Script = "$PSScriptRoot\run_bronze.ps1"; Label = "Bronze  (CSV → Bronze schema)"              }
    silver = @{ Script = "$PSScriptRoot\run_silver.ps1"; Label = "Silver  (Bronze → Silver, cleanse/upsert)"  }
    gold   = @{ Script = "$PSScriptRoot\run_gold.ps1";   Label = "Gold    (Silver → dim / fact Star Schema)"  }
}

$LAYER_ORDER = @("bronze","silver","gold")
$START_IDX   = $LAYER_ORDER.IndexOf($StartFrom)

# Collect only the layers we'll actually run
$RUN_LAYERS  = $LAYER_ORDER[$START_IDX..($LAYER_ORDER.Count - 1)]

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Banner -Title "MEDALLION PIPELINE  —  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -LogFile $LOG
Write-Log "Database   : $PG_USER@$PG_HOST`:$PG_PORT/$PG_DB" "INFO" $LOG
Write-Log "Start from : $StartFrom"                          "INFO" $LOG
Write-Log "Log file   : $LOG"                                "INFO" $LOG
Write-Log ""                                                  "INFO" $LOG

Write-SectionBanner -Title "Execution Plan" -LogFile $LOG
$step = 1
foreach ($layer in $RUN_LAYERS) {
    Write-Log "  [$step/$($RUN_LAYERS.Count)]  $($LAYERS[$layer].Label)" "INFO" $LOG
    $step++
}
Write-Log "" "INFO" $LOG

if ($DryRun) {
    Write-Log "DRY RUN — no procedures were called." "WARN" $LOG
    exit 0
}

# ---------------------------------------------------------------------------
# Validate psql is on PATH
# ---------------------------------------------------------------------------
if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    Write-Log "psql not found on PATH. Add your PostgreSQL bin directory to \$env:PATH." "ERROR" $LOG
    Write-Log "  Example: `$env:PATH += ';C:\Program Files\PostgreSQL\16\bin'" "WARN" $LOG
    exit 1
}

# ---------------------------------------------------------------------------
# Run each layer
# ---------------------------------------------------------------------------
$results  = [ordered]@{}
$anyFailed = $false
$step      = 1

foreach ($layer in $RUN_LAYERS) {
    $info      = $LAYERS[$layer]
    $layerLog  = Get-LogPath -Stage $layer -Name "run_$layer"

    Write-Log "" "INFO" $LOG
    Write-SectionBanner -Title "[$step/$($RUN_LAYERS.Count)] Running: $($info.Label)" -LogFile $LOG

    $layerStart = Get-Date

    # Call the individual layer script; pass -SkipXxxCheck so it doesn't
    # re-query — we're running in sequence so dependencies are guaranteed
    $scriptArgs = @("-EnvFile", $EnvFile)
    if ($layer -eq "silver") { $scriptArgs += "-SkipBronzeCheck" }
    if ($layer -eq "gold")   { $scriptArgs += "-SkipSilverCheck" }

    & $info.Script @scriptArgs

    $exitCode    = $LASTEXITCODE
    $layerElapsed = [math]::Round(((Get-Date) - $layerStart).TotalSeconds, 2)

    if ($exitCode -eq 0) {
        $results[$layer] = "SUCCESS  (${layerElapsed}s)"
        Write-Log "Layer '$layer' completed successfully in ${layerElapsed}s." "SUCCESS" $LOG
    } else {
        $results[$layer] = "FAILED   (${layerElapsed}s)"
        $anyFailed = $true
        Write-Log "Layer '$layer' FAILED after ${layerElapsed}s — pipeline will continue but Gold may be stale." "ERROR" $LOG
    }

    $step++
}

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
$TOTAL_ELAPSED = [math]::Round(((Get-Date) - $RUN_START).TotalSeconds, 2)

Write-Log "" "INFO" $LOG
Write-Banner -Title "PIPELINE SUMMARY" -LogFile $LOG

foreach ($layer in $RUN_LAYERS) {
    $status = $results[$layer]
    $level  = if ($status -like "SUCCESS*") { "SUCCESS" } else { "ERROR" }
    Write-Log ("  {0,-8}  {1}" -f $layer.ToUpper(), $status) $level $LOG
}

Write-Log "" "INFO" $LOG
Write-Log "  Total elapsed : ${TOTAL_ELAPSED}s" "INFO" $LOG
Write-Log "  Completed at  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO" $LOG
Write-Log "  Master log    : $LOG" "INFO" $LOG
Write-Log ("=" * 60) "INFO" $LOG

if ($anyFailed) {
    Write-Log "PIPELINE FINISHED WITH ERRORS" "ERROR" $LOG
    exit 1
} else {
    Write-Log "PIPELINE FINISHED SUCCESSFULLY" "SUCCESS" $LOG
    exit 0
}