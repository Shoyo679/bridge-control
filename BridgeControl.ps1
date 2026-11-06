# Bridge Control: start / stop background programs (hidden, no console window) with a live status dot.
#   BridgeControl.ps1              opens the panel
#   BridgeControl.ps1 -Autostart   starts every app with "startAtLogin": true, then waits in the tray (used at Windows login)
# Closing the panel hides it to the tray; Quit in the tray icon's menu closes Bridge Control (the programs keep running).
# The programs are listed in apps.json next to this script (copy apps.example.json to start).
# Apps with "keepRunning": true are watched while Bridge Control runs: started again (hidden) if they stop by
# themselves, and swapped for a hidden copy if a copy Bridge Control didn't start shows up (e.g. after a self-update
# that came back in a terminal window). Stop turns this off until Start is pressed. Events go to bridge-control.log.
param([switch]$Autostart)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Name Native -Namespace BridgeControl -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] icons, uint[] ids, uint count, uint flags);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
'@
# Draw at the screen's real resolution instead of being stretched (blurry) by Windows.
[void][BridgeControl.Native]::SetProcessDPIAware()
# Its own taskbar identity, so the taskbar shows Bridge Control's icon instead of grouping it with PowerShell.
[void][BridgeControl.Native]::SetCurrentProcessExplicitAppUserModelID('BridgeControl.Panel')
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

# Looking a program up by name makes Windows list every process (~15 ms each time), so all lookups share one list of
# the processes with our programs' names, taken at most once a second and again right after a Start or Stop.
$appNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($app in $apps) { [void]$appNames.Add([IO.Path]::GetFileNameWithoutExtension($app.path)) }
$snapshot = @{ At = [DateTime]::MinValue; ByName = @{} }
function Get-Snapshot {
    if (((Get-Date) - $snapshot.At).TotalMilliseconds -gt 1000) {
        $byName = @{}
        foreach ($p in [Diagnostics.Process]::GetProcesses()) {
            if ($appNames.Contains($p.ProcessName)) {
                if ($byName.ContainsKey($p.ProcessName)) { $byName[$p.ProcessName] += $p } else { $byName[$p.ProcessName] = @($p) }
            }
        }
        $snapshot.ByName = $byName; $snapshot.At = Get-Date
    }
    $snapshot.ByName
}
function Reset-Snapshot { $snapshot.At = [DateTime]::MinValue }

function Get-AppProcess($app) {
    $procName = [IO.Path]::GetFileNameWithoutExtension($app.path)
    # Match on the full path when Windows lets us read it, so a different program with the same name is not mistaken for it.
    $list = (Get-Snapshot)[$procName]
    if ($list) { $list | Where-Object { -not $_.Path -or $_.Path -ieq $app.path } }
}
function Test-Running($app) { [bool](Get-AppProcess $app) }

$logPath = Join-Path $PSScriptRoot 'bridge-control.log'
function Write-Log($text) {
    try {
        if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 256KB) { Move-Item $logPath "$logPath.old" -Force }
        Add-Content $logPath "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $text"
    } catch {}
}

# The copies Bridge Control started, as "id:start time" (so a reused process id never counts). Kept in state.json
# so they are still recognised after Bridge Control itself is closed and opened again.
$statePath = Join-Path $PSScriptRoot 'state.json'
function Get-ProcessKey($proc) {
    $start = try { $proc.StartTime.ToFileTimeUtc() } catch { 0 }
    "$($proc.Id):$start"
}
function Test-Owned($proc) { $owned.ContainsKey((Get-ProcessKey $proc)) }
function Save-Owned {
    # Our copies always have one of our programs' names, so the fresh list is enough to see which still run.
    Reset-Snapshot
    $live = @{}
    foreach ($list in (Get-Snapshot).Values) { foreach ($p in $list) { $live[(Get-ProcessKey $p)] = $true } }
    foreach ($key in @($owned.Keys)) { if (-not $live.ContainsKey($key)) { $owned.Remove($key) } }
    try { ConvertTo-Json -InputObject @($owned.Keys) | Set-Content $statePath } catch {}
}
$owned = @{}
try { foreach ($key in @(Get-Content $statePath -Raw -ErrorAction Stop | ConvertFrom-Json | ForEach-Object { $_ })) { $owned["$key"] = $true } } catch {}
Save-Owned

