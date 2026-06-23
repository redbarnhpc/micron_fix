#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Micron NVMe Firmware Check - Windows Edition

.DESCRIPTION
    Scans NVMe devices for known-bad Micron firmware versions affected by the
    panic-state defect (7450 series: E2MU200, 7500 series: E3MQ000), and
    provides exact remediation guidance.

    Uses built-in Windows CIM/WMI — no additional tools required.
    For firmware flashing, use Micron's msecli (Storage Executive) on Windows.

    Released by Red Barn HPC
    https://redbarnhpc.com
    Release date: 2026-06-22

.NOTES
    Must be run as Administrator.
    Tested on Windows 10/11 and Windows Server 2019/2022.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SCRIPT_VERSION      = "1.1.0"
$SCRIPT_RELEASE_DATE = "2026-06-22"

# Known-bad firmware versions
$BAD_FW = @{
    '7450' = 'E2MU200'
    '7500' = 'E3MQ000'
}

# Fixed firmware targets
$FIX_FW = @{
    '7450' = 'E2MU300'
    '7500' = 'E3MQ005'
}

# Firmware download URLs (verified from micron.com/products/storage/ssd/micron-ssd-firmware)
$FW_URLS = @{
    '7450' = 'https://assets.micron.com/adobe/assets/urn:aaid:aem:09a5aa0b-2dd0-42ec-90ec-1b5aa21f59bb/renditions/original/as/micron-7450-e2mu300-release-ubi.zip'
    '7500' = 'https://assets.micron.com/adobe/assets/urn:aaid:aem:8f57c338-6f7e-406b-91e0-6c250a026be3/renditions/original/as/micron-7500-e3mq005-release-ubi.zip'
}

