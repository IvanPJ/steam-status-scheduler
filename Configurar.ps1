# Configurar.ps1 - Steam Status Scheduler text-mode configuration UI
#
# Edits the installed config.json (%LOCALAPPDATA%\SteamStatusScheduler), shows whether the
# service is running, the weekly schedule as an ASCII grid, the log, and runs a live test.
# Launched at the end of install.ps1, by Configurar.bat, or from the Start Menu shortcut.
#
# ASCII only on purpose: PowerShell 5.1 reads BOM-less files as ANSI.

[CmdletBinding()]
param([switch]$RenderOnly)

$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:LOCALAPPDATA 'SteamStatusScheduler'
$ConfigPath = Join-Path $InstallDir 'config.json'
$LogPath    = Join-Path $InstallDir 'scheduler.log'
$TaskName   = 'SteamStatusScheduler'
$BoxWidth          = 76

$DayNamesEn  = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
$DayNamesPt  = @('Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sab', 'Dom')
$Statuses    = @('invisible', 'offline', 'away', 'busy', 'online')
$StatusChar  = @{ invisible = '#'; offline = 'X'; away = '~'; busy = '!'; online = '=' }
$StatusColor = @{ invisible = 'Magenta'; offline = 'Red'; away = 'Yellow'; busy = 'DarkYellow'; online = 'Green' }
$StatusHelp  = @{
    invisible = 'parece offline, mas ve amigos e recebe msg (recomendado)'
    offline   = 'modo "ficar offline" (desconecta do chat)'
    away      = 'ausente'
    busy      = 'ocupado'
    online    = 'online normal'
}

$Banner = @'
   ___ _____ ___   _   __  __    ___ _____ _ _____ _   _ ___
  / __|_   _| __| /_\ |  \/  |  / __|_   _/_\_   _| | | / __|
  \__ \ | | | _| / _ \| |\/| |  \__ \ | |/ _ \| | | |_| \__ \
  |___/ |_| |___/_/ \_\_|  |_|  |___/ |_/_/ \_\_|  \___/|___/
                          S C H E D U L E R
'@

# ---------------------------------------------------------------- drawing helpers

function Clear-Screen { try { Clear-Host } catch { } }

function Write-Seg { param([string]$Text, [string]$Color = 'Gray'); Write-Host -NoNewline -ForegroundColor $Color $Text }
function Write-Line { param([string]$Text = '', [string]$Color = 'Gray'); Write-Host -ForegroundColor $Color $Text }
function Write-Border { Write-Host -ForegroundColor DarkCyan ('+' + ('-' * $BoxWidth) + '+') }

function Write-Row {
    # $Segments: list of @(text, color) pairs rendered inside the box borders
    param([object[]]$Segments)
    Write-Seg '|' 'DarkCyan'
    $len = 0
    foreach ($seg in $Segments) {
        if ($seg -is [string]) { $text = $seg; $color = 'Gray' }
        else { $text = [string]$seg[0]; $color = 'Gray'; if ($seg.Count -gt 1) { $color = [string]$seg[1] } }
        if ($len + $text.Length -gt $BoxWidth) { $text = $text.Substring(0, [Math]::Max(0, $BoxWidth - $len)) }
        if ($text.Length -gt 0) { Write-Seg $text $color }
        $len += $text.Length
    }
    if ($len -lt $BoxWidth) { Write-Seg (' ' * ($BoxWidth - $len)) }
    Write-Line '|' 'DarkCyan'
}
function Write-Text { param([string]$Text = '', [string]$Color = 'Gray'); Write-Row @(, @($Text, $Color)) }

function Show-Flash { param([string]$Text, [string]$Color = 'Green'); Write-Line ''; Write-Line $Text $Color; Start-Sleep -Milliseconds 1500 }
function Pause-Key { Write-Line ''; Write-Line '  aperte qualquer tecla pra voltar' 'DarkGray'; [void](Read-Key) }

# ---------------------------------------------------------------- input helpers