function Start-App($app, [switch]$Quiet) {
    if (Test-Running $app) { return }
    if (-not (Test-Path $app.path)) {
        if (-not $Quiet) { Show-Error "$($app.name): file not found:`n$($app.path)" }
        return
    }
    $startArgs = @{ FilePath = $app.path; WorkingDirectory = (Split-Path $app.path); WindowStyle = 'Hidden'; PassThru = $true }
    if ($app.args) { $startArgs.ArgumentList = $app.args }
    $proc = Start-Process @startArgs
    if ($proc) { $owned[(Get-ProcessKey $proc)] = $true; Save-Owned }
}

function Stop-App($app) {
    $procs = @(Get-AppProcess $app)
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    # Wait only until they have really closed (usually a few ms), so the card shows Offline straight away.
    foreach ($p in $procs) { try { [void]$p.WaitForExit(1000) } catch {} }
    Reset-Snapshot
}

# Only one Bridge Control at a time. Opening it again tells the running one to show its window.
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\BridgeControlPanel', [ref]$created)
$showSignal = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\BridgeControlShow')
if (-not $created) {
    if (-not $Autostart) { [void]$showSignal.Set() }
    exit 0
}

# keepRunning: wait this long before acting, so a program that is updating itself can finish. After each automatic
# restart the wait doubles (up to 5 minutes), so a program that keeps failing isn't restarted over and over; it goes
# back to the start once the program has run calmly for 5 minutes.
$restartDelay = 10     # seconds a stopped program stays stopped before it is started again
$takeoverDelay = 20    # seconds a copy Bridge Control didn't start may run before it is swapped for a hidden one
$guard = @(foreach ($app in $apps) { @{ Wanted = $false; Since = $null; Wait = $restartDelay; CalmSince = $null } })

for ($i = 0; $i -lt $apps.Count; $i++) {
    $loginStart = $Autostart -and $apps[$i].startAtLogin
    if ($loginStart) { Start-App $apps[$i] -Quiet }
    # Watch what should be running: what was started at login and whatever is already running.
    $guard[$i].Wanted = $loginStart -or (Test-Running $apps[$i])
}

function Watch-Apps {
    $now = Get-Date
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $app = $apps[$i]; $g = $guard[$i]
        if (-not $app.keepRunning -or -not $g.Wanted) { continue }
        $procs = @(Get-AppProcess $app)
        $foreign = @($procs | Where-Object { -not (Test-Owned $_) })
        if ($procs.Count -gt 0 -and $foreign.Count -eq 0) {
            $g.Since = $null
            if (-not $g.CalmSince) { $g.CalmSince = $now }
            elseif (($now - $g.CalmSince).TotalMinutes -ge 5) { $g.Wait = $restartDelay }
            continue
        }
        $g.CalmSince = $null
        if (-not $g.Since) { $g.Since = $now; continue }
        $limit = if ($procs.Count -eq 0) { $g.Wait } else { [Math]::Max($takeoverDelay, $g.Wait) }
        if (($now - $g.Since).TotalSeconds -lt $limit) { continue }

        if ($procs.Count -eq 0) {
            Write-Log "$($app.name) had stopped by itself; starting it again (hidden)."
        } else {
            $foreign | Stop-Process -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $foreign.Id -Timeout 5 -ErrorAction SilentlyContinue
            Reset-Snapshot
            if (@(Get-AppProcess $app | Where-Object { -not (Test-Owned $_) }).Count -gt 0) {
                Write-Log "$($app.name) is running in a copy Bridge Control didn't start, and it could not be closed (it may need administrator rights)."
            } elseif ($procs.Count -gt $foreign.Count) {
                Write-Log "$($app.name): closed an extra copy that Bridge Control didn't start; the hidden one keeps running."
            } else {
                Write-Log "$($app.name) was running in a copy Bridge Control didn't start (often after it updated itself); swapped it for a hidden one."
            }
        }
        Start-App $app -Quiet
        if (-not (Test-Path $app.path)) { Write-Log "$($app.name): file not found: $($app.path)" }
        $g.Since = $null
        $g.Wait = [Math]::Min(2 * $g.Wait, 300)
    }
}

