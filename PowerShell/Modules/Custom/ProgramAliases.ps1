# CLI program replacements
function Invoke-EzaClickable {
    $esc = [char]27
    $bel = [char]7

    $output = & eza --icons=always --color=always --hyperlink=always @args |
        Out-String -Stream

    foreach ($line in $output) {
        $fixed = [regex]::Replace(
            $line,
            '\x1b]8;([^;]*);(file://)([^\x1b\x07]+)(\x1b\\|\x07)',
            {
                param($match)

                $rawPath = $match.Groups[3].Value
                $rawPath = [uri]::UnescapeDataString($rawPath)

                $uri = ([uri]$rawPath).AbsoluteUri

                return "$esc]8;$($match.Groups[1].Value);$uri$($match.Groups[4].Value)"
            }
        )

        Write-Host $fixed
    }
}

Remove-Alias ls -Force -ErrorAction SilentlyContinue

function ls {
    Invoke-EzaClickable --group-directories-first @args
}

function ll {
    Invoke-EzaClickable -lah --group-directories-first --git @args
}

function tree {
    Invoke-EzaClickable --tree --group-directories-first @args
}

Remove-Alias cat -Force -ErrorAction SilentlyContinue
function cat { bat --paging=never @args }

function find { fd @args }
function grep { rg @args }
function du { dust @args }
function top { btm @args }

Remove-Alias curl -Force -ErrorAction SilentlyContinue
function curl { xh @args }

Set-Alias flex fastfetch

if (Get-Command mingw32-make -ErrorAction SilentlyContinue) {
    Set-Alias make mingw32-make
}
