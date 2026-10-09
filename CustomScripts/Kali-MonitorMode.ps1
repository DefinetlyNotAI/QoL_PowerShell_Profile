#requires -Version 7.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Configures a USB Wi-Fi adapter for monitor mode inside Kali Linux on WSL2.

.DESCRIPTION
    Automates the process of passing a supported USB Wi-Fi adapter from
    Windows to a Kali Linux WSL2 instance and configuring its wireless
    interface for monitor mode.

    The script detects the configured USB adapter by VID:PID, starts the
    target Kali WSL2 distribution, binds and attaches the adapter through
    usbipd, loads the configured Linux wireless driver, detects the resulting
    wireless interface, and switches that interface into monitor mode.

    Once monitor mode is ready, an interactive Kali shell is opened for the
    user. When the shell exits, or if an error occurs, the script performs a
    cleanup sequence intended to restore the system to its previous state.

    Cleanup includes restoring the wireless interface mode, detaching the USB
    device from WSL2, removing temporary usbipd bindings created by this
    script, and shutting down WSL2.

    Runtime state is tracked so that resources which existed before execution
    are preserved where possible.

.AUTHOR
    Shahm Najeeb

.VERSION
    1.0.0

.CREATED
    2026-09-04

.LASTUPDATED
    2026-09-04

.REQUIREMENTS
    - PowerShell 7.0 or later
    - Administrator privileges
    - Windows Subsystem for Linux 2 (WSL2)
    - Kali Linux WSL distribution
    - usbipd-win
    - A compatible USB Wi-Fi adapter
    - Required wireless driver installed in the Kali kernel
    - iw, ip, and lsusb available inside Kali

.CONFIGURATION
    Distro
        Name of the WSL distribution used by the script.
        Default: kali-linux

    TargetVidPid
        USB vendor and product identifier used to locate the Wi-Fi adapter.
        Default: 0bda:0811

    Driver
        Linux kernel module loaded for the wireless adapter.
        Default: rtw88_8821au

    UsbPollMs
        Delay between USB detection checks.

    UsbTimeoutSec
        Maximum time to wait for USB enumeration inside Kali.

    WlanTimeoutSec
        Maximum time to wait for a wireless interface after loading the driver.

.BEHAVIOR
    1. Verifies required Windows executables and the target WSL distribution.
    2. Waits for the target Wi-Fi adapter to be disconnected and reconnected.
    3. Detects and selects the matching USB device.
    4. Starts the Kali WSL2 distribution.
    5. Binds the adapter to usbipd when necessary.
    6. Attaches the adapter to WSL2.
    7. Loads the configured wireless kernel module.
    8. Detects the wireless interface.
    9. Records its original operating mode.
    10. Switches the interface into monitor mode.
    11. Opens an interactive Kali shell.
    12. Restores the interface and USB state when the session ends.

.CLEANUP
    Cleanup executes from a finally block and attempts each restoration step
    independently so that failure of one cleanup operation does not prevent
    subsequent operations.

    The script attempts to:
    - Restore the wireless interface to its original mode.
    - Detach the USB adapter from WSL2.
    - Remove the usbipd binding only if this script created it.
    - Shut down WSL2.
    - Terminate the WSL keep-alive process if necessary.

.SECURITY
    Monitor mode provides access to raw IEEE 802.11 traffic and may be used
    with packet capture and wireless testing utilities.

    Use wireless testing functionality only on networks and devices for which
    you have authorization.

.NOTES
    File        : Kali-MonitorMode.ps1
    Platform    : Windows with WSL2
    Shell       : PowerShell 7+
    Privileges  : Administrator
    WSL Distro  : Kali Linux

    The script executes Linux commands directly through wsl.exe rather than
    constructing shell command strings, reducing quoting and escaping issues
    between PowerShell and Linux shells.
    
    Custom-built kernel based on Microsoft's WSL2 Linux kernel source.
    Kernel build and setup instructions are not included.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================================
# Configuration
# ============================================================================

$Debug = $false

$Distro       = "kali-linux"
$TargetVidPid = "0bda:0811"
$Driver       = "rtw88_8821au"

$UsbPollMs      = 500
$UsbTimeoutSec  = 20
$WlanTimeoutSec = 20

# ============================================================================
# Runtime state
# ============================================================================

