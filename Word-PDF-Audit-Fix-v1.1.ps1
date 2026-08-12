<#
.SYNOPSIS
    Word PDF Rendering Auditor / Fixer

.DESCRIPTION
    Audits Microsoft Word settings that can affect drawings, pictures, backgrounds,
    tracked changes/markup and PDF/printing behavior.

    It can:
      - Audit the local computer/user.
      - Apply a conservative fix for the most relevant Word rendering options.
      - Export a JSON report.
      - Compare the current machine with a JSON report from a known-good machine.

    IMPORTANT:
      - Run this script in the affected USER context, because most Word settings are per-user.
      - Close Microsoft Word before using -Mode Fix.
      - The script does NOT delete/reset Normal.dotm and does NOT wipe the Word registry.
      - It does NOT require administrative rights for the normal audit/fix.

.PARAMETER Mode
    Audit   = Show current settings.
    Fix     = Enable the safe Word rendering/printing settings most related to missing drawings/images.
    Export  = Export a diagnostic JSON report.
    Compare = Compare this computer against a previously exported JSON report.

.PARAMETER OutputPath
    JSON file used by Export mode.

.PARAMETER ReferenceReport
    JSON report from the known-good machine, used by Compare mode.

.EXAMPLE
    .\Word-PDF-Audit-Fix.ps1 -Mode Audit

.EXAMPLE
    .\Word-PDF-Audit-Fix.ps1 -Mode Fix

.EXAMPLE
    .\Word-PDF-Audit-Fix.ps1 -Mode Export -OutputPath C:\Temp\Word-GOOD-23H2.json

.EXAMPLE
    .\Word-PDF-Audit-Fix.ps1 -Mode Compare -ReferenceReport C:\Temp\Word-GOOD-23H2.json

.NOTES
    Recommended comparison:
      1. On a GOOD 23H2/working machine:
         .\Word-PDF-Audit-Fix.ps1 -Mode Export -OutputPath C:\Temp\Word-GOOD.json

      2. Copy Word-GOOD.json to the affected 25H2 machine.

      3. On the BAD 25H2 machine:
         .\Word-PDF-Audit-Fix.ps1 -Mode Compare -ReferenceReport C:\Temp\Word-GOOD.json

      4. If appropriate:
         .\Word-PDF-Audit-Fix.ps1 -Mode Fix
#>

[CmdletBinding()]
param(
    [ValidateSet('Audit','Fix','Export','Compare')]
    [string]$Mode = 'Audit',

    [string]$OutputPath = "$env:TEMP\Word-PDF-Audit-$env:COMPUTERNAME-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json",

    [string]$ReferenceReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan
}

