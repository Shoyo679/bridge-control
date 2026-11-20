# Bridge Control: start / stop background programs (hidden, no console window) with a live status dot.
#   BridgeControl.ps1              opens the panel
#   BridgeControl.ps1 -Autostart   starts every app with "startAtLogin": true, then waits in the tray (used at Windows login)
# Closing the panel hides it to the tray; Quit in the tray icon's menu closes Bridge Control (the programs keep running).
# The programs are listed in apps.json next to this script (copy apps.example.json to start).
# Apps with "keepRunning": true are watched while Bridge Control runs: started again (hidden) if they stop by
# themselves, and swapped for a hidden copy if a copy Bridge Control didn't start shows up (e.g. after a self-update
# that came back in a terminal window). Stop turns this off until Start is pressed. Events go to bridge-control.log.
# Apps with "service" run under Windows by themselves (e.g. as a background task): Bridge Control shows their status
# (from their own status file when given) and its button runs their own start / stop command as administrator.
param([switch]$Autostart)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Name Native -Namespace BridgeControl -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] icons, uint[] ids, uint count, uint flags);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
'@
# (DwmSetWindowAttribute: 20 = dark title bar, 34 / 35 / 36 = border / caption / title text colour on Windows 11.)
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

# A path may have * in a folder name, for a program that installs into a new folder with each update
# (e.g. C:\Program Files\Tool\*\Tool.exe); it is looked up again before each start or stop.
function Resolve-AppPath($app) {
    if (-not $app.pathPattern) { return }
    $hit = @(Resolve-Path $app.pathPattern -ErrorAction SilentlyContinue)
    if ($hit.Count) { $app.path = $hit[-1].Path }
}
foreach ($app in $apps) {
    if ($app.path -like '*`**') { $app | Add-Member -NotePropertyName pathPattern -NotePropertyValue $app.path; Resolve-AppPath $app }
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
# Quicker than Save-Owned for the panel's Start: just adds the new copy (Save-Owned also drops ended ones).
function Add-Owned($key) {
    $owned[$key] = $true
    try { [IO.File]::WriteAllText($statePath, '["' + (@($owned.Keys) -join '","') + '"]') } catch {}
}
$owned = @{}
try { foreach ($key in @(Get-Content $statePath -Raw -ErrorAction Stop | ConvertFrom-Json | ForEach-Object { $_ })) { $owned["$key"] = $true } } catch {}
Save-Owned

function Read-ServiceStatus($app) {
    if (-not $app.service.statusFile) { return $null }
    try { Get-Content $app.service.statusFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
}

# Used at login and by keepRunning (the panel's buttons work in the background, see Invoke-InBackground).
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

# The panel's Start / Stop run in the background, so the window keeps animating while Windows starts a program
# (0.1-0.5 s) or while a service's administrator prompt is open. Complete-Jobs picks up the results.
$jobScripts = @{
    # Same as Start-Process -WindowStyle Hidden; hands back "id:start time" so the copy is known as ours.
    start = { param($path, $arguments)
        $psi = New-Object Diagnostics.ProcessStartInfo($path)
        $psi.WorkingDirectory = [IO.Path]::GetDirectoryName($path); $psi.WindowStyle = 'Hidden'; $psi.UseShellExecute = $true
        if ($arguments) { $psi.Arguments = $arguments }
        $p = [Diagnostics.Process]::Start($psi)
        if ($p) { "$($p.Id):$($p.StartTime.ToFileTimeUtc())" } }
    # Waits until each one has really closed (usually a few ms).
    stop = { param($ids)
        foreach ($id in $ids) { try { $p = [Diagnostics.Process]::GetProcessById($id); $p.Kill(); [void]$p.WaitForExit(2000) } catch {} } }
    # A service's own command, with Windows' administrator prompt.
    service = { param($path, $command)
        try { Start-Process -FilePath $path -ArgumentList $command -Verb RunAs -WindowStyle Hidden -ErrorAction Stop; 'ok' }
        catch { "not run ($($_.Exception.Message))" } }
}
$jobs = New-Object System.Collections.ArrayList
function Invoke-InBackground($row, $kind, [object[]]$arguments) {
    $ps = [PowerShell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript($jobScripts[$kind]); foreach ($a in $arguments) { [void]$ps.AddArgument($a) }
    [void]$jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Row = $row; Kind = $kind; Command = $arguments[-1] })
}
function Complete-Jobs {
    $done = $false
    for ($j = $jobs.Count - 1; $j -ge 0; $j--) {
        $job = $jobs[$j]
        if (-not $job.Handle.IsCompleted) { continue }
        $out = try { @($job.PS.EndInvoke($job.Handle)) } catch { @() }
        $job.PS.Dispose(); $jobs.RemoveAt($j); $done = $true
        $app = $apps[$job.Row]
        switch ($job.Kind) {
            'start' { if ($out.Count -and $out[-1]) { Add-Owned "$($out[-1])" } }
            'service' {
                if ("$($out[-1])" -eq 'ok') { Write-Log "$($app.name): asked it to $($job.Command)." }
                else { Write-Log "$($app.name): '$($job.Command)' was $($out[-1])."; $view[$job.Row].PendingUntil = $null }   # prompt cancelled: nothing will change
            }
        }
    }
    if ($done) { Reset-Snapshot; Update-Rows }
}

# Only one Bridge Control at a time. Opening it again tells the running one to show its window.
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\BridgeControlPanel', [ref]$created)
$showSignal = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\BridgeControlShow')
if (-not $created) {
    if (-not $Autostart) { [void]$showSignal.Set() }
    exit 0
}
# Two background workers for the panel's Start / Stop (see Invoke-InBackground).
$pool = [RunspaceFactory]::CreateRunspacePool(1, 2); $pool.Open()

# keepRunning: wait this long before acting, so a program that is updating itself can finish. After each automatic
# restart the wait doubles (up to 5 minutes), so a program that keeps failing isn't restarted over and over; it goes
# back to the start once the program has run calmly for 5 minutes.
$restartDelay = 10     # seconds a stopped program stays stopped before it is started again
$takeoverDelay = 20    # seconds a copy Bridge Control didn't start may run before it is swapped for a hidden one
$guard = @(foreach ($app in $apps) { @{ Wanted = $false; Since = $null; Wait = $restartDelay; CalmSince = $null } })

for ($i = 0; $i -lt $apps.Count; $i++) {
    # A service starts with Windows by itself.
    $loginStart = $Autostart -and $apps[$i].startAtLogin -and -not $apps[$i].service
    if ($loginStart) { [void](Start-App $apps[$i] -Quiet) }
    # Watch what should be running: what was started at login and whatever is already running.
    $guard[$i].Wanted = $loginStart -or (Test-Running $apps[$i])
}

function Watch-Apps {
    $now = Get-Date
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $app = $apps[$i]; $g = $guard[$i]
        if (-not $app.keepRunning -or $app.service -or -not $g.Wanted) { continue }
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
        [void](Start-App $app -Quiet)
        if (-not (Test-Path $app.path)) { Write-Log "$($app.name): file not found: $($app.path)" }
        $g.Since = $null
        $g.Wait = [Math]::Min(2 * $g.Wait, 300)
    }
}

