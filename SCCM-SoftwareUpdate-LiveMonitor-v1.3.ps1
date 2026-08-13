#requires -Version 5.1
<#
.SYNOPSIS
    SCCM Software Update Live Monitor
.DESCRIPTION
    WinForms tool to monitor Configuration Manager software update progress in real time.
    Uses the ConfigMgr Client SDK (root\ccm\ClientSDK:CCM_SoftwareUpdate) and tails
    UpdatesHandler.log, UpdatesDeployment.log and WUAHandler.log through the admin share.

    Default refresh interval: 5 seconds.
    Remote CIM access uses DCOM (no WinRM required), but requires normal remote WMI/RPC access
    and administrative rights on the target.

.NOTES
    Run as Administrator from a management workstation with network access to the client.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# -----------------------------
# State maps - ConfigMgr Client SDK
# -----------------------------
$script:EvaluationStates = @{
    0  = 'None'
    1  = 'Available'
    2  = 'Submitted'
    3  = 'Detecting'
    4  = 'Pre-Download'
    5  = 'Downloading'
    6  = 'Waiting to Install'
    7  = 'Installing'
    8  = 'Pending Soft Reboot'
    9  = 'Pending Hard Reboot'
    10 = 'Waiting for Reboot'
    11 = 'Verifying'
    12 = 'Install Complete'
    13 = 'Error'
    14 = 'Waiting Service Window'
    15 = 'Waiting User Logon'
    16 = 'Waiting User Logoff'
    17 = 'Waiting Job User Logon'
    18 = 'Waiting User Reconnect'
    19 = 'Pending User Logoff'
    20 = 'Pending Update'
    21 = 'Waiting Retry'
    22 = 'Waiting Presentation Mode Off'
    23 = 'Waiting for Orchestration'
}

$script:ComplianceStates = @{
    0 = 'Missing'
    1 = 'Present'
    2 = 'Unknown / Not Applicable'
    3 = 'Evaluation Error'
    4 = 'Not Evaluated'
    5 = 'Not Updated'
    6 = 'Not Configured'
}

$script:CimSession = $null
$script:ConnectedComputer = $null
$script:LastLogSignature = @{}
$script:Busy = $false
$script:CurrentUpdates = @()
$script:DOProgressHistory = @{}
$script:DOStallMinutes = 5

function Convert-ErrorCode {
    param([object]$Value)

    if ($null -eq $Value) { return '' }
    try {
        $n = [uint32]$Value
        if ($n -eq 0) { return '0x00000000' }
        return ('0x{0:X8}' -f $n)
    }
    catch {
        return [string]$Value
    }
}

function Get-StateName {
    param([int]$State)
    if ($script:EvaluationStates.ContainsKey($State)) {
        return $script:EvaluationStates[$State]
    }
    return "Unknown ($State)"
}

function Get-ComplianceName {
    param([int]$State)
    if ($script:ComplianceStates.ContainsKey($State)) {
        return $script:ComplianceStates[$State]
    }
    return "Unknown ($State)"
}

function Get-StateCategory {
    param([int]$State)

    switch ($State) {
        5 { 'Downloading'; break }
        6 { 'Waiting'; break }
        7 { 'Installing'; break }
        8 { 'Reboot'; break }
        9 { 'Reboot'; break }
        10 { 'Reboot'; break }
        12 { 'Complete'; break }
        13 { 'Error'; break }
        14 { 'Waiting'; break }
        15 { 'Waiting'; break }
        16 { 'Waiting'; break }
        17 { 'Waiting'; break }
        18 { 'Waiting'; break }
        19 { 'Waiting'; break }
        20 { 'Waiting'; break }
        21 { 'Waiting'; break }
        22 { 'Waiting'; break }
        23 { 'Waiting'; break }
        default { 'Other' }
    }
}