function Read-Key {
    # returns a single upper-case character, 'ENTER' or 'ESC'
    if ([Console]::IsInputRedirected) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { throw 'input ended' }
        if ($line -eq '') { return 'ENTER' }
        return $line.Substring(0, 1).ToUpper()
    }
    $k = [Console]::ReadKey($true)
    if ($k.Key -eq 'Enter') { return 'ENTER' }
    if ($k.Key -eq 'Escape') { return 'ESC' }
    return $k.KeyChar.ToString().ToUpper()
}

function Read-Text {
    # Read-Host when interactive; plain stdin line when input is redirected (scripted use)
    param([string]$Prompt)
    if ([Console]::IsInputRedirected) {
        Write-Seg ($Prompt + ': ') 'Gray'
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { throw 'input ended' }
        Write-Line $line 'White'
        return $line
    }
    return [string](Read-Host $Prompt)
}

function Confirm-Key {
    param([string]$Prompt)
    Write-Seg ($Prompt + ' ') 'Gray'
    while ($true) {
        $k = Read-Key
        if ($k -eq 'S' -or $k -eq 'Y') { Write-Line 'S' 'Green'; return $true }
        if ($k -eq 'N' -or $k -eq 'ESC') { Write-Line 'N' 'Red'; return $false }
    }
}

function Read-Time {
    param([string]$Label, [string]$Default)
    while ($true) {
        $in = Read-Text ($Label + ' (HH:mm) [' + $Default + ']')
        if (-not $in.Trim()) { return $Default }
        if ($in -match '^\s*(\d{1,2})(?::(\d{1,2}))?\s*$') {
            $h = [int]$matches[1]; $m = 0
            if ($matches[2]) { $m = [int]$matches[2] }
            if ($h -le 23 -and $m -le 59) { return ('{0:00}:{1:00}' -f $h, $m) }
        }
        Write-Line '  Horario invalido. Exemplos: 06:00, 7, 13:30 (de 00:00 ate 23:59)' 'Red'
    }
}

function Read-Days {
    param([string[]]$Current)
    $sel = New-Object bool[] 7
    foreach ($d in $Current) { $i = Get-DayIndex $d; if ($i -ge 0) { $sel[$i] = $true } }
    Write-Line ''
    $top = -1
    try { $top = [Console]::CursorTop } catch { }
    $msg = ''
    while ($true) {
        if ($top -ge 0) { try { [Console]::SetCursorPosition(0, $top) } catch { } }
        Write-Seg ' Dias: ' 'Gray'
        for ($i = 0; $i -lt 7; $i++) {
            if ($sel[$i]) { Write-Seg ('[x] ' + ($i + 1) + ' ' + $DayNamesPt[$i] + ' ') 'Green' }
            else          { Write-Seg ('[ ] ' + ($i + 1) + ' ' + $DayNamesPt[$i] + ' ') 'DarkGray' }
        }
        Write-Line ''
        Write-Line '        1-7 marca/desmarca   U = seg a sex   F = sab e dom   T = todos' 'DarkGray'
        Write-Line '        ENTER confirma' 'DarkGray'
        Write-Line ('        ' + $msg).PadRight(70) 'Red'
        $k = Read-Key
        $msg = ''
        if ($k -match '^[1-7]$') { $sel[[int]$k - 1] = -not $sel[[int]$k - 1] }
        elseif ($k -eq 'U') { for ($i = 0; $i -lt 7; $i++) { $sel[$i] = ($i -le 4) } }
        elseif ($k -eq 'F') { for ($i = 0; $i -lt 7; $i++) { $sel[$i] = ($i -ge 5) } }
        elseif ($k -eq 'T') { for ($i = 0; $i -lt 7; $i++) { $sel[$i] = $true } }
        elseif ($k -eq 'ENTER') {
            $out = @()
            for ($i = 0; $i -lt 7; $i++) { if ($sel[$i]) { $out += $DayNamesEn[$i] } }
            if ($out.Count -gt 0) { return $out }
            $msg = 'Marca pelo menos um dia.'
        }
    }
}

