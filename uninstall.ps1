# uninstall.ps1 - remove a tarefa agendada e a pasta %LOCALAPPDATA%\SteamStatusScheduler

$TaskName   = 'SteamStatusScheduler'
$InstallDir = Join-Path $env:LOCALAPPDATA 'SteamStatusScheduler'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Steam Status Scheduler.lnk'
$ErrorActionPreference = 'SilentlyContinue'

# if the scheduler had set a status, put the user back online before leaving
$statePath = Join-Path $InstallDir 'state.json'
if (Test-Path $statePath) {
    $state = Get-Content -Raw $statePath | ConvertFrom-Json
    if ($state.appliedWindow) { Start-Process 'steam://friends/status/online' }
}

Stop-ScheduledTask -TaskName $TaskName
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*SteamStatusScheduler.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Remove-Item -Path $ShortcutPath -Force
Write-Host "Tarefa '$TaskName' e atalho do Menu Iniciar removidos."

if (Test-Path $InstallDir) {
    # this script may live inside the folder, so the folder is deleted a few seconds after we exit
    Start-Process cmd.exe -ArgumentList "/c timeout /t 3 /nobreak >nul & rmdir /s /q `"$InstallDir`"" -WindowStyle Hidden
    Write-Host "A pasta $InstallDir sera apagada em alguns segundos."
}
