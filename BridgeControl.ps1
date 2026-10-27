# Bridge Control: start / stop background programs (hidden, no console window) with a live status dot.
#   BridgeControl.ps1              opens the panel
#   BridgeControl.ps1 -Autostart   starts every app with "startAtLogin": true, then waits in the tray (used at Windows login)
# Closing the panel hides it to the tray; Quit in the tray icon's menu closes Bridge Control (the programs keep running).
# The programs are listed in apps.json next to this script (copy apps.example.json to start).
param([switch]$Autostart)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$configPath = Join-Path $PSScriptRoot 'apps.json'

function Show-Error($text) {
    [void][System.Windows.Forms.MessageBox]::Show($text, 'Bridge Control', 'OK', 'Warning')
}

if (-not (Test-Path $configPath)) {
    Show-Error "apps.json was not found in:`n$PSScriptRoot`n`nCopy apps.example.json to apps.json and put your programs in it."
    exit 1
}
try {
    # ForEach-Object unrolls the list (Windows PowerShell 5.1 otherwise hands back the whole array as one item).
    $apps = @(Get-Content $configPath -Raw | ConvertFrom-Json | ForEach-Object { $_ })
} catch {
    Show-Error "apps.json could not be read:`n$($_.Exception.Message)`n`nCheck the commas, quotes and that every \ is written as \\."
    exit 1
}
if ($apps.Count -eq 0) {
    Show-Error 'apps.json has no programs in it.'
    exit 1
}

function Get-AppProcess($app) {
    $procName = [IO.Path]::GetFileNameWithoutExtension($app.path)
    # Match on the full path when Windows lets us read it, so a different program with the same name is not mistaken for it.
    Get-Process -Name $procName -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Path -or $_.Path -ieq $app.path }
}
function Test-Running($app) { [bool](Get-AppProcess $app) }

function Start-App($app) {
    if (Test-Running $app) { return }
    if (-not (Test-Path $app.path)) {
        if (-not $Autostart) { Show-Error "$($app.name): file not found:`n$($app.path)" }
        return
    }
    $startArgs = @{ FilePath = $app.path; WorkingDirectory = (Split-Path $app.path); WindowStyle = 'Hidden' }
    if ($app.args) { $startArgs.ArgumentList = $app.args }
    Start-Process @startArgs
}

function Stop-App($app) {
    Get-AppProcess $app | Stop-Process -Force -ErrorAction SilentlyContinue
}

if ($Autostart) {
    foreach ($app in $apps) { if ($app.startAtLogin) { Start-App $app } }
}

# Only one Bridge Control at a time. Opening it again tells the running one to show its window.
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\BridgeControlPanel', [ref]$created)
$showSignal = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\BridgeControlShow')
if (-not $created) {
    if (-not $Autostart) { [void]$showSignal.Set() }
    exit 0
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Bridge Control'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = 'Dpi'
$form.ClientSize = New-Object System.Drawing.Size(450, (30 + 50 * $apps.Count))
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$iconPath = Join-Path $PSScriptRoot 'icon.ico'
try {
    if (Test-Path $iconPath) { $form.Icon = New-Object System.Drawing.Icon($iconPath) }
    else { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($apps[0].path) }
} catch {}

$rows = @()
for ($i = 0; $i -lt $apps.Count; $i++) {
    $y = 20 + 50 * $i

    $dot = New-Object System.Windows.Forms.Label
    $dot.Text = [char]0x25CF
    $dot.Font = New-Object System.Drawing.Font('Segoe UI', 16)
    $dot.Location = New-Object System.Drawing.Point(12, ($y - 8))
    $dot.Size = New-Object System.Drawing.Size(28, 34)

    $name = New-Object System.Windows.Forms.Label
    $name.Text = $apps[$i].name
    $name.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $name.AutoEllipsis = $true
    $name.Location = New-Object System.Drawing.Point(42, $y)
    $name.Size = New-Object System.Drawing.Size(170, 24)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(212, $y)
    $status.Size = New-Object System.Drawing.Size(70, 24)

    $start = New-Object System.Windows.Forms.Button
    $start.Text = 'Start'
    $start.Tag = $i
    $start.Location = New-Object System.Drawing.Point(286, ($y - 4))
    $start.Size = New-Object System.Drawing.Size(72, 30)
    $start.Add_Click({
        Start-App $apps[$this.Tag]
        Update-Rows
    })

    $stop = New-Object System.Windows.Forms.Button
    $stop.Text = 'Stop'
    $stop.Tag = $i
    $stop.Location = New-Object System.Drawing.Point(366, ($y - 4))
    $stop.Size = New-Object System.Drawing.Size(72, 30)
    $stop.Add_Click({
        Stop-App $apps[$this.Tag]
        Start-Sleep -Milliseconds 300
        Update-Rows
    })

    $form.Controls.AddRange(@($dot, $name, $status, $start, $stop))
    $rows += @{ Dot = $dot; Status = $status; Start = $start; Stop = $stop }
}

# Tray icon: a dot that is green when everything is online, amber when some are, grey when none are.
Add-Type -Name Native -Namespace BridgeControl -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);'
function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)), 2, 2, 28, 28)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush($color)), 5, 5, 22, 22)
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}
$trayIcons = @{
    all  = New-DotIcon ([System.Drawing.Color]::FromArgb(34, 197, 94))
    some = New-DotIcon ([System.Drawing.Color]::FromArgb(245, 158, 11))
    none = New-DotIcon ([System.Drawing.Color]::FromArgb(148, 163, 184))
}

