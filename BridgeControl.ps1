# Bridge Control: start / stop background programs (hidden, no console window) with a live status dot.
#   BridgeControl.ps1              opens the panel
#   BridgeControl.ps1 -Autostart   starts every app with "startAtLogin": true, no panel (used at Windows login)
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
    exit 0
}

# Only one panel at a time.
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\BridgeControlPanel', [ref]$created)
if (-not $created) { exit 0 }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Bridge Control'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = 'Dpi'
$form.ClientSize = New-Object System.Drawing.Size(430, (30 + 50 * $apps.Count))
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
    $name.Size = New-Object System.Drawing.Size(150, 24)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(192, $y)
    $status.Size = New-Object System.Drawing.Size(70, 24)

    $start = New-Object System.Windows.Forms.Button
    $start.Text = 'Start'
    $start.Tag = $i
    $start.Location = New-Object System.Drawing.Point(266, ($y - 4))
    $start.Size = New-Object System.Drawing.Size(72, 30)
    $start.Add_Click({
        Start-App $apps[$this.Tag]
        Update-Rows
    })

    $stop = New-Object System.Windows.Forms.Button
    $stop.Text = 'Stop'
    $stop.Tag = $i
    $stop.Location = New-Object System.Drawing.Point(346, ($y - 4))
    $stop.Size = New-Object System.Drawing.Size(72, 30)
    $stop.Add_Click({
        Stop-App $apps[$this.Tag]
        Start-Sleep -Milliseconds 300
        Update-Rows
    })

    $form.Controls.AddRange(@($dot, $name, $status, $start, $stop))
    $rows += @{ Dot = $dot; Status = $status; Start = $start; Stop = $stop }
}

function Update-Rows {
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $on = Test-Running $apps[$i]
        $r = $rows[$i]
        $r.Dot.ForeColor = if ($on) { [System.Drawing.Color]::LimeGreen } else { [System.Drawing.Color]::Gray }
        $r.Status.Text = if ($on) { 'Online' } else { 'Offline' }
        $r.Start.Enabled = -not $on
        $r.Stop.Enabled = $on
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Rows })
$timer.Start()

Update-Rows
[void]$form.ShowDialog()
$timer.Stop()
$mutex.ReleaseMutex()
