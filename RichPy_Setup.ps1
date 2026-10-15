# Use rich globally for python so that it always uses rich for exceptions,
# This script initialises this and is intended to be run once
# This script assumes you already installed the other powershell QoL mentioned above

$dir = "$env:LOCALAPPDATA\PythonGlobal"

# Create directory
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# Create sitecustomize.py
@'
try:
    from rich.traceback import install

    install(
        show_locals=True,
        width=160,
        extra_lines=5,
        max_frames=100,
        theme="monokai",
        word_wrap=True,
    )
except ImportError:
    pass
'@ | Set-Content "$dir\sitecustomize.py" -Encoding utf8

# Register global Python startup directory
$current = [Environment]::GetEnvironmentVariable("PYTHONPATH", "User")
$paths = @($current -split ';' | Where-Object { $_ })

if ($dir -notin $paths) {
    $paths = @($dir) + $paths
    [Environment]::SetEnvironmentVariable(
        "PYTHONPATH",
        ($paths -join ';'),
        "User"
    )
}

# Apply immediately to current terminal
$env:PYTHONPATH = ($paths -join ';')

# Test Rich traceback
python --allow -c "1/0"