$quitting = $false
$hintShown = $false

function Show-Panel {
    $form.Show()
    if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
    $form.Activate()
    Update-Rows
}

function Exit-BridgeControl {
    $script:quitting = $true
    $tray.Visible = $false
    $form.Close()
    $context.ExitThread()
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $menu.Items.Add('Open Bridge Control')
$openItem.Font = New-Object System.Drawing.Font($openItem.Font, [System.Drawing.FontStyle]::Bold)
$openItem.Add_Click({ Show-Panel })
[void]$menu.Items.Add('-')
$quitItem = $menu.Items.Add('Quit Bridge Control')
$quitItem.Add_Click({ Exit-BridgeControl })

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $trayIcons.none
$tray.Text = 'Bridge Control'
$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ if ($_.Button -eq 'Left') { Show-Panel } })
$tray.Visible = $true

# The X hides the panel to the tray; only Quit really closes it.
$form.Add_FormClosing({
    # Let Windows shut down / sign out without being held up.
    if ($script:quitting -or $_.CloseReason -in 'WindowsShutDown', 'TaskManagerClosing') { return }
    $_.Cancel = $true
    $form.Hide()
    if (-not $script:hintShown) {
        $script:hintShown = $true
        $tray.ShowBalloonTip(3000, 'Bridge Control is still here', 'Click this icon to open it. Right-click > Quit to close it. Your programs keep running either way.', 'Info')
    }
})

function Update-Rows {
    $online = 0
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $on = Test-Running $apps[$i]
        $r = $rows[$i]
        $r.Dot.ForeColor = if ($on) { [System.Drawing.Color]::LimeGreen } else { [System.Drawing.Color]::Gray }
        $r.Status.Text = if ($on) { 'Online' } else { 'Offline' }
        $r.Start.Enabled = -not $on
        $r.Stop.Enabled = $on
        if ($on) { $online++ }
    }
    $tray.Icon = if ($online -eq $apps.Count) { $trayIcons.all } elseif ($online -gt 0) { $trayIcons.some } else { $trayIcons.none }
    $tip = "Bridge Control - $online of $($apps.Count) online"
    $tray.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Rows })
$timer.Start()

# Another launch asked us to show the panel.
$signalTimer = New-Object System.Windows.Forms.Timer
$signalTimer.Interval = 300
$signalTimer.Add_Tick({ if ($showSignal.WaitOne(0)) { Show-Panel } })
$signalTimer.Start()

Update-Rows
$context = New-Object System.Windows.Forms.ApplicationContext
# At login it waits in the tray; opened by hand it shows the panel.
if (-not $Autostart) { Show-Panel }
[System.Windows.Forms.Application]::Run($context)

$timer.Stop(); $signalTimer.Stop()
$tray.Dispose()
foreach ($icon in $trayIcons.Values) { [void][BridgeControl.Native]::DestroyIcon($icon.Handle) }
$mutex.ReleaseMutex()