function Write-Banner {
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "  Micron NVMe Firmware Check" -ForegroundColor Cyan
    Write-Host "  by Red Barn HPC | https://redbarnhpc.com" -ForegroundColor Cyan
    Write-Host "  v$SCRIPT_VERSION | Released $SCRIPT_RELEASE_DATE" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Get-NvmeDrives {
    # Return all SCSI-interface drives that look like Micron NVMe parts.
    # Micron 7450/7500 part numbers start with MTFD; Windows reports InterfaceType
    # as SCSI for NVMe drives and does not include "NVMe" in the model string.
    $all = Get-CimInstance -ClassName Win32_DiskDrive
    $drives = $all | Where-Object {
        $_.Model -match 'NVMe|NVME|Micron|MTFD'
    }
    return $drives
}

function Get-DriveFamily {
    param([string]$Model, [string]$FirmwareRevision)

    # Primary: firmware revision prefix is unambiguous
    # 7500 firmware: E3MQxxx   7450 firmware: E2MUxxx
    if ($FirmwareRevision -match '^E3MQ') { return '7500' }
    if ($FirmwareRevision -match '^E2MU') { return '7450' }

    # Fallback: model/part number heuristics
    # MTFDKCC is ambiguous (7450 MAX U.3 AND 7500 U.3) -- resolved by firmware above
    # Unambiguous 7450-only prefixes:
    #   MTFDKBA = 7450 M.2
    #   MTFDKBG = 7450 E1.S 25mm
    #   MTFDKBZ = 7450 E1.S 5.9mm
    #   MTFDKCE = 7450 E1.S 15mm
    if ($Model -match '7500') { return '7500' }
    if ($Model -match '7450|MTFDKBA|MTFDKBG|MTFDKBZ|MTFDKCE') { return '7450' }

    return $null
}

function Test-MicronAffected {
    param([string]$Family, [string]$FirmwareRevision)
    if (-not $Family) { return $false }
    return ($FirmwareRevision -eq $BAD_FW[$Family])
}

function Show-DriveTable {
    param([array]$Drives, [hashtable]$AffectedMap)

    Write-Host "NVMe drives found:" -ForegroundColor White
    Write-Host ("-" * 90)
    Write-Host ("{0,-6} {1,-40} {2,-20} {3,-12} {4}" -f "Index", "Model", "Serial", "Firmware", "Status")
    Write-Host ("-" * 90)

    foreach ($drive in $Drives) {
        $idx      = $drive.Index
        $model    = $drive.Model.Trim()
        $serial   = $drive.SerialNumber.Trim()
        $firmware = $drive.FirmwareRevision.Trim()
        $family   = Get-DriveFamily -Model $model -FirmwareRevision $firmware
        $affected = Test-MicronAffected -Family $family -FirmwareRevision $firmware

        if ($affected) {
            Write-Host ("{0,-6} {1,-40} {2,-20} {3,-12} {4}" -f $idx, $model, $serial, $firmware, "*** AFFECTED ***") -ForegroundColor Red
        } else {
            $status = if ($family -and $firmware -eq $FIX_FW[$family]) { "OK" }
                      elseif ($family) { "Check/Update" }
                      else { "-" }
            Write-Host ("{0,-6} {1,-40} {2,-20} {3,-12} {4}" -f $idx, $model, $serial, $firmware, $status) -ForegroundColor Gray
        }
    }

    Write-Host ("-" * 90)
}

function Show-Remediation {
    param([array]$AffectedDrives)

    $msecli = "& 'C:\Program Files\Micron Technology\Micron Storage Executive CLI\msecli.exe'"

    Write-Host ""
    Write-Host "REMEDIATION" -ForegroundColor Yellow
    Write-Host "==========="
    Write-Host ""
    Write-Host "Step 1: Install Micron Storage Executive (msecli)" -ForegroundColor White
    Write-Host "  Download: https://www.micron.com/sales-support/downloads/software-drivers/storage-executive-software" -ForegroundColor Cyan
    Write-Host "  Install location: C:\Program Files\Micron Technology\Micron Storage Executive CLI\msecli.exe" -ForegroundColor Gray
    Write-Host ""

    $families = $AffectedDrives | ForEach-Object { Get-DriveFamily -Model $_.Model -FirmwareRevision $_.FirmwareRevision.Trim() } | Sort-Object -Unique

    foreach ($family in $families) {
        $targetFw  = $FIX_FW[$family]
        $fwUrl     = $FW_URLS[$family]
        $badFw     = $BAD_FW[$family]
        $ubiFIlename = "Micron_${family}_${targetFw}_release.ubi"
        $drivesInFamily = $AffectedDrives | Where-Object { (Get-DriveFamily -Model $_.Model -FirmwareRevision $_.FirmwareRevision.Trim()) -eq $family }

        Write-Host "--- Micron $family series (bad: $badFw  fix: $targetFw) ---" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Step 2: Download and extract the firmware" -ForegroundColor White
        Write-Host "  Download zip: $fwUrl" -ForegroundColor Cyan
        Write-Host "  Extract the zip. You should have a file named: $ubiFIlename" -ForegroundColor Gray
        Write-Host "  Note the FULL path to that file (e.g. C:\Users\You\Downloads\$ubiFIlename)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Step 3: Find the msecli device name for each affected drive" -ForegroundColor White
        Write-Host "  Run: $msecli -L" -ForegroundColor Green
        Write-Host "  Look for drives matching the models listed below and note their 'Device Name' value." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Affected drives detected by this script:" -ForegroundColor White
        foreach ($drive in $drivesInFamily) {
            Write-Host "    Model : $($drive.Model.Trim())" -ForegroundColor Gray
            Write-Host "    Serial: $($drive.SerialNumber.Trim()) (WMI format - do NOT use this in msecli commands)" -ForegroundColor DarkYellow
            Write-Host ""
        }
        Write-Host "Step 4: Flash each affected drive" -ForegroundColor White
        Write-Host "  IMPORTANT: Use the full path to the .ubi file. Relative paths may fail." -ForegroundColor DarkYellow
        Write-Host "  Replace <DeviceName> with the value from 'Device Name' in Step 3 output." -ForegroundColor Gray
        Write-Host "  Replace <FullPathToUbi> with the full path to $ubiFIlename." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  $msecli -F -U <FullPathToUbi> -n <DeviceName> -S 2" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Example:" -ForegroundColor Gray
        Write-Host "  $msecli -F -U C:\Users\RBC\Downloads\$ubiFIlename -n mtinvme202510C3A431 -S 2" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Step 5: Reboot the system (full power cycle, not just restart)" -ForegroundColor White
        Write-Host "  Then verify the firmware updated:" -ForegroundColor Gray
        Write-Host "  $msecli -L" -ForegroundColor Green
        Write-Host "  FW-Rev should now show: $targetFw" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  NOTE: If flashing fails with an internal error, the drive may require" -ForegroundColor DarkYellow
        Write-Host "  sanitize first (DESTROYS ALL DATA). Linux nvme-cli required for sanitize:" -ForegroundColor DarkYellow
        Write-Host "  sudo nvme sanitize /dev/nvmeX --sanact=4" -ForegroundColor DarkYellow
        Write-Host ""
    }

    Write-Host "Micron firmware downloads page:" -ForegroundColor White
    Write-Host "https://www.micron.com/products/storage/ssd/micron-ssd-firmware" -ForegroundColor Cyan
    Write-Host ""
}

function Main {
    Write-Banner

    # Verify running as admin (belt-and-suspenders, #Requires handles it too)
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "ERROR: Must be run as Administrator." -ForegroundColor Red
        exit 1
    }

    Write-Host "Scanning NVMe drives..." -ForegroundColor White
    Write-Host ""

    try {
        $allDrives = Get-NvmeDrives
    } catch {
        Write-Host "ERROR: Failed to query drives: $_" -ForegroundColor Red
        exit 1
    }

    if (-not $allDrives) {
        Write-Host "No NVMe drives detected." -ForegroundColor Yellow
        exit 0
    }

    $affectedDrives = @()
    foreach ($drive in $allDrives) {
        $family = Get-DriveFamily -Model $drive.Model -FirmwareRevision $drive.FirmwareRevision.Trim()
        if ($family -and (Test-MicronAffected -Family $family -FirmwareRevision $drive.FirmwareRevision.Trim())) {
            $affectedDrives += $drive
        }
    }

    Show-DriveTable -Drives $allDrives -AffectedMap @{}

    Write-Host ""

    if ($affectedDrives.Count -eq 0) {
        Write-Host "No affected Micron firmware versions detected." -ForegroundColor Green
        Write-Host "Verify any Micron 7450/7500 drives above are on E2MU300 / E3MQ005 or later." -ForegroundColor Gray
    } else {
        Write-Host "$($affectedDrives.Count) affected drive(s) found." -ForegroundColor Red
        Show-Remediation -AffectedDrives $affectedDrives
    }
}

Main
