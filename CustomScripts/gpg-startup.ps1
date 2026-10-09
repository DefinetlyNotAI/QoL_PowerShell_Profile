#requires -Version 7.0
<#
Starts the user's GPG agent. Optional passphrase presetting reads a DPAPI-
encrypted file and a keygrip supplied at runtime, never from repository data.
To opt in: provide -Keygrip, and create -EncryptedPassphrasePath locally.
GPG agent must permit presetting (allow-preset-passphrase in gpg-agent.conf).
]#>
[CmdletBinding()]
param(
    [string]$Keygrip = $env:GPG_PRESET_KEYGRIP,
    [string]$EncryptedPassphrasePath = (Join-Path $env:LOCALAPPDATA 'GnuPG-Secure/passphrase.dat'),
    [ValidateRange(1,20)][int]$Attempts = 5
)
$ErrorActionPreference = 'Stop'

function Find-GpgProgram([string]$Name) {
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $candidate = Join-Path $base "GnuPG/bin/$Name"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw "Missing GnuPG executable: $Name"
}

$connect = Find-GpgProgram 'gpg-connect-agent.exe'
$ready = $false
for ($i = 1; $i -le $Attempts; $i++) {
    & $connect /bye *> $null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    if ($i -lt $Attempts) { Start-Sleep -Seconds 1 }
}
if (-not $ready) { throw "GPG agent failed to initialize after $Attempts attempts." }
Write-Host 'GPG agent is ready.'

if (-not $Keygrip) {
    Write-Verbose 'No keygrip supplied. Skipping optional passphrase preset.'
    return
}
if ($Keygrip -cnotmatch '^[0-9a-fA-F]{40}$') { throw 'Keygrip must be 40 hexadecimal characters.' }
if (-not (Test-Path -LiteralPath $EncryptedPassphrasePath -PathType Leaf)) {
    throw "Local encrypted passphrase file not found: $EncryptedPassphrasePath"
}
$preset = Find-GpgProgram 'gpg-preset-passphrase.exe'
$encrypted = (Get-Content -LiteralPath $EncryptedPassphrasePath -Raw).Trim()
$secret = ConvertTo-SecureString -String $encrypted
$bstr = [IntPtr]::Zero
$plain = $null
$process = $null
try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $preset
    $info.ArgumentList.Add('--preset')
    $info.ArgumentList.Add($Keygrip)
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardOutput = $true
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    $process.StandardInput.WriteLine($plain)
    $process.StandardInput.Close()
    $stderr = $process.StandardError.ReadToEnd()
    $null = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "GPG preset failed (exit $($process.ExitCode)): $stderr" }
    Write-Host 'GPG passphrase was preset successfully.'
} finally {
    if ($process) { $process.Dispose() }
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $plain = $null
    $secret = $null
    $encrypted = $null
}