function New-StatusLabel {
    param(
        [string]$Text,
        [int]$Left,
        [int]$Top,
        [int]$Width = 145
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Left = $Left
    $panel.Top = $Top
    $panel.Width = $Width
    $panel.Height = 58
    $panel.BorderStyle = 'FixedSingle'
    $panel.BackColor = [System.Drawing.Color]::White

    $title = New-Object System.Windows.Forms.Label
    $title.Text = $Text
    $title.Left = 8
    $title.Top = 7
    $title.Width = $Width - 16
    $title.Height = 18
    $title.ForeColor = [System.Drawing.Color]::DimGray

    $value = New-Object System.Windows.Forms.Label
    $value.Text = '0'
    $value.Left = 8
    $value.Top = 25
    $value.Width = $Width - 16
    $value.Height = 26
    $value.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $value.ForeColor = [System.Drawing.Color]::Black

    $panel.Controls.Add($title)
    $panel.Controls.Add($value)

    return [pscustomobject]@{
        Panel = $panel
        Value = $value
    }
}

function Disconnect-Target {
    if ($script:CimSession) {
        try { Remove-CimSession -CimSession $script:CimSession -ErrorAction SilentlyContinue } catch {}
    }
    $script:CimSession = $null
    $script:ConnectedComputer = $null
}

function Connect-Target {
    param([string]$ComputerName)

    Disconnect-Target

    $computer = $ComputerName.Trim()
    if ([string]::IsNullOrWhiteSpace($computer)) {
        throw 'Enter a computer name.'
    }

    $localAliases = @('.', 'localhost', $env:COMPUTERNAME)
    if ($localAliases -contains $computer) {
        $script:ConnectedComputer = $env:COMPUTERNAME
        return
    }

    $sessionOption = New-CimSessionOption -Protocol Dcom
    $script:CimSession = New-CimSession -ComputerName $computer -SessionOption $sessionOption -ErrorAction Stop
    $script:ConnectedComputer = $computer

    # Fast validation that the ConfigMgr client namespace is reachable.
    Get-CimInstance -CimSession $script:CimSession `
        -Namespace 'root\ccm\ClientSDK' `
        -ClassName 'CCM_SoftwareUpdate' `
        -ErrorAction Stop | Select-Object -First 1 | Out-Null
}

function Get-ClientUpdates {
    if ($script:CimSession) {
        return @(Get-CimInstance -CimSession $script:CimSession `
            -Namespace 'root\ccm\ClientSDK' `
            -ClassName 'CCM_SoftwareUpdate' `
            -ErrorAction Stop)
    }

    return @(Get-CimInstance `
        -Namespace 'root\ccm\ClientSDK' `
        -ClassName 'CCM_SoftwareUpdate' `
        -ErrorAction Stop)
}

function Get-ClientServices {
    $names = @('CcmExec','DoSvc','wuauserv','BITS')
    $filter = "Name='CcmExec' OR Name='DoSvc' OR Name='wuauserv' OR Name='BITS'"

    if ($script:CimSession) {
        return @(Get-CimInstance -CimSession $script:CimSession `
            -Namespace 'root\cimv2' `
            -ClassName 'Win32_Service' `
            -Filter $filter `
            -ErrorAction Stop)
    }

    return @(Get-CimInstance `
        -Namespace 'root\cimv2' `
        -ClassName 'Win32_Service' `
        -Filter $filter `
        -ErrorAction Stop)
}

function Get-LogRoot {
    if ($script:ConnectedComputer -eq $env:COMPUTERNAME) {
        return 'C:\Windows\CCM\Logs'
    }
    return "\\$($script:ConnectedComputer)\c$\Windows\CCM\Logs"
}

function ConvertFrom-CMTraceLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $Line }

    # Native CMTrace XML-ish format:
    # <![LOG[message]LOG]!><time="13:20:24.437+240" date="08-13-2026" component="..." ...>
    if ($Line -match '^\<\!\[LOG\[(?<msg>.*)\]LOG\]\!\>\<time="(?<time>[^"]+)".*component="(?<component>[^"]*)"') {

        # IMPORTANT: copy the captures now. A second -match would overwrite $Matches.
        $message   = [string]$Matches['msg']
        $timeValue = [string]$Matches['time']
        $component = [string]$Matches['component']

        $displayTime = $timeValue
        if ($timeValue -match '^(\d{2}:\d{2}:\d{2})') {
            $displayTime = $Matches[1]
        }

        if ([string]::IsNullOrWhiteSpace($component)) {
            return ('{0}  {1}' -f $displayTime, $message)
        }

        return ('{0}  [{1}]  {2}' -f $displayTime, $component, $message)
    }

    return $Line
}

function Get-InterestingLogLines {
    param(
        [string]$Path,
        [int]$Tail = 220
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @("[Log not reachable] $Path")
    }

    $rawLines = @(Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop)
    $lines = @($rawLines | ForEach-Object { ConvertFrom-CMTraceLine $_ })

    # Keep important operational lines while still showing recent context.
    $important = @(
        $lines | Where-Object {
            $_ -match '(?i)install|actionable|download|percent|reboot|restart|failed|failure|error|0x[0-9a-f]{8}|success|initiating|completed|state\s*=|superseded'
        }
    )

    if ($important.Count -gt 0) {
        return @($important | Select-Object -Last 100)
    }

    return @($lines | Select-Object -Last 60)
}

function Set-LogText {
    param(
        [System.Windows.Forms.RichTextBox]$Box,
        [string[]]$Lines
    )

    $Box.SuspendLayout()
    try {
        $Box.Clear()

        foreach ($line in $Lines) {
            $start = $Box.TextLength
            $Box.AppendText($line + [Environment]::NewLine)

            if ($line -match '(?i)error|failed|failure|0x8[0-9a-f]{7}') {
                $Box.Select($start, $line.Length)
                $Box.SelectionColor = [System.Drawing.Color]::Firebrick
            }
            elseif ($line -match '(?i)install complete|success|successfully|completed') {
                $Box.Select($start, $line.Length)
                $Box.SelectionColor = [System.Drawing.Color]::DarkGreen
            }
            elseif ($line -match '(?i)installing|initiating|download|percent') {
                $Box.Select($start, $line.Length)
                $Box.SelectionColor = [System.Drawing.Color]::DarkBlue
            }
        }

        $Box.Select($Box.TextLength, 0)
        $Box.ScrollToCaret()
    }
    finally {
        $Box.ResumeLayout()
    }
}


function Invoke-InstallSoftwareUpdates {
    param(
        [object[]]$Updates
    )

    if (-not $Updates -or $Updates.Count -eq 0) {
        throw 'No software updates were selected.'
    }

    # Microsoft ConfigMgr Client SDK:
    # root\ccm\ClientSDK:CCM_SoftwareUpdatesManager.InstallUpdates(CCM_SoftwareUpdate[])
    if ($script:CimSession) {
        $manager = Get-CimClass -CimSession $script:CimSession `
            -Namespace 'root\ccm\ClientSDK' `
            -ClassName 'CCM_SoftwareUpdatesManager' `
            -ErrorAction Stop

        $result = Invoke-CimMethod `
            -CimSession $script:CimSession `
            -CimClass $manager `
            -MethodName 'InstallUpdates' `
            -Arguments @{ CCMUpdates = [ciminstance[]]$Updates } `
            -ErrorAction Stop
    }
    else {
        $manager = Get-CimClass `
            -Namespace 'root\ccm\ClientSDK' `
            -ClassName 'CCM_SoftwareUpdatesManager' `
            -ErrorAction Stop

        $result = Invoke-CimMethod `
            -CimClass $manager `
            -MethodName 'InstallUpdates' `
            -Arguments @{ CCMUpdates = [ciminstance[]]$Updates } `
            -ErrorAction Stop
    }

    return $result
}

function Get-SelectedUpdateObjects {
    param([object[]]$AllUpdates)

    $selected = @()
    foreach ($row in $grid.SelectedRows) {
        $updateId = [string]$row.Tag
        if (-not [string]::IsNullOrWhiteSpace($updateId)) {
            $obj = $AllUpdates | Where-Object { [string]$_.UpdateID -eq $updateId } | Select-Object -First 1
            if ($obj) { $selected += $obj }
        }
    }
    return @($selected)
}

function Get-InstallableUpdates {
    param([object[]]$AllUpdates)

    # Only updates currently exposed by CCM_SoftwareUpdate and not already
    # installing/completed/error/reboot states.
    return @(
        $AllUpdates | Where-Object {
            [int]$_.EvaluationState -notin 7,8,9,10,11,12,13
        }
    )
}


