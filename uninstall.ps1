# uninstall.ps1 - remove a tarefa agendada, o atalho e a pasta %LOCALAPPDATA%\SteamStatusScheduler

$TaskName     = 'SteamStatusScheduler'
$InstallDir   = Join-Path $env:LOCALAPPDATA 'SteamStatusScheduler'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Steam Status Scheduler.lnk'
$ErrorActionPreference = 'SilentlyContinue'

# se o agendador tinha deixado voce invisivel, volta pra online antes de sair
$statePath = Join-Path $InstallDir 'state.json'
if (Test-Path $statePath) {
    $state = Get-Content -Raw $statePath | ConvertFrom-Json
    if ($state.appliedWindow) { Start-Process 'steam://friends/status/online' }
}

Stop-ScheduledTask -TaskName $TaskName
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Remove-Item -Path $ShortcutPath -Force
Write-Host "Tarefa '$TaskName' e atalho do Menu Iniciar removidos."

if (Test-Path $InstallDir) {
    # este script pode estar dentro da pasta, entao ela e apagada alguns segundos depois de sair
    Start-Process cmd.exe -ArgumentList "/c timeout /t 3 /nobreak >nul & rmdir /s /q `"$InstallDir`"" -WindowStyle Hidden
    Write-Host "A pasta $InstallDir sera apagada em alguns segundos."
}