function Invoke-Start($i) {
    $g = $guard[$i]
    $g.Wanted = $true; $g.Since = $null; $g.Wait = $restartDelay
    Start-App $apps[$i]
}
function Invoke-Stop($i) {
    $guard[$i].Wanted = $false
    Stop-App $apps[$i]
}

# ---- The panel: a dark card per program with its logo, its status and one Start / Stop button. ----
# Everything is drawn in Paint, laid out in 96-dpi units and scaled by $k for the screen.
$probe = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $k = $probe.DpiX / 96; $probe.Dispose()
function Get-Color($hex, $alpha = 255) { [System.Drawing.Color]::FromArgb($alpha, [System.Drawing.ColorTranslator]::FromHtml($hex)) }
$theme = @{
    bg = Get-Color '#0E1014'; card = Get-Color '#161920'; edge = Get-Color '#232833'
    text = Get-Color '#ECEEF3'; muted = Get-Color '#8B93A5'; faint = Get-Color '#5A6273'
    on = Get-Color '#22C55E'; wait = Get-Color '#F5A524'; off = Get-Color '#5B6474'
    button = Get-Color '#1F2430'; buttonHover = Get-Color '#323B4F'; buttonEdge = Get-Color '#2C3341'
    startText = Get-Color '#06210F'; startHover = Get-Color '#34D370'; dim = Get-Color '#0E1014' 150
}
function New-PxFont($family, $px) { New-Object System.Drawing.Font($family, $px, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel) }
$fonts = @{ title = New-PxFont 'Segoe UI Semibold' 20; name = New-PxFont 'Segoe UI Semibold' 14.5; text = New-PxFont 'Segoe UI' 12; button = New-PxFont 'Segoe UI Semibold' 12 }
$brushes = @{}; foreach ($key in $theme.Keys) { $brushes[$key] = New-Object System.Drawing.SolidBrush($theme[$key]) }
$edgePen = New-Object System.Drawing.Pen($theme.edge); $buttonPen = New-Object System.Drawing.Pen($theme.buttonEdge)
$nameFormat = New-Object System.Drawing.StringFormat; $nameFormat.Trimming = 'EllipsisCharacter'; $nameFormat.FormatFlags = 'NoWrap'
$centered = New-Object System.Drawing.StringFormat; $centered.Alignment = 'Center'; $centered.LineAlignment = 'Center'
$dot = [char]0x00B7