$State = [ordered]@{
    SelectedDevice = $null
    BusId          = $null

    BoundByUs      = $false
    AttachedByUs   = $false

    Interface      = $null
    OriginalMode   = $null
    MonitorEnabled = $false

    KeepAlive      = $null
    WslStarted     = $false
}

# ============================================================================
# Logging
# ============================================================================

function Write-Log {
    param(
        [ValidateSet("INFO", "OK", "WARN", "ERROR", "STEP", "DEBUG")]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message
    )

    # Suppress DEBUG messages when debugging is disabled
    if ($Level -eq "DEBUG" -and -not $Debug) {
        return
    }

    $time = Get-Date -Format "HH:mm:ss"

    $color = switch ($Level) {
        "INFO"  { "Gray" }
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "STEP"  { "Cyan" }
        "DEBUG" { "DarkGray" }
    }

    $prefix = switch ($Level) {
        "INFO"  { "[ INFO  ]" }
        "OK"    { "[SUCCESS]" }
        "WARN"  { "[ WARN  ]" }
        "ERROR" { "[ ERROR ]" }
        "STEP"  { "[ STEP  ]" }
        "DEBUG" { "[ DEBUG ]" }
    }

    Write-Host "[$time] $prefix $Message" -ForegroundColor $color
}

function Write-Banner {
    Clear-Host

    Write-Host
    Write-Host " Kali WSL2 Monitor Mode" -ForegroundColor Cyan
    Write-Host " ======================" -ForegroundColor Cyan
    Write-Host

    Write-Log INFO "Target distro : $Distro"
    Write-Log INFO "Target USB    : $TargetVidPid"
    Write-Log INFO "Kernel driver : $Driver"

    Write-Host
}

# ============================================================================
# Native process helpers
# ============================================================================

function Invoke-Native {
    param(
        [Parameter(Mandatory)]
        [string]$File,

        [string[]]$Arguments = @(),

        [switch]$IgnoreExitCode,

        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-Log DEBUG "$File $($Arguments -join ' ')"
    }

    $output = @(
        & $File @Arguments 2>&1 |
            ForEach-Object { "$_" }
    )

    $exitCode = $LASTEXITCODE

    if (-not $Quiet) {
        foreach ($line in $output) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Log DEBUG $line
            }
        }
    }

    if (($exitCode -ne 0) -and (-not $IgnoreExitCode)) {
        $details = ($output -join [Environment]::NewLine)

        if ([string]::IsNullOrWhiteSpace($details)) {
            throw "$File exited with code $exitCode."
        }

        throw "$File exited with code $exitCode.`n$details"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory)]
        [string[]]$Command,

        [switch]$IgnoreExitCode,

        [switch]$Quiet
    )

    $args = @(
        "-d", $Distro,
        "-u", "root",
        "--"
    ) + $Command

    return Invoke-Native `
        -File "wsl.exe" `
        -Arguments $args `
        -IgnoreExitCode:$IgnoreExitCode `
        -Quiet:$Quiet
}

# ============================================================================
# USB discovery
# ============================================================================

