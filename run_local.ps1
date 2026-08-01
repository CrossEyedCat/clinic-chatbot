# run_local.ps1 - one-click local launch of the BrightCare clinic bot (Windows)
#
#   powershell -ExecutionPolicy Bypass -File run_local.ps1            # start everything
#   powershell -ExecutionPolicy Bypass -File run_local.ps1 -Stop      # stop everything
#   powershell -ExecutionPolicy Bypass -File run_local.ps1 -Retrain   # force retrain
#
# What it does: finds Python 3.8-3.10 -> creates a venv -> installs Rasa 3.6 ->
# trains the model (if missing) -> starts the action server (:5055), the Rasa
# REST API (:5005) and a static server for the web chat (:8088) -> opens the chat.

param(
    [string]$Python = "",                     # explicit path to python.exe 3.8-3.10
    [string]$VenvDir = "$PSScriptRoot\.venv-rasa",
    [int]$RasaPort = 5005,
    [int]$ActionPort = 5055,
    [int]$WebPort = 8088,
    [switch]$Retrain,
    [switch]$Stop,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$PidFile = Join-Path $PSScriptRoot ".run_local_pids.json"
$LogDir = Join-Path $PSScriptRoot ".logs"

function Stop-All {
    if (Test-Path $PidFile) {
        $pids = Get-Content $PidFile | ConvertFrom-Json
        foreach ($p in $pids) {
            try { Stop-Process -Id $p -Force -ErrorAction Stop; Write-Host "  stopped PID $p" } catch {}
        }
        Remove-Item $PidFile -Force
        Write-Host "All bot processes stopped."
    } else {
        Write-Host "Nothing to stop ($PidFile not found)."
    }
}

function Stop-PortListeners {
    # frees the three ports even if the processes were started outside this script
    foreach ($port in @($RasaPort, $ActionPort, $WebPort)) {
        $lines = netstat -ano | Select-String ":$port\s.*LISTENING"
        foreach ($l in $lines) {
            $ownerPid = ($l.ToString() -split '\s+')[-1]
            if ($ownerPid -match '^\d+$' -and $ownerPid -ne "0") {
                Write-Host "  freeing port ${port} (PID $ownerPid)"
                try { taskkill /PID $ownerPid /F 2>$null | Out-Null } catch {}
            }
        }
    }
}

if ($Stop) { Stop-All; Stop-PortListeners; exit 0 }

# ---------------------------------------------------------------- find python
function Get-PyVersion([string]$exe) {
    try {
        $out = & $exe --version 2>&1 | Out-String
        if ($out -match "Python (\d+)\.(\d+)\.(\d+)") {
            return [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
        }
    } catch {}
    return $null
}

$py = $null
if ($Python) {
    $v = Get-PyVersion $Python
    if ($null -eq $v -or $v -lt [version]"3.8" -or $v -ge [version]"3.11") {
        throw "Python at '$Python' is not version 3.8-3.10 (Rasa 3.6 requirement)."
    }
    $py = $Python
} else {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python39\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python38\python.exe",
        "python3.10", "python3.9", "python3.8", "python"
    )
    foreach ($c in $candidates) {
        $v = Get-PyVersion $c
        if ($null -ne $v -and $v -ge [version]"3.8" -and $v -lt [version]"3.11") { $py = $c; break }
    }
    if ($null -eq $py) {
        throw "No Python 3.8-3.10 found. Install it from python.org and re-run, or pass -Python C:\path\to\python.exe"
    }
}
Write-Host "Using Python: $py ($(Get-PyVersion $py))"

# ---------------------------------------------------------------- venv + rasa
$venvPy = Join-Path $VenvDir "Scripts\python.exe"
$rasaExe = Join-Path $VenvDir "Scripts\rasa.exe"

if (-not (Test-Path $venvPy)) {
    Write-Host "Creating virtual environment at $VenvDir ..."
    & $py -m venv $VenvDir
}

$hasRasa = $false
try { & $venvPy -c "import rasa" 2>$null; if ($LASTEXITCODE -eq 0) { $hasRasa = $true } } catch {}
if (-not $hasRasa) {
    Write-Host "Installing Rasa 3.6.21 (this takes 5-10 minutes on first run) ..."
    & $venvPy -m pip install --upgrade pip
    # greenlet has no sources-only build on plain Windows - force the binary wheel
    & $venvPy -m pip install --only-binary :all: greenlet
    & $venvPy -m pip install --prefer-binary "rasa==3.6.21"
    if ($LASTEXITCODE -ne 0) { throw "Rasa installation failed - see output above." }
}

# ---------------------------------------------------------------- train model
$needTrain = $Retrain
if (-not (Test-Path "$PSScriptRoot\models") ) { $needTrain = $true }
elseif (-not (Get-ChildItem "$PSScriptRoot\models" -Filter *.tar.gz -ErrorAction SilentlyContinue)) { $needTrain = $true }
else {
    # retrain when training data / config is newer than the latest model
    $newestModel = Get-ChildItem "$PSScriptRoot\models" -Filter *.tar.gz |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $newestData = Get-ChildItem "$PSScriptRoot\data\*.yml", "$PSScriptRoot\config.yml", "$PSScriptRoot\domain.yml" |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newestData.LastWriteTime -gt $newestModel.LastWriteTime) {
        Write-Host "Training data changed after the last model - retraining."
        $needTrain = $true
    }
}
if ($needTrain) {
    Write-Host "Training the model (a few minutes) ..."
    & $rasaExe train
    if ($LASTEXITCODE -ne 0) { throw "rasa train failed." }
} else {
    Write-Host "Model found - skipping training (use -Retrain to force)."
}

