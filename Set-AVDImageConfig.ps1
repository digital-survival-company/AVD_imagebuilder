#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configureer Nederlandse regio-instellingen en FSLogix op een AVD Image Builder image.

.DESCRIPTION
    Dit script draait tijdens de Azure Image Builder customization (voor sysprep) en doet:
      1. Systeemlocale instellen op nl-NL
      2. Default User profiel (NTUSER.DAT) aanpassen zodat nieuwe gebruikers NL-instellingen krijgen
      3. HKU\.DEFAULT (SYSTEM-account) registry aanpassen
      4. FSLogix: CCDLocations uitlezen, waarde overnemen in VHDLocations, CCDLocations verwijderen

.NOTES
    Versie  : 1.0
    Auteur  : Steven van Beek
    Datum   : 2026-03-12
    Context : Azure Image Builder - draait als SYSTEM, geen gebruikers ingelogd
#>

# ============================================================
#  CONFIGURATIE
# ============================================================
$ScriptName    = 'Set-AVDImageConfig'
$ScriptVersion = '1.0'
$LogDir        = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AVD_builder'
$LogFile       = Join-Path $LogDir "$ScriptName`_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$FSLogixPath   = 'HKLM:\SOFTWARE\FSLogix\Profiles'

# ============================================================
#  LOGGING
# ============================================================
function Initialize-Log {
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    Write-Log "========================================"
    Write-Log "$ScriptName v$ScriptVersion gestart"
    Write-Log "Computer : $env:COMPUTERNAME"
    Write-Log "Gebruiker: $env:USERNAME"
    Write-Log "Datum/tijd: $(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')"
    Write-Log "========================================"
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'dd-MM-yyyy HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'ERROR'   { Write-Error   $Message }
        'WARN'    { Write-Warning $Message }
        'SUCCESS' { Write-Host    $Message -ForegroundColor Green }
        default   { Write-Host    $Message }
    }
}

# ============================================================
#  NL REGISTRY WAARDEN
# ============================================================
function Get-NLIntlValues {
    return @{
        Locale           = '00000413'
        LocaleName       = 'nl-NL'
        sLanguage        = 'NLD'
        sCountry         = 'Nederland'
        iCountry         = '31'
        sList            = ';'
        iMeasure         = '0'
        iDate            = '1'
        iTime            = '1'
        iFirstDayOfWeek  = '0'
        sShortDate       = 'dd-MM-yyyy'
        sLongDate        = 'dddd d MMMM yyyy'
        sTimeFormat      = 'HH:mm:ss'
        sShortTime       = 'HH:mm'
        sCurrency        = 'eu'
        sMonDecimalSep   = ','
        sMonThousandSep  = '.'
        sDecimal         = ','
        sThousand        = '.'
    }
}

function Write-IntlRegistry {
    param([string]$IntlPath, [string]$GeoPath)
    $intlValues = Get-NLIntlValues
    if (-not (Test-Path $IntlPath)) { New-Item -Path $IntlPath -Force | Out-Null }
    if (-not (Test-Path $GeoPath))  { New-Item -Path $GeoPath  -Force | Out-Null }
    foreach ($kv in $intlValues.GetEnumerator()) {
        Set-ItemProperty -Path $IntlPath -Name $kv.Key -Value $kv.Value -Type String -Force
    }
    Set-ItemProperty -Path $GeoPath -Name Nation -Value '176' -Type String -Force
}