# A power button / Start all / Stop all: Start sets keepRunning's watch again, Stop pauses it until the next Start.
# Returns $false when nothing could be started (file not found).
function Request-Change($i, [bool]$start) {
    $app = $apps[$i]; $g = $guard[$i]
    if ($start) { $g.Wanted = $true; $g.Since = $null; $g.Wait = $restartDelay } else { $g.Wanted = $false }
    if ($app.service) {
        Resolve-AppPath $app
        $command = if ($start) { if ($app.service.start) { $app.service.start } else { 'start' } } else { if ($app.service.stop) { $app.service.stop } else { 'stop' } }
        Invoke-InBackground $i 'service' @($app.path, $command)
    } elseif ($start) {
        if (-not (Test-Path $app.path)) { Show-Error "$($app.name): file not found:`n$($app.path)"; return $false }
        Invoke-InBackground $i 'start' @($app.path, $app.args)
    } else {
        Invoke-InBackground $i 'stop' @(, @(Get-AppProcess $app | ForEach-Object { $_.Id }))
    }
}

# ---- The panel: a grid of tiles on deep blue, one per program: logo, status, uptime, the last hour and a power button. ----
# Everything is drawn in Paint, laid out in 96-dpi units and scaled by $k for the screen.
$probe = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $k = $probe.DpiX / 96; $probe.Dispose()
function Get-Color($hex, $alpha = 255) { [System.Drawing.Color]::FromArgb($alpha, [System.Drawing.ColorTranslator]::FromHtml($hex)) }
$theme = @{
    bgTop = Get-Color '#0A1830'; bgBottom = Get-Color '#050B18'
    tileTop = Get-Color '#10223F' 235; tileBottom = Get-Color '#0B1830' 235; edge = Get-Color '#1D3355'; edgeOn = Get-Color '#22D3EE' 60
    text = Get-Color '#E8F1FF'; muted = Get-Color '#7F97BA'; faint = Get-Color '#4C6283'
    on = Get-Color '#22D3EE'; wait = Get-Color '#FBBF24'; off = Get-Color '#4A5F80'
    barOff = Get-Color '#1E2E48'; stripOff = Get-Color '#1C2D4A'; ringOff = Get-Color '#2A4066'; glyphOff = Get-Color '#6F87AD'
    pillFill = Get-Color '#22D3EE' 22; pillHover = Get-Color '#22D3EE' 48; pillEdge = Get-Color '#22D3EE' 150; pillText = Get-Color '#A5F3FC'
    dim = Get-Color '#081326' 160; highlight = Get-Color '#9FD8FF' 30
}
# Segoe UI Variable (Windows 11) with the classic Segoe UI as a fallback; Cascadia Mono for the small captions.
$installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families.Name
$display = if ($installed -contains 'Segoe UI Variable Display') { 'Segoe UI Variable Display' } else { 'Segoe UI' }
$body = if ($installed -contains 'Segoe UI Variable Text') { 'Segoe UI Variable Text' } else { 'Segoe UI' }
$mono = if ($installed -contains 'Cascadia Mono') { 'Cascadia Mono' } else { 'Consolas' }
function New-PxFont($family, $px, $style = 'Regular') { New-Object System.Drawing.Font($family, $px, [System.Drawing.FontStyle]$style, [System.Drawing.GraphicsUnit]::Pixel) }
$fonts = @{
    title = New-PxFont $display 21 'Bold'; sub = New-PxFont $body 13; button = New-PxFont $body 13 'Bold'
    name = New-PxFont $display 15.5 'Bold'; pill = New-PxFont $body 11.5 'Bold'; caption = New-PxFont $mono 9 'Bold'
    value = New-PxFont $display 22 'Bold'; valueSmall = New-PxFont $display 16 'Bold'
}
$brushes = @{}; foreach ($key in $theme.Keys) { $brushes[$key] = New-Object System.Drawing.SolidBrush($theme[$key]) }
$pens = @{ edge = New-Object System.Drawing.Pen($theme.edge); edgeOn = New-Object System.Drawing.Pen($theme.edgeOn); pill = New-Object System.Drawing.Pen($theme.pillEdge); tag = New-Object System.Drawing.Pen((Get-Color '#7F97BA' 120)); highlight = New-Object System.Drawing.Pen($theme.highlight) }
$nameFormat = New-Object System.Drawing.StringFormat; $nameFormat.Trimming = 'EllipsisCharacter'; $nameFormat.FormatFlags = 'NoWrap'
$centered = New-Object System.Drawing.StringFormat; $centered.Alignment = 'Center'; $centered.LineAlignment = 'Center'
$typo = [System.Drawing.StringFormat]::GenericTypographic
$stripBrushes = @{ on = New-Object System.Drawing.SolidBrush((Get-Color '#22D3EE' 210)); onDim = New-Object System.Drawing.SolidBrush((Get-Color '#22D3EE' 70)); wait = New-Object System.Drawing.SolidBrush((Get-Color '#FBBF24' 230)) }