$layout = @{ width = 480; top = 92; rowStep = 76; cardHeight = 66; logo = 40; buttonW = 70; buttonH = 28 }
function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90); $p.AddArc($x + $w - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
    $p.AddArc($x + $w - 2 * $r, $y + $h - 2 * $r, 2 * $r, 2 * $r, 0, 90); $p.AddArc($x, $y + $h - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $p.CloseFigure(); $p
}
function Get-CardY($i) { $layout.top + $layout.rowStep * $i }
function Get-ButtonRect($i) { New-Object System.Drawing.RectangleF(($layout.width - 104), ((Get-CardY $i) + 19), $layout.buttonW, $layout.buttonH) }
$startAllRect = New-Object System.Drawing.RectangleF(($layout.width - 128), 18, 110, 26)

# Each program's logo, rounded and sized once: "icon" from apps.json if given, else the program's own icon,
# else its first letter on a coloured tile.
function Get-Logo($app) {
    $size = [int][Math]::Round($layout.logo * $k)
    $src = $null
    try {
        if ($app.icon) {
            $file = if ([IO.Path]::IsPathRooted($app.icon)) { $app.icon } else { Join-Path $PSScriptRoot $app.icon }
            $stream = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($file))
            $img = [System.Drawing.Image]::FromStream($stream); $src = New-Object System.Drawing.Bitmap($img); $img.Dispose(); $stream.Dispose()
        } elseif (Test-Path $app.path) {
            $handles = New-Object IntPtr[] 1
            if ([BridgeControl.Native]::PrivateExtractIcons($app.path, 0, 256, 256, $handles, $null, 1, 0) -gt 0 -and $handles[0] -ne [IntPtr]::Zero) {
                $src = [System.Drawing.Icon]::FromHandle($handles[0]).ToBitmap()
                [void][BridgeControl.Native]::DestroyIcon($handles[0])
            }
        }
    } catch {}
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
    $g.SetClip((New-RoundRect 0 0 $size $size ($size * 0.22)))
    if ($src) { $g.DrawImage($src, 0, 0, $size, $size); $src.Dispose() }
    else {
        $hue = [Math]::Abs($app.name.GetHashCode()) % 6
        $g.Clear((Get-Color (@('#6366F1', '#0EA5E9', '#14B8A6', '#F59E0B', '#EC4899', '#8B5CF6')[$hue])))
        $g.TextRenderingHint = 'AntiAliasGridFit'
        $g.DrawString($app.name.Substring(0, 1).ToUpper(), (New-PxFont 'Segoe UI Semibold' ($size * 0.5)), [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, $size, $size)), $centered)
    }
    $g.Dispose()
    $bmp
}
$logos = @(foreach ($app in $apps) { Get-Logo $app })

# What each card shows; filled in by Update-Rows, the countdown / uptime is worked out when drawing.
$view = @(foreach ($app in $apps) { @{ State = 'off'; Line = 'Offline'; Until = $null; Up = $null } })
$watchingSince = Get-Date
$hover = $null           # 'all' or a row number while the mouse is over a button
$clock = [Diagnostics.Stopwatch]::StartNew()