function Get-RegistrySnapshot {
    param([string]$Path)

    $result = [ordered]@{
        Path   = $Path
        Exists = $false
        Values = [ordered]@{}
    }

    if (-not (Test-Path $Path)) {
        return [pscustomobject]$result
    }

    $result.Exists = $true

    try {
        $item = Get-ItemProperty -Path $Path
        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') {
                $value = $property.Value

                if ($value -is [byte[]]) {
                    $value = [System.BitConverter]::ToString($value)
                }
                elseif ($value -is [array]) {
                    $value = @($value)
                }

                $result.Values[$property.Name] = $value
            }
        }
    }
    catch {
        $result.Values['_ReadError'] = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-OfficeExecutableInfo {
    $candidates = @(
        "$env:ProgramFiles\Microsoft Office\root\Office16\WINWORD.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\WINWORD.EXE",
        "$env:ProgramFiles\Microsoft Office\Office16\WINWORD.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office16\WINWORD.EXE"
    ) | Where-Object { $_ -and (Test-Path $_) }

    if (-not $candidates) {
        try {
            $appPath = Get-ItemProperty 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Winword.exe' -ErrorAction Stop
            if ($appPath.'(default)' -and (Test-Path $appPath.'(default)')) {
                $candidates = @($appPath.'(default)')
            }
        }
        catch {}
    }

    if (-not $candidates) {
        return [pscustomobject]@{
            Found       = $false
            Path        = $null
            FileVersion = $null
            ProductVersion = $null
        }
    }

    $path = $candidates | Select-Object -First 1
    $vi = (Get-Item $path).VersionInfo

    [pscustomobject]@{
        Found          = $true
        Path           = $path
        FileVersion    = $vi.FileVersion
        ProductVersion = $vi.ProductVersion
    }
}

function Get-WordComSnapshot {
    $word = $null

    try {
        $word = New-Object -ComObject Word.Application
        $word.Visible = $false

        $options = $word.Options

        $data = [ordered]@{
            Available                              = $true
            Version                                = $word.Version
            Build                                  = $word.Build
            PrintDrawingObjects                    = $options.PrintDrawingObjects
            PrintBackgrounds                       = $options.PrintBackgrounds
            PrintBackground                        = $options.PrintBackground
            PrintComments                          = $options.PrintComments
            PrintHiddenText                        = $options.PrintHiddenText
            PrintFieldCodes                        = $options.PrintFieldCodes
            ShowMarkupOpenSave                     = $options.ShowMarkupOpenSave
            WarnBeforeSavingPrintingSendingMarkup  = $options.WarnBeforeSavingPrintingSendingMarkup
            UpdateFieldsAtPrint                    = $options.UpdateFieldsAtPrint
            UpdateFieldsWithTrackedChangesAtPrint  = $options.UpdateFieldsWithTrackedChangesAtPrint
            UpdateLinksAtPrint                     = $options.UpdateLinksAtPrint
            RevisedLinesMark                       = [int]$options.RevisedLinesMark
            RevisedLinesColor                      = [int]$options.RevisedLinesColor
            RevisionsBalloonPrintOrientation       = [int]$options.RevisionsBalloonPrintOrientation
        }

        return [pscustomobject]$data
    }
    catch {
        return [pscustomobject]@{
            Available = $false
            Error     = $_.Exception.Message
        }
    }
    finally {
        if ($word) {
            try { $word.Quit() } catch {}
            try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($word) } catch {}
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Get-SystemSnapshot {
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    $displayVersion = $null
    if ($cv.PSObject.Properties.Name -contains 'DisplayVersion') {
        $displayVersion = $cv.DisplayVersion
    }
    elseif ($cv.PSObject.Properties.Name -contains 'ReleaseId') {
        $displayVersion = $cv.ReleaseId
    }

    [pscustomobject]@{
        ComputerName     = $env:COMPUTERNAME
        User             = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        OSName           = $os.Caption
        OSVersion        = $os.Version
        OSBuild          = $os.BuildNumber
        DisplayVersion   = $displayVersion
        UBR              = $cv.UBR
        Architecture     = $os.OSArchitecture
        PowerShell       = $PSVersionTable.PSVersion.ToString()
        Timestamp        = (Get-Date).ToString('o')
    }
}

function Get-FullSnapshot {
    $registryPaths = @(
        'HKCU:\Software\Microsoft\Office\16.0\Word\Options',
        'HKCU:\Software\Microsoft\Office\16.0\Word\Data',
        'HKCU:\Software\Microsoft\Office\16.0\Word\Security',
        'HKCU:\Software\Microsoft\Office\Common\General',
        'HKCU:\Software\Policies\Microsoft\Office\16.0\Word\Options',
        'HKCU:\Software\Policies\Microsoft\Office\16.0\Word\Security',
        'HKLM:\Software\Policies\Microsoft\Office\16.0\Word\Options',
        'HKLM:\Software\Policies\Microsoft\Office\16.0\Word\Security'
    )

    $registry = foreach ($path in $registryPaths) {
        Get-RegistrySnapshot -Path $path
    }

    [pscustomobject]@{
        System       = Get-SystemSnapshot
        WordExe      = Get-OfficeExecutableInfo
        WordOptions  = Get-WordComSnapshot
        Registry     = @($registry)
    }
}

function Show-Snapshot {
    param($Snapshot)

    Write-Section "SYSTEM"
    $Snapshot.System | Format-List

    Write-Section "MICROSOFT WORD"
    $Snapshot.WordExe | Format-List

    Write-Section "WORD OPTIONS RELEVANT TO PDF / PRINT RENDERING"
    $Snapshot.WordOptions | Format-List

    Write-Section "WORD REGISTRY / POLICY SNAPSHOT"
    foreach ($entry in $Snapshot.Registry) {
        Write-Host ""
        Write-Host $entry.Path -ForegroundColor Yellow
        Write-Host ("Exists: {0}" -f $entry.Exists)

        if ($entry.Exists) {
            # Avoid .Count on PSObject.Properties under StrictMode.
            # Values is an OrderedDictionary; enumerate its keys safely.
            $valueNames = @($entry.Values.Keys)

            if ($valueNames.Count -eq 0) {
                Write-Host "  <no values>"
            }
            else {
                foreach ($name in $valueNames) {
                    Write-Host ("  {0} : {1}" -f $name, $entry.Values[$name])
                }
            }
        }
    }
}

function Set-WordSafeRenderingOptions {
    Write-Section "APPLYING CONSERVATIVE WORD PDF/PRINT FIX"

    $wordProcesses = Get-Process WINWORD -ErrorAction SilentlyContinue
    if ($wordProcesses) {
        throw "Microsoft Word is currently running. Close ALL Word windows and run the script again."
    }

    $word = $null

    try {
        $word = New-Object -ComObject Word.Application
        $word.Visible = $false

        $o = $word.Options

        $changes = [System.Collections.Generic.List[object]]::new()

        function Set-OptionValue {
            param(
                [string]$Name,
                [bool]$Desired
            )

            $before = [bool]$o.$Name

            if ($before -ne $Desired) {
                $o.$Name = $Desired
            }

            $after = [bool]$o.$Name

            $changes.Add([pscustomobject]@{
                Option = $Name
                Before = $before
                Desired = $Desired
                After = $after
                Changed = ($before -ne $after)
            })
        }

        # Core options for the reported symptom:
        # Missing Word drawings/shapes/text boxes/watermarks from PDF/print.
        Set-OptionValue -Name 'PrintDrawingObjects' -Desired $true

        # Include page background colors/images in print/PDF pipeline.
        Set-OptionValue -Name 'PrintBackgrounds' -Desired $true

        # Keep Word aware of markup when opening/saving documents.
        # This does not forcibly add markup to every PDF job; it preserves markup visibility behavior.
        Set-OptionValue -Name 'ShowMarkupOpenSave' -Desired $true

        # Warn when saving/printing/sending a file that contains tracked markup.
        Set-OptionValue -Name 'WarnBeforeSavingPrintingSendingMarkup' -Desired $true

        # Updating fields before print can prevent stale field-based content.
        Set-OptionValue -Name 'UpdateFieldsAtPrint' -Desired $true

        Write-Host ""
        $changes | Format-Table -AutoSize

        if (($changes | Where-Object { $_.After -ne $_.Desired }).Count -gt 0) {
            Write-Warning "One or more settings could not be changed. A Group Policy may be enforcing the value."
        }
        else {
            Write-Host ""
            Write-Host "Word rendering options applied successfully." -ForegroundColor Green
        }

        return $changes
    }
    finally {
        if ($word) {
            try { $word.Quit() } catch {}
            try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($word) } catch {}
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function ConvertTo-FlatMap {
    param(
        [Parameter(Mandatory)]
        $InputObject,
        [string]$Prefix = ''
    )

    $map = [ordered]@{}

    if ($null -eq $InputObject) {
        $map[$Prefix] = $null
        return $map
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $child = if ($Prefix) { "$Prefix.$key" } else { "$key" }
            $childMap = ConvertTo-FlatMap -InputObject $InputObject[$key] -Prefix $child
            foreach ($k in $childMap.Keys) { $map[$k] = $childMap[$k] }
        }
        return $map
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and
        -not ($InputObject -is [string])) {

        $i = 0
        foreach ($item in $InputObject) {
            $child = if ($Prefix) { "$Prefix[$i]" } else { "[$i]" }
            $childMap = ConvertTo-FlatMap -InputObject $item -Prefix $child
            foreach ($k in $childMap.Keys) { $map[$k] = $childMap[$k] }
            $i++
        }
        return $map
    }

    if ($InputObject -is [pscustomobject]) {
        foreach ($p in $InputObject.PSObject.Properties) {
            $child = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
            $childMap = ConvertTo-FlatMap -InputObject $p.Value -Prefix $child
            foreach ($k in $childMap.Keys) { $map[$k] = $childMap[$k] }
        }
        return $map
    }

    $map[$Prefix] = $InputObject
    return $map
}

function Compare-Snapshots {
    param(
        [Parameter(Mandatory)] $Reference,
        [Parameter(Mandatory)] $Current
    )

    Write-Section "COMPARISON: REFERENCE vs CURRENT"

    $refMap = ConvertTo-FlatMap -InputObject $Reference
    $curMap = ConvertTo-FlatMap -InputObject $Current

    $allKeys = @($refMap.Keys + $curMap.Keys) | Sort-Object -Unique

    $ignore = @(
        'System.Timestamp',
        'System.ComputerName',
        'System.User'
    )

    $differences = foreach ($key in $allKeys) {
        if ($ignore -contains $key) { continue }

        $refExists = $refMap.Contains($key)
        $curExists = $curMap.Contains($key)

        $refValue = if ($refExists) { $refMap[$key] } else { '<missing>' }
        $curValue = if ($curExists) { $curMap[$key] } else { '<missing>' }

        $refText = if ($null -eq $refValue) { '<null>' } else { [string]$refValue }
        $curText = if ($null -eq $curValue) { '<null>' } else { [string]$curValue }

        if ($refText -ne $curText) {
            [pscustomobject]@{
                Setting   = $key
                Reference = $refText
                Current   = $curText
            }
        }
    }

    if (-not $differences) {
        Write-Host "No differences found in the captured Word/System configuration." -ForegroundColor Green
        return @()
    }

    $importantPatterns = @(
        'WordOptions\.',
        'Policies',
        'Print',
        'Markup',
        'Drawing',
        'Background',
        'Revision',
        'WordExe'
    )

    $important = $differences | Where-Object {
        $setting = $_.Setting
        ($importantPatterns | Where-Object { $setting -match $_ }).Count -gt 0
    }

    if ($important) {
        Write-Host "Most relevant differences:" -ForegroundColor Yellow
        $important | Format-Table -AutoSize -Wrap
    }

    Write-Host ""
    Write-Host "All captured differences:" -ForegroundColor Yellow
    $differences | Format-Table -AutoSize -Wrap

    return @($differences)
}

try {
    switch ($Mode) {
        'Audit' {
            $snapshot = Get-FullSnapshot
            Show-Snapshot -Snapshot $snapshot
        }

        'Fix' {
            $before = Get-FullSnapshot

            Write-Section "BEFORE"
            $before.WordOptions | Format-List

            $null = Set-WordSafeRenderingOptions

            Start-Sleep -Seconds 1
            $after = Get-FullSnapshot

            Write-Section "AFTER"
            $after.WordOptions | Format-List

            Write-Host ""
            Write-Host "Next test:" -ForegroundColor Cyan
            Write-Host "  1. Open the same problematic DOCX."
            Write-Host "  2. File > Print and confirm Print Markup when revision bars are expected."
            Write-Host "  3. Test Word Save As/Export PDF."
            Write-Host "  4. Test Microsoft Print to PDF."
            Write-Host "  5. If installed, test Adobe PDF/PDFMaker."
        }

        'Export' {
            $snapshot = Get-FullSnapshot

            $parent = Split-Path -Parent $OutputPath
            if ($parent -and -not (Test-Path $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            $snapshot | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputPath -Encoding UTF8

            Show-Snapshot -Snapshot $snapshot
            Write-Host ""
            Write-Host "Report exported to:" -ForegroundColor Green
            Write-Host "  $OutputPath"
        }

        'Compare' {
            if (-not $ReferenceReport) {
                throw "Compare mode requires -ReferenceReport <path-to-json>."
            }

            if (-not (Test-Path $ReferenceReport)) {
                throw "Reference report not found: $ReferenceReport"
            }

            $reference = Get-Content -Path $ReferenceReport -Raw | ConvertFrom-Json
            $current = Get-FullSnapshot

            $differences = Compare-Snapshots -Reference $reference -Current $current

            $comparePath = Join-Path $env:TEMP "Word-PDF-Compare-$env:COMPUTERNAME-$((Get-Date).ToString('yyyyMMdd-HHmmss')).csv"

            if (@($differences).Count -gt 0) {
                @($differences) | Export-Csv -Path $comparePath -NoTypeInformation -Encoding UTF8
                Write-Host ""
                Write-Host "Comparison CSV exported to:" -ForegroundColor Green
                Write-Host "  $comparePath"
            }
        }
    }
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