# ============================================================
#  STAP 1 - SYSTEEM LOCALE
# ============================================================
function Set-SystemLocaleSettings {
    Write-Log "--- Stap 1: Systeemlocale instellen ---"
    try {
        Set-WinSystemLocale -SystemLocale nl-NL
        Write-Log "Set-WinSystemLocale -> nl-NL" -Level SUCCESS

        Set-TimeZone -Id "W. Europe Standard Time"
        Write-Log "Tijdzone -> W. Europe Standard Time" -Level SUCCESS

        $nlsPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language"
        Set-ItemProperty -Path $nlsPath -Name "Default"         -Value "0413" -Type String -Force
        Set-ItemProperty -Path $nlsPath -Name "InstallLanguage" -Value "0413" -Type String -Force
        Write-Log "HKLM NLS Default + InstallLanguage -> 0413 (nl-NL)" -Level SUCCESS
    }
    catch {
        Write-Log "Fout bij instellen systeemlocale: $_" -Level ERROR
        throw
    }
}

# ============================================================
#  STAP 2 - DEFAULT USER PROFIEL (NTUSER.DAT)
# ============================================================
function Set-DefaultUserProfile {
    Write-Log "--- Stap 2: Default User profiel aanpassen (NTUSER.DAT) ---"
    $defaultHive = "C:\Users\Default\NTUSER.DAT"
    $mountKey    = "HKU\TempDefaultUser"

    try {
        $null = reg load $mountKey $defaultHive 2>&1
        Write-Log "Default User hive gemount op $mountKey"

        Write-IntlRegistry `
            -IntlPath "Registry::$mountKey\Control Panel\International" `
            -GeoPath  "Registry::$mountKey\Control Panel\International\Geo"

        Write-Log "NL-waarden geschreven naar Default User hive" -Level SUCCESS
    }
    catch {
        Write-Log "Fout bij aanpassen Default User profiel: $_" -Level ERROR
    }
    finally {
        [GC]::Collect()
        Start-Sleep -Seconds 2
        $null = reg unload $mountKey 2>&1
        Write-Log "Default User hive ontkoppeld"
    }
}

# ============================================================
#  STAP 3 - HKU\.DEFAULT (SYSTEM-account)
# ============================================================
function Set-SystemAccountLocale {
    Write-Log "--- Stap 3: HKU\.DEFAULT (SYSTEM-account) registry aanpassen ---"
    try {
        Write-IntlRegistry `
            -IntlPath "Registry::HKU\.DEFAULT\Control Panel\International" `
            -GeoPath  "Registry::HKU\.DEFAULT\Control Panel\International\Geo"

        Write-Log "NL-waarden geschreven naar HKU\.DEFAULT" -Level SUCCESS
    }
    catch {
        Write-Log "Fout bij schrijven HKU\.DEFAULT: $_" -Level ERROR
        throw
    }
}

# ============================================================
#  STAP 4 - KERBEROS: CloudKerberosTicketRetrievalEnabled verwijderen
# ============================================================
function Remove-CloudKerberosKey {
    Write-Log "--- Stap 4: CloudKerberosTicketRetrievalEnabled verwijderen ---"
    $kerberosPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters"
    $keyName      = "CloudKerberosTicketRetrievalEnabled"

    if (-not (Test-Path $kerberosPath)) {
        Write-Log "Registry pad niet gevonden: $kerberosPath" -Level WARN
        return
    }

    $existing = Get-ItemProperty -Path $kerberosPath -Name $keyName -ErrorAction SilentlyContinue
    if ($existing) {
        try {
            Remove-ItemProperty -Path $kerberosPath -Name $keyName -Force
            Write-Log "$keyName verwijderd uit $kerberosPath" -Level SUCCESS
        }
        catch {
            Write-Log "Fout bij verwijderen $keyName : $_" -Level ERROR
            throw
        }
    }
    else {
        Write-Log "$keyName bestaat niet in $kerberosPath, niets te verwijderen" -Level INFO
    }
}