$layout = @{ width = 520; top = 104; tileW = 231; tileH = 206; gap = 14; logo = 56; power = 21; strip = 40 }
$rowCount = [Math]::Ceiling($apps.Count / 2)
function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90); $p.AddArc($x + $w - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
    $p.AddArc($x + $w - 2 * $r, $y + $h - 2 * $r, 2 * $r, 2 * $r, 0, 90); $p.AddArc($x, $y + $h - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $p.CloseFigure(); $p
}
function Get-TileOrigin($i) { New-Object System.Drawing.PointF((22 + ($i % 2) * ($layout.tileW + $layout.gap)), ($layout.top + [Math]::Floor($i / 2) * ($layout.tileH + $layout.gap))) }
function Get-PowerCenter($i) { $o = Get-TileOrigin $i; New-Object System.Drawing.PointF(($o.X + $layout.tileW - 38), ($o.Y + 40)) }
function Get-PowerRect($i) { $c = Get-PowerCenter $i; New-Object System.Drawing.RectangleF(($c.X - 24), ($c.Y - 24), 48, 48) }
$startAllRect = New-Object System.Drawing.RectangleF(($layout.width - 126), 24, 104, 34)
# A soft round light (fades to nothing at its edge).
function Fill-Glow($g, [float]$cx, [float]$cy, [float]$r, $color, [int]$alpha) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath; $p.AddEllipse(($cx - $r), ($cy - $r), (2 * $r), (2 * $r))
    $b = New-Object System.Drawing.Drawing2D.PathGradientBrush($p)
    $b.CenterColor = [System.Drawing.Color]::FromArgb($alpha, $color); $b.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $color))
    $g.FillPath($b, $p); $b.Dispose(); $p.Dispose()
}
# Small capitals with letter spacing (GDI+ has none of its own).
# (Letter widths are measured once per font and letter.)
$letterWidths = @{}
function Draw-Spaced($g, [string]$text, $font, $brush, [float]$x, [float]$y, [float]$track) {
    foreach ($ch in $text.ToCharArray()) {
        $s = [string]$ch; $key = "$($font.Name)|$($font.Size)|$s"
        if (-not $letterWidths.ContainsKey($key)) { $letterWidths[$key] = $g.MeasureString($s, $font, 1000, $typo).Width + $(if ($s -eq ' ') { $font.Size * 0.3 } else { 0 }) }
        $g.DrawString($s, $font, $brush, $x, $y, $typo); $x += $letterWidths[$key] + $track
    }
    $x
}

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
    $g.SetClip((New-RoundRect 0 0 $size $size ($size * 0.27)))
    if ($src) { $g.DrawImage($src, 0, 0, $size, $size); $src.Dispose() }
    else {
        $hue = [Math]::Abs($app.name.GetHashCode()) % 6
        $g.Clear((Get-Color (@('#6366F1', '#0EA5E9', '#14B8A6', '#F59E0B', '#EC4899', '#8B5CF6')[$hue])))
        $g.TextRenderingHint = 'AntiAliasGridFit'
        $g.DrawString($app.name.Substring(0, 1).ToUpper(), (New-PxFont $display ($size * 0.5) 'Bold'), [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, $size, $size)), $centered)
    }
    $g.Dispose()
    $bmp
}
$logos = @(foreach ($app in $apps) { Get-Logo $app })

# What each tile shows; filled in by Update-Rows. The value (uptime / countdown) is worked out when drawing.
#   Until/Total: countdown end and length; Pending*: a click is waiting for the program to actually change;
#   History: one letter per 90 s for the last hour (1 running, 2 restarting, 0 off); StoppedAt: when it was seen stopping.
#   FadeFrom/FadeAt: the power button's colour when the state last changed, blended into the new one over 0.35 s.
$view = @(foreach ($app in $apps) { @{ State = 'off'; Line = 'Stopped'; Until = $null; Total = 0; Up = $null; Update = $false; PendingUntil = $null; PendingTarget = $null; History = ''; StoppedAt = $null; FadeFrom = $null; FadeAt = $null } })
$historyStep = 90; $lastSample = [DateTime]::MinValue
$hover = $null           # 'all' or a tile number while the mouse is over a button
$clock = [Diagnostics.Stopwatch]::StartNew()

