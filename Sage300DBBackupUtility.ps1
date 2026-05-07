#requires -version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data

$AppTitle = 'Sage 300 DB Backup Utility'
$Version = 'v1.1.0'
$Author = 'Joshua Dwight'
$AuthorUrl = 'https://github.com/joshdwight101'
$SettingsPath = Join-Path $PSScriptRoot 'Sage300DBBackupUtility.settings.json'

function Write-UiLog {
    param([System.Windows.Forms.TextBox]$TextBox,[string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $TextBox.AppendText($line + [Environment]::NewLine)
    $TextBox.SelectionStart = $TextBox.Text.Length
    $TextBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-DefaultSettings {
    [ordered]@{
        SqlServer = 'localhost'
        UseIntegratedSecurity = $true
        SqlUser = ''
        SqlPassword = ''
        RuntimePath = 'C:\Sage300\runtime'
        BackupRoot = 'C:\Sage300\dbdump'
        SageAdminUser = 'ADMIN'
        SageAdminPassword = ''
    }
}

function Save-AppSettings {
    param([hashtable]$Settings,[string]$Path)
    ($Settings | ConvertTo-Json -Depth 4) | Set-Content -Path $Path -Encoding UTF8
}

function Load-AppSettings {
    param([string]$Path)
    $defaults = Get-DefaultSettings
    if (-not (Test-Path $Path)) { return $defaults }
    try {
        $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json
        foreach ($key in $defaults.Keys) {
            if ($null -ne $raw.$key) { $defaults[$key] = [string]$raw.$key }
        }
        $defaults.UseIntegratedSecurity = [System.Convert]::ToBoolean($raw.UseIntegratedSecurity)
    }
    catch {}
    return $defaults
}

function Get-SageDatabaseCandidates {
    param([string]$SqlServer,[string]$SqlUser,[string]$SqlPassword,[switch]$UseIntegratedSecurity)
    $connString = if ($UseIntegratedSecurity) {
        "Server=$SqlServer;Database=master;Integrated Security=True;TrustServerCertificate=True"
    } else {
        "Server=$SqlServer;Database=master;User ID=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True"
    }

    $query = @"
SELECT name FROM sys.databases
WHERE state_desc = 'ONLINE'
  AND name NOT IN ('master','model','msdb','tempdb')
  AND (name LIKE '%DAT' OR name LIKE '%SYS')
ORDER BY name;
"@

    $conn = [System.Data.SqlClient.SqlConnection]::new($connString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $reader = $cmd.ExecuteReader()
        $result = @()
        while ($reader.Read()) { $result += [string]$reader['name'] }
        return $result
    } finally {
        $conn.Close()
    }
}

function Invoke-SageDbDumpBackup {
    param(
        [string]$RuntimePath,[string]$BackupRoot,[string[]]$DatabaseNames,
        [string]$SageAdminUser,[string]$SageAdminPassword,
        [System.Windows.Forms.TextBox]$LogBox,[System.Windows.Forms.ProgressBar]$ProgressBar,[System.Windows.Forms.Label]$EtaLabel,
        [scriptblock]$IsCancelled
    )

    $dbDumpPath = Join-Path $RuntimePath 'dbdump32.exe'
    if (-not (Test-Path $dbDumpPath)) { throw "dbdump32.exe not found at $dbDumpPath" }

    $runFolder = Join-Path $BackupRoot (Get-Date -Format 'yyyy-MM-dd')
    New-Item -Path $runFolder -ItemType Directory -Force | Out-Null

    $total = $DatabaseNames.Count
    $durations = New-Object System.Collections.Generic.List[double]
    $i = 0

    foreach ($db in $DatabaseNames) {
        if (& $IsCancelled) {
            Write-UiLog -TextBox $LogBox -Message 'Cancellation requested before next database. Stopping backup run.'
            break
        }
        $i++
        $friendlyTime = Get-Date -Format 'yyyy-MM-dd_hh-mm-ss_tt'
        $dbFolder = Join-Path $runFolder ("{0}_backup_{1}" -f $db, $friendlyTime)
        New-Item -Path $dbFolder -ItemType Directory -Force | Out-Null

        Write-UiLog -TextBox $LogBox -Message "Starting backup for $db"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $args = @("/U$SageAdminUser", "/P$SageAdminPassword", "/L$db", '/Q', "/D$dbFolder")
        $proc = Start-Process -FilePath $dbDumpPath -ArgumentList $args -WorkingDirectory $RuntimePath -PassThru -NoNewWindow
        $script:currentBackupProcess = $proc
        while (-not $proc.HasExited) {
            if (& $IsCancelled) {
                Write-UiLog -TextBox $LogBox -Message "Cancellation requested. Stopping active backup process for $db..."
                try { $proc.Kill() } catch {}
                break
            }
            Start-Sleep -Milliseconds 250
            [System.Windows.Forms.Application]::DoEvents()
        }
        $sw.Stop()
        if (& $IsCancelled) {
            Write-UiLog -TextBox $LogBox -Message 'Backup run cancelled by user.'
            break
        }

        if ($proc.ExitCode -ne 0) {
            Write-UiLog -TextBox $LogBox -Message "Backup FAILED for $db (exit code $($proc.ExitCode))"
            throw "dbdump32.exe failed for $db"
        }

        $durations.Add($sw.Elapsed.TotalSeconds)
        $ProgressBar.Value = [Math]::Min([int][Math]::Round(($i / $total) * 100), 100)
        $avg = ($durations | Measure-Object -Average).Average
        $remaining = [Math]::Max($total - $i, 0)
        $eta = [TimeSpan]::FromSeconds([Math]::Round($avg * $remaining))
        $EtaLabel.Text = "Estimated time remaining: {0:hh\:mm\:ss}" -f $eta
        Write-UiLog -TextBox $LogBox -Message "Completed backup for $db in $([int]$sw.Elapsed.TotalSeconds)s"
    }

    $EtaLabel.Text = 'Estimated time remaining: 00:00:00'
}

$settings = Load-AppSettings -Path $SettingsPath
$saveGuard = $false
$script:isBackupRunning = $false
$script:cancelBackup = $false
$script:currentBackupProcess = $null

$form = [System.Windows.Forms.Form]::new()
$form.Text = "$AppTitle $Version  |  Author: $Author"
$form.Size = [System.Drawing.Size]::new(980, 720)
$form.StartPosition = 'CenterScreen'
$form.Font = [System.Drawing.Font]::new('Segoe UI', 10)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

$menu = [System.Windows.Forms.MenuStrip]::new()
$fileMenu = [System.Windows.Forms.ToolStripMenuItem]::new('File')
$fileExit = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')
$fileMenu.DropDownItems.Add($fileExit) | Out-Null
$helpMenu = [System.Windows.Forms.ToolStripMenuItem]::new('Help')
$aboutMenu = [System.Windows.Forms.ToolStripMenuItem]::new('About')
$helpMenu.DropDownItems.Add($aboutMenu) | Out-Null
$menu.Items.Add($fileMenu) | Out-Null
$menu.Items.Add($helpMenu) | Out-Null
$form.MainMenuStrip = $menu
$form.Controls.Add($menu)

$lblServer = [System.Windows.Forms.Label]::new(); $lblServer.Text='SQL Server:'; $lblServer.Location='20,50'; $lblServer.AutoSize=$true; $form.Controls.Add($lblServer)
$txtServer = [System.Windows.Forms.TextBox]::new(); $txtServer.Location='140,46'; $txtServer.Size='280,28'; $txtServer.Text=$settings.SqlServer; $form.Controls.Add($txtServer)
$chkIntegrated = [System.Windows.Forms.CheckBox]::new(); $chkIntegrated.Text='Use Windows Authentication'; $chkIntegrated.Location='440,48'; $chkIntegrated.Checked=[bool]$settings.UseIntegratedSecurity; $chkIntegrated.AutoSize=$true; $form.Controls.Add($chkIntegrated)

$lblSqlUser = [System.Windows.Forms.Label]::new(); $lblSqlUser.Text='SQL User:'; $lblSqlUser.Location='20,85'; $lblSqlUser.AutoSize=$true; $form.Controls.Add($lblSqlUser)
$txtSqlUser = [System.Windows.Forms.TextBox]::new(); $txtSqlUser.Location='140,80'; $txtSqlUser.Size='200,28'; $txtSqlUser.Text=$settings.SqlUser; $form.Controls.Add($txtSqlUser)
$lblSqlPass = [System.Windows.Forms.Label]::new(); $lblSqlPass.Text='SQL Password:'; $lblSqlPass.Location='360,85'; $lblSqlPass.AutoSize=$true; $form.Controls.Add($lblSqlPass)
$txtSqlPass = [System.Windows.Forms.TextBox]::new(); $txtSqlPass.Location='480,80'; $txtSqlPass.Size='220,28'; $txtSqlPass.Text=$settings.SqlPassword; $txtSqlPass.UseSystemPasswordChar=$true; $form.Controls.Add($txtSqlPass)

$lblRuntime = [System.Windows.Forms.Label]::new(); $lblRuntime.Text='Sage Runtime Path:'; $lblRuntime.Location='20,120'; $lblRuntime.AutoSize=$true; $form.Controls.Add($lblRuntime)
$txtRuntime = [System.Windows.Forms.TextBox]::new(); $txtRuntime.Location='140,116'; $txtRuntime.Size='560,28'; $txtRuntime.Text=$settings.RuntimePath; $form.Controls.Add($txtRuntime)
$btnBrowseRuntime = [System.Windows.Forms.Button]::new(); $btnBrowseRuntime.Text='Browse...'; $btnBrowseRuntime.Location='720,118'; $btnBrowseRuntime.Size='120,36'; $btnBrowseRuntime.BackColor=[System.Drawing.Color]::FromArgb(225,225,225); $form.Controls.Add($btnBrowseRuntime)

$lblBackupRoot = [System.Windows.Forms.Label]::new(); $lblBackupRoot.Text='Backup Root:'; $lblBackupRoot.Location='20,155'; $lblBackupRoot.AutoSize=$true; $form.Controls.Add($lblBackupRoot)
$txtBackupRoot = [System.Windows.Forms.TextBox]::new(); $txtBackupRoot.Location='140,151'; $txtBackupRoot.Size='560,28'; $txtBackupRoot.Text=$settings.BackupRoot; $form.Controls.Add($txtBackupRoot)
$btnBrowseBackup = [System.Windows.Forms.Button]::new(); $btnBrowseBackup.Text='Browse...'; $btnBrowseBackup.Location='720,160'; $btnBrowseBackup.Size='120,36'; $btnBrowseBackup.BackColor=[System.Drawing.Color]::FromArgb(225,225,225); $form.Controls.Add($btnBrowseBackup)

$btnDetect = [System.Windows.Forms.Button]::new(); $btnDetect.Text='Detect Databases'; $btnDetect.Location='720,76'; $btnDetect.Size='120,36'; $btnDetect.BackColor=[System.Drawing.Color]::FromArgb(225,225,225); $form.Controls.Add($btnDetect)
$listDb = [System.Windows.Forms.CheckedListBox]::new(); $listDb.Location='20,205'; $listDb.Size='940,200'; $listDb.CheckOnClick=$true; $form.Controls.Add($listDb)

$lblSageUser = [System.Windows.Forms.Label]::new(); $lblSageUser.Text='Sage Admin User:'; $lblSageUser.Location='20,425'; $lblSageUser.AutoSize=$true; $form.Controls.Add($lblSageUser)
$txtSageUser = [System.Windows.Forms.TextBox]::new(); $txtSageUser.Location='160,420'; $txtSageUser.Size='180,28'; $txtSageUser.Text=$settings.SageAdminUser; $form.Controls.Add($txtSageUser)
$lblSagePass = [System.Windows.Forms.Label]::new(); $lblSagePass.Text='Sage Admin Password:'; $lblSagePass.Location='360,425'; $lblSagePass.AutoSize=$true; $form.Controls.Add($lblSagePass)
$txtSagePass = [System.Windows.Forms.TextBox]::new(); $txtSagePass.Location='530,420'; $txtSagePass.Size='220,28'; $txtSagePass.Text=$settings.SageAdminPassword; $txtSagePass.UseSystemPasswordChar=$true; $form.Controls.Add($txtSagePass)
$btnStart = [System.Windows.Forms.Button]::new(); $btnStart.Text='Start Backup'; $btnStart.Location='760,418'; $btnStart.Size='180,34'; $btnStart.BackColor=[System.Drawing.Color]::FromArgb(198,239,206); $form.Controls.Add($btnStart)

$progress = [System.Windows.Forms.ProgressBar]::new(); $progress.Location='20,465'; $progress.Size='940,24'; $progress.Minimum=0; $progress.Maximum=100; $form.Controls.Add($progress)
$lblEta = [System.Windows.Forms.Label]::new(); $lblEta.Text='Estimated time remaining: --:--:--'; $lblEta.Location='20,495'; $lblEta.AutoSize=$true; $form.Controls.Add($lblEta)
$logBox = [System.Windows.Forms.TextBox]::new(); $logBox.Location='20,525'; $logBox.Size='940,150'; $logBox.Multiline=$true; $logBox.ScrollBars='Vertical'; $logBox.ReadOnly=$true; $logBox.BackColor=[System.Drawing.Color]::FromArgb(30,30,30); $logBox.ForeColor=[System.Drawing.Color]::FromArgb(230,230,230); $form.Controls.Add($logBox)

$saveSettings = {
    if ($saveGuard) { return }
    $current = [ordered]@{
        SqlServer = $txtServer.Text
        UseIntegratedSecurity = $chkIntegrated.Checked
        SqlUser = $txtSqlUser.Text
        SqlPassword = $txtSqlPass.Text
        RuntimePath = $txtRuntime.Text
        BackupRoot = $txtBackupRoot.Text
        SageAdminUser = $txtSageUser.Text
        SageAdminPassword = $txtSagePass.Text
    }
    Save-AppSettings -Settings $current -Path $SettingsPath
}

$chkIntegrated.Add_CheckedChanged({
    $txtSqlUser.Enabled = -not $chkIntegrated.Checked
    $txtSqlPass.Enabled = -not $chkIntegrated.Checked
    & $saveSettings
})
$txtSqlUser.Enabled = -not $chkIntegrated.Checked
$txtSqlPass.Enabled = -not $chkIntegrated.Checked

$autoSaveControls = @($txtServer,$txtSqlUser,$txtSqlPass,$txtRuntime,$txtBackupRoot,$txtSageUser,$txtSagePass)
foreach ($c in $autoSaveControls) { $c.Add_TextChanged({ & $saveSettings }) }

$browseFolder = {
    param($targetTextBox)
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dlg.ShowNewFolderButton = $true
    if (Test-Path $targetTextBox.Text) { $dlg.SelectedPath = $targetTextBox.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $targetTextBox.Text = $dlg.SelectedPath
        & $saveSettings
    }
}
$btnBrowseRuntime.Add_Click({ & $browseFolder $txtRuntime })
$btnBrowseBackup.Add_Click({ & $browseFolder $txtBackupRoot })

$fileExit.Add_Click({ $form.Close() })
$aboutMenu.Add_Click({
    $about = [System.Windows.Forms.Form]::new()
    $about.Text = "About - $AppTitle"
    $about.Size = [System.Drawing.Size]::new(540,270)
    $about.StartPosition = 'CenterParent'
    $about.FormBorderStyle = 'FixedDialog'
    $about.MaximizeBox = $false
    $about.MinimizeBox = $false

    $lblInfo = [System.Windows.Forms.Label]::new()
    $lblInfo.Text = "$AppTitle`r`nVersion: $Version`r`n`r`nPurpose:`r`nDetect Sage 300 databases and run sequential backups using dbdump32.exe.`r`n`r`nUsage:`r`n1) Configure SQL/runtime/backup settings.`r`n2) Click Detect Databases and select targets.`r`n3) Enter Sage admin credentials and click Start Sequential Backup.`r`n`r`nAuthor: $Author"
    $lblInfo.Location = '20,20'
    $lblInfo.Size = [System.Drawing.Size]::new(470,150)
    $about.Controls.Add($lblInfo)

    $lblAuthorLink = [System.Windows.Forms.Label]::new()
    $lblAuthorLink.Text = 'Author GitHub:'
    $lblAuthorLink.Location = '20,176'
    $lblAuthorLink.AutoSize = $true
    $about.Controls.Add($lblAuthorLink)

    $link = [System.Windows.Forms.LinkLabel]::new()
    $link.Text = $AuthorUrl
    $link.Location = '112,176'
    $link.AutoSize = $true
    $link.Add_LinkClicked({ Start-Process $AuthorUrl })
    $about.Controls.Add($link)

    $btnClose = [System.Windows.Forms.Button]::new(); $btnClose.Text='Close'; $btnClose.Location='400,188'; $btnClose.Size='80,30'; $btnClose.Add_Click({ $about.Close() }); $about.Controls.Add($btnClose)
    [void]$about.ShowDialog($form)
})

$btnDetect.Add_Click({
    try {
        $listDb.Items.Clear()
        Write-UiLog -TextBox $logBox -Message 'Detecting Sage candidate databases...'
        $dbs = Get-SageDatabaseCandidates -SqlServer $txtServer.Text -SqlUser $txtSqlUser.Text -SqlPassword $txtSqlPass.Text -UseIntegratedSecurity:$chkIntegrated.Checked
        foreach ($db in $dbs) { [void]$listDb.Items.Add($db, $true) }
        Write-UiLog -TextBox $logBox -Message "Detected $($dbs.Count) database(s)."
    } catch {
        Write-UiLog -TextBox $logBox -Message "Detection error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Detection failed', 'OK', 'Error') | Out-Null
    }
})

$btnStart.Add_Click({
    if (-not $script:isBackupRunning) {
        try {
            if ($listDb.CheckedItems.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('Select at least one database to backup.', 'No databases selected', 'OK', 'Warning') | Out-Null
                return
            }
            $selected = @(); foreach ($item in $listDb.CheckedItems) { $selected += [string]$item }
            $script:isBackupRunning = $true
            $script:cancelBackup = $false
            $btnStart.Text = 'Stop Backup'
            $btnStart.BackColor = [System.Drawing.Color]::FromArgb(255,199,206)
            Write-UiLog -TextBox $logBox -Message "Backup job started. Selected DBs: $($selected -join ', ')"
            $progress.Value = 0
            Invoke-SageDbDumpBackup -RuntimePath $txtRuntime.Text -BackupRoot $txtBackupRoot.Text -DatabaseNames $selected -SageAdminUser $txtSageUser.Text -SageAdminPassword $txtSagePass.Text -LogBox $logBox -ProgressBar $progress -EtaLabel $lblEta -IsCancelled { $script:cancelBackup }
            if ($script:cancelBackup) {
                Write-UiLog -TextBox $logBox -Message 'Backup operation ended due to cancellation request.'
            } else {
                Write-UiLog -TextBox $logBox -Message 'All selected database backups completed successfully.'
                [System.Windows.Forms.MessageBox]::Show('Backup completed successfully.', 'Complete', 'OK', 'Information') | Out-Null
            }
        } catch {
            Write-UiLog -TextBox $logBox -Message "Backup error: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Backup failed', 'OK', 'Error') | Out-Null
        } finally {
            $script:isBackupRunning = $false
            $script:cancelBackup = $false
            $script:currentBackupProcess = $null
            $btnStart.Text = 'Start Backup'
            $btnStart.BackColor = [System.Drawing.Color]::FromArgb(198,239,206)
        }
    } else {
        $script:cancelBackup = $true
        Write-UiLog -TextBox $logBox -Message 'Stop requested by user. Attempting graceful cancellation...'
        if ($script:currentBackupProcess -and -not $script:currentBackupProcess.HasExited) {
            try {
                $script:currentBackupProcess.Kill()
                Write-UiLog -TextBox $logBox -Message 'Active backup process terminated.'
            } catch {
                Write-UiLog -TextBox $logBox -Message "Unable to terminate active process cleanly: $($_.Exception.Message)"
            }
        }
    }
})

& $saveSettings
[void]$form.ShowDialog()

# SIG # Begin signature block
# MIIFiwYJKoZIhvcNAQcCoIIFfDCCBXgCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUd8l02OpYedIicuHD5sKnp36H
# tf6gggMcMIIDGDCCAgCgAwIBAgIQdTnGUb3fnrZCF1K2xTtGMjANBgkqhkiG9w0B
# AQsFADAkMSIwIAYDVQQDDBlDSEVTSS1KRENvZGUtU2lnbmluZy0yMDI2MB4XDTI2
# MDMwNjE0NDY0NVoXDTI3MDMwNjE0NDY0NVowJDEiMCAGA1UEAwwZQ0hFU0ktSkRD
# b2RlLVNpZ25pbmctMjAyNjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
# AMIvE+cjfWSthiMrydvmvgrd9ucGb77R+W5jS2EfE73xAMxLBjZBbfTdh8Ig1Oj2
# aZuTWPwXoETEdh4ocXbtyYX0WDXqnNwSzDGDLKNiMzQ2bJEgfeegSGazOCUXchya
# x82YR81WyxGd4sIqBBC3JpFxr+O6MZHHtqUHkkHyUY1Q8phH40X6UOH+l7AIB3yC
# zxqyEJ68RNQFh4UhD2dS4DneN0xyPlQ/VhXcMF4dONwQz7lSIIgD+iiJzXo9Ka7F
# ZOGm1jtq7i/p3XwLuq3zMxgeHh3VcVWh2QbO2PODgIxtchRMFBkW5BtiBjV5nSs7
# D879uPSkhTEGk2UAHDDsbKkCAwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBQGI/EgF0UkEE5pOr6J/upQmqqo2jAN
# BgkqhkiG9w0BAQsFAAOCAQEABPRv9v2ibkmhWvzlXApwWNScLZ2c6r1ErdcIYEDf
# UHMPwiWV8ztOT9cK6NunF9VjPSb/dCxu2OU+F+HGl1utqoTtPMV+95p9ctwu12KR
# 20/JxfmfoGu1dTYQYZZeWapbBNOwwPg3GEti2PNHMCI+QBSN3MbnfABwVFs9T2X+
# 7tQaOdAhY1kqp8siaCoCpwcoGWlhDdO6+hCrI3Qz5oWN/hMCrL6Sm3afgDoh8xzB
# fxnNdcwQq2+etj+JM9Gcz+C8fUnlZmKPn+wEsMS+oZqfEUt5HEzEIe8LVuuub/Ah
# 8eTO2IA6ouL9V9TyN0aWtV2l0qoqyoY+odq6v1QPInnLfDGCAdkwggHVAgEBMDgw
# JDEiMCAGA1UEAwwZQ0hFU0ktSkRDb2RlLVNpZ25pbmctMjAyNgIQdTnGUb3fnrZC
# F1K2xTtGMjAJBgUrDgMCGgUAoHgwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZ
# BgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYB
# BAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUgUsqITB54Aggoz7TPzxiyonnbXQwDQYJ
# KoZIhvcNAQEBBQAEggEAZM1zHgvpk2lbe/CjFr/ULPYgqtjuQx9Dn7vsi+zJwjZN
# O8qLS3I0d9mPJAmldYtA0kWyBqjBaajBS4933YdsRxs+biSLA3NqInZYSc/WTMub
# zGfgsZV3Q6DThrw3SfiCc+5JDln2PNcsWWDraXCpoCTSGC/ijg9Rct7PQHbCg3H2
# eogLcWCSD4QW50CSoQC/7KPhpHbNI19YlLBbZ/UIabZ2igT0pFh9vsw2ykhrgvCd
# j7RTN4lLeY0/0WOlqA4JDOlISlRWBrrgSjeQteHewHX1UkwVOEU3HjMUY1VbXY+Y
# tddJcas1ww8QGt2o9nKSATOmTJWbIe3rlcg/wlHEVg==
# SIG # End signature block
