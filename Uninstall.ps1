# Removes the shortcuts made by Install.ps1. Your programs, this folder and apps.json are left alone.
$links = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Bridge Control.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Startup')) 'Bridge Control (autostart).lnk')
)
foreach ($link in $links) {
    if (Test-Path $link) { Remove-Item $link; Write-Host "Removed $link" }
}
Write-Host 'Bridge Control shortcuts removed. Programs that are running keep running; stop them first if you want.'
