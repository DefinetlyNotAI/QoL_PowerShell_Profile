# Python execution policy
# Environment variables are configured in the main profile.
function python {
    $PythonExe = (Get-Command python.exe -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source
    $PythonArgs = @($args)

    # --allow bypasses the custom execution restriction.
    # It may appear anywhere and is not forwarded to Python.
    $Allow = $false
    $FilteredArgs = @(
        foreach ($Arg in $PythonArgs) {
            if ($Arg -ceq '--allow') {
                $Allow = $true
            }
            else {
                $Arg
            }
        }
    )

    if ($Allow) {
        & $PythonExe @FilteredArgs
        return
    }

    if ($env:VIRTUAL_ENV) {
        & $PythonExe @FilteredArgs
        return
    }

    if ($FilteredArgs.Count -eq 0) {
        & $PythonExe
        return
    }

    if ($FilteredArgs.Count -eq 1 -and
        $FilteredArgs[0] -cin @('--version', '-V', '--help', '-h')) {
        & $PythonExe @FilteredArgs
        return
    }

    # Permit creation of virtual environments outside an active venv.
    if ($FilteredArgs[0] -ceq '-m' -and
        $FilteredArgs.Count -ge 3 -and
        $FilteredArgs[1] -ceq 'venv') {
        & $PythonExe @FilteredArgs
        return
    }

    Write-Error -Message @"
Python execution blocked outside a virtual environment.

Create/activate one with:
    python -m venv .venv
    .\.venv\Scripts\Activate.ps1

To bypass this restriction:
    python --allow <arguments>
"@ -ErrorAction Continue
    $global:LASTEXITCODE = 1
}

Set-Alias py python