$fadeTime = 0.35
# The power button's colour now: its state's colour, or on its way there after a change (eased out).
function Get-PowerColor($v, [double]$t) {
    $to = switch ($v.State) { 'on' { $theme.on } 'wait' { $theme.wait } default { $theme.ringOff } }
    if ($null -eq $v.FadeAt -or ($t - $v.FadeAt) -ge $fadeTime) { return $to }
    $f = 1.0 - [Math]::Pow(1.0 - ($t - $v.FadeAt) / $fadeTime, 2)
    $a = $v.FadeFrom
    [System.Drawing.Color]::FromArgb([int]($a.A + ($to.A - $a.A) * $f), [int]($a.R + ($to.R - $a.R) * $f), [int]($a.G + ($to.G - $a.G) * $f), [int]($a.B + ($to.B - $a.B) * $f))
}
# Call just before a tile's state changes: the fade starts from whatever colour is showing.
function Set-Fade($v) { $t = $clock.Elapsed.TotalSeconds; $v.FadeFrom = Get-PowerColor $v $t; $v.FadeAt = $t }
function Test-Fading($v) { $null -ne $v.FadeAt -and ($clock.Elapsed.TotalSeconds - $v.FadeAt) -lt $fadeTime }

function Format-Span([TimeSpan]$s) {
    if ($s.TotalMinutes -lt 1) { '<1m' }
    elseif ($s.TotalHours -lt 1) { '{0}m' -f [int][Math]::Floor($s.TotalMinutes) }
    elseif ($s.TotalDays -lt 1) { '{0}h {1}m' -f [int][Math]::Floor($s.TotalHours), $s.Minutes }
    else { '{0}d {1}h' -f [int][Math]::Floor($s.TotalDays), $s.Hours }
}
# The small caption and the big value under a tile's status.
function Get-Readout($v) {
    $now = Get-Date
    switch ($v.State) {
        'on' { if ($v.Up) { 'UPTIME', (Format-Span ($now - $v.Up)) } else { 'STATUS', 'Running' } }
        'off' { if ($v.StoppedAt) { 'LAST RAN', ((Format-Span ($now - $v.StoppedAt)) + ' ago') } else { 'STATUS', 'Stopped' } }
        default {
            if ($v.Until) {
                $left = [Math]::Max(0, [int][Math]::Ceiling(($v.Until - $now).TotalSeconds))
                $(if ($v.Line -eq 'Restarting') { 'BACK IN' } else { 'SWAP IN' }), "${left}s"
            } elseif ($v.Line -in 'Paused', 'Connecting') { 'CONNECTION', $v.Line }
            else { 'PLEASE WAIT', '...' }
        }
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Bridge Control'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = 'None'
$form.BackColor = $theme.bgTop
$form.ClientSize = New-Object System.Drawing.Size([int]($layout.width * $k), [int](($layout.top + $rowCount * ($layout.tileH + $layout.gap) - $layout.gap + 22) * $k))
# Draw into a back buffer so the tiles don't flicker.
$form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($form, $true)
$iconPath = Join-Path $PSScriptRoot 'icon.ico'
try {
    if (Test-Path $iconPath) { $form.Icon = New-Object System.Drawing.Icon($iconPath) }
    else { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($apps[0].path) }
} catch {}
# Dark title bar, coloured navy like the panel on Windows 11 (older versions keep their own colour).
$form.Add_HandleCreated({
    foreach ($pair in @(@(20, 1), @(35, 0x0030180A), @(34, 0x0055331D), @(36, 0x00FFF1E8))) {
        $value = $pair[1]; [void][BridgeControl.Native]::DwmSetWindowAttribute($form.Handle, $pair[0], [ref]$value, 4)
    }
})

# Everything that only changes with a status or the mouse is kept as pictures: the background (drawn once), one per tile
# (redrawn only when that tile changes) and the header, put together into one picture. Each frame then only adds the
# power buttons and the big values on top.
$static = @{ Key = $null; Bitmap = $null; Dirty = $true; Background = $null; Tiles = @{}; TileKeys = @{} }
function Get-TileKey($v) { "$($v.State)|$($v.Line)|$($v.Update)|$($v.History)|$([bool]$v.Up)|$([bool]$v.StoppedAt)|$([bool]$v.Until)" }
# Called whenever the statuses or the hovered button may have changed; the pictures are redrawn only if they did, and
# only the header and the tiles that changed are repainted.
function Update-StaticKey {
    $key = (@(foreach ($v in $view) { Get-TileKey $v }) -join ';') + "|$hover"
    if ($key -eq $static.Key) { return }
    $static.Key = $key; $static.Dirty = $true
    if (-not $form.Visible) { return }
    $form.Invalidate((New-Object System.Drawing.Rectangle(0, 0, $form.ClientSize.Width, [int](($layout.top - 4) * $k))))
    for ($i = 0; $i -lt $apps.Count; $i++) {
        if ($static.TileKeys[$i] -eq (Get-TileKey $view[$i])) { continue }
        $o = Get-TileOrigin $i
        $form.Invalidate((New-Object System.Drawing.Rectangle([int](($o.X - 2) * $k), [int](($o.Y - 2) * $k), [int](($layout.tileW + 4) * $k), [int](($layout.tileH + 4) * $k))))
    }
}
function Invalidate-Power($i) {
    if ("$i" -notmatch '^\d+$') { return }
    $c = Get-PowerCenter ([int]$i)
    $form.Invalidate((New-Object System.Drawing.Rectangle([int](($c.X - 38) * $k), [int](($c.Y - 38) * $k), [int](76 * $k), [int](76 * $k))))
}
function Set-Quality($g) { $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality' }
function Draw-Background($g) {
    $W = $layout.width; $H = $form.ClientSize.Height / $k
    $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF(0, $H)), $theme.bgTop, $theme.bgBottom)
    $g.FillRectangle($bg, 0, 0, $W, $H); $bg.Dispose()
    Fill-Glow $g ($W - 60) 10 230 $theme.on 34
    Fill-Glow $g 40 ($H - 20) 220 (Get-Color '#3B82F6') 26
}
function Draw-Header($g) {
    $W = $layout.width
    # Header: title, how many are online, Start all / Stop all, one bar segment per program.
    $online = @($view | Where-Object { $_.State -eq 'on' }).Count
    $g.DrawString('Bridge Control', $fonts.title, $brushes.text, 22, 20)
    $g.DrawString("$online of $($apps.Count) online", $fonts.sub, $brushes.muted, 23, 50)
    # Stop all when every program is online, otherwise Start all (greyed when nothing is off).
    $allOn = $online -eq $apps.Count
    $usable = $allOn -or @($view | Where-Object { $_.State -eq 'off' }).Count -gt 0
    $pill = New-RoundRect $startAllRect.X $startAllRect.Y $startAllRect.Width $startAllRect.Height 17
    $g.FillPath($(if ($usable -and "$hover" -eq 'all') { $brushes.pillHover } else { $brushes.pillFill }), $pill); $g.DrawPath($pens.pill, $pill)
    $g.DrawString($(if ($allOn) { 'Stop all' } else { 'Start all' }), $fonts.button, $(if ($usable) { $brushes.pillText } else { $brushes.faint }), $startAllRect, $centered)
    $segW = ($W - 44 - 6 * ($apps.Count - 1)) / $apps.Count; $sx = 22
    foreach ($v in $view) { $g.FillPath($(if ($v.State -eq 'off') { $brushes.barOff } else { $brushes[$v.State] }), (New-RoundRect $sx 82 $segW 5 2.5)); $sx += $segW + 6 }
}
function Draw-Tile($g, $i) {
    $v = $view[$i]; $o = Get-TileOrigin $i; $x = $o.X; $y = $o.Y; $tw = $layout.tileW
    $off = $v.State -eq 'off'
    $tile = New-RoundRect $x $y $tw $layout.tileH 18
    $tb = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF(0, $y)), (New-Object System.Drawing.PointF(0, ($y + $layout.tileH))), $theme.tileTop, $theme.tileBottom)
    $g.FillPath($tb, $tile); $tb.Dispose()
    $g.SetClip($tile); $g.DrawLine($pens.highlight, ($x + 18), ($y + 0.5), ($x + $tw - 18), ($y + 0.5)); $g.ResetClip()
    $g.DrawPath($(if ($v.State -eq 'on') { $pens.edgeOn } else { $pens.edge }), $tile)

    # Logo with a cyan halo when online, faded when off.
    $lx = $x + 18; $ly = $y + 18
    if ($v.State -eq 'on') { Fill-Glow $g ($lx + 28) ($ly + 28) 46 $theme.on 46 }
    $g.DrawImage($logos[$i], $lx, $ly, $layout.logo, $layout.logo)
    if ($off) { $g.FillPath($brushes.dim, (New-RoundRect $lx $ly $layout.logo $layout.logo 15)) }

    # Name, status pill, then SERVICE / UPDATE tags.
    $g.DrawString($apps[$i].name, $fonts.name, $(if ($off) { $brushes.muted } else { $brushes.text }), (New-Object System.Drawing.RectangleF(($x + 17), ($y + 86), ($tw - 30), 24)), $nameFormat)
    $color = $theme[$v.State]
    $pw = $g.MeasureString($v.Line, $fonts.pill, 1000, $typo).Width + 26
    $g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(36, $color))), (New-RoundRect ($x + 18) ($y + 114) $pw 22 11))
    $g.FillEllipse($brushes[$v.State], ($x + 27), ($y + 122), 6, 6)
    $g.DrawString($v.Line, $fonts.pill, $(if ($off) { New-Object System.Drawing.SolidBrush((Get-Color '#8EA3C4')) } else { $brushes[$v.State] }), ($x + 37), ($y + 117), $typo)
    $tx = $x + 24 + $pw
    foreach ($tag in @($(if ($apps[$i].service) { 'SERVICE' }), $(if ($v.Update) { 'UPDATE' })) | Where-Object { $_ }) {
        $tagW = $g.MeasureString($tag, $fonts.caption, 1000, $typo).Width + $tag.Length * 0.9 + 18
        if ($tx + $tagW -gt $x + $tw - 12) { break }
        $g.DrawPath($(if ($tag -eq 'UPDATE') { $pens.pill } else { $pens.tag }), (New-RoundRect $tx ($y + 114) $tagW 22 11))
        [void](Draw-Spaced $g $tag $fonts.caption $(if ($tag -eq 'UPDATE') { $brushes.pillText } else { $brushes.muted }) ($tx + 9) ($y + 119) 0.9)
        $tx += $tagW + 6
    }

    # The caption over the big value (the value itself changes by the second, so it is drawn each frame).
    [void](Draw-Spaced $g (Get-Readout $v)[0] $fonts.caption $brushes.faint ($x + 18) ($y + 148) 1.4)

    # The last hour, one bar per 90 s, newest on the right.
    $bars = $v.History.PadLeft($layout.strip, ' ')
    $bx = $x + $tw - 18 - $layout.strip * 2.5
    foreach ($c in $bars.ToCharArray()) {
        $bar = switch ($c) { '1' { if ($off) { $stripBrushes.onDim } else { $stripBrushes.on } } '2' { $stripBrushes.wait } default { $brushes.stripOff } }
        $g.FillRectangle($bar, $bx, ($y + 176), 1.6, 12); $bx += 2.5
    }

}
# A transparent picture covering part of the window (in layout units), with a Graphics that draws in layout units.
function New-Canvas([float]$x, [float]$y, [float]$w, [float]$h) {
    $px = [int][Math]::Floor($x * $k); $py = [int][Math]::Floor($y * $k)
    $bmp = New-Object System.Drawing.Bitmap(([int][Math]::Ceiling(($x + $w) * $k) - $px), ([int][Math]::Ceiling(($y + $h) * $k) - $py))
    $g = [System.Drawing.Graphics]::FromImage($bmp); Set-Quality $g
    $g.Transform = New-Object System.Drawing.Drawing2D.Matrix($k, 0, 0, $k, (-$px), (-$py))
    @{ Bitmap = $bmp; Graphics = $g; X = $px; Y = $py }
}
function Update-StaticPicture {
    if (-not $static.Background) {
        $c = New-Canvas 0 0 $layout.width ($form.ClientSize.Height / $k); Draw-Background $c.Graphics; $c.Graphics.Dispose(); $static.Background = $c
    }
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $tk = Get-TileKey $view[$i]
        if ($static.TileKeys[$i] -eq $tk -and $static.Tiles[$i]) { continue }
        if ($static.Tiles[$i]) { $static.Tiles[$i].Bitmap.Dispose() }
        $o = Get-TileOrigin $i
        $c = New-Canvas ($o.X - 2) ($o.Y - 2) ($layout.tileW + 4) ($layout.tileH + 4); Draw-Tile $c.Graphics $i; $c.Graphics.Dispose()
        $static.Tiles[$i] = $c; $static.TileKeys[$i] = $tk
    }
    if (-not $static.Bitmap) { $static.Bitmap = New-Object System.Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height) }
    $g = [System.Drawing.Graphics]::FromImage($static.Bitmap)
    $g.DrawImageUnscaled($static.Background.Bitmap, 0, 0)
    Set-Quality $g; $g.ScaleTransform($k, $k); Draw-Header $g; $g.ResetTransform()
    foreach ($p in $static.Tiles.Values) { $g.DrawImageUnscaled($p.Bitmap, $p.X, $p.Y) }
    $g.Dispose(); $static.Dirty = $false
}
# The power symbol: an open ring with a bar through the gap.
function Draw-PowerGlyph($g, [float]$cx, [float]$cy, [float]$r, $color, [float]$w) {
    $pen = New-Object System.Drawing.Pen($color, $w); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawArc($pen, ($cx - $r), ($cy - $r), (2 * $r), (2 * $r), -60, 300)
    $g.DrawLine($pen, $cx, ($cy - $r - 1), $cx, ($cy - 1)); $pen.Dispose()
}