function Get-UsbDevices {
    $result = Invoke-Native `
        -File "usbipd.exe" `
        -Arguments @("list") `
        -Quiet

    $devices = foreach ($line in $result.Output) {

        if (
            $line -match
            '^\s*(\d+-\d+(?:\.\d+)*)\s+([0-9A-Fa-f]{4}:[0-9A-Fa-f]{4})\s+(.+?)\s{2,}(.+?)\s*$'
        ) {
            [PSCustomObject]@{
                BusId  = $Matches[1]
                VidPid = $Matches[2].ToLowerInvariant()
                Device = $Matches[3].Trim()
                State  = $Matches[4].Trim()
            }
        }
    }

    return @($devices)
}

function Get-TargetDongles {
    return @(
        Get-UsbDevices |
            Where-Object {
                $_.VidPid -eq $TargetVidPid
            }
    )
}

function Wait-ForDongleRemoval {
    Write-Log STEP "Remove the Wi-Fi dongle if it is currently connected."

    $devices = @(Get-TargetDongles)

    if ($devices.Count -eq 0) {
        Write-Log OK "Dongle is already disconnected."
        return
    }

    Write-Log INFO "Detected $($devices.Count) matching dongle(s)."
    Write-Log INFO "Waiting for physical removal..."

    while ($true) {
        Start-Sleep -Milliseconds $UsbPollMs

        $devices = @(Get-TargetDongles)

        if ($devices.Count -eq 0) {
            break
        }

        Write-Log DEBUG "Dongle still connected: $($devices[0].BusId)"
    }

    Write-Log OK "Dongle removal detected."
}

function Wait-ForDongleInsertion {
    Write-Host
    Write-Log STEP "Reconnect the Wi-Fi dongle."
    Write-Log INFO "Waiting for Windows to enumerate $TargetVidPid..."

    while ($true) {
        $devices = @(Get-TargetDongles)

        if ($devices.Count -gt 0) {
            Write-Log OK "Detected $($devices.Count) matching USB device(s)."
            return $devices
        }

        Start-Sleep -Milliseconds $UsbPollMs
    }
}

function Select-Dongle {
    param(
        [Parameter(Mandatory)]
        [array]$Devices
    )

    if ($Devices.Count -eq 1) {
        $device = $Devices[0]

        Write-Log OK "Automatically selected USB device."
        Write-Log INFO "Device : $($device.Device)"
        Write-Log DEBUG "BUSID  : $($device.BusId)"
        Write-Log DEBUG "VID:PID: $($device.VidPid)"
        Write-Log DEBUG "State  : $($device.State)"

        return $device
    }

    Write-Host
    Write-Log STEP "Multiple matching adapters were detected."

    for ($i = 0; $i -lt $Devices.Count; $i++) {
        $number = $i + 1

        Write-Host (
            "  [{0}] {1,-8} {2,-10} {3}" -f
            $number,
            $Devices[$i].BusId,
            $Devices[$i].VidPid,
            $Devices[$i].Device
        )
    }

    while ($true) {
        $choice = Read-Host "Select adapter"

        if ($choice -match '^\d+$') {
            $index = [int]$choice - 1

            if (($index -ge 0) -and ($index -lt $Devices.Count)) {
                return $Devices[$index]
            }
        }

        Write-Log WARN "Invalid selection."
    }
}

# ============================================================================
# WSL lifecycle
# ============================================================================

function Assert-UsbipdFirewall {
    Write-Log INFO "Checking usbipd service and firewall..."

    $service = Get-Service -Name "usbipd" -ErrorAction SilentlyContinue

    if ($null -eq $service) {
        throw "usbipd service is not installed."
    }

    if ($service.Status -ne "Running") {
        Write-Log WARN "usbipd service is not running. Starting it..."
        Start-Service -Name "usbipd"
        Write-Log OK "usbipd service started."
    }
    else {
        Write-Log OK "usbipd service is running."
    }

    $listeners = @(
        Get-NetTCPConnection `
            -LocalPort 3240 `
            -State Listen `
            -ErrorAction SilentlyContinue
    )

    if ($listeners.Count -eq 0) {
        throw "usbipd service is running, but TCP port 3240 is not listening."
    }

    Write-Log OK "usbipd is listening on TCP port 3240."

    $rules = @(
        Get-NetFirewallRule `
            -DisplayName "usbipd" `
            -ErrorAction SilentlyContinue
    )

    if ($rules.Count -eq 0) {
        Write-Log WARN "usbipd firewall rule is missing."
        Write-Log INFO "Creating inbound TCP 3240 firewall rule..."

        New-NetFirewallRule `
            -DisplayName "usbipd" `
            -Description "Allow WSL2 to connect to the usbipd USB/IP service." `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort 3240 `
            -Profile Any `
            -Enabled True | Out-Null

        Write-Log OK "usbipd firewall rule created."
    }
    else {
        Write-Log OK "usbipd firewall rule exists."

        $disabledRules = @(
            $rules |
                Where-Object { $_.Enabled -ne "True" }
        )

        if ($disabledRules.Count -gt 0) {
            Write-Log WARN "usbipd firewall rule is disabled. Enabling it..."

            $disabledRules |
                Enable-NetFirewallRule

            Write-Log OK "usbipd firewall rule enabled."
        }
    }

    $allowRule = @(
        Get-NetFirewallRule `
            -DisplayName "usbipd" `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Enabled -eq "True" -and
                $_.Direction -eq "Inbound" -and
                $_.Action -eq "Allow"
            }
    )

    if ($allowRule.Count -eq 0) {
        throw "No enabled inbound Allow firewall rule exists for usbipd."
    }

    $portAllowed = $false

    foreach ($rule in $allowRule) {
        $filters = @(
            $rule | Get-NetFirewallPortFilter
        )

        foreach ($filter in $filters) {
            if (
                $filter.Protocol -eq "TCP" -and
                (
                    $filter.LocalPort -eq "3240" -or
                    $filter.LocalPort -eq "Any"
                )
            ) {
                $portAllowed = $true
                break
            }
        }

        if ($portAllowed) {
            break
        }
    }

    if (-not $portAllowed) {
        throw "usbipd firewall rule exists, but it does not allow inbound TCP port 3240."
    }

    Write-Log OK "Firewall allows inbound usbipd traffic on TCP 3240."
}

function Assert-Prerequisites {
    Write-Log STEP "Checking prerequisites..."

    foreach ($command in @("wsl.exe", "usbipd.exe")) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required executable '$command' was not found."
        }

        Write-Log OK "Found $command"
    }

    $result = Invoke-Native `
        -File "wsl.exe" `
        -Arguments @("--list", "--quiet") `
        -Quiet

    $distros = @(
        $result.Output |
            ForEach-Object {
                ($_ -replace "`0", "").Trim()
            } |
            Where-Object { $_ }
    )

    if ($Distro -notin $distros) {
        throw "WSL distribution '$Distro' does not exist."
    }

    Write-Log OK "Found WSL distribution '$Distro'."
}

