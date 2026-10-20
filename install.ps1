# install.ps1 - Steam Status Scheduler
#
# Instala (ou atualiza) em %LOCALAPPDATA%\SteamStatusScheduler e cria as tarefas agendadas.
# Cada janela de horario vira duas tarefas do Agendador do Windows que chamam a propria Steam
# (steam.exe steam://friends/status/...). Nao fica nenhum programa rodando em segundo plano.
#
# Como usar: extraia o ZIP e de duplo clique em Instalar.bat. Nao precisa de administrador.
# Reinstalar e seguro: o config.json existente (seus horarios) e mantido.

$InstallDir   = Join-Path $env:LOCALAPPDATA 'SteamStatusScheduler'
$Files        = @('Configurar.ps1', 'Tarefas.ps1', 'install.ps1', 'uninstall.ps1', 'Instalar.bat', 'Configurar.bat', 'Desinstalar.bat', 'README.md')
$ConfigFile   = 'config.json'
$Obsolete     = @('Editar-horarios.bat', 'Ver-status.bat', 'SteamStatusScheduler.ps1', 'state.json', 'heartbeat', 'scheduler.log')
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Steam Status Scheduler.lnk'
$PowerShell   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function New-StartMenuShortcut {
    $steamExe = Get-SssSteamExe
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($ShortcutPath)
    $lnk.TargetPath = $PowerShell
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $InstallDir 'Configurar.ps1') + '"'
    $lnk.WorkingDirectory = $InstallDir
    $lnk.WindowStyle = 7
    $lnk.Description = 'Configurar o Steam Status Scheduler'
    if ($steamExe) { $lnk.IconLocation = $steamExe + ',0' }
    $lnk.Save()
}

function Install-SteamStatusScheduler {
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        Write-Host ''
        Write-Host '=== Steam Status Scheduler - instalacao ==='
        Write-Host ''

        $sourceDir = $null
        if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'Tarefas.ps1'))) { $sourceDir = (Resolve-Path $PSScriptRoot).Path.TrimEnd('\') }
        if (-not $sourceDir) { throw 'Rode este instalador de dentro da pasta extraida do ZIP (os outros arquivos precisam estar junto).' }
        . (Join-Path $sourceDir 'Tarefas.ps1')
        if (-not (Get-SssSteamExe)) { throw 'Nao achei a Steam instalada neste usuario.' }

        if (Remove-SssLegacy) { Write-Host 'Versao antiga (servico em segundo plano) removida.' }

        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        if ($sourceDir -ne $InstallDir.TrimEnd('\')) {
            Write-Host "Copiando arquivos de $sourceDir ..."
            foreach ($name in ($Files + $ConfigFile)) {
                $dest = Join-Path $InstallDir $name
                if ($name -eq $ConfigFile -and (Test-Path $dest)) { Write-Host "  $name (mantido, ja existia)"; continue }
                Copy-Item -Path (Join-Path $sourceDir $name) -Destination $dest -Force
                Write-Host "  $name"
            }
        }
        foreach ($name in $Obsolete) { Remove-Item -Path (Join-Path $InstallDir $name) -Force -ErrorAction SilentlyContinue }

        $cfg = Get-Content -Raw -Path (Join-Path $InstallDir $ConfigFile) | ConvertFrom-Json
        $default = 'online'; if ($cfg.defaultStatus) { $default = [string]$cfg.defaultStatus }
        $count = Sync-SssTasks -Windows @($cfg.windows) -DefaultStatus $default
        $applied = Invoke-SssApplyNow -Windows @($cfg.windows) -DefaultStatus $default
        if ($applied) { Write-Host "Voce esta dentro de uma janela agora: status aplicado ($applied)." }

        $shortcutOk = $true
        try { New-StartMenuShortcut } catch { $shortcutOk = $false; Write-Host "Aviso: nao consegui criar o atalho do Menu Iniciar. Use o Configurar.bat." -ForegroundColor Yellow }

        Write-Host ''
        Write-Host "Instalado! $count tarefas agendadas na pasta SteamStatusScheduler do Agendador de Tarefas."
        Write-Host "Pasta: $InstallDir"
        if ($shortcutOk) { Write-Host '  - Menu Iniciar > "Steam Status Scheduler"  -> janela de configuracao' }
        Write-Host '  - Configurar.bat                           -> janela de configuracao'
        Write-Host '  - Desinstalar.bat                          -> remove tudo'
        Write-Host ''

        $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not $env:SSS_NO_UI
        if ($interactive) {
            Write-Host 'Abrindo a janela de configuracao...'
            Start-Process -FilePath $PowerShell -WindowStyle Minimized `
                -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $InstallDir 'Configurar.ps1') + '"')
        }
    } finally {
        $ErrorActionPreference = $previousEap
    }
}

Install-SteamStatusScheduler