function Read-Status {
    param([string]$Label, [string]$Default)
    Write-Line ''
    Write-Line ($Label + ' [' + $Default + ']') 'Gray'
    for ($i = 0; $i -lt $Statuses.Count; $i++) {
        $s = $Statuses[$i]
        Write-Seg ('    ' + ($i + 1) + '  ') 'Yellow'
        Write-Seg ('{0,-10}' -f $s) $StatusColor[$s]
        Write-Line ('  ' + $StatusHelp[$s]) 'DarkGray'
    }
    Write-Line '    1-5 escolhe   ENTER mantem' 'DarkGray'
    while ($true) {
        $k = Read-Key
        if ($k -eq 'ENTER') { return $Default }
        if ($k -match '^[1-5]$') { return $Statuses[[int]$k - 1] }
    }
}

function Read-Index {
    param([string]$Prompt, $Cfg)
    if ($Cfg.windows.Count -eq 0) { Show-Flash '  Nao tem nenhuma janela ainda.' 'Yellow'; return -1 }
    if ($Cfg.windows.Count -eq 1) { return 0 }
    $in = Read-Text ('  ' + $Prompt + ' (1-' + $Cfg.windows.Count + ', ENTER cancela)')
    if ($in -match '^\d+$' -and [int]$in -ge 1 -and [int]$in -le $Cfg.windows.Count) { return [int]$in - 1 }
    return -1
}

# ---------------------------------------------------------------- config

function Get-DayIndex {
    param([string]$Name)
    $n = $Name.Trim().ToLower()
    if ($n.Length -lt 3) { return -1 }
    return [Array]::IndexOf(@('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'), $n.Substring(0, 3))
}

function Format-Days {
    param([string[]]$Days)
    $idx = @($Days | ForEach-Object { Get-DayIndex $_ } | Where-Object { $_ -ge 0 } | Sort-Object -Unique)
    $key = $idx -join ','
    if ($idx.Count -eq 7) { return 'Todos os dias' }
    if ($key -eq '0,1,2,3,4') { return 'Seg a Sex' }
    if ($key -eq '5,6') { return 'Sab e Dom' }
    return (($idx | ForEach-Object { $DayNamesPt[$_] }) -join ' ')
}

function Test-WindowDay {
    param($Win, [int]$Index)
    foreach ($d in $Win.days) { if ((Get-DayIndex $d) -eq $Index) { return $true } }
    return $false
}

function Load-Config {
    $raw = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
    $cfg = @{ pollSeconds = 30; steamStartupGraceSeconds = 45; defaultStatus = 'online'; windows = New-Object System.Collections.ArrayList }
    if ($raw.pollSeconds) { $cfg.pollSeconds = [int]$raw.pollSeconds }
    if ($raw.steamStartupGraceSeconds) { $cfg.steamStartupGraceSeconds = [int]$raw.steamStartupGraceSeconds }
    if ($raw.defaultStatus) { $cfg.defaultStatus = [string]$raw.defaultStatus }
    foreach ($w in @($raw.windows)) {
        if ($null -eq $w) { continue }
        [void]$cfg.windows.Add(@{
            name = [string]$w.name; days = @($w.days | ForEach-Object { [string]$_ })
            start = [string]$w.start; end = [string]$w.end; status = [string]$w.status
        })
    }
    return $cfg
}

function Save-Config {
    param($Cfg)
    $out = [ordered]@{
        pollSeconds              = $Cfg.pollSeconds
        steamStartupGraceSeconds = $Cfg.steamStartupGraceSeconds
        defaultStatus            = $Cfg.defaultStatus
        windows                  = @($Cfg.windows | ForEach-Object {
            [ordered]@{ name = $_.name; days = @($_.days); start = $_.start; end = $_.end; status = $_.status }
        })
    }
    $json = $out | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($ConfigPath, $json, [Text.Encoding]::ASCII)
}

# ---------------------------------------------------------------- service / steam