function Start-Kali {
    Write-Host
    Write-Log STEP "Starting Kali WSL2..."

    # Keep Kali alive without relying on shell quoting.
    $processArgs = @(
        "-d", $Distro,
        "-u", "root",
        "--",
        "sleep", "infinity"
    )

    $State.KeepAlive = Start-Process `
        -FilePath "wsl.exe" `
        -ArgumentList $processArgs `
        -WindowStyle Hidden `
        -PassThru

    $deadline = (Get-Date).AddSeconds(15)

    while ((Get-Date) -lt $deadline) {

        $running = Invoke-Native `
            -File "wsl.exe" `
            -Arguments @("--list", "--running", "--quiet") `
            -Quiet

        $names = @(
            $running.Output |
                ForEach-Object {
                    ($_ -replace "`0", "").Trim()
                }
        )

        if ($Distro -in $names) {
            $State.WslStarted = $true

            Write-Log OK "Kali is running."
            Write-Log DEBUG "Keep-alive PID: $($State.KeepAlive.Id)"
            
            Write-Log INFO "Testing command execution inside Kali..."

            $probe = Invoke-Wsl `
                -Command @("uname", "-r") `
                -IgnoreExitCode `
                -Quiet

            if ($probe.ExitCode -ne 0) {
                throw "Kali entered the running state, but command execution failed."
            }

            $kernel = ($probe.Output -join " ").Trim()

            Write-Log OK "Kali command execution confirmed."

            if (-not [string]::IsNullOrWhiteSpace($kernel)) {
                Write-Log INFO "WSL kernel: $kernel"
            }
            return
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Kali did not reach the running state."
}

# ============================================================================
# USB/IP
# ============================================================================

function Attach-Dongle {
    param(
        [Parameter(Mandatory)]
        $Device
    )

    $State.BusId = $Device.BusId

    Write-Host
    Write-Log STEP "Preparing USB device $($Device.BusId)..."
    Write-Log INFO "Device : $($Device.Device)"
    Write-Log INFO "BUSID  : $($Device.BusId)"
    Write-Log INFO "VID:PID: $($Device.VidPid)"
    Write-Log INFO "State  : $($Device.State)"

    if ($Device.State -match '^Not shared') {
        Write-Log INFO "Device is not currently shared with usbipd."
        Write-Log INFO "Binding USB device $($Device.BusId)..."

        $bindStarted = Get-Date

        Invoke-Native `
            -File "usbipd.exe" `
            -Arguments @(
                "bind",
                "--busid", $Device.BusId
            ) | Out-Null

        $bindElapsed = (Get-Date) - $bindStarted

        $State.BoundByUs = $true

        Write-Log OK (
            "USB device bound to usbipd in {0:N2}s." -f
            $bindElapsed.TotalSeconds
        )
    }
    else {
        Write-Log INFO "USB device is already shared with usbipd."
        Write-Log INFO "Existing state: $($Device.State)"
    }

    Write-Log INFO "Refreshing usbipd device state..."

    $currentDevices = @(Get-TargetDongles)
    $currentDevice = $currentDevices |
        Where-Object { $_.BusId -eq $Device.BusId } |
        Select-Object -First 1

    if ($null -ne $currentDevice) {
        Write-Log INFO "Current usbipd state: $($currentDevice.State)"
    }
    else {
        Write-Log WARN "Device disappeared from usbipd list after binding."
    }

    Write-Log OK "USB dongle preparation complete."

    Write-Host
    Write-Log STEP "Routing USB device into WSL2..."
    Write-Log INFO "Target WSL distro : $Distro"
    Write-Log INFO "USB BUSID         : $($Device.BusId)"
    Write-Log INFO "Expected VID:PID  : $TargetVidPid"
    Write-Log INFO "Starting usbipd attach command..."
    Write-Log INFO "Command: usbipd attach --wsl --busid $($Device.BusId)"

    $attachStarted = Get-Date

    try {
        $attachResult = Invoke-Native `
            -File "usbipd.exe" `
            -Arguments @(
                "attach",
                "--wsl",
                "--busid", $Device.BusId
            )
    }
    catch {
        $attachElapsed = (Get-Date) - $attachStarted

        Write-Log ERROR (
            "usbipd attach failed after {0:N2}s." -f
            $attachElapsed.TotalSeconds
        )

        throw
    }

    $attachElapsed = (Get-Date) - $attachStarted

    Write-Log INFO (
        "usbipd attach command returned after {0:N2}s." -f
        $attachElapsed.TotalSeconds
    )

    Write-Log INFO "usbipd exit code: $($attachResult.ExitCode)"

    foreach ($line in $attachResult.Output) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log INFO "usbipd: $line"
        }
    }

    $State.AttachedByUs = $true

    Write-Log OK "usbipd attach completed."

    Write-Log INFO "Checking Windows-side usbipd state after attachment..."

    $attachedDevices = @(Get-TargetDongles)
    $attachedDevice = $attachedDevices |
        Where-Object { $_.BusId -eq $Device.BusId } |
        Select-Object -First 1

    if ($null -ne $attachedDevice) {
        Write-Log INFO "Post-attach state: $($attachedDevice.State)"
    }
    else {
        Write-Log WARN "Device is no longer visible in usbipd list."
    }

    Write-Host
    Write-Log INFO "Waiting for Kali to enumerate the USB adapter..."
    Write-Log INFO "Enumeration timeout: $UsbTimeoutSec seconds"

    $deadline = (Get-Date).AddSeconds($UsbTimeoutSec)
    $attempt = 0

    while ((Get-Date) -lt $deadline) {
        $attempt++

        $remaining = [math]::Max(
            0,
            [math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        )

        Write-Log INFO (
            "USB enumeration check #{0}, {1}s remaining..." -f
            $attempt,
            $remaining
        )

        $usb = Invoke-Wsl `
            -Command @("lsusb") `
            -IgnoreExitCode `
            -Quiet

        if ($usb.ExitCode -ne 0) {
            Write-Log WARN "lsusb returned exit code $($usb.ExitCode)."
        }
        else {
            $matchingLines = @(
                $usb.Output |
                    Where-Object {
                        $_ -match [regex]::Escape($TargetVidPid)
                    }
            )

            if ($matchingLines.Count -gt 0) {
                foreach ($line in $matchingLines) {
                    Write-Log INFO "Kali lsusb: $($line.Trim())"
                }

                Write-Log OK "Kali detected USB device $TargetVidPid."
                Write-Log OK "USB routing into WSL2 is complete."
                return
            }

            Write-Log INFO (
                "Kali responded to lsusb, but $TargetVidPid is not present yet."
            )
        }

        Start-Sleep -Milliseconds 500
    }

    Write-Log ERROR (
        "Kali failed to enumerate $TargetVidPid within $UsbTimeoutSec seconds."
    )

    Write-Log INFO "Final Kali lsusb output follows:"

    $finalUsb = Invoke-Wsl `
        -Command @("lsusb") `
        -IgnoreExitCode `
        -Quiet

    if ($finalUsb.Output.Count -eq 0) {
        Write-Log WARN "lsusb produced no output."
    }
    else {
        foreach ($line in $finalUsb.Output) {
            Write-Log INFO "lsusb: $($line.Trim())"
        }
    }

    throw "USB attachment succeeded, but Kali never detected $TargetVidPid."
}

# ============================================================================
# Wireless interface helpers
# ============================================================================

function Get-WirelessInterfaces {
    $result = Invoke-Wsl `
        -Command @("iw", "dev") `
        -IgnoreExitCode `
        -Quiet

    if ($result.ExitCode -ne 0) {
        return @()
    }

    $interfaces = foreach ($line in $result.Output) {
        if ($line -match '^\s*Interface\s+(\S+)\s*$') {
            $Matches[1]
        }
    }

    return @($interfaces)
}