function Format-Span([TimeSpan]$s) {
    if ($s.TotalMinutes -lt 1) { 'just now' }
    elseif ($s.TotalHours -lt 1) { '{0}m' -f [int][Math]::Floor($s.TotalMinutes) }
    elseif ($s.TotalDays -lt 1) { '{0}h {1}m' -f [int][Math]::Floor($s.TotalHours), $s.Minutes }
    else { '{0}d {1}h' -f [int][Math]::Floor($s.TotalDays), $s.Hours }
}
function Get-Detail($v) {
    $now = Get-Date
    switch ($v.State) {
        'on'  { if ($v.Up) { 'up ' + (Format-Span ($now - $v.Up)) } else { '' } }
        'off' { 'not running' }
        'wait' {
            if ($v.Line -in 'Starting', 'Stopping') { '' }
            elseif (-not $v.Until) { 'shortly' }
            else {
                $left = [int][Math]::Ceiling(($v.Until - $now).TotalSeconds)
                $when = if ($left -gt 0) { "in ${left}s" } else { 'now' }
                if ($v.Line -eq 'Restarting') { "back $when" } else { $when }
            }
        }
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Bridge Control'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = 'None'
$form.BackColor = $theme.bg
$form.ClientSize = New-Object System.Drawing.Size([int]($layout.width * $k), [int](($layout.top + $layout.rowStep * $apps.Count + 4) * $k))
# Draw into a back buffer so the cards don't flicker.
$form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($form, $true)
$iconPath = Join-Path $PSScriptRoot 'icon.ico'
try {
    if (Test-Path $iconPath) { $form.Icon = New-Object System.Drawing.Icon($iconPath) }
    else { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($apps[0].path) }
} catch {}
# Dark title bar to match (Windows 10 20H1 and later; older versions just keep the light one).
$form.Add_HandleCreated({ $on = 1; [void][BridgeControl.Native]::DwmSetWindowAttribute($form.Handle, 20, [ref]$on, 4) })

# Everything that only changes with a status or the mouse (cards, logos, names, buttons) is drawn once into a picture;
# each frame (10 a second) then only adds the breathing dots and the timers on top.
$static = @{ Key = $null; Bitmap = $null }
function Set-Quality($g) { $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'; $g.InterpolationMode = 'HighQualityBicubic' }
function Draw-Static($g) {
    $W = $layout.width

    # Header: title, how many are online, Start all.
    $online = @($view | Where-Object { $_.State -eq 'on' }).Count
    $g.DrawString('Bridges', $fonts.title, $brushes.text, 17, 12)
    $g.DrawString("$online of $($apps.Count) online  $dot  watching since $($watchingSince.ToString('h:mm tt'))", $fonts.text, $brushes.muted, 19, 44)
    $anyOff = @($view | Where-Object { $_.State -eq 'off' }).Count -gt 0
    $pill = New-RoundRect $startAllRect.X $startAllRect.Y $startAllRect.Width $startAllRect.Height 13
    $g.FillPath($(if ($anyOff -and "$hover" -eq 'all') { $brushes.buttonHover } else { $brushes.button }), $pill); $g.DrawPath($buttonPen, $pill)
    $g.DrawString('Start all', $fonts.button, $(if ($anyOff) { $brushes.text } else { $brushes.faint }), $startAllRect, $centered)

    for ($i = 0; $i -lt $apps.Count; $i++) {
        $v = $view[$i]; $y = Get-CardY $i
        $off = $v.State -eq 'off'
        $card = New-RoundRect 14 $y ($W - 28) $layout.cardHeight 10
        $g.FillPath($brushes.card, $card); $g.DrawPath($edgePen, $card)
        $g.SetClip($card); $g.FillRectangle($brushes[$v.State], 14, $y, 3, $layout.cardHeight); $g.ResetClip()

        # Logo, dimmed when off (its status dot is drawn each frame).
        $lx = 30; $ly = $y + 13
        $g.DrawImage($logos[$i], $lx, $ly, $layout.logo, $layout.logo)
        if ($off) { $g.FillPath($brushes.dim, (New-RoundRect $lx $ly $layout.logo $layout.logo 9)) }

        # Name, then status in its colour; the detail after it is drawn each frame at DetailX.
        $g.DrawString($apps[$i].name, $fonts.name, $(if ($off) { $brushes.muted } else { $brushes.text }), (New-Object System.Drawing.RectangleF(82, ($y + 12), 282, 22)), $nameFormat)
        $g.DrawString($v.Line, $fonts.text, $brushes[$v.State], 83, ($y + 37))
        $v.DetailX = 89 + $g.MeasureString($v.Line, $fonts.text, (New-Object System.Drawing.PointF(0, 0)), [System.Drawing.StringFormat]::GenericTypographic).Width

        # One button: green Start when off, Stop otherwise.
        $b = Get-ButtonRect $i
        $shape = New-RoundRect $b.X $b.Y $b.Width $b.Height 8
        if ($off) {
            $g.FillPath($(if ("$hover" -eq "$i") { $brushes.startHover } else { $brushes.on }), $shape)
            $g.DrawString('Start', $fonts.button, $brushes.startText, $b, $centered)
        } else {
            $g.FillPath($(if ("$hover" -eq "$i") { $brushes.buttonHover } else { $brushes.button }), $shape); $g.DrawPath($buttonPen, $shape)
            $g.DrawString('Stop', $fonts.button, $brushes.text, $b, $centered)
        }
    }
}

$form.Add_Paint({
    $g = $_.Graphics
    $key = (@($view | ForEach-Object { "$($_.State)|$($_.Line)" }) -join ';') + "|$hover"
    if ($static.Key -ne $key -or -not $static.Bitmap) {
        if ($static.Bitmap) { $static.Bitmap.Dispose() }
        $bmp = New-Object System.Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
        $sg = [System.Drawing.Graphics]::FromImage($bmp)
        $sg.Clear($theme.bg); Set-Quality $sg; $sg.ScaleTransform($k, $k)
        Draw-Static $sg
        $sg.Dispose()
        $static.Bitmap = $bmp; $static.Key = $key
    }
    $g.DrawImageUnscaled($static.Bitmap, 0, 0)

    Set-Quality $g
    $g.ScaleTransform($k, $k)
    # The status dots breathe slowly (2.4 s); the detail (uptime / countdown) changes by the second.
    $pulse = 0.5 + 0.5 * [Math]::Sin($clock.Elapsed.TotalSeconds * 2 * [Math]::PI / 2.4)
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $v = $view[$i]; $y = Get-CardY $i
        $color = $theme[$v.State]
        $dx = 63; $dy = $y + 46
        if ($v.State -ne 'off') {
            $glow = New-Object System.Drawing.Drawing2D.GraphicsPath; $glow.AddEllipse(($dx - 10), ($dy - 10), 20, 20)
            $glowBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush($glow)
            $glowBrush.CenterColor = [System.Drawing.Color]::FromArgb([int](70 + 110 * $pulse), $color)
            $glowBrush.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $color))
            $g.FillPath($glowBrush, $glow); $glowBrush.Dispose(); $glow.Dispose()
        }
        $g.FillEllipse($brushes.card, ($dx - 6), ($dy - 6), 12, 12); $g.FillEllipse($brushes[$v.State], ($dx - 4), ($dy - 4), 8, 8)
        $detail = Get-Detail $v
        if ($detail) { $g.DrawString("$dot  $detail", $fonts.text, $brushes.faint, $v.DetailX, ($y + 37)) }
    }
})

