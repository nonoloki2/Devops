# Define the time interval to check (in minutes)
$interval = 60

# Get the current time
$currentTime = Get-Date

# Calculate the start time for the check
$startTime = $currentTime.AddMinutes(-$interval)

# Define the log name for Windows Update events
$logName = "Microsoft-Windows-WindowsUpdateClient/Operational"

# Query the Windows Update event logs for events in the specified interval
$windowsUpdateEvents = Get-WinEvent -LogName $logName | Where-Object {
    $_.TimeCreated -ge $startTime -and ($_.Id -eq 19 -or $_.Id -eq 25)
}

# Check if any events were found
if ($windowsUpdateEvents.Count -gt 0) {
    Write-Host "Windows Update ran in the last $interval minutes."
    $result = $true
} else {
    
    $result = $false
}

# Return the result
Exit $result