# ---------------------------------------------------------------- start servers
Write-Host "Freeing ports $RasaPort/$ActionPort/$WebPort if busy ..."
Stop-PortListeners
New-Item -ItemType Directory -Force $LogDir | Out-Null
$procs = @()

Write-Host "Starting action server on :$ActionPort ..."
$pAct = Start-Process -FilePath $rasaExe -ArgumentList "run", "actions", "--port", "$ActionPort" `
    -RedirectStandardOutput "$LogDir\actions.log" -RedirectStandardError "$LogDir\actions.err.log" `
    -WindowStyle Hidden -PassThru
$procs += $pAct.Id

Write-Host "Starting Rasa API on :$RasaPort ..."
$pRasa = Start-Process -FilePath $rasaExe -ArgumentList "run", "--enable-api", "--cors", "*", "--port", "$RasaPort", "--endpoints", "endpoints.yml" `
    -RedirectStandardOutput "$LogDir\rasa.log" -RedirectStandardError "$LogDir\rasa.err.log" `
    -WindowStyle Hidden -PassThru
$procs += $pRasa.Id

Write-Host "Starting web chat on :$WebPort ..."
$pWeb = Start-Process -FilePath $venvPy -ArgumentList "-m", "http.server", "$WebPort", "--directory", "webchat" `
    -RedirectStandardOutput "$LogDir\web.log" -RedirectStandardError "$LogDir\web.err.log" `
    -WindowStyle Hidden -PassThru
$procs += $pWeb.Id

$procs | ConvertTo-Json | Set-Content $PidFile -Encoding utf8

# ---------------------------------------------------------------- wait + open
Write-Host "Waiting for the Rasa server (model loading takes ~30-60 s) ..."
$up = $false
foreach ($i in 1..60) {
    try {
        $r = Invoke-WebRequest "http://localhost:$RasaPort/status" -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { $up = $true; break }
    } catch {}
    Start-Sleep -Seconds 2
}

if ($up) {
    Write-Host ""
    Write-Host "=============================================================="
    Write-Host "  Bot is up!"
    Write-Host "  Rasa API:      http://localhost:$RasaPort/status"
    Write-Host "  Action server: http://localhost:$ActionPort/health"
    Write-Host "  Web chat:      http://localhost:$WebPort"
    if ($RasaPort -ne 5005) {
        Write-Host "  (non-default API port: open http://localhost:$WebPort/?rasa=http://localhost:$RasaPort)"
    }
    Write-Host "  Logs:          $LogDir"
    Write-Host "  Stop with:     powershell -ExecutionPolicy Bypass -File run_local.ps1 -Stop"
    Write-Host "=============================================================="
    if (-not $NoBrowser) {
        if ($RasaPort -ne 5005) { Start-Process "http://localhost:$WebPort/?rasa=http://localhost:$RasaPort" }
        else { Start-Process "http://localhost:$WebPort" }
    }
} else {
    Write-Host "Rasa did not come up in 2 minutes - check $LogDir\rasa.err.log" -ForegroundColor Red
    Stop-All
    exit 1
}