function Get-RemoteRegistryValue {
    param(
        [string]$SubKey,
        [string]$ValueName,
        [ValidateSet('DWORD','String')][string]$Type = 'String'
    )

    # HKLM = 2147483650
    $hklm = [uint32]2147483650

    try {
        if ($script:CimSession) {
            $regClass = Get-CimClass -CimSession $script:CimSession `
                -Namespace 'root\default' -ClassName 'StdRegProv' -ErrorAction Stop
            $args = @{ hDefKey = $hklm; sSubKeyName = $SubKey; sValueName = $ValueName }

            if ($Type -eq 'DWORD') {
                $r = Invoke-CimMethod -CimSession $script:CimSession -CimClass $regClass `
                    -MethodName 'GetDWORDValue' -Arguments $args -ErrorAction Stop
                if ($r.ReturnValue -eq 0) { return $r.uValue }
            }
            else {
                $r = Invoke-CimMethod -CimSession $script:CimSession -CimClass $regClass `
                    -MethodName 'GetStringValue' -Arguments $args -ErrorAction Stop
                if ($r.ReturnValue -eq 0) { return $r.sValue }
            }
        }
        else {
            $regClass = Get-CimClass -Namespace 'root\default' -ClassName 'StdRegProv' -ErrorAction Stop
            $args = @{ hDefKey = $hklm; sSubKeyName = $SubKey; sValueName = $ValueName }

            if ($Type -eq 'DWORD') {
                $r = Invoke-CimMethod -CimClass $regClass -MethodName 'GetDWORDValue' `
                    -Arguments $args -ErrorAction Stop
                if ($r.ReturnValue -eq 0) { return $r.uValue }
            }
            else {
                $r = Invoke-CimMethod -CimClass $regClass -MethodName 'GetStringValue' `
                    -Arguments $args -ErrorAction Stop
                if ($r.ReturnValue -eq 0) { return $r.sValue }
            }
        }
    }
    catch {}

    return $null
}

function Get-DOModeInfo {
    param([object]$Mode)

    if ($null -eq $Mode) {
        return [pscustomobject]@{ Value = $null; Name = 'Not configured / unreadable' }
    }

    switch ([int]$Mode) {
        0   { $name = 'HTTP only (no peer-to-peer)' }
        1   { $name = 'LAN' }
        2   { $name = 'Group' }
        3   { $name = 'Internet' }
        99  { $name = 'Simple / offline' }
        100 { $name = 'Bypass (deprecated on Windows 11)' }
        default { $name = 'Unknown' }
    }

    return [pscustomobject]@{ Value = [int]$Mode; Name = $name }
}

function Get-RemoteTcpListener {
    param([int]$Port)

    try {
        if ($script:CimSession) {
            $items = @(Get-CimInstance -CimSession $script:CimSession `
                -Namespace 'root\StandardCimv2' `
                -ClassName 'MSFT_NetTCPConnection' `
                -Filter "LocalPort=$Port AND State=2" `
                -ErrorAction Stop)
        }
        else {
            $items = @(Get-CimInstance `
                -Namespace 'root\StandardCimv2' `
                -ClassName 'MSFT_NetTCPConnection' `
                -Filter "LocalPort=$Port AND State=2" `
                -ErrorAction Stop)
        }
        return ($items.Count -gt 0)
    }
    catch {
        return $null
    }
}

function Get-DODeepMetrics {
    # Local target: run DO cmdlets directly.
    if ($script:ConnectedComputer -eq $env:COMPUTERNAME) {
        try {
            return [pscustomobject]@{
                Available = $true
                Method = 'Local PowerShell'
                Status = @(Get-DeliveryOptimizationStatus -ErrorAction Stop)
                Perf = Get-DeliveryOptimizationPerfSnap -ErrorAction Stop
                Error = $null
            }
        }
        catch {
            return [pscustomobject]@{
                Available = $false
                Method = 'Local PowerShell'
                Status = @()
                Perf = $null
                Error = $_.Exception.Message
            }
        }
    }

    # Remote target: try WinRM only for deep DO metrics. Core monitoring remains DCOM-based.
    try {
        $remote = Invoke-Command -ComputerName $script:ConnectedComputer -ErrorAction Stop -ScriptBlock {
            $status = @(Get-DeliveryOptimizationStatus -ErrorAction Stop)
            $perf = Get-DeliveryOptimizationPerfSnap -ErrorAction Stop

            [pscustomobject]@{
                Status = $status
                Perf = $perf
            }
        }

        return [pscustomobject]@{
            Available = $true
            Method = 'PowerShell Remoting'
            Status = @($remote.Status)
            Perf = $remote.Perf
            Error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Available = $false
            Method = 'PowerShell Remoting unavailable'
            Status = @()
            Perf = $null
            Error = $_.Exception.Message
        }
    }
}

function Update-DOStallTracking {
    param([object[]]$Updates)

    $now = Get-Date
    $activeIds = @()

    foreach ($u in @($Updates | Where-Object { [int]$_.EvaluationState -eq 5 })) {
        $id = [string]$u.UpdateID
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $activeIds += $id
        $pct = [int]$u.PercentComplete

        if (-not $script:DOProgressHistory.ContainsKey($id)) {
            $script:DOProgressHistory[$id] = [pscustomobject]@{
                LastPercent = $pct
                LastChange = $now
                FirstSeen = $now
            }
        }
        else {
            $state = $script:DOProgressHistory[$id]
            if ($pct -ne [int]$state.LastPercent) {
                $state.LastPercent = $pct
                $state.LastChange = $now
            }
        }
    }

    foreach ($id in @($script:DOProgressHistory.Keys)) {
        if ($activeIds -notcontains $id) {
            $script:DOProgressHistory.Remove($id)
        }
    }
}

function Get-DOStallState {
    param([object[]]$Updates)

    $downloading = @($Updates | Where-Object { [int]$_.EvaluationState -eq 5 })
    if ($downloading.Count -eq 0) {
        return [pscustomobject]@{
            IsStalled = $false
            Text = 'Idle'
            Detail = 'No update is currently in Downloading state.'
        }
    }

    $now = Get-Date
    $stalled = @()

    foreach ($u in $downloading) {
        $id = [string]$u.UpdateID
        if (-not $script:DOProgressHistory.ContainsKey($id)) { continue }

        $state = $script:DOProgressHistory[$id]
        $age = $now - $state.LastChange

        if ([int]$u.PercentComplete -eq 0 -and $age.TotalMinutes -ge $script:DOStallMinutes) {
            $stalled += $u
        }
    }

    if ($stalled.Count -gt 0) {
        return [pscustomobject]@{
            IsStalled = $true
            Text = "STALLED 0% ($($stalled.Count))"
            Detail = "$($stalled.Count) update(s) remained at 0% for at least $($script:DOStallMinutes) minute(s)."
        }
    }

    $pcts = $downloading | ForEach-Object { [int]$_.PercentComplete }
    return [pscustomobject]@{
        IsStalled = $false
        Text = "Downloading ($($downloading.Count))"
        Detail = "Active download state. Progress values: $($pcts -join ', ')%"
    }
}

function Get-DODiagnosticSnapshot {
    if (-not $script:ConnectedComputer) {
        throw 'Connect to a computer first.'
    }

    $policyPath = 'SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    $mode = Get-RemoteRegistryValue -SubKey $policyPath -ValueName 'DODownloadMode' -Type DWORD
    $groupId = Get-RemoteRegistryValue -SubKey $policyPath -ValueName 'DOGroupId' -Type String
    if ([string]::IsNullOrWhiteSpace([string]$groupId)) {
        $groupId = Get-RemoteRegistryValue -SubKey $policyPath -ValueName 'DOGroupID' -Type String
    }
    $cacheHost = Get-RemoteRegistryValue -SubKey $policyPath -ValueName 'DOCacheHost' -Type String
    $modeInfo = Get-DOModeInfo $mode

    $services = Get-ClientServices
    $doSvc = $services | Where-Object Name -eq 'DoSvc' | Select-Object -First 1

    $port7680 = Get-RemoteTcpListener -Port 7680
    $port8005 = Get-RemoteTcpListener -Port 8005
    $stall = Get-DOStallState -Updates $script:CurrentUpdates

    $deep = Get-DODeepMetrics

    [pscustomobject]@{
        Computer = $script:ConnectedComputer
        Time = Get-Date
        DODownloadMode = $modeInfo.Value
        DODownloadModeName = $modeInfo.Name
        DOGroupId = if ($groupId) { $groupId } else { 'Not configured' }
        DOCacheHost = if ($cacheHost) { $cacheHost } else { 'Not configured' }
        DoSvc = if ($doSvc) { $doSvc.State } else { 'Not found' }
        Port7680Listening = $port7680
        Port8005Listening = $port8005
        Stall = $stall
        Deep = $deep
    }
}

function Format-NullableBool {
    param([object]$Value)
    if ($null -eq $Value) { return 'Unknown / not queryable' }
    if ([bool]$Value) { return 'Yes' }
    return 'No'
}

function Convert-DODeepMetricsToText {
    param([object]$Deep)

    $lines = New-Object System.Collections.Generic.List[string]

    if (-not $Deep.Available) {
        $lines.Add("Deep metrics: unavailable ($($Deep.Method))")
        $lines.Add("Reason: $($Deep.Error)")
        $lines.Add("Note: core monitoring and policy diagnostics still use DCOM and do not depend on WinRM.")
        return $lines.ToArray()
    }

    $lines.Add("Deep metrics method: $($Deep.Method)")
    $lines.Add("")

    $statusItems = @($Deep.Status)
    if ($statusItems.Count -eq 0) {
        $lines.Add('Get-DeliveryOptimizationStatus: no current DO jobs returned.')
    }
    else {
        $lines.Add("Current DO jobs: $($statusItems.Count)")
        foreach ($s in $statusItems) {
            $fileId = if ($s.FileId) { $s.FileId } else { '<no FileId>' }
            $lines.Add("  FileId: $fileId")
            foreach ($p in @(
                'Status','Priority','TotalSize','BytesFromHttp','BytesFromPeers',
                'BytesFromLanPeers','BytesFromInternetPeers','BytesFromCacheServer',
                'DownloadMode','NumPeers','PercentPeerCaching','ErrorCode'
            )) {
                if ($s.PSObject.Properties.Name -contains $p) {
                    $lines.Add(("    {0}: {1}" -f $p, $s.$p))
                }
            }
        }
    }

    if ($Deep.Perf) {
        $lines.Add("")
        $lines.Add('Delivery Optimization performance snapshot:')
        foreach ($p in $Deep.Perf.PSObject.Properties) {
            if ($p.Name -match 'Peer|Http|Cache|Byte|Download|Upload|Bandwidth|File') {
                $lines.Add(("  {0}: {1}" -f $p.Name, $p.Value))
            }
        }
    }

    return $lines.ToArray()
}

function Save-DODiagnosticBundle {
    param([object]$Snapshot)

    $base = Join-Path $PSScriptRoot 'DO-Diagnostics'
    if (-not (Test-Path $base)) {
        New-Item -ItemType Directory -Path $base -Force | Out-Null
    }

    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $folder = Join-Path $base ("{0}_{1}" -f $script:ConnectedComputer, $stamp)
    New-Item -ItemType Directory -Path $folder -Force | Out-Null

    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add("Computer: $($Snapshot.Computer)")
    $summary.Add("Time: $($Snapshot.Time)")
    $summary.Add("DODownloadMode: $($Snapshot.DODownloadMode) ($($Snapshot.DODownloadModeName))")
    $summary.Add("DOGroupId: $($Snapshot.DOGroupId)")
    $summary.Add("DOCacheHost: $($Snapshot.DOCacheHost)")
    $summary.Add("DoSvc: $($Snapshot.DoSvc)")
    $summary.Add("TCP 7680 listening: $(Format-NullableBool $Snapshot.Port7680Listening)")
    $summary.Add("TCP 8005 listening: $(Format-NullableBool $Snapshot.Port8005Listening)")
    $summary.Add("Stall state: $($Snapshot.Stall.Text)")
    $summary.Add("Stall detail: $($Snapshot.Stall.Detail)")
    $summary.Add("")
    $summary.AddRange([string[]](Convert-DODeepMetricsToText -Deep $Snapshot.Deep))
    $summary | Set-Content -LiteralPath (Join-Path $folder 'DO-Summary.txt') -Encoding UTF8

    # Save current Client SDK update state.
    $script:CurrentUpdates |
        Select-Object ArticleID,Name,UpdateID,EvaluationState,PercentComplete,ComplianceState,
            @{N='ErrorCodeHex';E={ Convert-ErrorCode $_.ErrorCode }} |
        Export-Csv -LiteralPath (Join-Path $folder 'SoftwareUpdates.csv') -NoTypeInformation -Encoding UTF8

    $logRoot = Get-LogRoot
    foreach ($name in @(
        'UpdateDOGpo.log','DeltaDownload.log','WUAHandler.log','UpdatesHandler.log',
        'UpdatesDeployment.log','CAS.log','ContentTransferManager.log','DataTransferService.log'
    )) {
        $srcLog = Join-Path $logRoot $name
        if (Test-Path -LiteralPath $srcLog) {
            try {
                Get-Content -LiteralPath $srcLog -Tail 2000 -ErrorAction Stop |
                    Set-Content -LiteralPath (Join-Path $folder $name) -Encoding UTF8
            }
            catch {}
        }
    }

    return $folder
}

function Invoke-ClientSchedule {
    param([string]$ScheduleId)

    if ($script:CimSession) {
        $client = Get-CimClass -CimSession $script:CimSession `
            -Namespace 'root\ccm' -ClassName 'SMS_Client' -ErrorAction Stop
        return Invoke-CimMethod -CimSession $script:CimSession -CimClass $client `
            -MethodName 'TriggerSchedule' -Arguments @{ sScheduleID = $ScheduleId } -ErrorAction Stop
    }

    $client = Get-CimClass -Namespace 'root\ccm' -ClassName 'SMS_Client' -ErrorAction Stop
    return Invoke-CimMethod -CimClass $client -MethodName 'TriggerSchedule' `
        -Arguments @{ sScheduleID = $ScheduleId } -ErrorAction Stop
}

function Restart-RemoteServiceByCim {
    param([string]$ServiceName)

    if ($script:CimSession) {
        $svc = Get-CimInstance -CimSession $script:CimSession -ClassName Win32_Service `
            -Filter "Name='$ServiceName'" -ErrorAction Stop
        if (-not $svc) { throw "Service $ServiceName not found." }

        if ($svc.State -eq 'Running') {
            Invoke-CimMethod -CimSession $script:CimSession -InputObject $svc `
                -MethodName StopService -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 2
        }

        $svc = Get-CimInstance -CimSession $script:CimSession -ClassName Win32_Service `
            -Filter "Name='$ServiceName'" -ErrorAction Stop
        Invoke-CimMethod -CimSession $script:CimSession -InputObject $svc `
            -MethodName StartService -ErrorAction Stop | Out-Null
    }
    else {
        Restart-Service -Name $ServiceName -Force -ErrorAction Stop
    }
}

function Invoke-DOSafeRepair {
    # No DO policy changes. No SoftwareDistribution reset. No CCM client reset.
    # Capture evidence first, then restart DoSvc and trigger supported ConfigMgr cycles.
    $snapshot = Get-DODiagnosticSnapshot
    $folder = Save-DODiagnosticBundle -Snapshot $snapshot

    Restart-RemoteServiceByCim -ServiceName 'DoSvc'

    # Software Updates Assignments Evaluation Cycle
    [void](Invoke-ClientSchedule -ScheduleId '{00000000-0000-0000-0000-000000000108}')

    # Scan by Update Source
    [void](Invoke-ClientSchedule -ScheduleId '{00000000-0000-0000-0000-000000000113}')

    return $folder
}

function Invoke-DOCacheClear {
    if ($script:ConnectedComputer -eq $env:COMPUTERNAME) {
        Delete-DeliveryOptimizationCache -Force -IncludePinnedFiles -ErrorAction Stop
        return
    }

    Invoke-Command -ComputerName $script:ConnectedComputer -ErrorAction Stop -ScriptBlock {
        Delete-DeliveryOptimizationCache -Force -IncludePinnedFiles -ErrorAction Stop
    } | Out-Null
}

function Show-DODiagnostics {
    $snapshot = Get-DODiagnosticSnapshot

    $diag = New-Object System.Windows.Forms.Form
    $diag.Text = "Delivery Optimization Diagnostics - $($snapshot.Computer)"
    $diag.StartPosition = 'CenterParent'
    $diag.Size = New-Object System.Drawing.Size(900, 700)
    $diag.MinimumSize = New-Object System.Drawing.Size(760, 560)
    $diag.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'
    $top.Height = 126
    $diag.Controls.Add($top)

    $lblMode = New-Object System.Windows.Forms.Label
    $lblMode.Left = 12
    $lblMode.Top = 10
    $lblMode.Width = 430
    $lblMode.Height = 24
    $lblMode.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    if ($null -eq $snapshot.DODownloadMode) {
        $lblMode.Text = 'DO Mode: Not configured / unreadable'
        $lblMode.ForeColor = [System.Drawing.Color]::DarkRed
    }
    else {
        $lblMode.Text = "DO Mode: $($snapshot.DODownloadMode) ($($snapshot.DODownloadModeName))"
        $lblMode.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    $top.Controls.Add($lblMode)

    $lblGroup = New-Object System.Windows.Forms.Label
    $lblGroup.Left = 12
    $lblGroup.Top = 38
    $lblGroup.Width = 700
    $lblGroup.Text = "DOGroupId: $($snapshot.DOGroupId)"
    $top.Controls.Add($lblGroup)

    $lblCache = New-Object System.Windows.Forms.Label
    $lblCache.Left = 12
    $lblCache.Top = 60
    $lblCache.Width = 700
    $lblCache.Text = "DOCacheHost: $($snapshot.DOCacheHost)"
    $top.Controls.Add($lblCache)

    $lblHealth = New-Object System.Windows.Forms.Label
    $lblHealth.Left = 12
    $lblHealth.Top = 84
    $lblHealth.Width = 820
    $lblHealth.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblHealth.Text = "DoSvc: $($snapshot.DoSvc)   |   TCP 7680: $(Format-NullableBool $snapshot.Port7680Listening)   |   SCCM Delta 8005: $(Format-NullableBool $snapshot.Port8005Listening)   |   $($snapshot.Stall.Text)"
    if ($snapshot.Stall.IsStalled) {
        $lblHealth.ForeColor = [System.Drawing.Color]::DarkRed
    }
    else {
        $lblHealth.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    $top.Controls.Add($lblHealth)

    $tabsDiag = New-Object System.Windows.Forms.TabControl
    $tabsDiag.Dock = 'Fill'
    $diag.Controls.Add($tabsDiag)

    $tabSummary = New-Object System.Windows.Forms.TabPage
    $tabSummary.Text = 'Summary'
    $tabsDiag.TabPages.Add($tabSummary)

    $txtSummary = New-Object System.Windows.Forms.RichTextBox
    $txtSummary.Dock = 'Fill'
    $txtSummary.ReadOnly = $true
    $txtSummary.WordWrap = $false
    $txtSummary.Font = New-Object System.Drawing.Font('Consolas', 9)
    $tabSummary.Controls.Add($txtSummary)

    $summaryLines = New-Object System.Collections.Generic.List[string]
    $summaryLines.Add("Computer        : $($snapshot.Computer)")
    $summaryLines.Add("DO Mode         : $($snapshot.DODownloadMode) ($($snapshot.DODownloadModeName))")
    $summaryLines.Add("DOGroupId       : $($snapshot.DOGroupId)")
    $summaryLines.Add("DOCacheHost     : $($snapshot.DOCacheHost)")
    $summaryLines.Add("DoSvc           : $($snapshot.DoSvc)")
    $summaryLines.Add("TCP 7680 listen : $(Format-NullableBool $snapshot.Port7680Listening)")
    $summaryLines.Add("TCP 8005 listen : $(Format-NullableBool $snapshot.Port8005Listening)")
    $summaryLines.Add("Download health : $($snapshot.Stall.Text)")
    $summaryLines.Add("Detail          : $($snapshot.Stall.Detail)")
    $summaryLines.Add("")
    $summaryLines.AddRange([string[]](Convert-DODeepMetricsToText -Deep $snapshot.Deep))
    $txtSummary.Text = ($summaryLines -join [Environment]::NewLine)

    $tabEvidence = New-Object System.Windows.Forms.TabPage
    $tabEvidence.Text = 'Evidence'
    $tabsDiag.TabPages.Add($tabEvidence)

    $txtEvidence = New-Object System.Windows.Forms.RichTextBox
    $txtEvidence.Dock = 'Fill'
    $txtEvidence.ReadOnly = $true
    $txtEvidence.WordWrap = $false
    $txtEvidence.Font = New-Object System.Drawing.Font('Consolas', 9)
    $tabEvidence.Controls.Add($txtEvidence)

    $evidence = New-Object System.Collections.Generic.List[string]
    $logRoot = Get-LogRoot
    foreach ($logName in @('UpdateDOGpo.log','DeltaDownload.log','WUAHandler.log','ContentTransferManager.log','CAS.log')) {
        $evidence.Add("===== $logName =====")
        try {
            $lines = Get-InterestingLogLines -Path (Join-Path $logRoot $logName) -Tail 250
            foreach ($line in ($lines | Select-Object -Last 35)) { $evidence.Add($line) }
        }
        catch {
            $evidence.Add("Unable to read: $($_.Exception.Message)")
        }
        $evidence.Add("")
    }
    $txtEvidence.Text = ($evidence -join [Environment]::NewLine)

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 52
    $diag.Controls.Add($bottom)

    $btnSaveDiag = New-Object System.Windows.Forms.Button
    $btnSaveDiag.Text = 'Save Diagnostic Bundle'
    $btnSaveDiag.Left = 12
    $btnSaveDiag.Top = 10
    $btnSaveDiag.Width = 155
    $bottom.Controls.Add($btnSaveDiag)

    $btnSafeRepair = New-Object System.Windows.Forms.Button
    $btnSafeRepair.Text = 'Safe DO Repair'
    $btnSafeRepair.Left = 178
    $btnSafeRepair.Top = 10
    $btnSafeRepair.Width = 125
    $bottom.Controls.Add($btnSafeRepair)

    $btnClearCache = New-Object System.Windows.Forms.Button
    $btnClearCache.Text = 'Clear DO Cache'
    $btnClearCache.Left = 314
    $btnClearCache.Top = 10
    $btnClearCache.Width = 125
    $bottom.Controls.Add($btnClearCache)

    $btnCloseDiag = New-Object System.Windows.Forms.Button
    $btnCloseDiag.Text = 'Close'
    $btnCloseDiag.Left = 450
    $btnCloseDiag.Top = 10
    $btnCloseDiag.Width = 90
    $bottom.Controls.Add($btnCloseDiag)

    $btnSaveDiag.Add_Click({
        try {
            $folder = Save-DODiagnosticBundle -Snapshot $snapshot
            [System.Windows.Forms.MessageBox]::Show(
                "Diagnostic bundle saved to:`r`n$folder",
                'DO Diagnostics',
                'OK',
                'Information'
            ) | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'DO Diagnostics','OK','Error') | Out-Null
        }
    })

    $btnSafeRepair.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "This action will:`r`n`r`n1. Save a diagnostic bundle FIRST`r`n2. Restart DoSvc`r`n3. Trigger SCCM Software Updates Assignments Evaluation`r`n4. Trigger Scan by Update Source`r`n`r`nIt will NOT change DODownloadMode, reset SoftwareDistribution, or reset the SCCM client.`r`n`r`nContinue?",
            'Confirm Safe DO Repair',
            'YesNo',
            'Warning'
        )

        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try {
            $folder = Invoke-DOSafeRepair
            [System.Windows.Forms.MessageBox]::Show(
                "Safe repair completed.`r`nEvidence saved to:`r`n$folder`r`n`r`nThe main monitor will continue tracking progress.",
                'Safe DO Repair',
                'OK',
                'Information'
            ) | Out-Null
            Refresh-Monitor
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Safe DO Repair','OK','Error') | Out-Null
        }
    })

    $btnClearCache.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Clear the Delivery Optimization cache on $($script:ConnectedComputer)?`r`n`r`nThis uses the Microsoft Delete-DeliveryOptimizationCache cmdlet.`r`nA diagnostic bundle will be saved first.`r`n`r`nRemote use requires PowerShell Remoting (WinRM).",
            'Confirm Clear DO Cache',
            'YesNo',
            'Warning'
        )

        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try {
            $before = Get-DODiagnosticSnapshot
            $folder = Save-DODiagnosticBundle -Snapshot $before
            Invoke-DOCacheClear

            [System.Windows.Forms.MessageBox]::Show(
                "DO cache cleared.`r`nPre-change evidence saved to:`r`n$folder",
                'Clear DO Cache',
                'OK',
                'Information'
            ) | Out-Null
            Refresh-Monitor
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "DO cache clear failed.`r`n`r`n$($_.Exception.Message)`r`n`r`nNo DO policy was changed.",
                'Clear DO Cache',
                'OK',
                'Error'
            ) | Out-Null
        }
    })

    $btnCloseDiag.Add_Click({ $diag.Close() })

    [void]$diag.ShowDialog($form)
}

