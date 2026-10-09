#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(1,65535)][int]$Port = 9090,
    [ValidateSet('127.0.0.1','0.0.0.0')][string]$HostAddress = '127.0.0.1',
    [ValidateRange(5,300)][int]$TimeoutSeconds = 60,
    [switch]$StartFcc,
    [switch]$UpdateWebUI,
    [switch]$OpenBrowser
)
$ErrorActionPreference = 'Stop'

function Get-Executable([string]$Name) {
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}
function Test-Endpoint([string]$Url) {
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 3 -SkipHttpErrorCheck -ErrorAction Stop
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
    } catch { return $false }
}
function Start-Detached([string]$Executable, [string[]]$Arguments) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -PassThru -ErrorAction Stop
    return $process
}

$webui = Get-Executable 'open-webui.exe'
if (-not $webui) { $webui = Get-Executable 'open-webui' }
if (-not $webui) { throw 'open-webui is not installed or not on PATH. Install it in a Python environment and expose its executable on PATH.' }

if ($UpdateWebUI) {
    $pip = Get-Executable 'uv.exe'
    if (-not $pip) { throw 'UpdateWebUI requires uv on PATH. Install uv or update Open WebUI manually using its own environment.' }
    Write-Host 'Updating Open WebUI via uv tool...'
    & $pip tool upgrade open-webui
    if ($LASTEXITCODE -ne 0) { throw "Open WebUI update failed (exit $LASTEXITCODE)." }
}

$url = "http://127.0.0.1:$Port/"
$startedWebUI = $false
if (Test-Endpoint $url) {
    Write-Host "HTTP service is already responding at $url (identity not verified)."
} else {
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($listener) { throw "Port $Port is occupied by another process. Choose -Port or stop the listener." }
    Write-Host "Starting Open WebUI on $HostAddress`:$Port..."
    $proc = Start-Detached $webui @('serve','--host',$HostAddress,'--port',"$Port")
    $startedWebUI = $true
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Endpoint $url) { break }
        $proc.Refresh()
        if ($proc.HasExited) { throw "Open WebUI exited during startup (code $($proc.ExitCode)). Launch it manually for the complete error output." }
        Start-Sleep -Milliseconds 750
    }
    if (-not (Test-Endpoint $url)) { throw "WebUI did not respond within $TimeoutSeconds seconds. Process ID: $($proc.Id)." }
}

Write-Host "WebUI responding: $url"
if ($HostAddress -eq '0.0.0.0') {
    Write-Host 'Listening on all interfaces. Check your firewall and Open WebUI authentication before exposing this port.'
}
if ($StartFcc) {
    $fcc = Get-Executable 'fcc-server.exe'
    if (-not $fcc) { $fcc = Get-Executable 'fcc-server' }
    if (-not $fcc) {
        Write-Warning 'fcc-server not found on PATH; WebUI remains running.'
    } else {
        $fccRunning = @(Get-Process -Name 'fcc-server' -ErrorAction SilentlyContinue).Count -gt 0
        if ($fccRunning) { Write-Host 'fcc-server process is already running.' }
        else {
            $fccProc = Start-Detached $fcc @()
            Write-Host "Started fcc-server (PID $($fccProc.Id))."
        }
    }
}
if ($OpenBrowser) { Start-Process $url }
