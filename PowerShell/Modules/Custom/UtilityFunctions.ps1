# Utility functions
function monitor-mode {
    & "$HOME\.custom\Kali-MonitorMode.ps1"
}

function cdl { Set-Location @args }

function which {
    param(
        [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
        [string[]]$Name
    )

    foreach ($Item in $Name) {
        $Commands = @(Get-Command -Name $Item -All -ErrorAction SilentlyContinue)

        if ($Commands.Count -eq 0) {
            Write-Error "Command not found: $Item"
            continue
        }

        foreach ($Command in $Commands) {
            switch ($Command.CommandType) {
                'Application' { $Command.Source }
                'ExternalScript' { $Command.Path }
                'Alias' {
                    if ($Command.ResolvedCommand) {
                        $Command.ResolvedCommand.Source ?? $Command.ResolvedCommand.Name
                    }
                    else {
                        $Command.Definition
                    }
                }
                'Function' { "Function: $($Command.Name)" }
                'Cmdlet' { "Cmdlet: $($Command.Name) [$($Command.Source)]" }
                default { "$($Command.CommandType): $($Command.Name)" }
            }
        }
    }
}