# -----------------------------
# Form
# -----------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'SCCM Software Update Live Monitor v1.3'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1420, 900)
$form.MinimumSize = New-Object System.Drawing.Size(1180, 720)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(245,247,250)

# Top toolbar
$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = 'Top'
$topPanel.Height = 74
$topPanel.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($topPanel)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'SCCM Software Update Live Monitor v1.3'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$title.Left = 16
$title.Top = 9
$title.Width = 390
$title.Height = 29
$topPanel.Controls.Add($title)

$lblComputer = New-Object System.Windows.Forms.Label
$lblComputer.Text = 'Computer'
$lblComputer.Left = 420
$lblComputer.Top = 13
$lblComputer.Width = 70
$topPanel.Controls.Add($lblComputer)

$txtComputer = New-Object System.Windows.Forms.TextBox
$txtComputer.Left = 490
$txtComputer.Top = 9
$txtComputer.Width = 190
$txtComputer.Text = $env:COMPUTERNAME
$topPanel.Controls.Add($txtComputer)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = 'Connect'
$btnConnect.Left = 690
$btnConnect.Top = 8
$btnConnect.Width = 90
$btnConnect.Height = 28
$topPanel.Controls.Add($btnConnect)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh Now'
$btnRefresh.Left = 788
$btnRefresh.Top = 8
$btnRefresh.Width = 100
$btnRefresh.Height = 28
$btnRefresh.Enabled = $false
$topPanel.Controls.Add($btnRefresh)

