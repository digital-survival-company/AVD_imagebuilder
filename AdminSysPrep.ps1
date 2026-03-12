#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Custom AdminSysPrep script voor Azure Image Builder (Win11 24H2 compatible).

.DESCRIPTION
    Vervangt het standaard Microsoft AdminSysPrep.ps1 script dat faalt op Win11 24H2
    omdat WindowsAzureTelemetryService niet meer bestaat.

    Dit script:
      1. Wacht op RdAgent service
      2. Wacht op WindowsAzureTelemetryService (als die bestaat, anders skip)
      3. Wacht op WindowsAzureGuestAgent service
      4. Ruimt unattend.xml bestanden op
      5. Voert Sysprep uit (/oobe /generalize /quit /mode:vm)
      6. Wacht tot IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE bereikt is

.NOTES
    Versie  : 1.0
    Auteur  : Steven van Beek
    Datum   : 2026-03-12
    Context : Azure Image Builder - draait als SYSTEM
#>

# --- Wacht op RdAgent ---
Write-Output '>>> Waiting for GA Service (RdAgent) to start ...'
while ((Get-Service RdAgent).Status -ne 'Running') { Start-Sleep -s 5 }
Write-Output '>>> RdAgent is running.'

# --- Wacht op WindowsAzureTelemetryService (als die bestaat) ---
Write-Output '>>> Checking for GA Service (WindowsAzureTelemetryService) ...'
$telemetrySvc = Get-Service -Name WindowsAzureTelemetryService -ErrorAction SilentlyContinue
if ($telemetrySvc) {
    Write-Output '>>> WindowsAzureTelemetryService found, waiting for Running state ...'
    while ($telemetrySvc.Status -ne 'Running') {
        Start-Sleep -s 5
        $telemetrySvc.Refresh()
    }
    Write-Output '>>> WindowsAzureTelemetryService is running.'
}
else {
    Write-Output '>>> WindowsAzureTelemetryService not found (expected on Win11 24H2), skipping.'
}

# --- Wacht op WindowsAzureGuestAgent ---
Write-Output '>>> Waiting for GA Service (WindowsAzureGuestAgent) to start ...'
while ((Get-Service WindowsAzureGuestAgent).Status -ne 'Running') { Start-Sleep -s 5 }
Write-Output '>>> WindowsAzureGuestAgent is running.'

# --- Opruimen unattend.xml ---
if (Test-Path $Env:SystemRoot\system32\Sysprep\unattend.xml) {
    Write-Output '>>> Removing Sysprep\unattend.xml ...'
    Remove-Item $Env:SystemRoot\system32\Sysprep\unattend.xml -Force
}

if (Test-Path $Env:SystemRoot\Panther\unattend.xml) {
    Write-Output '>>> Removing Panther\unattend.xml ...'
    Remove-Item $Env:SystemRoot\Panther\unattend.xml -Force
}

# --- Sysprep uitvoeren ---
Write-Output '>>> Sysprepping VM ...'
& $Env:SystemRoot\System32\Sysprep\Sysprep.exe /oobe /generalize /quit /mode:vm

# --- Wacht op IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE ---
while ($true) {
    $imageState = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State).ImageState
    Write-Output $imageState
    if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }
    Start-Sleep -s 5
}
Write-Output '>>> Sysprep complete ...'

# --- Zelfdestructie: verwijder dit script van de image ---
Write-Output '>>> Cleanup: removing DeprovisioningScript.ps1 from image ...'
Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
Write-Output '>>> Cleanup complete.'