$script:SvcCache = $null
$script:SvcTime  = [datetime]::MinValue
function Get-ServiceState {
    param([switch]$Refresh)
    if ($Refresh -or ((Get-Date) - $script:SvcTime).TotalSeconds -gt 10) {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $t) { $script:SvcCache = @('NAO INSTALADO', 'Red') }
        elseif ($t.State -eq 'Running') { $script:SvcCache = @('ATIVO', 'Green') }
        else { $script:SvcCache = @(('PARADO (' + $t.State + ')'), 'Yellow') }
        $script:SvcTime = Get-Date
    }
    return $script:SvcCache
}

function Set-SteamStatus {
    param([string]$Status)
    $url = 'steam://friends/status/' + $Status
    $exe = $null
    try { $exe = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamExe } catch { }
    if ($exe -and (Test-Path $exe)) { Start-Process -FilePath $exe -ArgumentList $url | Out-Null }
    else { Start-Process $url | Out-Null }
}

# ---------------------------------------------------------------- screens

function Draw-Grid {
    param($Cfg)
    $cols = 48
    $hdr = (' ' * $cols).ToCharArray()
    foreach ($h in 0, 3, 6, 9, 12, 15, 18, 21) {
        $lbl = [string]$h
        for ($j = 0; $j -lt $lbl.Length; $j++) { $hdr[$h * 2 + $j] = $lbl[$j] }
    }
    Write-Text '  SEMANA  (cada bloco = 30 min)' 'White'
    Write-Row @( @('         ', 'Gray'), @(((-join $hdr) + '24'), 'DarkGray') )
    for ($d = 0; $d -lt 7; $d++) {
        $cellChar = New-Object char[] $cols
        $cellColor = New-Object string[] $cols
        for ($i = 0; $i -lt $cols; $i++) { $cellChar[$i] = '.'; $cellColor[$i] = 'DarkGray' }
        foreach ($w in $Cfg.windows) {
            if (-not (Test-WindowDay $w $d)) { continue }
            $s = [int][Math]::Floor(([TimeSpan]$w.start).TotalMinutes / 30)
            $e = [int][Math]::Ceiling(([TimeSpan]$w.end).TotalMinutes / 30)
            for ($i = $s; $i -lt $e -and $i -lt $cols; $i++) {
                $cellChar[$i] = $StatusChar[$w.status]; $cellColor[$i] = $StatusColor[$w.status]
            }
        }
        $segs = New-Object System.Collections.ArrayList
        [void]$segs.Add(@(('   ' + $DayNamesPt[$d] + '   '), 'White'))
        $run = ''; $runColor = $cellColor[0]
        for ($i = 0; $i -lt $cols; $i++) {
            if ($cellColor[$i] -ne $runColor) { [void]$segs.Add(@($run, $runColor)); $run = ''; $runColor = $cellColor[$i] }
            $run += $cellChar[$i]
        }
        [void]$segs.Add(@($run, $runColor))
        Write-Row $segs.ToArray()
    }
    Write-Row @( @('         ', 'Gray'), @('# invisible  ', 'Magenta'), @('X offline  ', 'Red'), @('~ away  ', 'Yellow'), @('! busy  ', 'DarkYellow'), @('= online', 'Green') )
}

