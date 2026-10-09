# ── UTF-8 console setup ─────────────────────────────────────────────
#
# Required so Nerd Font / PUA glyphs render correctly through
# [Console]::Write() instead of becoming '?' or mojibake.

$utf8 = [System.Text.UTF8Encoding]::new($false)

[Console]::InputEncoding  = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding           = $utf8


# ── Lightweight Atuin Up/Down history ───────────────────────────────

$global:AtuinHistoryItems = @()
$global:AtuinHistoryIndex = -1
$global:AtuinHistoryOriginal = ""

$global:AtuinMetadataVisible = $false
$global:AtuinMetadataRow = -1
$global:AtuinMetadataStart = -1
$global:AtuinMetadataLength = 0


# ── Oh My Posh detection ────────────────────────────────────────────

function Test-OhMyPoshActive {
    return (
        -not [string]::IsNullOrWhiteSpace($env:POSH_SHELL_VERSION) -or
        $null -ne (
            Get-Variable `
                -Name poshContext `
                -Scope Global `
                -ErrorAction SilentlyContinue
        )
    )
}


# ── Metadata renderer ────────────────────────────────────────────────
#
# OMP:
#
#     41ms   40s ago 
#
# Purple duration segment joined to blue relative-time segment.
#
# Non-OMP:
#
#   (41ms | 40s ago)

function Get-AtuinMetadataRender {
    param(
        [Parameter(Mandatory)]
        [string]$Duration,

        [Parameter(Mandatory)]
        [string]$Time
    )

    if (Test-OhMyPoshActive) {
        $esc = [string][char]27

        # Powerline glyphs
        $leftCap  = ([char]0xE0B6).ToString() # 
        $join     = ([char]0xE0B2).ToString() # 
        $rightCap = ([char]0xE0B4).ToString() # 

        # Icons
        $durationIcon = ([char]0xF2F2).ToString() #  stopwatch
        $historyIcon  = ([char]0xF1DA).ToString() #  history

        # Colors
        $durationBg = "131;118;156" # #83769c
        $historyBg  = "48;48;48"     # #303030
        $white      = "255;255;255"

        # Match the width of OMP's "_2,15:04" time field.
        #
        # Examples:
        #
        # "2s ago"   -> "  2s ago"
        # "16s ago"  -> " 16s ago"
        # "1m ago"   -> "  1m ago"
        # "12m ago"  -> " 12m ago"
        #
        # Longer values are left intact instead of being truncated.
        $historyText = $Time.PadLeft(8)

        # Fixed timer width with icon left and duration right.
        $durationSegmentWidth = 14

        $durationPadding = [Math]::Max(
            1,
            $durationSegmentWidth - $Duration.Length - 6
        )

        $durationContent = " $durationIcon $(' ' * $durationPadding)$Duration "
        $historyContent  = " $historyIcon $historyText "

        $plain =
            $leftCap +
            $durationContent +
            $join +
            $historyContent +
            $rightCap

        # Left rounded cap
        $left =
            "${esc}[49m" +
            "${esc}[38;2;${durationBg}m" +
            $leftCap

        # Duration segment
        $durationBody =
            "${esc}[48;2;${durationBg}m" +
            "${esc}[38;2;${white}m" +
            $durationContent

        # Joined transition
        $separator =
            "${esc}[48;2;${durationBg}m" +
            "${esc}[38;2;${historyBg}m" +
            $join

        # Relative-time/history segment
        $historyBody =
            "${esc}[48;2;${historyBg}m" +
            "${esc}[38;2;${white}m" +
            $historyContent

        # Right rounded cap
        $right =
            "${esc}[49m" +
            "${esc}[38;2;${historyBg}m" +
            $rightCap +
            "${esc}[0m"

        return [PSCustomObject]@{
            Plain        = $plain
            Rendered     = (
                $left +
                $durationBody +
                $separator +
                $historyBody +
                $right
            )
            DisplayWidth = $plain.Length
        }
    }

    $plain = "($Duration | $Time)"

    return [PSCustomObject]@{
        Plain        = $plain
        Rendered     = "`e[90m$plain`e[0m"
        DisplayWidth = $plain.Length
    }
}


# ── Atuin history retrieval ─────────────────────────────────────────

function Get-AtuinNavigationHistory {
    $fieldSeparator = [char]0x1F
    $entrySeparator = [char]0x1E

    # Capture stdout as one string so real multiline commands remain intact.
    $output = & atuin search `
        --limit 500 `
        --search-mode prefix `
        --filter-mode global `
        --format "{command}${fieldSeparator}{duration}${fieldSeparator}{relativetime} ago${entrySeparator}" `
        2>$null | Out-String

    $items = @(
        foreach (
            $record in (
                $output -split [regex]::Escape(
                    [string]$entrySeparator
                )
            )
        ) {
            if (-not $record) {
                continue
            }

            # Atuin adds a newline after each formatted history entry.
            #
            # Once split by our custom record separator, that newline appears
            # at the beginning of the next record.
            #
            # Remove exactly that separator newline without touching newlines
            # that are part of a genuine multiline command.
            $record = $record -replace "^\r?\n", ""

            # Remove the final Atuin stdout newline.
            $record = $record -replace "\r?\n$", ""

            if (-not $record) {
                continue
            }

            $parts = $record -split `
                [regex]::Escape([string]$fieldSeparator), 3

            if ($parts.Count -eq 3) {
                [PSCustomObject]@{
                    Command  = $parts[0]
                    Duration = $parts[1]
                    Time     = $parts[2]
                }
            }
        }
    )

    # Atuin returns oldest -> newest.
    #
    # UpArrow should begin with newest -> oldest.
    [array]::Reverse($items)

    return $items
}


# ── Metadata cleanup ────────────────────────────────────────────────

function Clear-AtuinMetadata {
    if (-not $global:AtuinMetadataVisible) {
        return
    }

    $savedLeft = [Console]::CursorLeft
    $savedTop  = [Console]::CursorTop

    try {
        $bufferWidth  = [Console]::BufferWidth
        $bufferHeight = [Console]::BufferHeight

        $row    = $global:AtuinMetadataRow
        $start  = $global:AtuinMetadataStart
        $length = $global:AtuinMetadataLength

        if (
            $row -ge 0 -and
            $start -ge 0 -and
            $row -lt $bufferHeight -and
            $start -lt $bufferWidth
        ) {
            [Console]::SetCursorPosition(
                $start,
                $row
            )

            # Protect against terminal resizing.
            $available = $bufferWidth - $start

            $clearLength = [Math]::Min(
                $length,
                $available
            )

            if ($clearLength -gt 0) {
                [Console]::Write(
                    " " * $clearLength
                )
            }
        }
    }
    catch {
        # Visual metadata should never break navigation.
    }
    finally {
        try {
            $bufferWidth  = [Console]::BufferWidth
            $bufferHeight = [Console]::BufferHeight

            if (
                $savedLeft -ge 0 -and
                $savedTop -ge 0 -and
                $savedLeft -lt $bufferWidth -and
                $savedTop -lt $bufferHeight
            ) {
                [Console]::SetCursorPosition(
                    $savedLeft,
                    $savedTop
                )
            }
        }
        catch {}

        $global:AtuinMetadataVisible = $false
        $global:AtuinMetadataRow = -1
        $global:AtuinMetadataStart = -1
        $global:AtuinMetadataLength = 0
    }
}


# ── Navigation state ────────────────────────────────────────────────

function Reset-AtuinNavigation {
    $global:AtuinHistoryItems = @()
    $global:AtuinHistoryIndex = -1
    $global:AtuinHistoryOriginal = ""
}


function Exit-AtuinNavigation {
    if (
        $global:AtuinHistoryIndex -ne -1 -or
        $global:AtuinMetadataVisible
    ) {
        Clear-AtuinMetadata
        Reset-AtuinNavigation
    }
}


# ── History entry display ───────────────────────────────────────────

function Show-AtuinHistoryEntry {
    param(
        [Parameter(Mandatory)]
        $Entry
    )

    Clear-AtuinMetadata

    $command = [string]$Entry.Command

    $meta = Get-AtuinMetadataRender `
        -Duration ([string]$Entry.Duration) `
        -Time ([string]$Entry.Time)

    # Remember the physical row where PSReadLine starts drawing.
    $startRow = [Console]::CursorTop

    # Only the command itself belongs in PSReadLine's editable buffer.
    [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert($command)

    # Save actual editing cursor position after rendering.
    $savedLeft = [Console]::CursorLeft
    $savedTop  = [Console]::CursorTop

    $windowWidth = [Console]::WindowWidth
    $bufferWidth = [Console]::BufferWidth

    # Keep positioning valid for both visible width and buffer width.
    $width = [Math]::Min(
        $windowWidth,
        $bufferWidth
    )

    if ($width -le 0) {
        return
    }

    if ($command -match "[`r`n]") {
        $firstLine = ($command -split "\r?\n", 2)[0]

        # Revert to the prompt to locate its actual first input row.
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()

        $row = [Console]::CursorTop
        $promptEndX = [Console]::CursorLeft

        # Restore the full command.
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($command)

        # Re-read cursor after PSReadLine redraw.
        $savedLeft = [Console]::CursorLeft
        $savedTop  = [Console]::CursorTop

        $commandEndX = $promptEndX + $firstLine.Length
    }
    else {
        $row = [Console]::CursorTop
        $commandEndX = [Console]::CursorLeft
    }

    $metadataWidth = [int]$meta.DisplayWidth

    # Metadata cannot fit.
    if (
        $metadataWidth -le 0 -or
        $metadataWidth -ge $width
    ) {
        return
    }

    $metadataStart = $width - $metadataWidth

    # Horizontal bounds.
    if (
        $metadataStart -lt 0 -or
        $metadataStart -ge $bufferWidth
    ) {
        return
    }

    # Vertical bounds.
    $bufferHeight = [Console]::BufferHeight

    if (
        $row -lt 0 -or
        $row -ge $bufferHeight
    ) {
        return
    }

    # Never overwrite the command.
    if ($metadataStart -le $commandEndX) {
        return
    }

    try {
        [Console]::SetCursorPosition(
            $metadataStart,
            $row
        )

        [Console]::Write(
            [string]$meta.Rendered
        )
    }
    catch {
        return
    }
    finally {
        try {
            $currentBufferWidth  = [Console]::BufferWidth
            $currentBufferHeight = [Console]::BufferHeight

            if (
                $savedLeft -ge 0 -and
                $savedTop -ge 0 -and
                $savedLeft -lt $currentBufferWidth -and
                $savedTop -lt $currentBufferHeight
            ) {
                [Console]::SetCursorPosition(
                    $savedLeft,
                    $savedTop
                )
            }
        }
        catch {}
    }

    $global:AtuinMetadataVisible = $true
    $global:AtuinMetadataRow = $row
    $global:AtuinMetadataStart = $metadataStart
    $global:AtuinMetadataLength = $metadataWidth
}


# ── Up Arrow ────────────────────────────────────────────────────────
#
# Older Atuin history entry.

Set-PSReadLineKeyHandler -Chord UpArrow -ScriptBlock {
    if ($global:AtuinHistoryIndex -eq -1) {
        $line = $null
        $cursor = 0

        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState(
            [ref]$line,
            [ref]$cursor
        )

        $global:AtuinHistoryOriginal = $line

        $global:AtuinHistoryItems = @(
            Get-AtuinNavigationHistory
        )

        if ($global:AtuinHistoryItems.Count -eq 0) {
            return
        }

        $global:AtuinHistoryIndex = 0
    }
    elseif (
        $global:AtuinHistoryIndex -lt
        $global:AtuinHistoryItems.Count - 1
    ) {
        $global:AtuinHistoryIndex++
    }

    Show-AtuinHistoryEntry `
        $global:AtuinHistoryItems[$global:AtuinHistoryIndex]
}


# ── Down Arrow ──────────────────────────────────────────────────────
#
# Newer Atuin history entry.

Set-PSReadLineKeyHandler -Chord DownArrow -ScriptBlock {
    if ($global:AtuinHistoryIndex -gt 0) {
        $global:AtuinHistoryIndex--

        Show-AtuinHistoryEntry `
            $global:AtuinHistoryItems[$global:AtuinHistoryIndex]

        return
    }

    if ($global:AtuinHistoryIndex -eq 0) {
        Clear-AtuinMetadata

        $original = $global:AtuinHistoryOriginal

        Reset-AtuinNavigation

        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()

        if ($original) {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert(
                $original
            )
        }
    }
}


# ── Editing handlers ────────────────────────────────────────────────
#
# Any command edit exits Atuin navigation and clears metadata.


# Printable ASCII characters.
$AtuinSelfInsertKeys = @(
    32..126 | ForEach-Object {
        [char]$_
    }
)

Set-PSReadLineKeyHandler `
    -Key $AtuinSelfInsertKeys `
    -ScriptBlock {
        param($key, $arg)

        Exit-AtuinNavigation

        [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert(
            $key,
            $arg
        )
    }


# Backspace
Set-PSReadLineKeyHandler -Key Backspace -ScriptBlock {
    param($key, $arg)

    Exit-AtuinNavigation

    [Microsoft.PowerShell.PSConsoleReadLine]::BackwardDeleteChar(
        $key,
        $arg
    )
}


# Delete
Set-PSReadLineKeyHandler -Key Delete -ScriptBlock {
    param($key, $arg)

    Exit-AtuinNavigation

    [Microsoft.PowerShell.PSConsoleReadLine]::DeleteChar(
        $key,
        $arg
    )
}


# Ctrl+V paste
Set-PSReadLineKeyHandler -Chord Ctrl+v -ScriptBlock {
    param($key, $arg)

    Exit-AtuinNavigation

    [Microsoft.PowerShell.PSConsoleReadLine]::Paste(
        $key,
        $arg
    )
}


# Shift+Insert paste
Set-PSReadLineKeyHandler -Chord Shift+Insert -ScriptBlock {
    param($key, $arg)

    Exit-AtuinNavigation

    [Microsoft.PowerShell.PSConsoleReadLine]::Paste(
        $key,
        $arg
    )
}


# Tab completion
Set-PSReadLineKeyHandler -Key Tab -ScriptBlock {
    param($key, $arg)

    Exit-AtuinNavigation

    [Microsoft.PowerShell.PSConsoleReadLine]::TabCompleteNext(
        $key,
        $arg
    )
}


# Shift+Tab completion
Set-PSReadLineKeyHandler -Chord Shift+Tab -ScriptBlock {
    param($key, $arg)

    Exit-AtuinNavigation

    [Microsoft.PowerShell.PSConsoleReadLine]::TabCompletePrevious(
        $key,
        $arg
    )
}


# Ctrl+Z undo
Set-PSReadLineKeyHandler -Chord Ctrl+z -ScriptBlock {
    param($key, $arg)

    Exit-AtuinNavigation

    [Microsoft.PowerShell.PSConsoleReadLine]::Undo(
        $key,
        $arg
    )
}


# Ctrl+Y redo
Set-PSReadLineKeyHandler -Chord Ctrl+y -ScriptBlock {
    param($key, $arg)

    Exit-AtuinNavigation

    [Microsoft.PowerShell.PSConsoleReadLine]::Redo(
        $key,
        $arg
    )
}


# Ctrl+W removes the previous word.
Set-PSReadLineKeyHandler -Chord Ctrl+w -ScriptBlock {
    param($key, $arg)

    Exit-AtuinNavigation

    [Microsoft.PowerShell.PSConsoleReadLine]::BackwardKillWord(
        $key,
        $arg
    )
}


# Ctrl+U removes from cursor to beginning.
Set-PSReadLineKeyHandler -Chord Ctrl+u -ScriptBlock {
    param($key, $arg)

    Exit-AtuinNavigation

    [Microsoft.PowerShell.PSConsoleReadLine]::BackwardKillLine(
        $key,
        $arg
    )
}


# Ctrl+K removes from cursor to end.
Set-PSReadLineKeyHandler -Chord Ctrl+k -ScriptBlock {
    param($key, $arg)

    Exit-AtuinNavigation

    [Microsoft.PowerShell.PSConsoleReadLine]::KillLine(
        $key,
        $arg
    )
}


# If you prefer Ctrl+Y as Emacs-style Yank instead of Redo:
#
# Set-PSReadLineKeyHandler -Chord Ctrl+y -ScriptBlock {
#     param($key, $arg)
#
#     Exit-AtuinNavigation
#
#     [Microsoft.PowerShell.PSConsoleReadLine]::Yank(
#         $key,
#         $arg
#     )
# }


# ── Enter ───────────────────────────────────────────────────────────

Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {
    Clear-AtuinMetadata
    Reset-AtuinNavigation

    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
}

# ────────────────────────────────────────────────────────────────────