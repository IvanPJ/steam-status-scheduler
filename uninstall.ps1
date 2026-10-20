# uninstall.ps1 - remove as tarefas agendadas, o atalho e a pasta %LOCALAPPDATA%\SteamStatusScheduler

$InstallDir   = Join-Path $env:LOCALAPPDATA 'SteamStatusScheduler'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Steam Status Scheduler.lnk'
$ErrorActionPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'Tarefas.ps1')
Remove-SssTasks
[void](Remove-SssLegacy)
Remove-Item -Path $ShortcutPath -Force
Write-Host 'Tarefas agendadas e atalho do Menu Iniciar removidos.'

# volta pra online, caso uma janela estivesse ativa
$steam = Get-SssSteamExe
if ($steam -and (Get-Process steam -ErrorAction SilentlyContinue)) { Start-Process -FilePath $steam -ArgumentList '-silent steam://friends/status/online' }

if (Test-Path $InstallDir) {
    # este script pode estar dentro da pasta, entao ela e apagada alguns segundos depois de sair
    Start-Process cmd.exe -ArgumentList "/c timeout /t 3 /nobreak >nul & rmdir /s /q `"$InstallDir`"" -WindowStyle Hidden
    Write-Host "A pasta $InstallDir sera apagada em alguns segundos."
}
