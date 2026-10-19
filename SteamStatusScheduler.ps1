# SteamStatusScheduler.ps1
#
# Keeps the Steam friends status in sync with the time windows defined in config.json.
# Inside a window the configured status (e.g. "invisible") is applied once; when the
# window ends the status is restored to "defaultStatus". Changes made manually during a
# window are respected (the script never re-applies within the same window occurrence).
#
# Intended to run forever, hidden, started at logon by the scheduled task registered by install.ps1.
# Installed copy lives in %LOCALAPPDATA%\SteamStatusScheduler together with config.json, state.json and scheduler.log.
#
# Usage:
#   .\SteamStatusScheduler.ps1                 # run the loop
#   .\SteamStatusScheduler.ps1 -Once           # evaluate a single tick and exit (testing)
#   .\SteamStatusScheduler.ps1 -Set invisible  # apply a status right now and exit

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Once,
    [ValidateSet('online', 'invisible', 'offline', 'away', 'busy')]
    [string]$Set
)

$ErrorActionPreference = 'Stop'

if (-not $ConfigPath) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $ConfigPath = Join-Path $scriptDir 'config.json'
}

$StateDir  = Join-Path $env:LOCALAPPDATA 'SteamStatusScheduler'
$StatePath = Join-Path $StateDir 'state.json'
$LogPath   = Join-Path $StateDir 'scheduler.log'
$ValidStatuses = @('online', 'invisible', 'offline', 'away', 'busy')

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Add-Content -Path $LogPath -Value $line
    if ($Once -or $Set) { Write-Host $line }
    # keep the log small
    if ((Get-Item $LogPath).Length -gt 1MB) {
        Get-Content $LogPath -Tail 300 | Set-Content $LogPath
    }
}

function Read-Config {
    $cfg = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
    if (-not $cfg.pollSeconds) { $cfg | Add-Member -NotePropertyName pollSeconds -NotePropertyValue 60 }
    if (-not $cfg.steamStartupGraceSeconds) { $cfg | Add-Member -NotePropertyName steamStartupGraceSeconds -NotePropertyValue 45 }
    if (-not $cfg.defaultStatus) { $cfg | Add-Member -NotePropertyName defaultStatus -NotePropertyValue 'online' }
    if ($ValidStatuses -notcontains $cfg.defaultStatus) { throw "Invalid defaultStatus '$($cfg.defaultStatus)'" }
    foreach ($w in $cfg.windows) {
        if ($ValidStatuses -notcontains $w.status) { throw "Invalid status '$($w.status)' in window '$($w.name)'" }
        if ([TimeSpan]$w.start -ge [TimeSpan]$w.end) { throw "Window '$($w.name)': start must be before end (same day)" }
    }
    return $cfg
}

function Get-ActiveWindow {
    param($Config, [datetime]$Now)
    $today = $Now.DayOfWeek.ToString().Substring(0, 3).ToLower()
    foreach ($w in $Config.windows) {
        $days = @($w.days | ForEach-Object { $_.ToString().Substring(0, 3).ToLower() })
        if ($days -notcontains $today) { continue }
        if ($Now.TimeOfDay -ge [TimeSpan]$w.start -and $Now.TimeOfDay -lt [TimeSpan]$w.end) { return $w }
    }
    return $null
}

function Get-WindowKey {
    param($Window, [datetime]$Now)
    return '{0:yyyy-MM-dd}|{1}|{2}|{3}' -f $Now, $Window.name, $Window.start, $Window.end
}

function Get-SteamExe {
    try {
        $exe = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamExe
        if ($exe -and (Test-Path $exe)) { return $exe }
    } catch { }
    return $null
}

function Get-SteamProcess {
    return Get-Process -Name 'steam' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Test-SteamReady {
    param($Config)
    $proc = Get-SteamProcess
    if (-not $proc) { return $false }
    try {
        $uptime = (Get-Date) - $proc.StartTime
        return $uptime.TotalSeconds -ge $Config.steamStartupGraceSeconds
    } catch {
        return $true
    }
}

function Set-SteamStatus {
    param([string]$Status)
    $url = "steam://friends/status/$Status"
    $exe = Get-SteamExe
    if ($exe) {
        Start-Process -FilePath $exe -ArgumentList $url | Out-Null
    } else {
        Start-Process $url | Out-Null
    }
}

function Read-State {
    if (Test-Path $StatePath) {
        try { return Get-Content -Raw -Path $StatePath | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ appliedWindow = $null; appliedStatus = $null }
}

function Save-State {
    param($State)
    $State | ConvertTo-Json | Set-Content -Path $StatePath
}

function Invoke-Tick {
    $cfg    = Read-Config
    $now    = Get-Date
    $window = Get-ActiveWindow -Config $cfg -Now $now
    $state  = Read-State

    if (-not (Test-SteamReady -Config $cfg)) { return }

    if ($window) {
        $key = Get-WindowKey -Window $window -Now $now
        if ($state.appliedWindow -ne $key) {
            Set-SteamStatus -Status $window.status
            $state.appliedWindow = $key
            $state.appliedStatus = $window.status
            Save-State $state
            Write-Log "window '$($window.name)' started -> status set to '$($window.status)'"
        }
    } elseif ($state.appliedWindow) {
        Set-SteamStatus -Status $cfg.defaultStatus
        Write-Log "window ended -> status restored to '$($cfg.defaultStatus)' (was '$($state.appliedStatus)')"
        $state.appliedWindow = $null
        $state.appliedStatus = $null
        Save-State $state
    }
}

if ($Set) {
    Set-SteamStatus -Status $Set
    Write-Log "manual -> status set to '$Set'"
    exit 0
}

Write-Log "scheduler started (pid $PID, config '$ConfigPath')"

while ($true) {
    try {
        Invoke-Tick
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)"
    }
    if ($Once) { break }
    $sleep = 60
    try { $sleep = [int](Read-Config).pollSeconds } catch { }
    Start-Sleep -Seconds $sleep
}
