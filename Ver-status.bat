@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t = Get-ScheduledTask SteamStatusScheduler -ErrorAction SilentlyContinue; if (-not $t) { Write-Host 'NAO INSTALADO' } else { Write-Host ('Tarefa SteamStatusScheduler: ' + $t.State + '  (Running = ativo)') }; $log = Join-Path $env:LOCALAPPDATA 'SteamStatusScheduler\scheduler.log'; if (Test-Path $log) { Write-Host ''; Write-Host 'Ultimas linhas do log:'; Get-Content $log -Tail 10 }"
pause
