# ── Zoxide + Local Filesystem CD ───────────────────────────────────
#
# cd <Tab>         -> Local directories only
# cd De<Tab>       -> Zoxide first, local directories second
# cd .\De<Tab>     -> Local directories only
# cd ..\De<Tab>    -> Local directories only
#
# cd Desktop       -> Local directory first, otherwise Zoxide
# cd .\Desktop     -> Local path only
# cd ..            -> Parent directory
#
# Tab             -> Next completion, wrapping around
# Shift+Tab       -> Previous completion
#
# Zoxide completion inserts the shortest unique directory suffix.
# Full paths remain available internally for navigation.
#
# Example:
#   C:\Users\Shahm\Desktop -> Desktop
#   C:\a\x\foo\bar\folder  -> x\foo\bar\folder
#   C:\a\y\foo\bar\folder  -> y\foo\bar\folder

Remove-Item Alias:cd -Force -ErrorAction SilentlyContinue


# ── Helpers ────────────────────────────────────────────────────────

function global:Test-CdExplicitPath {
    param([AllowEmptyString()][string]$Path)

    return (
        $Path.Contains('\') -or
        $Path.Contains('/') -or
        $Path.StartsWith('.') -or
        $Path.StartsWith('~') -or
        $Path.Contains(':')
    )
}


function global:Format-CdCompletion {
    param([string]$Value)

    if ($Value -match "[\s'`$]") {
        return "'" + $Value.Replace("'", "''") + "'"
    }

    return $Value
}


function global:Get-CdZoxidePaths {
    if (-not (Get-Command zoxide -ErrorAction SilentlyContinue)) {
        return
    }

    foreach ($path in @(zoxide query --list 2>$null)) {
        if (
            $path -and
            (Test-Path -LiteralPath $path -PathType Container)
        ) {
            $path
        }
    }
}


function global:Get-CdZoxideMatches {
    param([string]$Keyword)

    foreach ($path in @(Get-CdZoxidePaths)) {
        $leaf = Split-Path -Path $path -Leaf

        if ($leaf.StartsWith(
            $Keyword,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            $path
        }
    }
}


# ── Shortest Unique Zoxide Suffix ──────────────────────────────────

function global:Get-CdZoxideLabel {
    param(
        [string]$Path,
        [string[]]$AllPaths
    )

    $parts = @(
        $Path -split '[\\/]+' | Where-Object { $_ }
    )

    foreach ($depth in 1..$parts.Count) {
        $label = ($parts | Select-Object -Last $depth) -join '\'
        $conflict = $false

        foreach ($other in $AllPaths) {
            if ($other -ieq $Path) {
                continue
            }

            $otherParts = @(
                $other -split '[\\/]+' | Where-Object { $_ }
            )

            if ($otherParts.Count -lt $depth) {
                continue
            }

            $otherLabel = (
                $otherParts | Select-Object -Last $depth
            ) -join '\'

            if ($otherLabel -ieq $label) {
                $conflict = $true
                break
            }
        }

        if (-not $conflict) {
            return $label
        }
    }

    return $Path
}


# ── Resolve Zoxide Suffix ──────────────────────────────────────────

function global:Resolve-CdZoxideSuffix {
    param([string]$InputPath)

    $inputNormalized = $InputPath.Replace('/', '\')

    $matches = @(
        foreach ($path in @(Get-CdZoxidePaths)) {
            $normalized = $path.Replace('/', '\')

            if (
                $normalized -ieq $inputNormalized -or
                $normalized.EndsWith(
                    "\$inputNormalized",
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $path
            }
        }
    )

    if ($matches.Count -eq 1) {
        return $matches[0]
    }

    return $null
}


# ── Completion Provider ────────────────────────────────────────────

function global:Get-CdCompletions {
    param([AllowEmptyString()][string]$Word)

    $word = $Word.Trim("'`"")

    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $isExplicit = Test-CdExplicitPath $word

    # 1. Zoxide keyword completion.

    if ($word.Length -gt 0 -and -not $isExplicit) {
        $allPaths = @(Get-CdZoxidePaths)

        $matches = @(
            $allPaths | Where-Object {
                (Split-Path $_ -Leaf).StartsWith(
                    $word,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
        )

        foreach ($path in $matches) {
            if (-not $seen.Add($path)) {
                continue
            }

            $label = Get-CdZoxideLabel `
                -Path $path `
                -AllPaths $allPaths

            [pscustomobject]@{
                Text    = Format-CdCompletion $label
                Display = $label
                Path    = $path
                Source  = 'Zoxide'
            }
        }
    }

    # 2. Local directory completion.

    $parent = ''
    $prefix = $word
    $searchPath = '.'

    $lastSlash = [Math]::Max(
        $word.LastIndexOf('\'),
        $word.LastIndexOf('/')
    )

    if ($lastSlash -ge 0) {
        $parent = $word.Substring(0, $lastSlash + 1)
        $prefix = $word.Substring($lastSlash + 1)
        $searchPath = $parent
    }

    try {
        $items = @(
            Get-ChildItem `
                -LiteralPath $searchPath `
                -Directory `
                -Force `
                -ErrorAction Stop |
            Where-Object {
                $_.Name.StartsWith(
                    $prefix,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            } |
            Sort-Object Name
        )

        foreach ($item in $items) {
            if (-not $seen.Add($item.FullName)) {
                continue
            }

            $value = "$parent$($item.Name)"

            [pscustomobject]@{
                Text    = Format-CdCompletion $value
                Display = $item.Name
                Path    = $item.FullName
                Source  = 'Local'
            }
        }
    }
    catch {
        # Ignore inaccessible directories.
    }
}


# ── PowerShell Argument Completer ──────────────────────────────────

$global:CdTabCompleter = {
    param(
        $commandName,
        $parameterName,
        $wordToComplete,
        $commandAst,
        $fakeBoundParameters
    )

    foreach ($item in @(Get-CdCompletions -Word $wordToComplete)) {
        [System.Management.Automation.CompletionResult]::new(
            $item.Text,
            $item.Display,
            [System.Management.Automation.CompletionResultType]::ParameterValue,
            "$($item.Source): $($item.Path)"
        )
    }
}


# ── CD Command ─────────────────────────────────────────────────────

function global:cd {
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({
            param(
                $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters
            )

            & $global:CdTabCompleter `
                $commandName `
                $parameterName `
                $wordToComplete `
                $commandAst `
                $fakeBoundParameters
        })]
        [string]$Path
    )

    # No argument: home directory.

    if (-not $PSBoundParameters.ContainsKey('Path')) {
        Microsoft.PowerShell.Management\Set-Location -LiteralPath $HOME
        return
    }

    # Existing local directories always take priority.

    if (Test-Path -Path $Path -PathType Container) {
        Microsoft.PowerShell.Management\Set-Location -Path $Path
        return
    }

    # Explicit relative, home, and absolute paths stay local.

    $strictLocal = (
        $Path.StartsWith('.') -or
        $Path.StartsWith('~') -or
        [System.IO.Path]::IsPathRooted($Path)
    )

    if (-not $strictLocal) {

        # Resolve unique Zoxide suffixes.

        $suffix = Resolve-CdZoxideSuffix -InputPath $Path

        if ($suffix) {
            Microsoft.PowerShell.Management\Set-Location -LiteralPath $suffix
            return
        }

        # Resolve simple Zoxide keywords.

        if (-not (Test-CdExplicitPath $Path)) {
            $matches = @(Get-CdZoxideMatches -Keyword $Path)

            $exact = @(
                $matches | Where-Object {
                    (Split-Path $_ -Leaf) -ieq $Path
                }
            )

            if ($exact.Count -gt 0) {
                Microsoft.PowerShell.Management\Set-Location `
                    -LiteralPath $exact[0]
                return
            }

            if ($matches.Count -eq 1) {
                Microsoft.PowerShell.Management\Set-Location `
                    -LiteralPath $matches[0]
                return
            }

            if ($matches.Count -gt 1) {
                $ranked = zoxide query $Path 2>$null

                if (
                    $LASTEXITCODE -eq 0 -and
                    $ranked -and
                    (Test-Path -LiteralPath $ranked -PathType Container)
                ) {
                    Microsoft.PowerShell.Management\Set-Location `
                        -LiteralPath $ranked
                    return
                }

                Microsoft.PowerShell.Management\Set-Location `
                    -LiteralPath $matches[0]
                return
            }
        }
    }

    Write-Host "cd: directory not found: $Path" -ForegroundColor Red
}


# ── Completion Cycling State ───────────────────────────────────────

$global:CdCompletionState = @{
    Line       = $null
    Cursor     = -1
    Candidates = @()
    Index      = -1
    Start      = 0
    Length     = 0
}


# ── Custom Tab Handler ─────────────────────────────────────────────

function global:Invoke-CdTabCompletion {
    param([switch]$Backward)

    $line = $null
    $cursor = 0

    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState(
        [ref]$line,
        [ref]$cursor
    )

    # Other commands use normal PowerShell completion.

    if ($line -notmatch '^\s*cd\s+') {
        $global:CdCompletionState.Line = $null
        $global:CdCompletionState.Candidates = @()

        if ($Backward) {
            [Microsoft.PowerShell.PSConsoleReadLine]::TabCompletePrevious()
        }
        else {
            [Microsoft.PowerShell.PSConsoleReadLine]::TabCompleteNext()
        }

        return
    }

    $state = $global:CdCompletionState

    $continuing = (
        $state.Line -ceq $line -and
        $state.Cursor -eq $cursor -and
        $state.Candidates.Count -gt 0
    )

    if (-not $continuing) {

        # Extract the argument directly instead of relying on
        # PowerShell's built-in completion resolution.

        $match = [regex]::Match($line, '^\s*cd\s+')

        $start = $match.Length
        $length = $cursor - $start

        if ($length -lt 0) {
            return
        }

        $argument = $line.Substring($start, $length)

        $candidates = @(
            Get-CdCompletions -Word $argument |
                Select-Object -ExpandProperty Text
        )

        if ($candidates.Count -eq 0) {
            $state.Line = $null
            $state.Candidates = @()
            return
        }

        $state.Candidates = $candidates
        $state.Start = $start
        $state.Length = $length

        if ($Backward) {
            $state.Index = $candidates.Count - 1
        }
        else {
            $state.Index = 0
        }
    }
    else {
        $count = $state.Candidates.Count

        if ($Backward) {
            $state.Index = ($state.Index - 1 + $count) % $count
        }
        else {
            $state.Index = ($state.Index + 1) % $count
        }
    }

    $replacement = $state.Candidates[$state.Index]

    [Microsoft.PowerShell.PSConsoleReadLine]::Replace(
        $state.Start,
        $state.Length,
        $replacement
    )

    $state.Length = $replacement.Length

    # Track the updated command line.

    $updatedLine = $null
    $updatedCursor = 0

    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState(
        [ref]$updatedLine,
        [ref]$updatedCursor
    )

    $state.Line = $updatedLine
    $state.Cursor = $updatedCursor
}


# ── Register Tab Handlers ──────────────────────────────────────────

Set-PSReadLineKeyHandler `
    -Chord Tab `
    -BriefDescription 'CD next completion' `
    -ScriptBlock {
        Invoke-CdTabCompletion
    }

Set-PSReadLineKeyHandler `
    -Chord Shift+Tab `
    -BriefDescription 'CD previous completion' `
    -ScriptBlock {
        Invoke-CdTabCompletion -Backward
    }