function Draw-Main {
    param($Cfg, [bool]$Dirty)
    Clear-Screen
    Write-Line $Banner 'Cyan'
    Write-Line ''
    Write-Border
    $svc = Get-ServiceState
    $left = '  Servico: '
    $right = ''
    if ($Dirty) { $right = '* alteracoes nao salvas  ' }
    $pad = $BoxWidth - $left.Length - $svc[0].Length - $right.Length
    Write-Row @( @($left, 'Gray'), @($svc[0], $svc[1]), @((' ' * [Math]::Max(0, $pad)), 'Gray'), @($right, 'Yellow') )
    Write-Border
    Write-Text '  JANELAS DE HORARIO' 'White'
    Write-Text ('   {0,2}  {1,-20} {2,-22} {3,-12} {4}' -f '#', 'Nome', 'Dias', 'Horario', 'Status') 'DarkGray'
    if ($Cfg.windows.Count -eq 0) { Write-Text '      (nenhuma janela ainda - aperte A pra adicionar)' 'DarkGray' }
    $i = 0
    foreach ($w in $Cfg.windows) {
        $i++
        $name = $w.name
        if ($name.Length -gt 20) { $name = $name.Substring(0, 19) + '~' }
        $line = '   {0,2}  {1,-20} {2,-22} {3,-12} ' -f $i, $name, (Format-Days $w.days), ($w.start + '-' + $w.end)
        Write-Row @( @($line, 'Gray'), @($w.status, $StatusColor[$w.status]) )
    }
    Write-Text ''
    Write-Row @( @('  Fora das janelas: ', 'Gray'), @($Cfg.defaultStatus, $StatusColor[$Cfg.defaultStatus]) )
    Write-Border
    Draw-Grid $Cfg
    Write-Border
    Write-Row @( @('  [A]', 'Yellow'), @(' Adicionar  ', 'Gray'), @('[E]', 'Yellow'), @(' Editar  ', 'Gray'), @('[R]', 'Yellow'), @(' Remover  ', 'Gray'), @('[P]', 'Yellow'), @(' Status fora das janelas', 'Gray') )
    Write-Row @( @('  [T]', 'Yellow'), @(' Testar agora  ', 'Gray'), @('[L]', 'Yellow'), @(' Ver log  ', 'Gray'), @('[S]', 'Yellow'), @(' Salvar  ', 'Gray'), @('[Q]', 'Yellow'), @(' Sair', 'Gray') )
    if ($svc[0] -ne 'ATIVO') { Write-Row @( @('  [I]', 'Yellow'), @(' Iniciar o servico', 'Gray') ) }
    Write-Border
}

function Edit-Window {
    param($Win)
    $isNew = ($null -eq $Win)
    if ($isNew) { $w = @{ name = 'nova-janela'; days = @('Saturday', 'Sunday'); start = '06:00'; end = '12:00'; status = 'invisible' } }
    else { $w = @{ name = $Win.name; days = @($Win.days); start = $Win.start; end = $Win.end; status = $Win.status } }
    Clear-Screen
    Write-Border
    if ($isNew) { Write-Text '  NOVA JANELA' 'White' } else { Write-Text ('  EDITAR JANELA: ' + $w.name) 'White' }
    Write-Text '  ENTER mantem o valor que esta entre colchetes' 'DarkGray'
    Write-Border
    Write-Line ''
    $name = Read-Text ('  Nome [' + $w.name + ']')
    $name = ($name -replace '[^\x20-\x7E]', '').Trim()
    if ($name) { $w.name = $name }
    $w.days  = Read-Days $w.days
    $w.start = Read-Time '  Inicio' $w.start
    while ($true) {
        $w.end = Read-Time '  Fim   ' $w.end
        if ([TimeSpan]$w.end -gt [TimeSpan]$w.start) { break }
        Write-Line '  O fim precisa ser depois do inicio (e no mesmo dia).' 'Red'
    }
    $w.status = Read-Status '  Status durante a janela' $w.status
    Write-Line ''
    Write-Seg '  Resumo: ' 'Gray'
    Write-Seg ($w.name + '  ') 'White'
    Write-Seg ((Format-Days $w.days) + '  ' + $w.start + '-' + $w.end + '  ') 'Gray'
    Write-Line $w.status $StatusColor[$w.status]
    if (Confirm-Key '  Confirmar? (S/N)') { return $w }
    return $null
}

function Show-Log {
    Clear-Screen
    Write-Border
    Write-Text '  LOG DO SERVICO  (ultimas 20 linhas)' 'White'
    Write-Text ('  ' + $LogPath) 'DarkGray'
    Write-Border
    if (Test-Path $LogPath) {
        foreach ($l in (Get-Content $LogPath -Tail 20)) {
            $c = 'Gray'
            if ($l -match 'ERROR') { $c = 'Red' }
            elseif ($l -match "set to 'invisible'") { $c = 'Magenta' }
            elseif ($l -match 'restored') { $c = 'Green' }
            elseif ($l -match 'scheduler started') { $c = 'DarkGray' }
            Write-Line ('  ' + $l) $c
        }
    } else {
        Write-Line '  (ainda nao tem log; o servico cria quando inicia)' 'DarkGray'
    }
    Write-Border
    Pause-Key
}