$btnInstallSelected = New-Object System.Windows.Forms.Button
$btnInstallSelected.Text = 'Install Selected'
$btnInstallSelected.Left = 1138
$btnInstallSelected.Top = 8
$btnInstallSelected.Width = 120
$btnInstallSelected.Height = 28
$btnInstallSelected.Enabled = $false
$topPanel.Controls.Add($btnInstallSelected)

$btnInstallAll = New-Object System.Windows.Forms.Button
$btnInstallAll.Text = 'Install All'
$btnInstallAll.Left = 1264
$btnInstallAll.Top = 8
$btnInstallAll.Width = 95
$btnInstallAll.Height = 28
$btnInstallAll.Enabled = $false
$topPanel.Controls.Add($btnInstallAll)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = 'Auto refresh'
$chkAuto.Left = 902
$chkAuto.Top = 13
$chkAuto.Width = 100
$chkAuto.Checked = $true
$topPanel.Controls.Add($chkAuto)

$lblInterval = New-Object System.Windows.Forms.Label
$lblInterval.Text = 'every'
$lblInterval.Left = 1005
$lblInterval.Top = 13
$lblInterval.Width = 35
$topPanel.Controls.Add($lblInterval)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Left = 1042
$numInterval.Top = 9
$numInterval.Width = 54
$numInterval.Minimum = 2
$numInterval.Maximum = 60
$numInterval.Value = 5
$topPanel.Controls.Add($numInterval)