function Get-InterfaceMode {
    param(
        [Parameter(Mandatory)]
        [string]$Interface
    )

    $result = Invoke-Wsl `
        -Command @(
            "iw",
            "dev",
            $Interface,
            "info"
        ) `
        -IgnoreExitCode `
        -Quiet

    if ($result.ExitCode -ne 0) {
        return $null
    }

    foreach ($line in $result.Output) {
        if ($line -match '^\s*type\s+(\S+)\s*$') {
            return $Matches[1]
        }
    }

    return $null
}

function Test-InterfaceExists {
    param(
        [Parameter(Mandatory)]
        [string]$Interface
    )

    $result = Invoke-Wsl `
        -Command @(
            "iw",
            "dev",
            $Interface,
            "info"
        ) `
        -IgnoreExitCode `
        -Quiet

    return ($result.ExitCode -eq 0)
}

# ============================================================================
# Monitor mode
# ============================================================================

function Enable-MonitorMode {
    Write-Host
    Write-Log STEP "Loading Realtek Wi-Fi driver..."

    Invoke-Wsl `
        -Command @(
            "modprobe",
            $Driver
        ) | Out-Null

    Write-Log OK "Driver '$Driver' loaded."

    Write-Log INFO "Waiting for wireless interface..."

    $interface = $null
    $deadline  = (Get-Date).AddSeconds($WlanTimeoutSec)

    while ((Get-Date) -lt $deadline) {

        $interfaces = @(Get-WirelessInterfaces)

        if ($interfaces.Count -gt 0) {
            $interface = $interfaces[0]
            break
        }

        Start-Sleep -Milliseconds 500
    }

    if ([string]::IsNullOrWhiteSpace($interface)) {
        throw "No wireless interface appeared after loading '$Driver'."
    }

    $State.Interface = $interface

    Write-Log OK "Wireless interface detected: $interface"

    $mode = Get-InterfaceMode -Interface $interface

    if ([string]::IsNullOrWhiteSpace($mode)) {
        throw "Could not determine the current mode of '$interface'."
    }

    $State.OriginalMode = $mode

    Write-Log DEBUG "Original interface mode: $mode"

    if ($mode -eq "monitor") {
        $State.MonitorEnabled = $true
        Write-Log WARN "$interface is already in monitor mode."
        return
    }

    Write-Host
    Write-Log STEP "Switching $interface to monitor mode..."

    #
    # IMPORTANT:
    # Each Linux command is executed directly.
    # There is NO bash -lc and therefore no PowerShell/Bash quote corruption.
    #

    Write-Log INFO "Bringing $interface down..."

    Invoke-Wsl `
        -Command @(
            "ip",
            "link",
            "set",
            $interface,
            "down"
        ) | Out-Null

    Write-Log OK "$interface is down."

    Write-Log INFO "Changing interface type to monitor..."

    Invoke-Wsl `
        -Command @(
            "iw",
            "dev",
            $interface,
            "set",
            "type",
            "monitor"
        ) | Out-Null

    Write-Log OK "Monitor type command accepted."

    Write-Log INFO "Bringing $interface back up..."

    Invoke-Wsl `
        -Command @(
            "ip",
            "link",
            "set",
            $interface,
            "up"
        ) | Out-Null

    Write-Log OK "$interface is up."

    $newMode = Get-InterfaceMode -Interface $interface

    if ($newMode -ne "monitor") {
        throw "Monitor-mode verification failed. Current mode is '$newMode'."
    }

    $State.MonitorEnabled = $true

    Write-Log OK "$interface is confirmed in monitor mode."

    $info = Invoke-Wsl `
        -Command @(
            "iw",
            "dev",
            $interface,
            "info"
        ) `
        -Quiet

    foreach ($line in $info.Output) {
        Write-Log DEBUG "  $($line.Trim())"
    }
}

