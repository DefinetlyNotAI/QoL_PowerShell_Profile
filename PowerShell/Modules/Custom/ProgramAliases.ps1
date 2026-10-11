# CLI program replacements
Remove-Alias ls -Force -ErrorAction SilentlyContinue

function ls {
    eza --icons=always --hyperlink --group-directories-first @args
}

function ll {
    eza -lah --icons=always --hyperlink --group-directories-first --git @args
}

function tree {
    eza --tree --icons=always --hyperlink --group-directories-first @args
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