$lblSeconds = New-Object System.Windows.Forms.Label
$lblSeconds.Text = 'sec'
$lblSeconds.Left = 1099
$lblSeconds.Top = 13
$lblSeconds.Width = 30
$topPanel.Controls.Add($lblSeconds)

$connection = New-Object System.Windows.Forms.Label
$connection.Text = 'Not connected'
$connection.Left = 16
$connection.Top = 45
$connection.Width = 550
$connection.ForeColor = [System.Drawing.Color]::DarkRed
$topPanel.Controls.Add($connection)

$lastRefresh = New-Object System.Windows.Forms.Label
$lastRefresh.Text = 'Last refresh: -'
$lastRefresh.Left = 590
$lastRefresh.Top = 45
$lastRefresh.Width = 310
$lastRefresh.ForeColor = [System.Drawing.Color]::DimGray
$topPanel.Controls.Add($lastRefresh)

# Main
$main = New-Object System.Windows.Forms.Panel
$main.Dock = 'Fill'
$main.Padding = New-Object System.Windows.Forms.Padding(12)
$form.Controls.Add($main)

# Explicit row layout prevents the SplitContainer from rendering underneath
# the summary/service panels (the v1.1 blank-grid bug).
$contentLayout = New-Object System.Windows.Forms.TableLayoutPanel
$contentLayout.Dock = 'Fill'
$contentLayout.ColumnCount = 1
$contentLayout.RowCount = 3
$contentLayout.Margin = New-Object System.Windows.Forms.Padding(0)
$contentLayout.Padding = New-Object System.Windows.Forms.Padding(0)
[void]$contentLayout.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))
)
[void]$contentLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 78))
)
[void]$contentLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38))
)
[void]$contentLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))
)
$main.Controls.Add($contentLayout)

# Summary
$summaryPanel = New-Object System.Windows.Forms.Panel
$summaryPanel.Dock = 'Fill'
$summaryPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$contentLayout.Controls.Add($summaryPanel, 0, 0)

$cards = @{}
$x = 0
foreach ($item in @(
    @('Downloading',145),
    @('Waiting',145),
    @('Installing',145),
    @('Reboot',145),
    @('Complete',145),
    @('Error',145),
    @('Total',145)
)) {
    $card = New-StatusLabel -Text $item[0] -Left $x -Top 8 -Width $item[1]
    $summaryPanel.Controls.Add($card.Panel)
    $cards[$item[0]] = $card.Value
    $x += 155
}

# Services status
$servicePanel = New-Object System.Windows.Forms.Panel
$servicePanel.Dock = 'Fill'
$servicePanel.Margin = New-Object System.Windows.Forms.Padding(0)
$contentLayout.Controls.Add($servicePanel, 0, 1)

$lblServices = New-Object System.Windows.Forms.Label
$lblServices.Text = 'Services:'
$lblServices.Left = 0
$lblServices.Top = 10
$lblServices.Width = 65
$lblServices.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$servicePanel.Controls.Add($lblServices)

$serviceLabels = @{}
$sx = 70
foreach ($svc in @('CcmExec','DoSvc','wuauserv','BITS')) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = "${svc}: -"
    $l.Left = $sx
    $l.Top = 10
    $l.Width = 150
    $servicePanel.Controls.Add($l)
    $serviceLabels[$svc] = $l
    $sx += 160
}

