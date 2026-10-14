# PowerShell 7 profile

Modular Windows PowerShell 7 configuration with Atuin history navigation, Zoxide directory completion, Oh My Posh themes, custom CLI aliases, Python environment helpers, and optional standalone scripts.

## What is required?

The following table describes the actual files in this repository. “Required” means required for the **current unmodified profile** to start and provide its intended behavior, not for PowerShell itself.

| Path | Classification | Purpose |
| --- | --- | --- |
| `PowerShell/Microsoft.PowerShell_profile.ps1` | Required | Entry point; loads integrations and custom scripts |
| `PowerShell/Modules/Custom/AtuinUpKeyHistory.ps1` | Required by current profile | Custom PSReadLine history navigation |
| `PowerShell/Modules/Custom/ZoxideTabAutocomplete.ps1` | Required by current profile | Directory completion backed by Zoxide |
| `PowerShell/Modules/Custom/PythonEnvironment.ps1` | Required by current profile | Python wrapper requiring a venv unless explicitly bypassed |
| `PowerShell/Modules/Custom/UtilityFunctions.ps1` | Required by current profile | `which`, `cdl`, `monitor-mode` functions |
| `PowerShell/Modules/Custom/ProgramAliases.ps1` | Required by current profile | CLI replacement aliases |
| `Themes/atomic.omp.json` | Required for the configured Oh My Posh theme | Copy to `$HOME/.poshthemes/atomic.omp.json` |
| `Themes/frappe.omp.json`, `Themes/kali.omp.json` | Optional | Alternative themes |
| `Atuin/config.toml` | Optional | User's Atuin behavior, not necessary to start Atuin |
| `PowerShell/powershell.config.json` | Optional | PowerShell feature configuration |
| `CustomScripts/Kali-MonitorMode.ps1` | Optional, required only for `monitor-mode` | Kali WSL2 USB Wi-Fi helper |
| `CustomScripts/gpg-startup.ps1` | Optional | Starts GPG agent, optionally presets passphrase |
| `CustomScripts/start-webui.ps1` | Optional | Launches Open WebUI and optionally `fcc-server` |
| `Startup/startup.cmd` | Optional | Automates GPG initialization and WinGet maintenance on system startup |
| `.gitattributes`, `.gitignore` | Repository maintenance | Text normalization and exclusions |

All five `Modules/Custom/*.ps1` scripts are **unconditionally dot-sourced** by the existing profile. Do not delete one without removing its import line. The standalone scripts do not run at PowerShell startup.

## Programs and modules

Use **PowerShell 7**, not Windows PowerShell 5.1. For the full current configuration install:

```powershell
winget install --exact --id Microsoft.PowerShell
winget install --exact --id Microsoft.WindowsTerminal
winget install --exact --id JanDeDobbeleer.OhMyPosh
winget install --exact --id ajeetdsouza.zoxide
winget install --exact --id Atuinsh.Atuin
```

`atuin` and `zoxide` are required for the current profile's unguarded initialization calls. `oh-my-posh` is optional because its call is guarded. Install a Nerd Font in Windows Terminal to render prompt glyphs correctly. Reopen your terminal to refresh PATH after installing programs.

The alias script defines wrappers calling these programs. Install them for the corresponding aliases to function:

| Alias | External command | Suggested WinGet ID |
| --- | --- | --- |
| `ls`, `ll`, `tree` | `eza` | `eza-community.eza` |
| `cat` | `bat` | `sharkdp.bat` |
| `find` | `fd` | `sharkdp.fd` |
| `grep` | `rg` | `BurntSushi.ripgrep.MSVC` |
| `du` | `dust` | `bootandy.dust` |
| `top` | `btm` | `Clement.bottom` |
| `curl` | `xh` | `ducaale.xh` |
| `flex` | `fastfetch` | `Fastfetch-cli.Fastfetch` |

To install the full alias toolset:

```powershell
@(
    'eza-community.eza', 'sharkdp.bat', 'sharkdp.fd',
    'BurntSushi.ripgrep.MSVC', 'bootandy.dust', 'Clement.bottom',
    'ducaale.xh', 'Fastfetch-cli.Fastfetch'
) | ForEach-Object { winget install --exact --id $_ }
```

The Python wrapper needs `python.exe` on PATH. `py` is overridden with an alias to the wrapper, so the standard `py.exe` launcher is no longer invoked by typing `py` in this profile. `make` is aliased only if `mingw32-make` is installed.

PowerShell modules:

```powershell
Install-Module PSReadLine -Scope CurrentUser -Force
Install-Module Terminal-Icons -Scope CurrentUser
Install-Module Microsoft.WinGet.CommandNotFound -Scope CurrentUser
Install-Module wt-shell-integration -Scope CurrentUser
```

`PSReadLine` is required by the custom key-binding scripts. The other modules are optional imports, including `wt-shell-integration`. The latter is a third-party dependency **not vendored in this repository**. Module availability and compatibility may vary by installed PowerShell version.

## Installation

Run these commands from a clean PowerShell 7 session, ideally `pwsh -NoProfile`, at the repository root. Existing destination files with matching names will be overwritten, so back up your current setup first.

