# install.ps1 - Steam Status Scheduler
#
# Instala (ou atualiza) o Steam Status Scheduler em %LOCALAPPDATA%\SteamStatusScheduler
# e registra uma tarefa agendada que inicia o script, com janela oculta, no logon do Windows.
#
# Como usar: extraia o ZIP e de duplo clique em Instalar.bat (ou rode este arquivo no PowerShell).
# Reinstalar e seguro: o config.json existente (seus horarios) e mantido.
# Nao baixa nada da internet: copia apenas os arquivos que estao nesta pasta.

$TaskName     = 'SteamStatusScheduler'
$InstallDir   = Join-Path $env:LOCALAPPDATA 'SteamStatusScheduler'
$Files        = @('SteamStatusScheduler.ps1', 'Configurar.ps1', 'install.ps1', 'uninstall.ps1', 'Instalar.bat', 'Configurar.bat', 'Desinstalar.bat', 'README.md')
$ConfigFile   = 'config.json'
$Obsolete     = @('Editar-horarios.bat', 'Ver-status.bat')
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Steam Status Scheduler.lnk'
$PowerShell   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function New-StartMenuShortcut {
    # "Steam Status Scheduler" no Menu Iniciar abre a janela de configuracao
    $steamExe = $null
    try { $steamExe = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamExe -replace '/', '\' } catch { }
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($ShortcutPath)
    $lnk.TargetPath = $PowerShell
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $InstallDir 'Configurar.ps1') + '"'
    $lnk.WorkingDirectory = $InstallDir
    $lnk.WindowStyle = 7
    $lnk.Description = 'Configurar o Steam Status Scheduler'
    if ($steamExe -and (Test-Path $steamExe)) { $lnk.IconLocation = $steamExe + ',0' }
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
        if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'SteamStatusScheduler.ps1'))) {
            $sourceDir = (Resolve-Path $PSScriptRoot).Path.TrimEnd('\')
        }
        if (-not $sourceDir) { throw 'Rode este instalador de dentro da pasta extraida do ZIP (os outros arquivos precisam estar junto).' }
        $sameFolder = ($sourceDir -eq $InstallDir.TrimEnd('\'))

        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }

        if ($sameFolder) {
            Write-Host "Arquivos ja estao em $InstallDir"
        } else {
            Write-Host "Copiando arquivos de $sourceDir ..."
            foreach ($name in ($Files + $ConfigFile)) {
                $dest = Join-Path $InstallDir $name
                if ($name -eq $ConfigFile -and (Test-Path $dest)) {
                    Write-Host "  $name (mantido, ja existia)"
                    continue
                }
                Copy-Item -Path (Join-Path $sourceDir $name) -Destination $dest -Force
                Write-Host "  $name"
            }
        }
        foreach ($name in $Obsolete) { Remove-Item -Path (Join-Path $InstallDir $name) -Force -ErrorAction SilentlyContinue }

        $scriptPath = Join-Path $InstallDir 'SteamStatusScheduler.ps1'
        $action   = New-ScheduledTaskAction -Execute $PowerShell `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
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

        try { New-StartMenuShortcut; $shortcutOk = $true }
        catch { $shortcutOk = $false; Write-Host "Aviso: nao consegui criar o atalho do Menu Iniciar ($($_.Exception.Message)). Use o Configurar.bat." -ForegroundColor Yellow }

        Write-Host ''
        Write-Host "Instalado! Tarefa '$TaskName': $state"
        Write-Host "Pasta: $InstallDir"
        if ($shortcutOk) { Write-Host '  - Menu Iniciar > "Steam Status Scheduler"  -> janela de configuracao (horarios, status, log, teste)' }
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