$lblDOMode = New-Object System.Windows.Forms.Label
$lblDOMode.Text = 'DO Mode: -'
$lblDOMode.Left = $sx
$lblDOMode.Top = 10
$lblDOMode.Width = 160
$servicePanel.Controls.Add($lblDOMode)
$sx += 165

$lblDOHealth = New-Object System.Windows.Forms.Label
$lblDOHealth.Text = 'DO: -'
$lblDOHealth.Left = $sx
$lblDOHealth.Top = 10
$lblDOHealth.Width = 200
$servicePanel.Controls.Add($lblDOHealth)
$sx += 205

$btnDODiagnostics = New-Object System.Windows.Forms.Button
$btnDODiagnostics.Text = 'DO Diagnostics'
$btnDODiagnostics.Left = $sx
$btnDODiagnostics.Top = 5
$btnDODiagnostics.Width = 115
$btnDODiagnostics.Height = 27
$btnDODiagnostics.Enabled = $false
$servicePanel.Controls.Add($btnDODiagnostics)

# Split container
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Margin = New-Object System.Windows.Forms.Padding(0)
$split.Orientation = 'Horizontal'
$split.SplitterDistance = 390
$split.Panel1MinSize = 220
$split.Panel2MinSize = 190
$contentLayout.Controls.Add($split, 0, 2)

# Grid
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToOrderColumns = $true
$grid.ReadOnly = $true
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $true
$grid.AutoSizeColumnsMode = 'Fill'
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.BorderStyle = 'FixedSingle'
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$grid.ColumnHeadersHeight = 30
$grid.RowTemplate.Height = 28
$grid.AutoGenerateColumns = $false
$grid.Visible = $true
$split.Panel1.Controls.Add($grid)

[void]$grid.Columns.Add('KB','KB')
[void]$grid.Columns.Add('Name','Update')
[void]$grid.Columns.Add('State','State')
[void]$grid.Columns.Add('Percent','Progress %')
[void]$grid.Columns.Add('Compliance','Compliance')
[void]$grid.Columns.Add('Error','Error Code')

$grid.Columns['KB'].FillWeight = 60
$grid.Columns['Name'].FillWeight = 260
$grid.Columns['State'].FillWeight = 100
$grid.Columns['Percent'].FillWeight = 65
$grid.Columns['Compliance'].FillWeight = 100
$grid.Columns['Error'].FillWeight = 85

# Tabs / logs
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$split.Panel2.Controls.Add($tabs)

$logBoxes = @{}
foreach ($logName in @('UpdatesHandler.log','UpdatesDeployment.log','WUAHandler.log')) {
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = $logName

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Dock = 'Fill'
    $rtb.ReadOnly = $true
    $rtb.WordWrap = $false
    $rtb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $rtb.BackColor = [System.Drawing.Color]::White

    $tab.Controls.Add($rtb)
    $tabs.TabPages.Add($tab)
    $logBoxes[$logName] = $rtb
}

# Footer
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Ready'
[void]$statusStrip.Items.Add($statusLabel)
$form.Controls.Add($statusStrip)

function Update-GridAndSummary {
    param([object[]]$Updates)

    $grid.Rows.Clear()

    $counts = @{
        Downloading = 0
        Waiting = 0
        Installing = 0
        Reboot = 0
        Complete = 0
        Error = 0
        Total = $Updates.Count
    }

    foreach ($u in ($Updates | Sort-Object EvaluationState, ArticleID)) {
        $state = [int]$u.EvaluationState
        $category = Get-StateCategory $state
        if ($counts.ContainsKey($category)) {
            $counts[$category]++
        }

        $kb = if ($u.ArticleID) { "KB$($u.ArticleID)" } else { '' }
        $stateName = Get-StateName $state
        $compliance = Get-ComplianceName ([int]$u.ComplianceState)
        $errorText = Convert-ErrorCode $u.ErrorCode

        $idx = $grid.Rows.Add(
            $kb,
            [string]$u.Name,
            $stateName,
            ('{0}%' -f [int]$u.PercentComplete),
            $compliance,
            $errorText
        )

        $row = $grid.Rows[$idx]
        $row.Tag = [string]$u.UpdateID

        switch ($category) {
            'Installing' {
                $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,244,204)
                $row.DefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            }
            'Downloading' {
                $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(220,238,255)
            }
            'Reboot' {
                $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,232,204)
            }
            'Complete' {
                $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(225,245,225)
            }
            'Error' {
                $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,220,220)
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkRed
            }
        }
    }

    foreach ($key in $cards.Keys) {
        $cards[$key].Text = [string]$counts[$key]
    }

    if ($counts.Installing -gt 0) {
        $cards['Installing'].ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $cards['Installing'].ForeColor = [System.Drawing.Color]::Black
    }

    if ($counts.Error -gt 0) {
        $cards['Error'].ForeColor = [System.Drawing.Color]::DarkRed
    } else {
        $cards['Error'].ForeColor = [System.Drawing.Color]::Black
    }

    if ($counts.Reboot -gt 0) {
        $cards['Reboot'].ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $cards['Reboot'].ForeColor = [System.Drawing.Color]::Black
    }
}

function Update-ServiceDisplay {
    param([object[]]$Services)

    foreach ($name in $serviceLabels.Keys) {
        $svc = $Services | Where-Object Name -eq $name | Select-Object -First 1
        if ($svc) {
            $serviceLabels[$name].Text = "${name}: $($svc.State)"
            if ($svc.State -eq 'Running') {
                $serviceLabels[$name].ForeColor = [System.Drawing.Color]::DarkGreen
            } else {
                $serviceLabels[$name].ForeColor = [System.Drawing.Color]::DarkRed
            }
        }
        else {
            $serviceLabels[$name].Text = "${name}: Not found"
            $serviceLabels[$name].ForeColor = [System.Drawing.Color]::DarkRed
        }
    }
}