$form.Add_Paint({
    $g = $_.Graphics; $clip = $_.ClipRectangle
    if ($static.Dirty -or -not $static.Bitmap) { Update-StaticPicture }

    $g.DrawImageUnscaled($static.Bitmap, 0, 0)

    Set-Quality $g
    $g.ScaleTransform($k, $k)
    $t = $clock.Elapsed.TotalSeconds
    # Online buttons breathe slowly (2.4 s); a countdown fills the ring; waiting without one spins.
    $pulse = 0.5 + 0.5 * [Math]::Sin($t * 2 * [Math]::PI / 2.4)
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $v = $view[$i]; $o = Get-TileOrigin $i; $c = Get-PowerCenter $i; $r = $layout.power
        # Skip tiles outside the area being redrawn (most frames only one tile's button changes).
        if (-not $clip.IntersectsWith((New-Object System.Drawing.Rectangle([int]($o.X * $k), [int]($o.Y * $k), [int]($layout.tileW * $k), [int]($layout.tileH * $k))))) { continue }
        $color = Get-PowerColor $v $t; $hot = "$hover" -eq "$i"
        switch ($v.State) {
            'on' {
                Fill-Glow $g $c.X $c.Y 36 $color ([int](45 + 50 * $pulse + $(if ($hot) { 40 } else { 0 })))
                $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($(if ($hot) { 70 } else { 40 }), $color))), ($c.X - $r), ($c.Y - $r), (2 * $r), (2 * $r))
                $g.DrawEllipse((New-Object System.Drawing.Pen($color, 2)), ($c.X - $r), ($c.Y - $r), (2 * $r), (2 * $r))
                Draw-PowerGlyph $g $c.X ($c.Y + 1) 8 $color 2.4
            }
            'wait' {
                $g.DrawEllipse((New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(50, $color), 2.5)), ($c.X - $r), ($c.Y - $r), (2 * $r), (2 * $r))
                $arc = New-Object System.Drawing.Pen($color, 2.5); $arc.StartCap = 'Round'; $arc.EndCap = 'Round'
                if ($v.Until -and $v.Total -gt 0) {
                    # (1.0 / 0.0 / 2.0: with plain 1 PowerShell picks the whole-number Min and rounds the fraction away)
                    $done = 1.0 - [Math]::Max(0.0, ($v.Until - (Get-Date)).TotalSeconds) / $v.Total
                    $sweep = [Math]::Max(2.0, 360.0 * [Math]::Min(1.0, $done))
                    $g.DrawArc($arc, ($c.X - $r), ($c.Y - $r), (2 * $r), (2 * $r), -90, $sweep)
                } else {
                    $g.DrawArc($arc, ($c.X - $r), ($c.Y - $r), (2 * $r), (2 * $r), (($t * 300) % 360), 90)
                }
                $arc.Dispose()
                Draw-PowerGlyph $g $c.X ($c.Y + 1) 8 $color 2.4
            }
            default {
                if ($hot) { Fill-Glow $g $c.X $c.Y 34 $theme.on 50 }
                $g.DrawEllipse((New-Object System.Drawing.Pen($(if ($hot) { $theme.on } else { $color }), 2)), ($c.X - $r), ($c.Y - $r), (2 * $r), (2 * $r))
                Draw-PowerGlyph $g $c.X ($c.Y + 1) 8 $(if ($hot) { $theme.on } elseif (Test-Fading $v) { $color } else { $theme.glyphOff }) 2.4
            }
        }
        $value = (Get-Readout $v)[1]
        # A long value ("3h 20m ago") gets the smaller size so it stays clear of the hour strip.
        $room = $layout.tileW - 18 - $layout.strip * 2.5 - 30
        $big = $g.MeasureString($value, $fonts.value, 1000, $typo).Width -le $room
        $g.DrawString($value, $(if ($big) { $fonts.value } else { $fonts.valueSmall }), $(if ($v.State -eq 'off') { $brushes.muted } else { $brushes.text }), ($o.X + 16), ($o.Y + $(if ($big) { 160 } else { 166 })))
    }
})