function Run-Test {
    Clear-Screen
    Write-Border
    Write-Text '  TESTE AO VIVO' 'White'
    Write-Border
    Write-Line ''
    Write-Line '  Vou deixar sua Steam INVISIVEL agora, segurar 45 segundos e voltar pra ONLINE.' 'Gray'
    Write-Line '  Olha sua lista de amigos (ou pede pra alguem olhar seu perfil) enquanto isso.' 'Gray'
    Write-Line ''
    if (-not (Get-Process -Name 'steam' -ErrorAction SilentlyContinue)) {
        Write-Line '  A Steam nao esta aberta. Abre ela e tenta de novo.' 'Red'
        Pause-Key
        return
    }
    if (-not (Confirm-Key '  Comecar? (S/N)')) { return }
    Set-SteamStatus 'invisible'
    for ($s = 45; $s -gt 0; $s--) {
        Write-Seg ("`r  invisivel  [") 'Magenta'
        Write-Seg (('#' * $s).PadRight(45)) 'Magenta'
        Write-Seg (']  volta pra online em ' + ('{0,2}' -f $s) + 's ') 'Gray'
        Start-Sleep -Seconds 1
    }
    Set-SteamStatus 'online'
    Write-Line ''
    Write-Line ''
    Write-Line '  Pronto, de volta pra online. Se o status mudou, o servico vai funcionar igual nos horarios.' 'Green'
    Pause-Key
}

# ---------------------------------------------------------------- main loop

function Start-Ui {
    try { $Host.UI.RawUI.WindowTitle = 'Steam Status Scheduler' } catch { }
    if (-not (Test-Path $ConfigPath)) {
        Write-Line ''
        Write-Line ('  Steam Status Scheduler nao esta instalado (nao achei ' + $ConfigPath + ').') 'Red'
        Write-Line '  Roda o Instalar.bat primeiro.' 'Gray'
        Pause-Key
        return
    }
    $cfg = Load-Config
    $dirty = $false
    while ($true) {
        Draw-Main $cfg $dirty
        if ($RenderOnly) { return }
        $k = Read-Key
        switch ($k) {
            'A' { $w = Edit-Window $null; if ($w) { [void]$cfg.windows.Add($w); $dirty = $true } }
            'E' {
                $i = Read-Index 'Editar qual' $cfg
                if ($i -ge 0) { $w = Edit-Window $cfg.windows[$i]; if ($w) { $cfg.windows[$i] = $w; $dirty = $true } }
            }
            'R' {
                $i = Read-Index 'Remover qual' $cfg
                if ($i -ge 0 -and (Confirm-Key ('  Remover "' + $cfg.windows[$i].name + '"? (S/N)'))) { $cfg.windows.RemoveAt($i); $dirty = $true }
            }
            'P' { $cfg.defaultStatus = Read-Status '  Status fora das janelas' $cfg.defaultStatus; $dirty = $true }
            'T' { Run-Test }
            'L' { Show-Log }
            'I' { Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2; [void](Get-ServiceState -Refresh) }
            'S' { Save-Config $cfg; $dirty = $false; Show-Flash '  Salvo! O servico le o novo config em ate 30 segundos.' 'Green' }
            'Q' {
                if (-not $dirty) { return }
                Write-Line ''
                Write-Seg '  Tem alteracoes nao salvas.  ' 'Yellow'
                Write-Seg '[S]' 'Yellow'; Write-Seg ' salvar e sair   ' 'Gray'
                Write-Seg '[N]' 'Yellow'; Write-Seg ' sair sem salvar   ' 'Gray'
                Write-Seg '[C]' 'Yellow'; Write-Line ' cancelar' 'Gray'
                $a = Read-Key
                if ($a -eq 'S') { Save-Config $cfg; return }
                if ($a -eq 'N') { return }
            }
        }
    }
}

Start-Ui
