# install.ps1 - Steam Status Scheduler
#
# Instala (ou atualiza) o Steam Status Scheduler em %LOCALAPPDATA%\SteamStatusScheduler
# e registra uma tarefa agendada que inicia o script, sem janela, no logon do Windows.
#
# Dois jeitos de rodar:
#   1) Da pasta baixada:   duplo clique em Instalar.bat
#   2) Direto da internet: irm https://raw.githubusercontent.com/IvanPJ/steam-status-scheduler/main/install.ps1 | iex
#
# Reinstalar e seguro: o config.json existente (seus horarios) e mantido.

$RepoRaw    = 'https://raw.githubusercontent.com/IvanPJ/steam-status-scheduler/main'
$TaskName   = 'SteamStatusScheduler'
$InstallDir = Join-Path $env:LOCALAPPDATA 'SteamStatusScheduler'
$Files      = @('SteamStatusScheduler.ps1', 'install.ps1', 'uninstall.ps1', 'Instalar.bat', 'Desinstalar.bat', 'Editar-horarios.bat', 'Ver-status.bat', 'README.md')
$ConfigFile = 'config.json'

function Stop-SchedulerInstances {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*SteamStatusScheduler.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Install-SteamStatusScheduler {
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        Write-Host ''
        Write-Host '=== Steam Status Scheduler - instalacao ==='
        Write-Host ''

        $sourceDir = $null
        if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'SteamStatusScheduler.ps1'))) {
            $sourceDir = (Resolve-Path $PSScriptRoot).Path.TrimEnd('\')
        }
        $sameFolder = $sourceDir -and ($sourceDir -eq $InstallDir.TrimEnd('\'))

        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        Stop-SchedulerInstances

        if ($sameFolder) {
            Write-Host "Arquivos ja estao em $InstallDir"
        } else {
            if ($sourceDir) {
                Write-Host "Copiando arquivos de $sourceDir ..."
            } else {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Write-Host "Baixando arquivos de $RepoRaw ..."
            }
            foreach ($name in ($Files + $ConfigFile)) {
                $dest = Join-Path $InstallDir $name
                if ($name -eq $ConfigFile -and (Test-Path $dest)) {
                    Write-Host "  $name (mantido, ja existia)"
                    continue
                }
                if ($sourceDir) {
                    Copy-Item -Path (Join-Path $sourceDir $name) -Destination $dest -Force
                } else {
                    Invoke-WebRequest -UseBasicParsing -Uri "$RepoRaw/$name" -OutFile $dest
                }
                Write-Host "  $name"
            }
        }

        $scriptPath = Join-Path $InstallDir 'SteamStatusScheduler.ps1'
        $action   = New-ScheduledTaskAction -Execute 'conhost.exe' `
            -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`""
        $trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
            -MultipleInstances IgnoreNew `
            -StartWhenAvailable
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
            -Description 'Steam Status Scheduler: troca o status da Steam nos horarios do config.json' -Force | Out-Null
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 2
        $state = (Get-ScheduledTask -TaskName $TaskName).State

        Write-Host ''
        Write-Host "Instalado! Tarefa '$TaskName': $state"
        Write-Host "Pasta: $InstallDir"
        Write-Host '  - Editar-horarios.bat  -> muda os dias/horarios (config.json)'
        Write-Host '  - Ver-status.bat       -> mostra se esta rodando e o log'
        Write-Host '  - Desinstalar.bat      -> remove tudo'
        Write-Host ''
    } finally {
        $ErrorActionPreference = $previousEap
    }
}

Install-SteamStatusScheduler