function Get-HitTarget($e) {
    $p = New-Object System.Drawing.PointF(($e.X / $k), ($e.Y / $k))
    if ($startAllRect.Contains($p)) { return 'all' }
    for ($i = 0; $i -lt $apps.Count; $i++) { if ((Get-PowerRect $i).Contains($p)) { return $i } }
    $null
}
$form.Add_MouseMove({
    $target = Get-HitTarget $_
    if ("$target" -ne "$script:hover") {
        $was = $script:hover; $script:hover = $target
        $form.Cursor = if ($null -ne $target) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
        Update-StaticKey; Invalidate-Power $was; Invalidate-Power $target
    }
})
$form.Add_MouseLeave({ if ($null -ne $script:hover) { $was = $script:hover; $script:hover = $null; $form.Cursor = [System.Windows.Forms.Cursors]::Default; Update-StaticKey; Invalidate-Power $was } })
# A button acts when the mouse is pressed and released on it.
$pressed = $null
$form.Add_MouseDown({ if ($_.Button -eq 'Left') { $script:pressed = Get-HitTarget $_ } })
$form.Add_MouseUp({
    if ($_.Button -ne 'Left') { return }
    $target = Get-HitTarget $_
    $wasPressed = $script:pressed; $script:pressed = $null
    if ($null -eq $target -or "$target" -ne "$wasPressed") { return }
    # Stop all (every program online) stops them all; Start all starts every program that is off; a tile's power
    # button starts it when off and stops it otherwise.
    $allRows = @(0..($apps.Count - 1))
    $rowsHit = if ("$target" -ne 'all') { @($target) }
               elseif (@($allRows | Where-Object { $view[$_].State -ne 'on' }).Count -eq 0) { $allRows }
               else { @($allRows | Where-Object { $view[$_].State -eq 'off' }) }
    $starting = @{}; foreach ($i in $rowsHit) { $starting[$i] = $view[$i].State -eq 'off' }
    # Show the change at once and keep showing it until the program has really changed (a service's own command
    # can take a few seconds), or for 30 s at most.
    foreach ($i in $rowsHit) {
        Set-Fade $view[$i]
        $view[$i].Line = if ($starting[$i]) { 'Starting' } else { 'Stopping' }
        $view[$i].State = 'wait'; $view[$i].Until = $null
        $view[$i].PendingTarget = if ($starting[$i]) { 'on' } else { 'off' }; $view[$i].PendingUntil = (Get-Date).AddSeconds(30)
    }
    Update-StaticKey; $form.Update()     # paint the changed tile now, before the work starts
    # The work runs in the background; Complete-Jobs updates the tiles when it is done.
    foreach ($i in $rowsHit) { if ((Request-Change $i $starting[$i]) -eq $false) { $view[$i].PendingUntil = $null } }
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
    $online = 0; $now = Get-Date
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $app = $apps[$i]; $g = $guard[$i]; $v = $view[$i]
        $before = $v.State; $beforeColor = Get-PowerColor $v $clock.Elapsed.TotalSeconds
        $procs = @(Get-AppProcess $app)
        $watched = $app.keepRunning -and -not $app.service -and $g.Wanted
        $v.Until = $null; $v.Total = 0; $v.Up = $null; $v.Update = $false
        if ($procs.Count -gt 0 -and $app.service) {
            # A service's own status file says whether it is connected or paused, since when, and about updates.
            $st = Read-ServiceStatus $app
            $v.Update = [bool]($st -and $st.updateAvailable)
            if ($st -and $st.paused) { $v.State = 'wait'; $v.Line = 'Paused' }
            elseif ($st -and $st.cloudState -and $st.cloudState -ne 'online') { $v.State = 'wait'; $v.Line = 'Connecting' }
            else {
                $v.State = 'on'; $v.Line = 'Online'
                if ($st -and $st.lastConnectedAt) { try { $v.Up = [DateTime]::Parse($st.lastConnectedAt, $null, 'RoundtripKind').ToLocalTime() } catch {} }
            }
        } elseif ($procs.Count -gt 0) {
            $v.Up = $procs | ForEach-Object { try { $_.StartTime } catch {} } | Sort-Object | Select-Object -First 1
            if ($watched -and @($procs | Where-Object { -not (Test-Owned $_) }).Count -gt 0) {
                # Running in a copy Bridge Control didn't start: it will be swapped for a hidden one.
                $v.State = 'wait'; $v.Line = 'Switching to hidden'
                if ($g.Since) { $v.Total = [Math]::Max($takeoverDelay, $g.Wait); $v.Until = $g.Since.AddSeconds($v.Total) }
            } else { $v.State = 'on'; $v.Line = 'Online' }
        } elseif ($watched) {
            $v.State = 'wait'; $v.Line = 'Restarting'
            if ($g.Since) { $v.Total = $g.Wait; $v.Until = $g.Since.AddSeconds($g.Wait) }
        } else { $v.State = 'off'; $v.Line = 'Stopped' }

        # After a click, keep showing Starting / Stopping until the program really got there (or 30 s passed).
        if ($v.PendingUntil) {
            if ($now -lt $v.PendingUntil -and $v.State -ne $v.PendingTarget) {
                $v.State = 'wait'; $v.Line = if ($v.PendingTarget -eq 'on') { 'Starting' } else { 'Stopping' }; $v.Until = $null
            } else { $v.PendingUntil = $null }
        }
        if ($v.State -ne $before) { $v.FadeFrom = $beforeColor; $v.FadeAt = $clock.Elapsed.TotalSeconds }
        if ($v.State -eq 'off' -and $before -ne 'off') { $v.StoppedAt = $now }
        if ($v.State -eq 'on') { $online++ }
    }
    # The last hour: one sample every 90 s.
    if (($now - $script:lastSample).TotalSeconds -ge $historyStep) {
        $script:lastSample = $now
        foreach ($v in $view) {
            $v.History += switch ($v.State) { 'on' { '1' } 'wait' { '2' } default { '0' } }
            if ($v.History.Length -gt $layout.strip) { $v.History = $v.History.Substring($v.History.Length - $layout.strip) }
        }
    }
    Update-StaticKey
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

# Picks up finished Start / Stop work, and redraws the open panel: ~30 frames a second while something moves (a
# spinner, a countdown, a colour fade), ~10 otherwise for the breathing buttons and the uptimes.
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 100
$animTick = 0
$animTimer.Add_Tick({
    if ($jobs.Count) { Complete-Jobs }
    if (-not $form.Visible -or $form.WindowState -eq 'Minimized') { $animTimer.Interval = 100; return }
    $script:animTick++
    $moving = @(for ($i = 0; $i -lt $apps.Count; $i++) { $view[$i].State -eq 'wait' -or (Test-Fading $view[$i]) })
    $fast = $jobs.Count -gt 0 -or $moving -contains $true
    # (Windows timers tick in ~15.6 ms steps: 25 ms comes out at ~31 ms, i.e. ~30 frames a second.)
    $animTimer.Interval = if ($fast) { 25 } else { 100 }
    # Only the power buttons and the big values move; redraw just those areas. When fast, calm tiles every 3rd frame.
    for ($i = 0; $i -lt $apps.Count; $i++) {
        if ($fast -and -not $moving[$i] -and $script:animTick % 3) { continue }
        $o = Get-TileOrigin $i; $c = Get-PowerCenter $i
        $form.Invalidate((New-Object System.Drawing.Rectangle([int](($c.X - 38) * $k), [int](($c.Y - 38) * $k), [int](76 * $k), [int](76 * $k))))
        $form.Invalidate((New-Object System.Drawing.Rectangle([int](($o.X + 12) * $k), [int](($o.Y + 156) * $k), [int](110 * $k), [int](36 * $k))))
    }
})
$animTimer.Start()

Update-Rows
$context = New-Object System.Windows.Forms.ApplicationContext
# At login it waits in the tray; opened by hand it shows the panel.
if (-not $Autostart) { Show-Panel }
[System.Windows.Forms.Application]::Run($context)

$timer.Stop(); $signalTimer.Stop(); $animTimer.Stop()
$pool.Close()
$tray.Dispose()
foreach ($icon in $trayIcons.Values) { [void][BridgeControl.Native]::DestroyIcon($icon.Handle) }
$mutex.ReleaseMutex()