function Get-HitTarget($e) {
    $p = New-Object System.Drawing.PointF(($e.X / $k), ($e.Y / $k))
    if ($startAllRect.Contains($p)) { return 'all' }
    for ($i = 0; $i -lt $apps.Count; $i++) { if ((Get-ButtonRect $i).Contains($p)) { return $i } }
    $null
}
$form.Add_MouseMove({
    $target = Get-HitTarget $_
    if ("$target" -ne "$script:hover") {
        $script:hover = $target
        $form.Cursor = if ($null -ne $target) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
        $form.Invalidate()
    }
})
$form.Add_MouseLeave({ if ($null -ne $script:hover) { $script:hover = $null; $form.Cursor = [System.Windows.Forms.Cursors]::Default; $form.Invalidate() } })
# A button acts when the mouse is pressed and released on it.
$pressed = $null
$form.Add_MouseDown({ if ($_.Button -eq 'Left') { $script:pressed = Get-HitTarget $_ } })
$form.Add_MouseUp({
    if ($_.Button -ne 'Left') { return }
    $target = Get-HitTarget $_
    $wasPressed = $script:pressed; $script:pressed = $null
    if ($null -eq $target -or "$target" -ne "$wasPressed") { return }
    # Start all starts every program that is off; a row's button starts it when off and stops it otherwise.
    $rowsHit = if ("$target" -eq 'all') { @(0..($apps.Count - 1) | Where-Object { $view[$_].State -eq 'off' }) } else { @($target) }
    $starting = @{}; foreach ($i in $rowsHit) { $starting[$i] = $view[$i].State -eq 'off' }
    # Show the change at once; starting a program can take a moment (Windows checks it first).
    foreach ($i in $rowsHit) {
        $view[$i].Line = if ($starting[$i]) { 'Starting' } else { 'Stopping' }
        $view[$i].State = 'wait'; $view[$i].Until = $null
    }
    $form.Refresh()
    foreach ($i in $rowsHit) { if ($starting[$i]) { Invoke-Start $i } else { Invoke-Stop $i } }
    Update-Rows
})

