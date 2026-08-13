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

function Get-InterestingLogLines {
    param(
        [string]$Path,
        [int]$Tail = 120
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @("[Log not reachable] $Path")
    }

    $lines = @(Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop)

    # Keep important operational lines while still showing latest activity.
    $important = @(
        $lines | Where-Object {
            $_ -match '(?i)install|download|percent|reboot|failed|failure|error|0x[0-9a-f]{8}|success|initiating|completed|state\s*='
        }
    )

    if ($important.Count -gt 0) {
        return @($important | Select-Object -Last 60)
    }

    return @($lines | Select-Object -Last 40)
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

# -----------------------------
# Form
# -----------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'SCCM Software Update Live Monitor'
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
$title.Text = 'SCCM Software Update Live Monitor'
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

# Summary
$summaryPanel = New-Object System.Windows.Forms.Panel
$summaryPanel.Dock = 'Top'
$summaryPanel.Height = 78
$main.Controls.Add($summaryPanel)

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
$servicePanel.Dock = 'Top'
$servicePanel.Height = 38
$main.Controls.Add($servicePanel)

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

# Split container
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = 'Horizontal'
$split.SplitterDistance = 390
$split.Panel1MinSize = 220
$split.Panel2MinSize = 190
$main.Controls.Add($split)

# Grid
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToOrderColumns = $true
$grid.ReadOnly = $true
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.BorderStyle = 'FixedSingle'
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
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
            [string]$u.PercentComplete,
            $compliance,
            $errorText
        )

        $row = $grid.Rows[$idx]

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
        $services = Get-ClientServices

        Update-GridAndSummary -Updates $updates
        Update-ServiceDisplay -Services $services

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

$form.Add_FormClosing({
    $timer.Stop()
    Disconnect-Target
})

# Connect automatically to local machine on startup only when explicitly launched locally.
$statusLabel.Text = 'Enter a computer name and click Connect.'
[void]$form.ShowDialog()
