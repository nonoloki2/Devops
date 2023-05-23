Add-Type -AssemblyName System.Windows.Forms

# Create the main form
$mainForm = New-Object System.Windows.Forms.Form
$mainForm.Text = "Windows Maintenance"
$mainForm.Width = 300
$mainForm.Height = 200

# Create a button for disk cleanup
$btnDiskCleanup = New-Object System.Windows.Forms.Button
$btnDiskCleanup.Text = "Disk Cleanup"
$btnDiskCleanup.Width = 100
$btnDiskCleanup.Height = 30
$btnDiskCleanup.Location = New-Object System.Drawing.Point(50, 50)
$btnDiskCleanup.Add_Click({
    Start-Process "cleanmgr.exe"
})

# Create a button for disk defragmentation
$btnDefragment = New-Object System.Windows.Forms.Button
$btnDefragment.Text = "Disk Defragmentation"
$btnDefragment.Width = 140
$btnDefragment.Height = 30
$btnDefragment.Location = New-Object System.Drawing.Point(50, 100)
$btnDefragment.Add_Click({
    Start-Process "dfrgui.exe"
})

# Add the buttons to the form
$mainForm.Controls.Add($btnDiskCleanup)
$mainForm.Controls.Add($btnDefragment)

# Show the form
$mainForm.ShowDialog()
