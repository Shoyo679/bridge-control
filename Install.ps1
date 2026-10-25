# Sets up Bridge Control for the current Windows user:
#   - a "Bridge Control" shortcut on the desktop (opens the panel)
#   - a login entry that starts every app with "startAtLogin": true (only when at least one has it)
# Safe to run again after editing apps.json. Undo with Uninstall.ps1.
param([switch]$NoPause)   # -NoPause: don't wait for Enter at the end
$ErrorActionPreference = 'Stop'
# "Run with PowerShell" closes the window at once, so wait for Enter to let people read the result.
function Exit-Install($code) { if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }; exit $code }
$here = $PSScriptRoot
$config = Join-Path $here 'apps.json'
$example = Join-Path $here 'apps.example.json'

# Files downloaded from the internet are marked as blocked; clear that so Windows runs them without asking.
Get-ChildItem $here -File | Unblock-File

if (-not (Test-Path $config)) {
    Copy-Item $example $config
    Write-Host "Created apps.json from the example. Put your programs in it, save, then run Install.ps1 again." -ForegroundColor Yellow
    Start-Process notepad.exe $config
    Exit-Install 0
}

try {
    # ForEach-Object unrolls the list (Windows PowerShell 5.1 otherwise hands back the whole array as one item).
    $apps = @(Get-Content $config -Raw | ConvertFrom-Json | ForEach-Object { $_ })
} catch {
    Write-Host "apps.json could not be read: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Check the commas and quotes, and that every \ in a path is written as \\.'
    Exit-Install 1
}

foreach ($app in $apps) {
    if (Test-Path $app.path) { Write-Host "  OK       $($app.name)" -ForegroundColor Green }
    else { Write-Host "  MISSING  $($app.name): $($app.path)" -ForegroundColor Red }
}

$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$vbs = Join-Path $here 'BridgeControl.vbs'
$iconFile = Join-Path $here 'icon.ico'
$icon = if (Test-Path $iconFile) { $iconFile }
        elseif ($apps.Count -gt 0 -and (Test-Path $apps[0].path)) { "$($apps[0].path),0" }
        else { "$env:WINDIR\System32\imageres.dll,93" }

$shell = New-Object -ComObject WScript.Shell
function New-Shortcut($path, $arguments) {
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = $wscript
    $lnk.Arguments = $arguments
    $lnk.WorkingDirectory = $here
    $lnk.IconLocation = $icon
    $lnk.Save()
}

$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Bridge Control.lnk'
New-Shortcut $desktopLink "`"$vbs`""
Write-Host "Desktop shortcut: $desktopLink"

$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Bridge Control (autostart).lnk'
if ($apps | Where-Object { $_.startAtLogin }) {
    New-Shortcut $startupLink "`"$vbs`" /autostart"
    Write-Host "Starts at login: $(($apps | Where-Object { $_.startAtLogin } | ForEach-Object { $_.name }) -join ', ')"
} elseif (Test-Path $startupLink) {
    Remove-Item $startupLink
    Write-Host 'No app has startAtLogin, so the login entry was removed.'
}

Write-Host 'Done. Double-click "Bridge Control" on your desktop.' -ForegroundColor Green
Exit-Install 0

