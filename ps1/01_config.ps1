# =============================================================================
# config.ps1  —  Shared configuration & utility functions
# Dot-source this in every pipeline script:  . "$PSScriptRoot\config.ps1"
# =============================================================================

# ---------------------------------------------------------------------------
# 1. LOAD .env  (same pattern as Python's python-dotenv)
# ---------------------------------------------------------------------------
function Import-DotEnv {
    param([string]$Path = "$PSScriptRoot\.env")

    if (-not (Test-Path $Path)) {
        Write-Host "  [WARN] .env not found at '$Path' — falling back to system env vars." -ForegroundColor Yellow
        return
    }

    foreach ($line in Get-Content $Path) {
        $line = $line.Trim()
        if ($line -eq "" -or $line.StartsWith("#"))  { continue }
        if ($line -match "^(?<key>[^=]+)=(?<val>.*)$") {
            $key = $Matches["key"].Trim()
            $val = $Matches["val"].Trim().Trim('"').Trim("'")
            [System.Environment]::SetEnvironmentVariable($key, $val, "Process")
        }
    }
}

Import-DotEnv

# ---------------------------------------------------------------------------
# 2. CONNECTION SETTINGS  (read after .env is loaded)
# ---------------------------------------------------------------------------
$PG_HOST = $env:POSTGRES_HOST     ?? "localhost"
$PG_PORT = $env:POSTGRES_PORT     ?? "5432"
$PG_DB   = $env:POSTGRES_DATABASE ?? "Datawarehouse"
$PG_USER = $env:POSTGRES_USERNAME ?? "postgres"
$PG_PASS = $env:POSTGRES_PASSWORD ?? ""

# ---------------------------------------------------------------------------
# 3. LOGGER UTILITY
# ---------------------------------------------------------------------------
function Get-LogPath {
    param(
        [ValidateSet("bronze","silver","gold","pipeline")]
        [string]$Stage,
        [string]$Name
    )
    $dir = Join-Path $PSScriptRoot "logs\$Stage"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ts  = (Get-Date).ToString("yyyy-MM-dd_HH-mm")
    return Join-Path $dir "${Name}_${ts}.log"
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$LogFile
    )
    $ts   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$ts | $($Level.PadRight(8)) | $Message"

    # Console colour
    switch ($Level) {
        "INFO"    { Write-Host $line -ForegroundColor Cyan    }
        "SUCCESS" { Write-Host $line -ForegroundColor Green   }
        "WARN"    { Write-Host $line -ForegroundColor Yellow  }
        "ERROR"   { Write-Host $line -ForegroundColor Red     }
        default   { Write-Host $line                          }
    }

    # File output (DEBUG+)
    if ($LogFile) { Add-Content -Path $LogFile -Value $line -Encoding UTF8 }
}

# ---------------------------------------------------------------------------
# 4. PSQL RUNNER
#    Calls psql, captures NOTICE + result, returns $true/$false
# ---------------------------------------------------------------------------
function Invoke-Psql {
    param(
        [string]$Sql,
        [string]$LogFile,
        [string]$Stage
    )

    # psql needs PGPASSWORD in the environment
    $env:PGPASSWORD = $PG_PASS

    # Build args — ON_ERROR_STOP=1 makes psql exit non-zero on SQL error
    $psqlArgs = @(
        "-h", $PG_HOST,
        "-p", $PG_PORT,
        "-U", $PG_USER,
        "-d", $PG_DB,
        "--set=ON_ERROR_STOP=1",
        "--set=client_min_messages=notice",
        "-c", $Sql
    )

    Write-Log "Connecting to $PG_HOST`:$PG_PORT/$PG_DB as $PG_USER" "INFO" $LogFile

    # Redirect stderr → stdout so RAISE NOTICE is captured alongside query output
    $output   = & psql @psqlArgs 2>&1
    $exitCode = $LASTEXITCODE

    # Print every line from psql (NOTICE lines arrive as ErrorRecord objects)
    foreach ($obj in $output) {
        $text = if ($obj -is [System.Management.Automation.ErrorRecord]) {
                    $obj.Exception.Message
                } else { $obj.ToString() }

        if ($LogFile) { Add-Content -Path $LogFile -Value $text -Encoding UTF8 }
        Write-Host $text -ForegroundColor White
    }

    $env:PGPASSWORD = ""   # clear password from env ASAP

    return ($exitCode -eq 0)
}

# ---------------------------------------------------------------------------
# 5. BANNER HELPERS
# ---------------------------------------------------------------------------
function Write-Banner {
    param([string]$Title, [string]$LogFile)
    $sep  = "=" * 60
    $line = "  $Title"
    Write-Log $sep  "INFO" $LogFile
    Write-Log $line "INFO" $LogFile
    Write-Log $sep  "INFO" $LogFile
}

function Write-SectionBanner {
    param([string]$Title, [string]$LogFile)
    $sep = "-" * 60
    Write-Log $sep   "INFO" $LogFile
    Write-Log "  $Title" "INFO" $LogFile
    Write-Log $sep   "INFO" $LogFile
}