function Refresh-Monitor {
    if ($script:Busy -or -not $script:ConnectedComputer) { return }

    $script:Busy = $true
    $btnRefresh.Enabled = $false
    $statusLabel.Text = "Refreshing $($script:ConnectedComputer)..."

    try {
        $updates = Get-ClientUpdates
        $script:CurrentUpdates = @($updates)
        Update-DOStallTracking -Updates $updates
        $services = Get-ClientServices

        try {
            Update-GridAndSummary -Updates $updates
            $grid.Refresh()
        }
        catch {
            throw "Grid update failed: $($_.Exception.Message)"
        }

        Update-ServiceDisplay -Services $services

        $modeRaw = Get-RemoteRegistryValue `
            -SubKey 'SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' `
            -ValueName 'DODownloadMode' -Type DWORD
        $modeInfo = Get-DOModeInfo $modeRaw
        if ($null -eq $modeInfo.Value) {
            $lblDOMode.Text = 'DO Mode: Not set'
            $lblDOMode.ForeColor = [System.Drawing.Color]::DarkRed
        }
        else {
            $lblDOMode.Text = "DO Mode: $($modeInfo.Value) ($($modeInfo.Name))"
            if ([int]$modeInfo.Value -eq 1) {
                $lblDOMode.ForeColor = [System.Drawing.Color]::DarkGreen
            }
            else {
                $lblDOMode.ForeColor = [System.Drawing.Color]::DarkOrange
            }
        }

        $doHealth = Get-DOStallState -Updates $updates
        $lblDOHealth.Text = "DO: $($doHealth.Text)"
        if ($doHealth.IsStalled) {
            $lblDOHealth.ForeColor = [System.Drawing.Color]::DarkRed
        }
        elseif (@($updates | Where-Object { [int]$_.EvaluationState -eq 5 }).Count -gt 0) {
            $lblDOHealth.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        else {
            $lblDOHealth.ForeColor = [System.Drawing.Color]::DimGray
        }

        $btnDODiagnostics.Enabled = $true

        $logRoot = Get-LogRoot
        foreach ($name in $logBoxes.Keys) {
            try {
                $lines = Get-InterestingLogLines -Path (Join-Path $logRoot $name)
                Set-LogText -Box $logBoxes[$name] -Lines $lines
            }
            catch {
                Set-LogText -Box $logBoxes[$name] -Lines @("Unable to read $name", $_.Exception.Message)
            }
        }

        $installing = @($updates | Where-Object { $_.EvaluationState -eq 7 }).Count
        $downloading = @($updates | Where-Object { $_.EvaluationState -eq 5 }).Count
        $reboot = @($updates | Where-Object { $_.EvaluationState -in 8,9,10 }).Count

        if ($installing -gt 0) {
            $statusLabel.Text = "LIVE: $installing update(s) installing"
        }
        elseif ($downloading -gt 0) {
            $statusLabel.Text = "LIVE: $downloading update(s) downloading"
        }
        elseif ($reboot -gt 0) {
            $statusLabel.Text = "LIVE: reboot pending"
        }
        else {
            $statusLabel.Text = 'LIVE: no active install at this instant'
        }

        $installableCount = @(Get-InstallableUpdates -AllUpdates $updates).Count
        $btnInstallSelected.Enabled = ($updates.Count -gt 0)
        $btnInstallAll.Enabled = ($installableCount -gt 0)

        $lastRefresh.Text = 'Last refresh: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    catch {
        $statusLabel.Text = 'Refresh failed: ' + $_.Exception.Message
        $connection.ForeColor = [System.Drawing.Color]::DarkRed
    }
    finally {
        $script:Busy = $false
        $btnRefresh.Enabled = $true
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
    if ($chkAuto.Checked) {
        Refresh-Monitor
    }
})

$numInterval.Add_ValueChanged({
    $timer.Interval = [int]$numInterval.Value * 1000
})

$btnConnect.Add_Click({
    $timer.Stop()
    $btnConnect.Enabled = $false
    $connection.Text = "Connecting to $($txtComputer.Text.Trim())..."
    $connection.ForeColor = [System.Drawing.Color]::DarkOrange
    $form.Refresh()

    try {
        Connect-Target -ComputerName $txtComputer.Text
        $connection.Text = "Connected: $($script:ConnectedComputer)"
        $connection.ForeColor = [System.Drawing.Color]::DarkGreen
        $btnRefresh.Enabled = $true
        Refresh-Monitor
        $timer.Start()
    }
    catch {
        Disconnect-Target
        $connection.Text = 'Connection failed'
        $connection.ForeColor = [System.Drawing.Color]::DarkRed
        $statusLabel.Text = $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show(
            "Unable to connect to $($txtComputer.Text).`r`n`r`n$($_.Exception.Message)`r`n`r`nRemote monitoring requires WMI/RPC access and administrative rights.",
            'Connection Error',
            'OK',
            'Error'
        ) | Out-Null
    }
    finally {
        $btnConnect.Enabled = $true
    }
})

$btnRefresh.Add_Click({
    Refresh-Monitor
})

$chkAuto.Add_CheckedChanged({
    if ($chkAuto.Checked -and $script:ConnectedComputer) {
        $timer.Start()
    }
    else {
        $timer.Stop()
    }
})

$txtComputer.Add_KeyDown({
    if ($_.KeyCode -eq 'Enter') {
        $btnConnect.PerformClick()
        $_.SuppressKeyPress = $true
    }
})

$btnDODiagnostics.Add_Click({
    try {
        Show-DODiagnostics
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'DO Diagnostics',
            'OK',
            'Error'
        ) | Out-Null
    }
})

$btnInstallSelected.Add_Click({
    try {
        if (-not $script:ConnectedComputer) { throw 'Connect to a computer first.' }

        $selected = Get-SelectedUpdateObjects -AllUpdates $script:CurrentUpdates
        if ($selected.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'Select one or more updates in the grid first.',
                'Install Selected',
                'OK',
                'Information'
            ) | Out-Null
            return
        }

        $names = ($selected | ForEach-Object { $_.Name }) -join "`r`n"
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Start installation of the selected update(s) on $($script:ConnectedComputer)?`r`n`r`n$names",
            'Confirm Installation',
            'YesNo',
            'Warning'
        )

        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $btnInstallSelected.Enabled = $false
        $btnInstallAll.Enabled = $false
        $statusLabel.Text = "Submitting $($selected.Count) update(s) for installation..."

        $result = Invoke-InstallSoftwareUpdates -Updates $selected
        $rv = if ($null -ne $result.ReturnValue) { [uint32]$result.ReturnValue } else { 0 }

        if ($rv -ne 0) {
            throw ("InstallUpdates returned 0x{0:X8}" -f $rv)
        }

        $statusLabel.Text = "Install request accepted for $($selected.Count) update(s). Monitoring..."
        Start-Sleep -Milliseconds 700
        Refresh-Monitor
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Install Selected Error',
            'OK',
            'Error'
        ) | Out-Null
        $statusLabel.Text = 'Install request failed: ' + $_.Exception.Message
    }
    finally {
        if ($script:ConnectedComputer) {
            $btnInstallSelected.Enabled = $true
            $btnInstallAll.Enabled = $true
        }
    }
})

$btnInstallAll.Add_Click({
    try {
        if (-not $script:ConnectedComputer) { throw 'Connect to a computer first.' }

        $installable = Get-InstallableUpdates -AllUpdates $script:CurrentUpdates
        if ($installable.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'No currently installable software updates were returned by the ConfigMgr Client SDK.',
                'Install All',
                'OK',
                'Information'
            ) | Out-Null
            return
        }

        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Start installation of ALL $($installable.Count) currently installable update(s) on $($script:ConnectedComputer)?",
            'Confirm Install All',
            'YesNo',
            'Warning'
        )

        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $btnInstallSelected.Enabled = $false
        $btnInstallAll.Enabled = $false
        $statusLabel.Text = "Submitting all $($installable.Count) update(s) for installation..."

        $result = Invoke-InstallSoftwareUpdates -Updates $installable
        $rv = if ($null -ne $result.ReturnValue) { [uint32]$result.ReturnValue } else { 0 }

        if ($rv -ne 0) {
            throw ("InstallUpdates returned 0x{0:X8}" -f $rv)
        }

        $statusLabel.Text = "Install-all request accepted. Monitoring..."
        Start-Sleep -Milliseconds 700
        Refresh-Monitor
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Install All Error',
            'OK',
            'Error'
        ) | Out-Null
        $statusLabel.Text = 'Install-all request failed: ' + $_.Exception.Message
    }
    finally {
        if ($script:ConnectedComputer) {
            $btnInstallSelected.Enabled = $true
            $btnInstallAll.Enabled = $true
        }
    }
})

$form.Add_FormClosing({
    $timer.Stop()
    Disconnect-Target
})

# Connect automatically to local machine on startup only when explicitly launched locally.
$statusLabel.Text = 'v1.3 ready - enter a computer name and click Connect.'
[void]$form.ShowDialog()