```powershell
$profileDir = Split-Path -Parent $PROFILE.CurrentUserCurrentHost
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
Copy-Item -Path .\PowerShell\* -Destination $profileDir -Recurse -Force

$themeDir = Join-Path $HOME '.poshthemes'
New-Item -ItemType Directory -Force -Path $themeDir | Out-Null
Copy-Item -Path .\Themes\*.json -Destination $themeDir -Force

$customDir = Join-Path $HOME '.custom'
New-Item -ItemType Directory -Force -Path $customDir | Out-Null
Copy-Item -Path .\CustomScripts\*.ps1 -Destination $customDir -Force

$atuinDir = Join-Path $HOME '.config\atuin'
New-Item -ItemType Directory -Force -Path $atuinDir | Out-Null
Copy-Item -LiteralPath .\Atuin\config.toml -Destination $atuinDir -Force
```

The profile expects `$HOME/.poshthemes/atomic.omp.json`. The `monitor-mode` function expects `$HOME/.custom/Kali-MonitorMode.ps1`. If execution policy blocks local scripts, inspect `Get-ExecutionPolicy -List` before using `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`. Reopen PowerShell 7 after installation.

## Standalone scripts

### `CustomScripts/start-webui.ps1`

Requires Open WebUI installed with an `open-webui` executable available on PATH. This script does **not** install it automatically. By default, it listens on **localhost port 9090**, doesn't kill processes, and doesn't upgrade packages. It checks for a port conflict, waits at most 60 seconds for an HTTP response, and reports early exits. Its HTTP readiness check proves a response, not service identity.

```powershell
& .\CustomScripts\start-webui.ps1
& .\CustomScripts\start-webui.ps1 -Port 9091 -OpenBrowser
& .\CustomScripts\start-webui.ps1 -StartFcc
& .\CustomScripts\start-webui.ps1 -HostAddress 0.0.0.0
```

`-StartFcc` optionally starts `fcc-server` if installed. `-UpdateWebUI` requires `uv` and upgrades a uv-tool-managed Open WebUI installation, so do not use it with a pip/venv-managed installation. The script does not manage all possible installations or verify readiness of `fcc-server`.

### `CustomScripts/gpg-startup.ps1`

Requires Windows GnuPG. With no parameters, it only connects to/initializes the GPG agent. It includes no private key, keygrip, passphrase or account-specific absolute path.

```powershell
& .\CustomScripts\gpg-startup.ps1
```

Optional presetting requires `gpg-preset-passphrase`, a user-provided keygrip, `allow-preset-passphrase` in local `gpg-agent.conf`, and a passphrase encrypted for the **current Windows account** using PowerShell DPAPI. Create the encrypted secret locally, never in the repo:

```powershell
$localDir = Join-Path $env:LOCALAPPDATA 'GnuPG-Secure'
New-Item -ItemType Directory -Path $localDir -Force | Out-Null
$secret = Read-Host 'GPG passphrase' -AsSecureString
$secret | ConvertFrom-SecureString | Set-Content (Join-Path $localDir 'passphrase.dat')
# Find your keygrip using: gpg --with-keygrip --list-secret-keys
& .\CustomScripts\gpg-startup.ps1 -Keygrip '<40-character-keygrip>'
```

This opt-in method briefly handles a plaintext passphrase in process memory. Presetting also means the unlocked secret is cached by the agent. Use standard pinentry instead if you do not need unattended presetting. The encrypted file stays out of the repository, and typically cannot be decrypted by a different Windows account.

### `CustomScripts/Kali-MonitorMode.ps1`

Requires administrator PowerShell 7, WSL2 Kali Linux, `usbipd-win`, `iw`, `iproute2`, `usbutils`, and a compatible USB wireless adapter/kernel driver. The script defaults to a particular adapter and driver, so inspect its configuration before use. It is not needed for the profile except when invoking `monitor-mode`.

You must use this [custom kernel for wsl2](https://github.com/DefinetlyNotAI/Kali_WSL2_Kernel) for this program to actually work, as current WSL2 kernel doesn't support this feature.

### `Startup/startup.cmd`

Requires Windows, WinGet, PowerShell, Windows Terminal, and administrator privileges. 
Place `startup.cmd` directly inside the Windows Startup folder (`Win + R` → `shell:startup`) to execute it automatically at user login.

The script requests administrator elevation if needed, runs `gpg-startup.ps1` (aforementioned script above), updates WinGet sources, and silently upgrades all eligible applications. It filters WinGet's unknown-version warning from the output (as it causes so many false positives such when you install scripts not via WinGet).

The hardcoded path to `gpg-startup.ps1` must match your local installation. 
Windows may prompt for administrator approval at every login.
The script does not install missing dependencies or guarantee successful upgrades.

## Security and version-control hygiene

Never commit Atuin history, GPG private keys, `passphrase.dat`, environment secrets, WebUI secret keys, or user-specific local configuration. These are not required for this repository. `.gitignore` prevents future accidental additions but cannot remove secrets already present in historical commits. Do not vendor installed PowerShell Gallery modules. The removed `PowerShell/Modules/wt-shell-integration/` directory should be installed externally instead.

## Known limitations

The profile currently assumes `atuin`, `zoxide`, and all five custom files are present. Some custom key-binding behavior depends on a compatible `PSReadLine` version. Aliases replace some native PowerShell commands. `CustomScripts` are optional and may require their own software and privileges. No automated installer or full test suite is included.