# Tray icon: the logo's four dots, each showing one program (green online, amber restarting, grey off; an unused
# dot is faint). With more than four programs the dots show the share of each state instead. Made once per mix.
$trayIcons = @{}
function Get-TrayIcon([string[]]$states) {
    $slots = if ($states.Count -le 4) { @($states) + @('empty') * (4 - $states.Count) }
             else { $sorted = @($states | Sort-Object { @('on', 'wait', 'off').IndexOf($_) }); @(0..3 | ForEach-Object { $sorted[[int][Math]::Floor($_ * $sorted.Count / 4)] }) }
    $key = $slots -join ','
    if (-not $trayIcons.ContainsKey($key)) {
        $s = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
        $bmp = New-Object System.Drawing.Bitmap($s, $s)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
        $tile = New-RoundRect ($s * 0.04) ($s * 0.04) ($s * 0.92) ($s * 0.92) ($s * 0.22)
        $g.FillPath((New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF(0, $s)), (Get-Color '#20242E'), (Get-Color '#101217'))), $tile)
        $g.DrawPath((New-Object System.Drawing.Pen((Get-Color '#2E3442'), 1)), $tile)
        # Dots a little bigger than in the logo, so they read at tray size.
        $r = $s * 0.14; $gap = $s * 0.31
        for ($i = 0; $i -lt 4; $i++) {
            $color = if ($slots[$i] -eq 'empty') { Get-Color '#2A303C' } else { $theme[$slots[$i]] }
            $cx = $s / 2 + (($i % 2) - 0.5) * $gap; $cy = $s / 2 + ([Math]::Floor($i / 2) - 0.5) * $gap
            $g.FillEllipse((New-Object System.Drawing.SolidBrush($color)), ($cx - $r), ($cy - $r), (2 * $r), (2 * $r))
        }
        $g.Dispose()
        $trayIcons[$key] = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        $bmp.Dispose()
    }
    $trayIcons[$key]
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
$tray.Icon = Get-TrayIcon @($view | ForEach-Object { $_.State })
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
        $app = $apps[$i]; $g = $guard[$i]; $v = $view[$i]
        $procs = @(Get-AppProcess $app)
        $watched = $app.keepRunning -and $g.Wanted
        $v.Until = $null; $v.Up = $null
        if ($procs.Count -gt 0) {
            $online++
            $v.Up = $procs | ForEach-Object { try { $_.StartTime } catch {} } | Sort-Object | Select-Object -First 1
            if ($watched -and @($procs | Where-Object { -not (Test-Owned $_) }).Count -gt 0) {
                # Running in a copy Bridge Control didn't start: it will be swapped for a hidden one.
                $v.State = 'wait'; $v.Line = 'Switching to hidden'
                if ($g.Since) { $v.Until = $g.Since.AddSeconds([Math]::Max($takeoverDelay, $g.Wait)) }
            } else { $v.State = 'on'; $v.Line = 'Online' }
        } elseif ($watched) {
            $v.State = 'wait'; $v.Line = 'Restarting'
            if ($g.Since) { $v.Until = $g.Since.AddSeconds($g.Wait) }
        } else { $v.State = 'off'; $v.Line = 'Offline' }
    }
    if ($form.Visible) { $form.Invalidate() }
    $tray.Icon = Get-TrayIcon @($view | ForEach-Object { $_.State })
    $tip = "Bridge Control - $online of $($apps.Count) online"
    $tray.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Watch-Apps; Update-Rows })
$timer.Start()

# Another launch asked us to show the panel.
$signalTimer = New-Object System.Windows.Forms.Timer
$signalTimer.Interval = 300
$signalTimer.Add_Tick({ if ($showSignal.WaitOne(0)) { Show-Panel } })
$signalTimer.Start()

# Redraws the open panel for the breathing dots and the counting-down / uptime text.
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 100
$animTimer.Add_Tick({ if ($form.Visible -and $form.WindowState -ne 'Minimized') { $form.Invalidate() } })
$animTimer.Start()

Update-Rows
$context = New-Object System.Windows.Forms.ApplicationContext
# At login it waits in the tray; opened by hand it shows the panel.
if (-not $Autostart) { Show-Panel }
[System.Windows.Forms.Application]::Run($context)

$timer.Stop(); $signalTimer.Stop(); $animTimer.Stop()
$tray.Dispose()
foreach ($icon in $trayIcons.Values) { [void][BridgeControl.Native]::DestroyIcon($icon.Handle) }
$mutex.ReleaseMutex()