# ============================================================================
# Cleanup
# ============================================================================

function Restore-WirelessMode {
    if ([string]::IsNullOrWhiteSpace([string]$State.Interface)) {
        Write-Log DEBUG "No wireless interface was recorded; nothing to restore."
        return
    }

    $interface = [string]$State.Interface

    if (-not (Test-InterfaceExists -Interface $interface)) {
        Write-Log WARN "Interface '$interface' no longer exists; skipping mode restoration."
        return
    }

    $targetMode = [string]$State.OriginalMode

    if ([string]::IsNullOrWhiteSpace($targetMode)) {
        $targetMode = "managed"
    }

    Write-Log INFO "Restoring $interface to '$targetMode' mode..."

    Invoke-Wsl `
        -Command @(
            "ip",
            "link",
            "set",
            $interface,
            "down"
        ) `
        -IgnoreExitCode `
        -Quiet | Out-Null

    Invoke-Wsl `
        -Command @(
            "iw",
            "dev",
            $interface,
            "set",
            "type",
            $targetMode
        ) `
        -IgnoreExitCode `
        -Quiet | Out-Null

    Invoke-Wsl `
        -Command @(
            "ip",
            "link",
            "set",
            $interface,
            "up"
        ) `
        -IgnoreExitCode `
        -Quiet | Out-Null

    $mode = Get-InterfaceMode -Interface $interface

    if ($mode -eq $targetMode) {
        $State.MonitorEnabled = $false
        Write-Log OK "$interface restored to '$targetMode'."
    }
    else {
        Write-Log WARN "Interface restoration could not be verified. Reported mode: '$mode'"
    }
}

function Detach-Usb {
    if ([string]::IsNullOrWhiteSpace([string]$State.BusId)) {
        Write-Log DEBUG "No BUSID recorded; USB detach not required."
        return
    }

    $busId = [string]$State.BusId

    Write-Log INFO "Detaching USB $busId from WSL..."

    $result = Invoke-Native `
        -File "usbipd.exe" `
        -Arguments @(
            "detach",
            "--busid", $busId
        ) `
        -IgnoreExitCode `
        -Quiet

    if ($result.ExitCode -eq 0) {
        $State.AttachedByUs = $false
        Write-Log OK "USB device detached from WSL."
    }
    else {
        Write-Log WARN "usbipd detach returned exit code $($result.ExitCode)."
    }
}

function Restore-UsbBinding {
    if (-not $State.BoundByUs) {
        Write-Log DEBUG "USB device was not bound by this script; preserving its original sharing state."
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$State.BusId)) {
        return
    }

    $busId = [string]$State.BusId

    Write-Log INFO "Removing temporary usbipd binding..."

    $result = Invoke-Native `
        -File "usbipd.exe" `
        -Arguments @(
            "unbind",
            "--busid", $busId
        ) `
        -IgnoreExitCode `
        -Quiet

    if ($result.ExitCode -eq 0) {
        $State.BoundByUs = $false
        Write-Log OK "usbipd binding removed."
    }
    else {
        Write-Log WARN "Could not remove usbipd binding cleanly."
    }
}

function Stop-Kali {
    Write-Log INFO "Shutting down WSL2..."

    Invoke-Native `
        -File "wsl.exe" `
        -Arguments @("--shutdown") `
        -IgnoreExitCode `
        -Quiet | Out-Null

    $State.WslStarted = $false

    Write-Log OK "WSL2 shutdown requested."

    if ($null -ne $State.KeepAlive) {
        try {
            if (-not $State.KeepAlive.HasExited) {
                $State.KeepAlive.Kill()
            }
        }
        catch {
            # WSL shutdown normally kills this process first.
        }

        $State.KeepAlive = $null
    }
}

function Invoke-Cleanup {
    Write-Host
    Write-Log STEP "Cleanup sequence started."

    #
    # Every cleanup operation is isolated.
    # One cleanup failure will NOT prevent later cleanup operations.
    #

    try {
        Restore-WirelessMode
    }
    catch {
        Write-Log WARN "Wireless cleanup failed: $($_.Exception.Message)"
    }

    try {
        Detach-Usb
    }
    catch {
        Write-Log WARN "USB detach failed: $($_.Exception.Message)"
    }

    try {
        Restore-UsbBinding
    }
    catch {
        Write-Log WARN "USB binding cleanup failed: $($_.Exception.Message)"
    }

    try {
        Stop-Kali
    }
    catch {
        Write-Log WARN "WSL shutdown failed: $($_.Exception.Message)"
    }

    Write-Log OK "Cleanup sequence finished."
}

# ============================================================================
# Main
# ============================================================================

try {
    Write-Banner

    Assert-Prerequisites
    Assert-UsbipdFirewall

    Write-Host
    Wait-ForDongleRemoval

    $devices = @(Wait-ForDongleInsertion)

    $State.SelectedDevice = Select-Dongle -Devices $devices
    $State.BusId          = $State.SelectedDevice.BusId

    Start-Kali

    Attach-Dongle -Device $State.SelectedDevice

    Enable-MonitorMode

    Write-Host
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host " MONITOR MODE READY" -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host
    Write-Host " Interface : $($State.Interface)"
    Write-Host " Mode      : monitor"
    Write-Host " USB BUSID : $($State.BusId)"
    Write-Host " VID:PID   : $TargetVidPid"
    Write-Host " Driver    : $Driver"

    Write-Host
    Write-Host " Quick Commands" -ForegroundColor Cyan
    Write-Host " --------------" -ForegroundColor Cyan
    Write-Host
    Write-Host " Scan nearby networks:"
    Write-Host "   sudo airodump-ng $($State.Interface)"
    Write-Host
    Write-Host " Show interface information:"
    Write-Host "   iw dev $($State.Interface) info"
    Write-Host
    Write-Host " Set channel:"
    Write-Host "   sudo iw dev $($State.Interface) set channel <channel>"
    Write-Host
    Write-Host " Capture to file:"
    Write-Host "   sudo airodump-ng --write capture $($State.Interface)"
    Write-Host
    Write-Host " Capture a specific AP:"
    Write-Host "   sudo airodump-ng --bssid <BSSID> --channel <channel> --write capture $($State.Interface)"
    Write-Host
    Write-Host " Packet capture:"
    Write-Host "   sudo tcpdump -i $($State.Interface) -e"
    Write-Host
    Write-Host " Test packet injection:"
    Write-Host "   sudo aireplay-ng --test $($State.Interface)"
    Write-Host
    Write-Host " Deauth test client (authorized lab only):"
    Write-Host "   sudo aireplay-ng --deauth <count> -a <AP-BSSID> -c <CLIENT-MAC> $($State.Interface)"
    Write-Host
    Write-Host " Open GUI via RDC (May take some time to init):"
    Write-Host "   kex --esm --ip -s"
    Write-Host

    Write-Host
    Write-Host " Session" -ForegroundColor Cyan
    Write-Host " -------" -ForegroundColor Cyan
    Write-Host
    Write-Host " An interactive Kali shell will now open."
    Write-Host " Type 'exit' when finished."
    Write-Host
    Write-Host " The script will then:"
    Write-Host "   - restore the interface mode"
    Write-Host "   - detach the USB adapter from WSL"
    Write-Host "   - restore its usbipd sharing state"
    Write-Host "   - shut down WSL2"
    Write-Host
    Write-Host "================================================================"
    Write-Host

    Write-Log STEP "Opening interactive Kali shell..."
    Write-Log INFO "Please understand this is a full on shell that is WSL"
    Write-Log INFO "This script is just attached to it"
    
    Write-Host "================================================================"
    Write-Host "================================================================"
    
    Write-Host

    & wsl.exe -d $Distro

    $shellExit = $LASTEXITCODE

    Write-Host
    Write-Host "================================================================"
    Write-Host "================================================================"
    Write-Host
    
    if ($shellExit -eq 0) {
        Write-Log DEBUG "Interactive Kali shell exited normally."
    }
    else {
        Write-Log WARN "Interactive Kali shell exited with code $shellExit."
    }
}
catch {
    Write-Host
    Write-Log ERROR $_.Exception.Message
}
finally {
    Invoke-Cleanup

    Write-Host "================================================================"
    Write-Log OK "Session complete."
    Write-Log INFO "USB adapter has been returned to Windows."
    Write-Log INFO "WSL2 has been shut down."
    Write-Host "================================================================"
    Write-Host
}