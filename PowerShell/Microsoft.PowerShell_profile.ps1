# Environment
$env:POWERSHELL_TELEMETRY_OPTOUT = '1'
$env:PIP_REQUIRE_VIRTUALENV = 'true'
$env:VIRTUAL_ENV_DISABLE_PROMPT = '1'
$env:PYENV_VIRTUALENV_DISABLE_PROMPT = '1'

# Oh My Posh
$env:POSH_CONFIG = "$HOME\.poshthemes\atomic.omp.json"
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    oh-my-posh init pwsh --config $env:POSH_CONFIG 2>$null | Invoke-Expression
}

# Optional modules
function Import-OptionalModule {
    param([Parameter(Mandatory)][string]$Name)
    & {
        $ErrorActionPreference = 'SilentlyContinue'
        $WarningPreference = 'SilentlyContinue'
        Import-Module $Name -ErrorAction SilentlyContinue
    } *> $null
}
Import-OptionalModule Microsoft.WinGet.CommandNotFound
Import-OptionalModule Terminal-Icons
Import-OptionalModule wt-shell-integration
Import-OptionalModule PSReadLine

# External shell integrations
Invoke-Expression (& { (zoxide init powershell --cmd cd | Out-String) })
& {
    Invoke-Expression (& { (atuin init powershell --disable-up-arrow | Out-String) })
} 3>$null

# Custom scripts, including the two already installed
$CustomModules = Join-Path $PSScriptRoot 'Modules\Custom'
@(
    'PythonEnvironment.ps1'
    'UtilityFunctions.ps1'
    'ProgramAliases.ps1'
    'AtuinUpKeyHistory.ps1'
    'ZoxideTabAutocomplete.ps1'
) | ForEach-Object {
    . (Join-Path $CustomModules $_)
}