# ============================================================
#  STAP 5 - FSLOGIX: CCDLocations -> VHDLocations
# ============================================================
function Set-FSLogixVHDLocations {
    Write-Log "--- Stap 5: FSLogix CCDLocations -> VHDLocations ---"

    # Controleer of het FSLogix Profiles pad bestaat
    if (-not (Test-Path $FSLogixPath)) {
        Write-Log "FSLogix Profiles registry pad niet gevonden: $FSLogixPath" -Level WARN
        return
    }

    # Lees CCDLocations uit
    $ccdLocations = $null
    try {
        $ccdLocations = Get-ItemProperty -Path $FSLogixPath -Name 'CCDLocations' -ErrorAction Stop
        $ccdValue = $ccdLocations.CCDLocations
        Write-Log "CCDLocations gevonden: $ccdValue"
    }
    catch {
        Write-Log "CCDLocations bestaat niet in $FSLogixPath" -Level WARN
    }

    # Bepaal de share-paden voor VHDLocations
    if ($ccdValue) {
        # CCDLocations kan meerdere entries bevatten (type=smb,connectionString=...)
        # Extraheer het UNC-pad (\\server\share formaat)
        $uncPaths = @()
        foreach ($entry in $ccdValue) {
            if ($entry -match '(\\\\[^\s,;]+)') {
                $uncPaths += $Matches[1]
                Write-Log "UNC-pad geëxtraheerd uit CCDLocations: $($Matches[1])"
            }
            elseif ($entry -match '^\\\\') {
                # Al een UNC-pad
                $uncPaths += $entry
                Write-Log "UNC-pad direct uit CCDLocations: $entry"
            }
        }

        if ($uncPaths.Count -eq 0) {
            Write-Log "Geen UNC-paden gevonden in CCDLocations, waarde wordt direct overgenomen" -Level WARN
            $uncPaths = @($ccdValue)
        }
    }
    else {
        Write-Log "Geen CCDLocations beschikbaar, VHDLocations wordt niet ingesteld" -Level WARN
        return
    }

    # Stel VHDLocations in
    try {
        Set-ItemProperty -Path $FSLogixPath -Name 'VHDLocations' -Value $uncPaths -Type MultiString -Force
        Write-Log "VHDLocations ingesteld op: $($uncPaths -join ', ')" -Level SUCCESS
    }
    catch {
        Write-Log "Fout bij instellen VHDLocations: $_" -Level ERROR
        throw
    }

    # Verwijder CCDLocations
    try {
        Remove-ItemProperty -Path $FSLogixPath -Name 'CCDLocations' -Force
        Write-Log "CCDLocations verwijderd uit registry" -Level SUCCESS
    }
    catch {
        Write-Log "Fout bij verwijderen CCDLocations: $_" -Level ERROR
        throw
    }
}

# ============================================================
#  STAP 6 - OPRUIMEN: C:\mmr verwijderen
# ============================================================
function Remove-MMRFolder {
    Write-Log "--- Stap 6: C:\mmr folder verwijderen ---"
    $mmrPath = 'C:\mmr'

    if (Test-Path $mmrPath) {
        try {
            Remove-Item -Path $mmrPath -Recurse -Force
            Write-Log "Folder $mmrPath verwijderd" -Level SUCCESS
        }
        catch {
            Write-Log "Fout bij verwijderen $mmrPath : $_" -Level ERROR
            throw
        }
    }
    else {
        Write-Log "Folder $mmrPath bestaat niet, niets te verwijderen" -Level INFO
    }
}

# ============================================================
#  HOOFDPROCES
# ============================================================
try {
    Initialize-Log
    Set-SystemLocaleSettings
    Set-DefaultUserProfile
    Set-SystemAccountLocale
    Remove-CloudKerberosKey
    Set-FSLogixVHDLocations
    Remove-MMRFolder

    Write-Log "========================================"
    Write-Log "$ScriptName v$ScriptVersion voltooid zonder fatale fouten" -Level SUCCESS
    Write-Log "Logbestand: $LogFile"
    Write-Log "========================================"
    Exit 0
}
catch {
    Write-Log "FATALE FOUT: $_" -Level ERROR
    Write-Log "Script afgebroken. Zie log: $LogFile" -Level ERROR
    Exit 1
}
