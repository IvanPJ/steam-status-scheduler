# Tarefas.ps1 - turns config.json into Windows scheduled tasks that call Steam directly.
#
# Each time window becomes two tasks in the Task Scheduler folder \SteamStatusScheduler\:
#   "NN <name> - inicio"  weekly on the window's days at start -> steam.exe -silent steam://friends/status/<status>
#   "NN <name> - fim"     weekly on the window's days at end   -> steam.exe -silent steam://friends/status/<defaultStatus>
# No background process, no hidden PowerShell: Windows runs steam.exe itself at those times.
# "Start when available" makes a time missed while the PC was off run as soon as it is on again.
#
# Dot-sourced by install.ps1 and Configurar.ps1.

$SssTaskPath  = '\SteamStatusScheduler\'
$SssDayNames  = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')

function Get-SssSteamExe {
    try {
        $exe = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamExe -replace '/', '\'
        if ($exe -and (Test-Path $exe)) { return $exe }
    } catch { }
    $fallback = Join-Path ${env:ProgramFiles(x86)} 'Steam\steam.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Get-SssDayName([string]$Name) {
    $n = $Name.Trim().ToLower()
    if ($n.Length -lt 3) { return $null }
    $i = [Array]::IndexOf(@('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'), $n.Substring(0, 3))
    if ($i -lt 0) { return $null }
    return $SssDayNames[$i]
}

function Get-SssTasks { return @(Get-ScheduledTask -TaskPath $SssTaskPath -ErrorAction SilentlyContinue) }

function Sync-SssTasks {
    # $Windows: list of @{ name; days; start; end; status }   $DefaultStatus: status applied at each window end
    param($Windows, [string]$DefaultStatus)
    $steam = Get-SssSteamExe
    if (-not $steam) { throw 'Não achei o steam.exe. A Steam está instalada?' }

    Get-SssTasks | ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $SssTaskPath -Confirm:$false }

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    $i = 0
    foreach ($w in @($Windows)) {
        $i++
        $days = @($w.days | ForEach-Object { Get-SssDayName $_ } | Where-Object { $_ } | Select-Object -Unique)
        if ($days.Count -eq 0) { continue }
        $label = (('{0:00} {1}' -f $i, $w.name) -replace '[\\/:*?"<>|]', '-').Trim()
        $pairs = @(
            @{ suffix = 'inicio'; at = $w.start; status = $w.status },
            @{ suffix = 'fim';    at = $w.end;   status = $DefaultStatus }
        )
        foreach ($p in $pairs) {
            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $days -At ([datetime]::Today + [TimeSpan]$p.at)
            $action  = New-ScheduledTaskAction -Execute $steam -Argument ('-silent steam://friends/status/' + $p.status)
            Register-ScheduledTask -TaskPath $SssTaskPath -TaskName ($label + ' - ' + $p.suffix) -Action $action -Trigger $trigger `
                -Settings $settings -Description ('Steam Status Scheduler: ' + $p.status + ' as ' + $p.at) | Out-Null
        }
    }
    return (Get-SssTasks).Count
}

function Remove-SssTasks {
    Get-SssTasks | ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $SssTaskPath -Confirm:$false }
    try {
        $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
        $svc.GetFolder('\').DeleteFolder('SteamStatusScheduler', 0)
    } catch { }
}

function Remove-SssLegacy {
    # v1 ran a hidden PowerShell loop from a task called SteamStatusScheduler; stop and remove it
    if (Get-ScheduledTask -TaskName 'SteamStatusScheduler' -TaskPath '\' -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName 'SteamStatusScheduler' -TaskPath '\' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName 'SteamStatusScheduler' -TaskPath '\' -Confirm:$false
        return $true
    }
    return $false
}
