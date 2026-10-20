# Configurar.ps1 - Steam Status Scheduler desktop UI
#
# Native WPF window (ships with every Windows 10/11, no extra runtime) to edit the installed
# config.json, see the service state, the weekly schedule as a drag-to-paint grid, the log,
# and run a live test. Launched by the Start Menu shortcut, Configurar.bat or install.ps1.
#
# This file is saved as UTF-8 WITH BOM on purpose: PowerShell 5.1 needs the BOM to read the
# accented strings correctly.

[CmdletBinding()]
param(
    [string]$Screenshot,           # debug: render the window to this PNG after a delay and exit
    [int]$ScreenshotDelayMs = 4000
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing

$InstallDir = Join-Path $env:LOCALAPPDATA 'SteamStatusScheduler'
$ConfigPath = Join-Path $InstallDir 'config.json'
$StatePath  = Join-Path $InstallDir 'state.json'
$LogPath    = Join-Path $InstallDir 'scheduler.log'
$BeatPath   = Join-Path $InstallDir 'heartbeat'
$TaskName   = 'SteamStatusScheduler'
$Version    = 'v1.2'

$DayNamesEn = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
$DayNamesPt = @('Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom')
$Statuses   = @('invisible', 'offline', 'away', 'busy', 'online')
$StatusPt   = @{ invisible = 'INVISÍVEL'; offline = 'OFFLINE'; away = 'AUSENTE'; busy = 'OCUPADO'; online = 'ONLINE' }
$StatusHex  = @{ invisible = '#A4F000'; offline = '#FF3B3B'; away = '#FFD23B'; busy = '#FF8C1A'; online = '#3FD16A' }

$Conv = New-Object Windows.Media.BrushConverter
function Brush([string]$Hex) { return $Conv.ConvertFromString($Hex) }
$Br = @{
    Lime = Brush '#A4F000'; LimeDim = Brush '#4E7300'; LimeSoft = Brush '#D9FF80'; Black = Brush '#000000'
    Panel = Brush '#000000'; Cell = Brush '#0D1216'; CellStroke = Brush '#1C2630'; Red = Brush '#FF3B3B'
    Gray = Brush '#5C6B75'; White = Brush '#F2FFE0'; SelBg = Brush '#0F1A00'; HoverBg = Brush '#09110A'
}
foreach ($s in $Statuses) { $Br[$s] = Brush $StatusHex[$s] }

# ====================================================================== config

function Get-DayIndex([string]$Name) {
    $n = $Name.Trim().ToLower()
    if ($n.Length -lt 3) { return -1 }
    return [Array]::IndexOf(@('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'), $n.Substring(0, 3))
}
function Test-WindowDay($Win, [int]$Index) {
    foreach ($d in $Win.days) { if ((Get-DayIndex $d) -eq $Index) { return $true } }
    return $false
}
function Format-Days([string[]]$Days) {
    $idx = @($Days | ForEach-Object { Get-DayIndex $_ } | Where-Object { $_ -ge 0 } | Sort-Object -Unique)
    $key = $idx -join ','
    if ($idx.Count -eq 7) { return 'todos os dias' }
    if ($key -eq '0,1,2,3,4') { return 'seg a sex' }
    if ($key -eq '5,6') { return 'sáb e dom' }
    return (($idx | ForEach-Object { $DayNamesPt[$_].ToLower() }) -join ' ')
}
function Test-Time([string]$Text) { return ($Text -match '^([01]?\d|2[0-3]):[0-5]\d$') }
function Format-Time([int]$Minutes) { return ('{0:00}:{1:00}' -f [Math]::Floor($Minutes / 60), ($Minutes % 60)) }

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

function Save-Config($Cfg) {
    $out = [ordered]@{
        pollSeconds              = $Cfg.pollSeconds
        steamStartupGraceSeconds = $Cfg.steamStartupGraceSeconds
        defaultStatus            = $Cfg.defaultStatus
        windows                  = @($Cfg.windows | ForEach-Object {
            [ordered]@{ name = $_.name; days = @($_.days); start = $_.start; end = $_.end; status = $_.status }
        })
    }
    $json = $out | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($ConfigPath, $json, (New-Object Text.UTF8Encoding $true))
}

function Test-Config($Cfg) {
    # returns an error message or $null
    $i = 0
    foreach ($w in $Cfg.windows) {
        $i++
        if (-not $w.name.Trim()) { return "Janela $i está sem nome." }
        if (@($w.days).Count -eq 0) { return "'$($w.name)' não tem nenhum dia marcado." }
        if (-not (Test-Time $w.start)) { return "'$($w.name)': início inválido ($($w.start)). Use HH:mm." }
        if (-not (Test-Time $w.end)) { return "'$($w.name)': fim inválido ($($w.end)). Use HH:mm." }
        if ([TimeSpan]$w.end -le [TimeSpan]$w.start) { return "'$($w.name)': o fim precisa ser depois do início." }
    }
    return $null
}

# ====================================================================== service / steam

function Get-SteamExe {
    try {
        $exe = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamExe -replace '/', '\'
        if ($exe -and (Test-Path $exe)) { return $exe }
    } catch { }
    return $null
}
function Set-SteamStatus([string]$Status) {
    $url = 'steam://friends/status/' + $Status
    $exe = Get-SteamExe
    if ($exe) { Start-Process -FilePath $exe -ArgumentList $url | Out-Null } else { Start-Process $url | Out-Null }
}
function Test-SteamRunning { return [bool](Get-Process -Name 'steam' -ErrorAction SilentlyContinue) }
function Test-TaskInstalled { return [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) }
function Get-ServiceState {
    # heartbeat file is touched by the scheduler every tick; fresh = alive (cheap, no WMI on the UI thread)
    if (Test-Path $BeatPath) {
        $age = ((Get-Date) - (Get-Item $BeatPath).LastWriteTime).TotalSeconds
        if ($age -lt 120) { return 'ATIVO' }
    }
    # fallback: ask the Task Scheduler, at most every 15 s
    if (-not $App.TaskCheckedAt -or ((Get-Date) - $App.TaskCheckedAt).TotalSeconds -gt 15) {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $App.TaskInstalled = [bool]$task
        $App.TaskState = ''
        if ($task) { $App.TaskState = [string]$task.State }
        $App.TaskCheckedAt = Get-Date
    }
    if ($App.TaskState -eq 'Running') { return 'ATIVO' }
    if ($App.TaskInstalled) { return 'PARADO' }
    return 'NÃO INSTALADO'
}
function Get-CurrentMode {
    if (Test-Path $StatePath) {
        try {
            $st = Get-Content -Raw -Path $StatePath | ConvertFrom-Json
            if ($st.appliedWindow) { return [string]$st.appliedStatus }
        } catch { }
    }
    return $App.Cfg.defaultStatus
}
function Get-NextEvent {
    $now = Get-Date
    $best = $null
    foreach ($w in $App.Cfg.windows) {
        if (-not (Test-Time $w.start) -or -not (Test-Time $w.end)) { continue }
        $st = [TimeSpan]$w.start; $en = [TimeSpan]$w.end
        for ($d = 0; $d -le 7; $d++) {
            $day = $now.Date.AddDays($d)
            $idx = ([int]$day.DayOfWeek + 6) % 7
            if (-not (Test-WindowDay $w $idx)) { continue }
            $start = $day + $st; $end = $day + $en
            if ($now -ge $start -and $now -lt $end) { return @{ kind = 'end'; when = $end; window = $w } }
            if ($start -gt $now) {
                if (-not $best -or $start -lt $best.when) { $best = @{ kind = 'start'; when = $start; window = $w } }
                break
            }
        }
    }
    return $best
}

# ====================================================================== ascii skull engine

$SkullCols = 64; $SkullRows = 30; $SkullFrameCount = 32
$Ramp = @(' ', ".'`,", ':;', '-~', '=', '+i', '*x', '#X', '%&', '@')
$Bayer = @(0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5)

function Draw-Skull($dc, [double]$Angle, [double]$Bob) {
    $cx = 128 + 18 * [Math]::Sin($Angle); $cy = 118 + $Bob
    $dc.PushTransform([Windows.Media.TranslateTransform]::new($cx, $cy))
    $dc.PushTransform([Windows.Media.ScaleTransform]::new([Math]::Cos($Angle), 1))
    $black = [Windows.Media.Brushes]::Black

    $g = New-Object Windows.Media.RadialGradientBrush
    $g.GradientOrigin = [Windows.Point]::new(0.38, 0.28); $g.Center = [Windows.Point]::new(0.5, 0.5)
    $g.RadiusX = 0.62; $g.RadiusY = 0.62
    $g.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color]::FromRgb(250, 250, 250), 0.0))
    $g.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color]::FromRgb(170, 170, 170), 0.65))
    $g.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color]::FromRgb(45, 45, 45), 1.0))
    $dc.DrawEllipse($g, $null, [Windows.Point]::new(0, -28), 92, 98)

    $lg = [Windows.Media.LinearGradientBrush]::new([Windows.Media.Color]::FromRgb(205, 205, 205), [Windows.Media.Color]::FromRgb(80, 80, 80), 90)
    $dc.DrawRoundedRectangle($lg, $null, [Windows.Rect]::new(-60, 10, 120, 108), 28, 28)

    $hollow = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromArgb(180, 15, 15, 15))
    $dc.DrawEllipse($hollow, $null, [Windows.Point]::new(-68, 52), 20, 27)
    $dc.DrawEllipse($hollow, $null, [Windows.Point]::new(68, 52), 20, 27)
    $brow = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromArgb(90, 0, 0, 0))
    $dc.DrawEllipse($brow, $null, [Windows.Point]::new(0, -14), 80, 10)

    $dc.DrawEllipse($black, $null, [Windows.Point]::new(-38, 4), 27, 21)
    $dc.DrawEllipse($black, $null, [Windows.Point]::new(38, 4), 27, 21)

    $geo = New-Object Windows.Media.StreamGeometry
    $ctx = $geo.Open()
    $ctx.BeginFigure([Windows.Point]::new(0, 28), $true, $true)
    $ctx.LineTo([Windows.Point]::new(-12, 66), $true, $true)
    $ctx.LineTo([Windows.Point]::new(12, 66), $true, $true)
    $ctx.Close()
    $dc.DrawGeometry($black, $null, $geo)

    $tooth = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(230, 230, 230))
    $gap = [Windows.Media.Pen]::new($black, 2.2)
    $dc.DrawRectangle($tooth, $null, [Windows.Rect]::new(-46, 76, 92, 40))
    for ($x = -46; $x -le 46; $x += 13) { $dc.DrawLine($gap, [Windows.Point]::new($x, 76), [Windows.Point]::new($x, 116)) }
    $dc.DrawLine($gap, [Windows.Point]::new(-46, 96), [Windows.Point]::new(46, 96))

    $crack = [Windows.Media.Pen]::new($black, 2.4)
    $dc.DrawLine($crack, [Windows.Point]::new(-22, -120), [Windows.Point]::new(-12, -82))
    $dc.DrawLine($crack, [Windows.Point]::new(-12, -82), [Windows.Point]::new(-28, -54))
    $dc.DrawLine($crack, [Windows.Point]::new(-12, -82), [Windows.Point]::new(2, -70))

    $dc.Pop(); $dc.Pop()
}

function New-SkullFrame([int]$f) {
    $angle = 0.9 * [Math]::Sin(2 * [Math]::PI * $f / $SkullFrameCount)
    $bob = 3 * [Math]::Sin(4 * [Math]::PI * $f / $SkullFrameCount)
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.PushTransform([Windows.Media.ScaleTransform]::new($SkullCols / 256.0, $SkullRows / 240.0))
    $dc.DrawRectangle([Windows.Media.Brushes]::Black, $null, [Windows.Rect]::new(0, 0, 256, 240))
    Draw-Skull $dc $angle $bob
    $dc.Pop()
    $dc.Close()
    $rtb = [Windows.Media.Imaging.RenderTargetBitmap]::new($SkullCols, $SkullRows, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $px = New-Object byte[] ($SkullCols * $SkullRows * 4)
    $rtb.CopyPixels($px, $SkullCols * 4, 0)
    $sb = New-Object Text.StringBuilder
    for ($r = 0; $r -lt $SkullRows; $r++) {
        for ($c = 0; $c -lt $SkullCols; $c++) {
            $i = ($r * $SkullCols + $c) * 4
            $b = ($px[$i] + $px[$i + 1] + $px[$i + 2]) / 765.0
            $b += ($Bayer[($r % 4) * 4 + ($c % 4)] / 16.0 - 0.5) * 0.12
            $band = [int][Math]::Floor($b * 9.99)
            if ($band -lt 0) { $band = 0 } elseif ($band -gt 9) { $band = 9 }
            $alt = $Ramp[$band]
            [void]$sb.Append($alt[($r * 7 + $c * 3) % $alt.Length])
        }
        if ($r -lt $SkullRows - 1) { [void]$sb.Append("`n") }
    }
    return $sb.ToString()
}

function Get-EyePositions([int]$f) {
    # returns @(lx, ly, rx, ry) in skull-cell units for frame $f
    $angle = 0.9 * [Math]::Sin(2 * [Math]::PI * $f / $SkullFrameCount)
    $bob = 3 * [Math]::Sin(4 * [Math]::PI * $f / $SkullFrameCount)
    $cx = 128 + 18 * [Math]::Sin($angle); $cy = 118 + $bob + 4
    $lx = ($cx - 38 * [Math]::Cos($angle)) / 4.0; $rx = ($cx + 38 * [Math]::Cos($angle)) / 4.0
    $y = $cy / 8.0
    return @($lx, $y, $rx, $y)
}

# ====================================================================== xaml

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Steam Status Scheduler" Width="1150" Height="820"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanMinimize" ShowInTaskbar="True"
        FontFamily="Cascadia Mono, Consolas, Courier New" FontSize="13" Foreground="#A4F000"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#A4F000"/></Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#A4F000"/>
      <Setter Property="BorderBrush" Value="#A4F000"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas, Courier New"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#A4F000"/>
                <Setter Property="Foreground" Value="#000000"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#6FA300"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Tog" TargetType="ToggleButton">
      <Setter Property="Foreground" Value="#A4F000"/>
      <Setter Property="Margin" Value="0,0,4,4"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas, Courier New"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="bd" Background="Transparent" BorderBrush="#4E7300" BorderThickness="1" CornerRadius="3" Padding="6,2">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="box" Text="[ ]" Foreground="#4E7300" Margin="0,0,6,0"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{Binding Foreground, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter TargetName="bd" Property="Background" Value="#0F1A00"/>
                <Setter TargetName="box" Property="Text" Value="[x]"/>
                <Setter TargetName="box" Property="Foreground" Value="{Binding Foreground, RelativeSource={RelativeSource TemplatedParent}}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#A4F000"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Tb" TargetType="TextBox">
      <Setter Property="Background" Value="#050806"/>
      <Setter Property="Foreground" Value="#D9FF80"/>
      <Setter Property="BorderBrush" Value="#4E7300"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CaretBrush" Value="#A4F000"/>
      <Setter Property="SelectionBrush" Value="#4E7300"/>
      <Setter Property="Padding" Value="6,3"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas, Courier New"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#A4F000"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SectionTitle" TargetType="TextBlock">
      <Setter Property="Background" Value="#000000"/>
      <Setter Property="Foreground" Value="#A4F000"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="10,0,0,0"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
    </Style>
    <Style x:Key="SectionBox" TargetType="Border">
      <Setter Property="BorderBrush" Value="#A4F000"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="2"/>
      <Setter Property="Margin" Value="0,9,0,0"/>
      <Setter Property="Padding" Value="10,14,10,10"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#4E7300"/>
      <Setter Property="Margin" Value="0,4,0,2"/>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" CornerRadius="10" Background="#07090D" BorderBrush="#A4F000" BorderThickness="1" Margin="14">
    <Border.Effect><DropShadowEffect Color="#A4F000" BlurRadius="34" ShadowDepth="0" Opacity="0.35"/></Border.Effect>
    <Grid ClipToBounds="True">
      <Border CornerRadius="10" ClipToBounds="True">
        <Grid>
          <TextBlock x:Name="Backdrop" FontSize="46" Foreground="#1A222B" LineHeight="52" LineStackingStrategy="BlockLineHeight"
                     Margin="-8,-10,0,0" IsHitTestVisible="False" TextWrapping="NoWrap"/>
          <Rectangle IsHitTestVisible="False" Opacity="0.22">
            <Rectangle.Fill>
              <DrawingBrush TileMode="Tile" Viewport="0,0,4,4" ViewportUnits="Absolute">
                <DrawingBrush.Drawing>
                  <GeometryDrawing Brush="#000000"><GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,4,2"/></GeometryDrawing.Geometry></GeometryDrawing>
                </DrawingBrush.Drawing>
              </DrawingBrush>
            </Rectangle.Fill>
          </Rectangle>
        </Grid>
      </Border>

      <Grid Margin="18">
        <Grid.RowDefinitions><RowDefinition Height="34"/><RowDefinition Height="*"/></Grid.RowDefinitions>

        <Grid x:Name="TitleBar" Background="Transparent">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="&#9608; " Foreground="#A4F000" FontSize="15"/>
            <TextBlock x:Name="TitleText" Text="STEAM STATUS SCHEDULER" FontSize="15" FontWeight="Bold">
              <TextBlock.Effect><DropShadowEffect Color="#A4F000" BlurRadius="12" ShadowDepth="0" Opacity="0.9"/></TextBlock.Effect>
            </TextBlock>
            <TextBlock x:Name="VersionText" Text="  //  v1.2" Foreground="#4E7300" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <TextBlock x:Name="Clock" Text="--:--:--" Foreground="#4E7300" Margin="0,0,18,0" VerticalAlignment="Center"/>
            <Button x:Name="BtnMin" Content="[ _ ]" Style="{StaticResource Btn}" Padding="6,1" BorderThickness="0" Margin="0"/>
            <Button x:Name="BtnClose" Content="[ x ]" Style="{StaticResource Btn}" Padding="6,1" BorderThickness="0" Margin="0"/>
          </StackPanel>
        </Grid>

        <Grid Grid.Row="1" Margin="0,8,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="424"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

          <!-- ===================== LEFT PANEL ===================== -->
          <Border Grid.Column="0" Background="#000000" BorderBrush="#A4F000" BorderThickness="2" CornerRadius="8" Padding="14,10,14,10">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <ScrollViewer VerticalScrollBarVisibility="Hidden">
                <StackPanel>

                  <Grid Margin="0,2,0,6">
                    <Border Style="{StaticResource SectionBox}">
                      <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <StackPanel>
                          <StackPanel Orientation="Horizontal">
                            <TextBlock x:Name="SvcDot" Text="&#9679;" Foreground="#4E7300" Margin="0,0,8,0" FontSize="14"/>
                            <TextBlock x:Name="SvcText" Text="verificando..." FontWeight="Bold"/>
                          </StackPanel>
                          <TextBlock x:Name="SteamText" Text="steam.exe: ..." Foreground="#4E7300" Margin="0,4,0,0"/>
                        </StackPanel>
                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                          <Button x:Name="BtnStart" Content="[ Iniciar ]" Style="{StaticResource Btn}" Visibility="Collapsed"/>
                          <Button x:Name="BtnLog" Content="[ Log ]" Style="{StaticResource Btn}" Margin="0"/>
                        </StackPanel>
                      </Grid>
                    </Border>
                    <TextBlock Text=" Serviço " Style="{StaticResource SectionTitle}"/>
                  </Grid>

                  <Grid Margin="0,4,0,6">
                    <Border Style="{StaticResource SectionBox}">
                      <StackPanel>
                        <ScrollViewer MaxHeight="150" VerticalScrollBarVisibility="Hidden"><StackPanel x:Name="WindowList"/></ScrollViewer>
                        <TextBlock x:Name="EmptyHint" Text="nenhuma janela. arraste na grade semanal ou clique em [ + Nova ]" Foreground="#4E7300" TextWrapping="Wrap" Margin="2,2,0,6"/>
                        <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                          <Button x:Name="BtnNew" Content="[ + Nova ]" Style="{StaticResource Btn}"/>
                          <Button x:Name="BtnDup" Content="[ Duplicar ]" Style="{StaticResource Btn}"/>
                          <Button x:Name="BtnDel" Content="[ Remover ]" Style="{StaticResource Btn}" BorderBrush="#FF3B3B" Foreground="#FF3B3B" Margin="0"/>
                        </StackPanel>
                      </StackPanel>
                    </Border>
                    <TextBlock Text=" 1. Janelas de horário " Style="{StaticResource SectionTitle}"/>
                  </Grid>

                  <Grid Margin="0,4,0,6" x:Name="EditorSection">
                    <Border Style="{StaticResource SectionBox}">
                      <StackPanel>
                        <TextBlock Text="Nome" Style="{StaticResource Label}" Margin="0,0,0,3"/>
                        <TextBox x:Name="TbName" Style="{StaticResource Tb}"/>
                        <TextBlock Text="Dias" Style="{StaticResource Label}"/>
                        <WrapPanel x:Name="DaysPanel"/>
                        <StackPanel Orientation="Horizontal">
                          <Button x:Name="BtnWeekdays" Content="seg-sex" Style="{StaticResource Btn}" Padding="6,1" FontSize="11" BorderBrush="#4E7300" Foreground="#4E7300"/>
                          <Button x:Name="BtnWeekend" Content="fds" Style="{StaticResource Btn}" Padding="6,1" FontSize="11" BorderBrush="#4E7300" Foreground="#4E7300"/>
                          <Button x:Name="BtnAllDays" Content="todos" Style="{StaticResource Btn}" Padding="6,1" FontSize="11" BorderBrush="#4E7300" Foreground="#4E7300"/>
                        </StackPanel>
                        <Grid Margin="0,6,0,0">
                          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                          <StackPanel>
                            <TextBlock Text="Início (HH:mm)" Style="{StaticResource Label}" Margin="0,0,0,3"/>
                            <TextBox x:Name="TbStart" Style="{StaticResource Tb}"/>
                          </StackPanel>
                          <StackPanel Grid.Column="2">
                            <TextBlock Text="Fim (HH:mm)" Style="{StaticResource Label}" Margin="0,0,0,3"/>
                            <TextBox x:Name="TbEnd" Style="{StaticResource Tb}"/>
                          </StackPanel>
                        </Grid>
                        <TextBlock Text="Status durante a janela" Style="{StaticResource Label}"/>
                        <WrapPanel x:Name="StatusPanel"/>
                      </StackPanel>
                    </Border>
                    <TextBlock Text=" 2. Editar janela " Style="{StaticResource SectionTitle}"/>
                  </Grid>

                  <Grid Margin="0,4,0,6">
                    <Border Style="{StaticResource SectionBox}">
                      <WrapPanel x:Name="DefaultPanel"/>
                    </Border>
                    <TextBlock Text=" 3. Fora das janelas, voltar pra " Style="{StaticResource SectionTitle}"/>
                  </Grid>

                </StackPanel>
              </ScrollViewer>

              <StackPanel Grid.Row="1" Margin="0,8,0,0">
                <TextBlock x:Name="MsgText" Text="" Foreground="#4E7300" TextWrapping="Wrap" MinHeight="18" Margin="2,0,0,6"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                  <Button x:Name="BtnSave" Content="[ SALVAR ]" Style="{StaticResource Btn}" Padding="18,6" FontWeight="Bold"/>
                  <Button x:Name="BtnTest" Content="[ Testar 45s ]" Style="{StaticResource Btn}" Padding="14,6" Margin="0"/>
                </StackPanel>
              </StackPanel>
            </Grid>
          </Border>

          <!-- ===================== RIGHT PANEL ===================== -->
          <Border Grid.Column="2" Background="#000000" BorderBrush="#A4F000" BorderThickness="2" CornerRadius="8" Padding="16,12,16,12">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

              <Grid Grid.Row="0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="MODO ATUAL" Foreground="#4E7300" FontSize="11"/>
                  <TextBlock x:Name="ModeText" Text="..." FontSize="26" FontWeight="Bold">
                    <TextBlock.Effect><DropShadowEffect Color="#A4F000" BlurRadius="14" ShadowDepth="0" Opacity="0.8"/></TextBlock.Effect>
                  </TextBlock>
                </StackPanel>
                <StackPanel Grid.Column="1" HorizontalAlignment="Right">
                  <TextBlock x:Name="NextLabel" Text="PRÓXIMA JANELA" Foreground="#4E7300" FontSize="11" HorizontalAlignment="Right"/>
                  <TextBlock x:Name="NextText" Text="..." FontSize="15" HorizontalAlignment="Right"/>
                  <TextBlock x:Name="CountText" Text="" FontSize="22" FontWeight="Bold" HorizontalAlignment="Right" Foreground="#D9FF80"/>
                </StackPanel>
              </Grid>

              <Grid Grid.Row="1" x:Name="SkullHost" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,6,0,6">
                <TextBlock x:Name="Skull" FontSize="11" LineHeight="13" LineStackingStrategy="BlockLineHeight" Foreground="#A4F000" Opacity="0.75" TextWrapping="NoWrap">
                  <TextBlock.Effect><DropShadowEffect Color="#A4F000" BlurRadius="5" ShadowDepth="0" Opacity="0.55"/></TextBlock.Effect>
                </TextBlock>
                <Canvas x:Name="EyeLayer" IsHitTestVisible="False">
                  <Ellipse x:Name="EyeL" Width="16" Height="9" Fill="#E4FF66" Opacity="0.9">
                    <Ellipse.Effect><DropShadowEffect Color="#A4F000" BlurRadius="24" ShadowDepth="0" Opacity="1"/></Ellipse.Effect>
                  </Ellipse>
                  <Ellipse x:Name="EyeR" Width="16" Height="9" Fill="#E4FF66" Opacity="0.9">
                    <Ellipse.Effect><DropShadowEffect Color="#A4F000" BlurRadius="24" ShadowDepth="0" Opacity="1"/></Ellipse.Effect>
                  </Ellipse>
                </Canvas>
              </Grid>

              <StackPanel Grid.Row="2" x:Name="TestPanel" Visibility="Collapsed" Margin="0,0,0,8">
                <TextBlock x:Name="TestText" Text="" HorizontalAlignment="Center" FontWeight="Bold"/>
                <Border BorderBrush="#4E7300" BorderThickness="1" Height="10" Margin="40,4,40,0" CornerRadius="2">
                  <Rectangle x:Name="TestBar" Fill="#A4F000" HorizontalAlignment="Left" Width="0"/>
                </Border>
              </StackPanel>

              <Grid Grid.Row="3">
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Text="SEMANA  //  arraste numa linha pra criar uma janela, clique numa janela pra editar" Foreground="#4E7300" FontSize="11" Margin="0,0,0,6"/>
                <Canvas x:Name="HourLabels" Grid.Row="1" Grid.Column="1" Height="14"/>
                <StackPanel x:Name="DayLabels" Grid.Row="2" Grid.Column="0"/>
                <Canvas x:Name="WeekCanvas" Grid.Row="2" Grid.Column="1" Background="#000000" Cursor="Cross" HorizontalAlignment="Left"/>
              </Grid>
            </Grid>
          </Border>
        </Grid>
      </Grid>

      <Border x:Name="Toast" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,34"
              Background="#000000" BorderBrush="#A4F000" BorderThickness="1" CornerRadius="4" Padding="16,8">
        <Border.Effect><DropShadowEffect Color="#A4F000" BlurRadius="20" ShadowDepth="0" Opacity="0.8"/></Border.Effect>
        <TextBlock x:Name="ToastText" Text="" FontWeight="Bold"/>
      </Border>

      <Grid x:Name="LogOverlay" Visibility="Collapsed" Background="#D9000000">
        <Border Width="760" MaxHeight="520" Background="#000000" BorderBrush="#A4F000" BorderThickness="2" CornerRadius="8" Padding="16">
          <Border.Effect><DropShadowEffect Color="#A4F000" BlurRadius="30" ShadowDepth="0" Opacity="0.6"/></Border.Effect>
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <TextBlock Text="LOG DO SERVIÇO  //  últimas 30 linhas" FontWeight="Bold" Margin="0,0,0,10"/>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
              <TextBlock x:Name="LogText" FontSize="12" TextWrapping="NoWrap"/>
            </ScrollViewer>
            <Button Grid.Row="2" x:Name="BtnLogClose" Content="[ fechar ]" Style="{StaticResource Btn}" HorizontalAlignment="Right" Margin="0,10,0,0"/>
          </Grid>
        </Border>
      </Grid>

      <Grid x:Name="Boot" Background="#07090D" Cursor="Hand">
        <TextBlock x:Name="BootText" Margin="46,40" FontSize="14" Foreground="#A4F000" TextWrapping="NoWrap" VerticalAlignment="Top">
          <TextBlock.Effect><DropShadowEffect Color="#A4F000" BlurRadius="8" ShadowDepth="0" Opacity="0.7"/></TextBlock.Effect>
        </TextBlock>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

# ====================================================================== build window

$App = @{
    Cfg = $null; Selected = -1; Dirty = $false; Loading = $false
    TaskInstalled = $false; Frames = New-Object System.Collections.ArrayList; FrameGen = 0; Frame = 0
    DragDay = -1; DragStart = -1; DragEnd = -1; Cells = $null; Testing = $false; TestLeft = 0
    Tick = 0; BootText = ''; BootPos = 0; BootDone = $false; Backdrop = $null; Rnd = New-Object Random
    SteamRunning = $false; EyeW = 6.0; Closing = $false
}
$Ctl = @{}

$reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($n in @('Root','Backdrop','TitleBar','TitleText','VersionText','Clock','BtnMin','BtnClose','SvcDot','SvcText','SteamText','BtnStart','BtnLog',
                 'WindowList','EmptyHint','BtnNew','BtnDup','BtnDel','EditorSection','TbName','DaysPanel','BtnWeekdays','BtnWeekend','BtnAllDays',
                 'TbStart','TbEnd','StatusPanel','DefaultPanel','MsgText','BtnSave','BtnTest','ModeText','NextLabel','NextText','CountText',
                 'SkullHost','Skull','EyeLayer','EyeL','EyeR','TestPanel','TestText','TestBar','HourLabels','DayLabels','WeekCanvas',
                 'Toast','ToastText','LogOverlay','LogText','BtnLogClose','Boot','BootText')) {
    $Ctl[$n] = $Window.FindName($n)
}
$Ctl.VersionText.Text = '  //  ' + $Version

try {
    $steamExe = Get-SteamExe
    if ($steamExe) {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($steamExe)
        $Window.Icon = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    }
} catch { }

# ---------------------------------------------------------------- ui helpers

function Show-Toast([string]$Text, [string]$Hex = '#A4F000') {
    $Ctl.ToastText.Text = $Text
    $Ctl.ToastText.Foreground = Brush $Hex
    $Ctl.Toast.BorderBrush = Brush $Hex
    $Ctl.Toast.Visibility = 'Visible'
    $Ctl.Toast.BeginAnimation([Windows.UIElement]::OpacityProperty, [Windows.Media.Animation.DoubleAnimation]::new(0, 1, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(200))))
    $App.ToastUntil = (Get-Date).AddMilliseconds(2600)
}
function Set-Msg([string]$Text, [string]$Hex = '#4E7300') { $Ctl.MsgText.Text = $Text; $Ctl.MsgText.Foreground = Brush $Hex }
function Set-Dirty([bool]$Value) {
    $App.Dirty = $Value
    if ($Value) {
        $Ctl.BtnSave.Effect = [Windows.Media.Effects.DropShadowEffect]::new()
        $Ctl.BtnSave.Effect.Color = [Windows.Media.Color]::FromRgb(164, 240, 0); $Ctl.BtnSave.Effect.BlurRadius = 18; $Ctl.BtnSave.Effect.ShadowDepth = 0
        $Ctl.BtnSave.Content = '[ SALVAR * ]'
    } else {
        $Ctl.BtnSave.Effect = $null
        $Ctl.BtnSave.Content = '[ SALVAR ]'
    }
}

function New-Tog([string]$Text, $Tag, [string]$Hex) {
    $t = New-Object Windows.Controls.Primitives.ToggleButton
    $t.Style = $Window.FindResource('Tog')
    $t.Content = $Text; $t.Tag = $Tag
    $t.Foreground = Brush $Hex
    return $t
}

# ---------------------------------------------------------------- window list / editor

function Get-SelectedWindow { if ($App.Selected -ge 0 -and $App.Selected -lt $App.Cfg.windows.Count) { return $App.Cfg.windows[$App.Selected] }; return $null }

function Refresh-List {
    $Ctl.WindowList.Children.Clear()
    $Ctl.EmptyHint.Visibility = @('Visible', 'Collapsed')[[int]($App.Cfg.windows.Count -gt 0)]
    for ($i = 0; $i -lt $App.Cfg.windows.Count; $i++) {
        $w = $App.Cfg.windows[$i]
        $row = New-Object Windows.Controls.Border
        $row.Tag = $i; $row.Cursor = 'Hand'; $row.Padding = '6,4'; $row.Margin = '0,0,0,3'; $row.CornerRadius = 3
        $row.BorderThickness = 1
        if ($i -eq $App.Selected) { $row.Background = $Br.SelBg; $row.BorderBrush = $Br.Lime } else { $row.Background = $Br.Black; $row.BorderBrush = $Br.Black }
        $g = New-Object Windows.Controls.Grid
        $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = '28'
        $c1 = New-Object Windows.Controls.ColumnDefinition
        $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
        $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
        $num = New-Object Windows.Controls.TextBlock; $num.Text = ('{0:00}' -f ($i + 1)); $num.Foreground = $Br.LimeDim; $num.VerticalAlignment = 'Center'
        $sp = New-Object Windows.Controls.StackPanel
        $t1 = New-Object Windows.Controls.TextBlock; $t1.Text = $w.name; $t1.FontWeight = 'Bold'; $t1.Foreground = $Br.LimeSoft
        $t2 = New-Object Windows.Controls.TextBlock; $t2.Text = (Format-Days $w.days) + '  ·  ' + $w.start + '-' + $w.end; $t2.Foreground = $Br.LimeDim; $t2.FontSize = 11
        $sp.Children.Add($t1) | Out-Null; $sp.Children.Add($t2) | Out-Null
        $chip = New-Object Windows.Controls.Border; $chip.BorderThickness = 1; $chip.CornerRadius = 3; $chip.Padding = '6,1'; $chip.VerticalAlignment = 'Center'
        $chip.BorderBrush = $Br[$w.status]
        $ct = New-Object Windows.Controls.TextBlock; $ct.Text = $w.status; $ct.Foreground = $Br[$w.status]; $ct.FontSize = 11
        $chip.Child = $ct
        [Windows.Controls.Grid]::SetColumn($sp, 1); [Windows.Controls.Grid]::SetColumn($chip, 2)
        $g.Children.Add($num) | Out-Null; $g.Children.Add($sp) | Out-Null; $g.Children.Add($chip) | Out-Null
        $row.Child = $g
        $row.Add_MouseLeftButtonDown({ Select-Window ([int]$args[0].Tag) })
        $row.Add_MouseEnter({ if ([int]$args[0].Tag -ne $App.Selected) { $args[0].Background = $Br.HoverBg } })
        $row.Add_MouseLeave({ if ([int]$args[0].Tag -ne $App.Selected) { $args[0].Background = $Br.Black } })
        $Ctl.WindowList.Children.Add($row) | Out-Null
    }
}

function Refresh-Editor {
    $App.Loading = $true
    $w = Get-SelectedWindow
    $has = ($null -ne $w)
    $Ctl.EditorSection.Opacity = @(0.35, 1)[[int]$has]
    $Ctl.EditorSection.IsEnabled = $has
    $Ctl.BtnDup.IsEnabled = $has; $Ctl.BtnDel.IsEnabled = $has
    if ($has) {
        $Ctl.TbName.Text = $w.name; $Ctl.TbStart.Text = $w.start; $Ctl.TbEnd.Text = $w.end
        foreach ($t in $Ctl.DaysPanel.Children) { $t.IsChecked = (Test-WindowDay $w ([int]$t.Tag)) }
        foreach ($t in $Ctl.StatusPanel.Children) { $t.IsChecked = ([string]$t.Tag -eq $w.status) }
    } else {
        $Ctl.TbName.Text = ''; $Ctl.TbStart.Text = ''; $Ctl.TbEnd.Text = ''
        foreach ($t in $Ctl.DaysPanel.Children) { $t.IsChecked = $false }
        foreach ($t in $Ctl.StatusPanel.Children) { $t.IsChecked = $false }
    }
    $Ctl.TbStart.BorderBrush = $Br.LimeDim; $Ctl.TbEnd.BorderBrush = $Br.LimeDim
    foreach ($t in $Ctl.DefaultPanel.Children) { $t.IsChecked = ([string]$t.Tag -eq $App.Cfg.defaultStatus) }
    $App.Loading = $false
}

function Select-Window([int]$Index) {
    $App.Selected = $Index
    Refresh-List; Refresh-Editor; Update-Grid
}

function Refresh-All { Refresh-List; Refresh-Editor; Update-Grid; Update-Readout }

function Apply-Days {
    if ($App.Loading) { return }
    $w = Get-SelectedWindow; if (-not $w) { return }
    $days = @()
    foreach ($t in $Ctl.DaysPanel.Children) { if ($t.IsChecked) { $days += $DayNamesEn[[int]$t.Tag] } }
    $w.days = $days
    Set-Dirty $true; Refresh-List; Update-Grid; Update-Readout
}

function Set-DaysPreset([int[]]$Indexes) {
    $w = Get-SelectedWindow; if (-not $w) { return }
    $App.Loading = $true
    foreach ($t in $Ctl.DaysPanel.Children) { $t.IsChecked = ($Indexes -contains [int]$t.Tag) }
    $App.Loading = $false
    Apply-Days
}

function Apply-Time([string]$Which) {
    if ($App.Loading) { return }
    $w = Get-SelectedWindow; if (-not $w) { return }
    $tb = $Ctl['Tb' + $Which]
    $text = $tb.Text.Trim()
    if ($text -match '^\d{1,2}$') { $text = ('{0:00}:00' -f [int]$text) }
    if ($text -match '^(\d{1,2}):(\d{1,2})$') { $text = ('{0:00}:{1:00}' -f [int]$matches[1], [int]$matches[2]) }
    if (Test-Time $text) {
        $tb.BorderBrush = $Br.LimeDim
        if ($Which -eq 'Start') { $w.start = $text } else { $w.end = $text }
        if ((Test-Time $w.start) -and (Test-Time $w.end) -and ([TimeSpan]$w.end -le [TimeSpan]$w.start)) {
            $Ctl.TbEnd.BorderBrush = $Br.Red; Set-Msg 'o fim precisa ser depois do início' '#FF3B3B'
        } else { Set-Msg '' }
        Set-Dirty $true; Refresh-List; Update-Grid; Update-Readout
    } else {
        $tb.BorderBrush = $Br.Red
    }
}

function New-WindowAt([int]$Day, [int]$ColStart, [int]$ColEnd, [string]$Status = 'invisible') {
    $n = $App.Cfg.windows.Count + 1
    $endMin = ($ColEnd + 1) * 30; if ($endMin -ge 1440) { $endMin = 1439 }
    $w = @{ name = ('janela-' + $n); days = @($DayNamesEn[$Day]); start = (Format-Time ($ColStart * 30)); end = (Format-Time $endMin); status = $Status }
    [void]$App.Cfg.windows.Add($w)
    Set-Dirty $true
    Select-Window ($App.Cfg.windows.Count - 1)
    Update-Readout
    $Ctl.TbName.Focus() | Out-Null; $Ctl.TbName.SelectAll()
}

# ---------------------------------------------------------------- weekly grid

$CellW = 12; $CellH = 15; $GridCols = 48
function Build-Grid {
    $Ctl.WeekCanvas.Width = $GridCols * $CellW; $Ctl.WeekCanvas.Height = 7 * $CellH
    $App.Cells = New-Object 'object[,]' 7, $GridCols
    for ($d = 0; $d -lt 7; $d++) {
        $lbl = New-Object Windows.Controls.TextBlock; $lbl.Text = $DayNamesPt[$d]; $lbl.Height = $CellH; $lbl.Foreground = $Br.LimeDim; $lbl.FontSize = 11
        $Ctl.DayLabels.Children.Add($lbl) | Out-Null
        for ($c = 0; $c -lt $GridCols; $c++) {
            $r = New-Object Windows.Shapes.Rectangle
            $r.Width = $CellW - 1; $r.Height = $CellH - 2; $r.Fill = $Br.Cell; $r.RadiusX = 1; $r.RadiusY = 1
            [Windows.Controls.Canvas]::SetLeft($r, $c * $CellW); [Windows.Controls.Canvas]::SetTop($r, $d * $CellH)
            $Ctl.WeekCanvas.Children.Add($r) | Out-Null
            $App.Cells[$d, $c] = $r
        }
    }
    foreach ($h in 0, 3, 6, 9, 12, 15, 18, 21, 24) {
        $t = New-Object Windows.Controls.TextBlock; $t.Text = [string]$h; $t.Foreground = $Br.LimeDim; $t.FontSize = 10
        [Windows.Controls.Canvas]::SetLeft($t, $h * 2 * $CellW - 3); [Windows.Controls.Canvas]::SetTop($t, 0)
        $Ctl.HourLabels.Children.Add($t) | Out-Null
    }
}

function Get-WindowIndexAt([int]$Day, [int]$Col) {
    $minute = $Col * 30
    for ($i = 0; $i -lt $App.Cfg.windows.Count; $i++) {
        $w = $App.Cfg.windows[$i]
        if (-not (Test-WindowDay $w $Day)) { continue }
        if (-not (Test-Time $w.start) -or -not (Test-Time $w.end)) { continue }
        $s = ([TimeSpan]$w.start).TotalMinutes; $e = ([TimeSpan]$w.end).TotalMinutes
        if ($minute -ge $s -and $minute -lt $e) { return $i }
    }
    return -1
}

function Update-Grid {
    if (-not $App.Cells) { return }
    for ($d = 0; $d -lt 7; $d++) {
        for ($c = 0; $c -lt $GridCols; $c++) {
            $r = $App.Cells[$d, $c]
            $i = Get-WindowIndexAt $d $c
            if ($i -ge 0) {
                $r.Fill = $Br[$App.Cfg.windows[$i].status]
                $r.Opacity = @(0.55, 1)[[int]($i -eq $App.Selected)]
            } else {
                $r.Fill = $Br.Cell; $r.Opacity = 1
            }
            if ($App.DragDay -eq $d -and $c -ge [Math]::Min($App.DragStart, $App.DragEnd) -and $c -le [Math]::Max($App.DragStart, $App.DragEnd)) {
                $r.Fill = $Br.White; $r.Opacity = 0.85
            }
        }
    }
}

# ---------------------------------------------------------------- readout (mode, next window, service)

function Update-Readout {
    $mode = Get-CurrentMode
    $Ctl.ModeText.Text = $StatusPt[$mode]; $Ctl.ModeText.Foreground = $Br[$mode]
    $Ctl.ModeText.Effect.Color = ($Br[$mode]).Color
    $isHidden = ($mode -ne 'online')
    $Ctl.Skull.Opacity = @(0.75, 1)[[int]$isHidden]
    $eyeHex = @('#E4FF66', '#FF4D4D')[[int]$isHidden]
    $Ctl.EyeL.Fill = Brush $eyeHex; $Ctl.EyeR.Fill = Brush $eyeHex
    $Ctl.EyeL.Effect.Color = (Brush $eyeHex).Color; $Ctl.EyeR.Effect.Color = (Brush $eyeHex).Color

    $ev = Get-NextEvent
    if (-not $ev) {
        $Ctl.NextLabel.Text = 'PRÓXIMA JANELA'; $Ctl.NextText.Text = 'nenhuma configurada'; $Ctl.CountText.Text = ''
    } else {
        $w = $ev.window
        $left = $ev.when - (Get-Date)
        $cd = ('{0:hh\:mm\:ss}' -f $left)
        if ($left.Days -ge 1) { $cd = ('{0}d {1:hh\:mm\:ss}' -f $left.Days, $left) }
        if ($ev.kind -eq 'end') {
            $Ctl.NextLabel.Text = 'JANELA ATIVA  //  ' + $w.name.ToUpper()
            $Ctl.NextText.Text = 'termina ' + $ev.when.ToString('ddd HH:mm')
        } else {
            $Ctl.NextLabel.Text = 'PRÓXIMA JANELA  //  ' + $w.name.ToUpper()
            $Ctl.NextText.Text = $StatusPt[$w.status].ToLower() + ' ' + $ev.when.ToString('ddd HH:mm') + ' às ' + $w.end
        }
        $Ctl.CountText.Text = $cd
    }

    $svc = Get-ServiceState
    $Ctl.SvcText.Text = 'serviço: ' + $svc
    if ($svc -eq 'ATIVO') { $Ctl.SvcDot.Foreground = $Br.Lime; $Ctl.SvcText.Foreground = $Br.Lime; $Ctl.BtnStart.Visibility = 'Collapsed' }
    else { $Ctl.SvcDot.Foreground = $Br.Red; $Ctl.SvcText.Foreground = $Br.Red; $Ctl.BtnStart.Visibility = @('Collapsed', 'Visible')[[int]$App.TaskInstalled] }
    $Ctl.SteamText.Text = 'steam.exe: ' + @('fechada (o status só muda com ela aberta)', 'rodando')[[int]$App.SteamRunning]
}

# ---------------------------------------------------------------- log

function Show-Log {
    $Ctl.LogText.Inlines.Clear()
    if (Test-Path $LogPath) {
        foreach ($l in (Get-Content $LogPath -Tail 30)) {
            $run = New-Object Windows.Documents.Run ($l + "`n")
            $run.Foreground = $Br.Gray
            if ($l -match 'ERROR') { $run.Foreground = $Br.Red }
            elseif ($l -match "set to 'invisible'") { $run.Foreground = $Br.Lime }
            elseif ($l -match 'restored') { $run.Foreground = $Br.online }
            elseif ($l -match 'manual') { $run.Foreground = $Br.LimeSoft }
            $Ctl.LogText.Inlines.Add($run)
        }
    } else {
        $Ctl.LogText.Inlines.Add((New-Object Windows.Documents.Run '(ainda não tem log; o serviço cria quando inicia)'))
    }
    $Ctl.LogOverlay.Visibility = 'Visible'
}

# ---------------------------------------------------------------- backdrop / boot

function New-Backdrop {
    $sb = New-Object Text.StringBuilder
    for ($r = 0; $r -lt 18; $r++) {
        for ($c = 0; $c -lt 24; $c++) { [void]$sb.Append($App.Rnd.Next(2)); [void]$sb.Append(' ') }
        [void]$sb.Append("`n")
    }
    $App.Backdrop = $sb.ToString().ToCharArray()
    $Ctl.Backdrop.Text = New-Object string (,$App.Backdrop)
}
function Mutate-Backdrop {
    for ($k = 0; $k -lt 10; $k++) {
        $i = $App.Rnd.Next($App.Backdrop.Length)
        if ($App.Backdrop[$i] -eq '0') { $App.Backdrop[$i] = '1' } elseif ($App.Backdrop[$i] -eq '1') { $App.Backdrop[$i] = '0' }
    }
    $Ctl.Backdrop.Text = New-Object string (,$App.Backdrop)
}

function Start-Boot {
    $svc = Get-ServiceState
    $steamWord = @('FECHADA', 'RODANDO')[[int]$App.SteamRunning]
    $App.BootStart = Get-Date
    $lines = @(
        "> STEAM STATUS SCHEDULER $Version",
        "> usuário ............................ $env:USERNAME",
        "> serviço agendado ................... $svc",
        "> steam.exe .......................... $steamWord",
        "> janelas carregadas ................. $($App.Cfg.windows.Count)",
        "> motor ascii ........................ OK",
        "> acesso liberado_"
    )
    $App.BootText = ($lines -join "`n"); $App.BootPos = 0
}

# ---------------------------------------------------------------- events

$Ctl.TitleBar.Add_MouseLeftButtonDown({ try { $Window.DragMove() } catch { } })
$Ctl.BtnMin.Add_Click({ $Window.WindowState = 'Minimized' })
$Ctl.BtnClose.Add_Click({ $Window.Close() })
$Window.Add_Closing({
    if ($App.Dirty -and -not $App.Closing) {
        $r = [Windows.MessageBox]::Show('Tem alterações não salvas. Salvar antes de sair?', 'Steam Status Scheduler', 'YesNoCancel', 'Question')
        if ($r -eq 'Cancel') { $args[1].Cancel = $true; return }
        if ($r -eq 'Yes') {
            $err = Test-Config $App.Cfg
            if ($err) { [Windows.MessageBox]::Show($err, 'Não deu pra salvar', 'OK', 'Warning'); $args[1].Cancel = $true; return }
            Save-Config $App.Cfg
        }
    }
    $App.Closing = $true
})
$Ctl.Boot.Add_MouseLeftButtonDown({ Finish-Boot })
$Ctl.BtnLog.Add_Click({ Show-Log })
$Ctl.BtnLogClose.Add_Click({ $Ctl.LogOverlay.Visibility = 'Collapsed' })
$Ctl.LogOverlay.Add_MouseLeftButtonDown({ if ($args[1].OriginalSource -eq $Ctl.LogOverlay) { $Ctl.LogOverlay.Visibility = 'Collapsed' } })
$Ctl.BtnStart.Add_Click({
    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Show-Toast 'serviço iniciado, aguardando o primeiro batimento...'
})
$Ctl.BtnNew.Add_Click({ New-WindowAt 5 12 23 'invisible'; Show-Toast 'janela criada: ajusta nome, dias e horário ao lado' })
$Ctl.BtnDup.Add_Click({
    $w = Get-SelectedWindow; if (-not $w) { return }
    $copy = @{ name = ($w.name + '-copia'); days = @($w.days); start = $w.start; end = $w.end; status = $w.status }
    [void]$App.Cfg.windows.Add($copy); Set-Dirty $true; Select-Window ($App.Cfg.windows.Count - 1); Update-Readout
})
$Ctl.BtnDel.Add_Click({
    $w = Get-SelectedWindow; if (-not $w) { return }
    $App.Cfg.windows.RemoveAt($App.Selected)
    if ($App.Selected -ge $App.Cfg.windows.Count) { $App.Selected = $App.Cfg.windows.Count - 1 }
    Set-Dirty $true; Refresh-All
    Show-Toast ('removida: ' + $w.name) '#FF3B3B'
})
$Ctl.TbName.Add_TextChanged({
    if ($App.Loading) { return }
    $w = Get-SelectedWindow; if (-not $w) { return }
    $w.name = $Ctl.TbName.Text
    Set-Dirty $true; Refresh-List; Update-Readout
})
$Ctl.TbStart.Add_TextChanged({ Apply-Time 'Start' })
$Ctl.TbEnd.Add_TextChanged({ Apply-Time 'End' })
$Ctl.TbStart.Add_LostFocus({ $w = Get-SelectedWindow; if ($w) { $App.Loading = $true; $Ctl.TbStart.Text = $w.start; $App.Loading = $false } })
$Ctl.TbEnd.Add_LostFocus({ $w = Get-SelectedWindow; if ($w) { $App.Loading = $true; $Ctl.TbEnd.Text = $w.end; $App.Loading = $false } })
$Ctl.BtnWeekdays.Add_Click({ Set-DaysPreset @(0, 1, 2, 3, 4) })
$Ctl.BtnWeekend.Add_Click({ Set-DaysPreset @(5, 6) })
$Ctl.BtnAllDays.Add_Click({ Set-DaysPreset @(0, 1, 2, 3, 4, 5, 6) })

for ($d = 0; $d -lt 7; $d++) {
    $t = New-Tog $DayNamesPt[$d] $d '#A4F000'
    $t.Add_Checked({ Apply-Days }); $t.Add_Unchecked({ Apply-Days })
    $Ctl.DaysPanel.Children.Add($t) | Out-Null
}
foreach ($st in $Statuses) {
    $t = New-Tog $st $st $StatusHex[$st]
    $t.Add_Click({
        $me = $args[0]
        foreach ($o in $Ctl.StatusPanel.Children) { if ($o -ne $me) { $o.IsChecked = $false } }
        $me.IsChecked = $true
        if ($App.Loading) { return }
        $w = Get-SelectedWindow; if (-not $w) { return }
        $w.status = [string]$me.Tag
        Set-Dirty $true; Refresh-List; Update-Grid; Update-Readout
    })
    $Ctl.StatusPanel.Children.Add($t) | Out-Null

    $t2 = New-Tog $st $st $StatusHex[$st]
    $t2.Add_Click({
        $me = $args[0]
        foreach ($o in $Ctl.DefaultPanel.Children) { if ($o -ne $me) { $o.IsChecked = $false } }
        $me.IsChecked = $true
        if ($App.Loading) { return }
        $App.Cfg.defaultStatus = [string]$me.Tag
        Set-Dirty $true; Update-Readout
    })
    $Ctl.DefaultPanel.Children.Add($t2) | Out-Null
}

$Ctl.BtnSave.Add_Click({
    $err = Test-Config $App.Cfg
    if ($err) { Set-Msg $err '#FF3B3B'; Show-Toast $err '#FF3B3B'; return }
    Save-Config $App.Cfg
    Set-Dirty $false; Set-Msg ('salvo ' + (Get-Date).ToString('HH:mm:ss') + '  //  o serviço aplica em até 30s')
    Show-Toast 'SALVO  //  o serviço lê o novo horário em até 30 segundos'
})

$Ctl.BtnTest.Add_Click({
    if ($App.Testing) { return }
    if (-not (Test-SteamRunning)) { Show-Toast 'a Steam não está aberta' '#FF3B3B'; return }
    $App.Testing = $true; $App.TestLeft = 45
    Set-SteamStatus 'invisible'
    $Ctl.TestPanel.Visibility = 'Visible'; $Ctl.BtnTest.IsEnabled = $false
    $Ctl.TestText.Text = 'TESTE: INVISÍVEL  //  volta pra online em 45s'
    $Ctl.TestBar.Width = 0
    Show-Toast 'invisível agora. olha sua lista de amigos.'
})

$Ctl.WeekCanvas.Add_MouseLeftButtonDown({
    $p = $args[1].GetPosition($Ctl.WeekCanvas)
    $d = [int][Math]::Floor($p.Y / $CellH); $c = [int][Math]::Floor($p.X / $CellW)
    if ($d -lt 0 -or $d -gt 6 -or $c -lt 0 -or $c -ge $GridCols) { return }
    $App.DragDay = $d; $App.DragStart = $c; $App.DragEnd = $c
    $Ctl.WeekCanvas.CaptureMouse() | Out-Null
    Update-Grid
})
$Ctl.WeekCanvas.Add_MouseMove({
    if ($App.DragDay -lt 0) { return }
    $p = $args[1].GetPosition($Ctl.WeekCanvas)
    $c = [int][Math]::Floor($p.X / $CellW); if ($c -lt 0) { $c = 0 }; if ($c -ge $GridCols) { $c = $GridCols - 1 }
    if ($c -ne $App.DragEnd) { $App.DragEnd = $c; Update-Grid }
})
$Ctl.WeekCanvas.Add_MouseLeftButtonUp({
    if ($App.DragDay -lt 0) { return }
    $Ctl.WeekCanvas.ReleaseMouseCapture()
    $d = $App.DragDay; $a = [Math]::Min($App.DragStart, $App.DragEnd); $b = [Math]::Max($App.DragStart, $App.DragEnd)
    $App.DragDay = -1
    $existing = Get-WindowIndexAt $d $a
    if ($a -eq $b -and $existing -ge 0) { Select-Window $existing; return }
    New-WindowAt $d $a $b 'invisible'
    Show-Toast ('nova janela ' + $DayNamesPt[$d] + ' ' + (Format-Time ($a * 30)) + '-' + (Format-Time ([Math]::Min(($b + 1) * 30, 1439))))
})

# ---------------------------------------------------------------- timers

function Finish-Boot {
    if ($App.BootDone) { return }
    $App.BootDone = $true
    $anim = [Windows.Media.Animation.DoubleAnimation]::new(1, 0, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(600)))
    $anim.Add_Completed({ $Ctl.Boot.Visibility = 'Collapsed' })
    $Ctl.Boot.BeginAnimation([Windows.UIElement]::OpacityProperty, $anim)
}

$FxTimer = New-Object Windows.Threading.DispatcherTimer
$FxTimer.Interval = [TimeSpan]::FromMilliseconds(60)
$FxTimer.Add_Tick({
    $App.Tick++
    # boot typewriter (3 chars per tick)
    if (-not $App.BootDone) {
        $elapsed = ((Get-Date) - $App.BootStart).TotalMilliseconds
        $msPerChar = 11; if ($Screenshot) { $msPerChar = 4 }
        $target = [Math]::Min($App.BootText.Length, [int]($elapsed / $msPerChar))
        if ($target -ne $App.BootPos) {
            $App.BootPos = $target
            $Ctl.BootText.Text = $App.BootText.Substring(0, $App.BootPos) + '_'
        }
        if ($App.BootPos -ge $App.BootText.Length -and $elapsed -gt ($App.BootText.Length * $msPerChar + 700)) { Finish-Boot }
    }
    # skull frames: generate progressively, then animate
    if ($App.FrameGen -lt $SkullFrameCount) {
        [void]$App.Frames.Add((New-SkullFrame $App.FrameGen)); $App.FrameGen++
        if ($App.FrameGen -eq 1) { $Ctl.Skull.Text = $App.Frames[0] }
    }
    if ($App.Frames.Count -gt 0 -and $App.Tick % 2 -eq 0) {
        $App.Frame = ($App.Frame + 1) % $App.Frames.Count
        $Ctl.Skull.Text = $App.Frames[$App.Frame]
        if ($Ctl.Skull.ActualWidth -gt 0) {
            $cw = $Ctl.Skull.ActualWidth / $SkullCols
            $e = Get-EyePositions $App.Frame
            [Windows.Controls.Canvas]::SetLeft($Ctl.EyeL, $e[0] * $cw - 8); [Windows.Controls.Canvas]::SetTop($Ctl.EyeL, $e[1] * 13 - 4)
            [Windows.Controls.Canvas]::SetLeft($Ctl.EyeR, $e[2] * $cw - 8); [Windows.Controls.Canvas]::SetTop($Ctl.EyeR, $e[3] * 13 - 4)
            $pulse = 0.55 + 0.45 * [Math]::Abs([Math]::Sin($App.Tick / 9.0))
            $Ctl.EyeL.Opacity = $pulse; $Ctl.EyeR.Opacity = $pulse
        }
    }
    # backdrop noise
    if ($App.Tick % 3 -eq 0) { Mutate-Backdrop }
    # title glitch
    if ($App.Tick % 40 -eq 0) {
        $chars = 'STEAM STATUS SCHEDULER'.ToCharArray()
        $glitch = '#%&@$01!?/\<>'
        for ($k = 0; $k -lt 3; $k++) { $i = $App.Rnd.Next($chars.Length); if ($chars[$i] -ne ' ') { $chars[$i] = $glitch[$App.Rnd.Next($glitch.Length)] } }
        $Ctl.TitleText.Text = New-Object string (,$chars)
    } elseif ($App.Tick % 40 -eq 2) {
        $Ctl.TitleText.Text = 'STEAM STATUS SCHEDULER'
    }
    # service dot blink
    if ($App.Tick % 10 -eq 0) { $Ctl.SvcDot.Opacity = @(1, 0.25)[[int]($Ctl.SvcDot.Opacity -gt 0.5)] }
    # toast expiry
    if ($App.ToastUntil -and (Get-Date) -gt $App.ToastUntil) { $Ctl.Toast.Visibility = 'Collapsed'; $App.ToastUntil = $null }
})

$ClockTimer = New-Object Windows.Threading.DispatcherTimer
$ClockTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
$ClockTimer.Add_Tick({
    $Ctl.Clock.Text = (Get-Date).ToString('ddd dd/MM  HH:mm:ss')
    $App.ClockTick = [int]$App.ClockTick + 1
    if ($App.ClockTick % 3 -eq 0) { $App.SteamRunning = Test-SteamRunning }
    Update-Readout
    if ($App.Testing) {
        $App.TestLeft--
        $Ctl.TestText.Text = ('TESTE: INVISÍVEL  //  volta pra online em {0}s' -f $App.TestLeft)
        $Ctl.TestBar.Width = [Math]::Max(0, (45 - $App.TestLeft) / 45.0 * ($Ctl.TestBar.Parent.ActualWidth - 2))
        if ($App.TestLeft -le 0) {
            Set-SteamStatus 'online'
            $App.Testing = $false; $Ctl.TestPanel.Visibility = 'Collapsed'; $Ctl.BtnTest.IsEnabled = $true
            Show-Toast 'teste concluído: de volta pra online'
        }
    }
})

# ---------------------------------------------------------------- go

if (-not (Test-Path $ConfigPath)) {
    [Windows.MessageBox]::Show("Não achei o config.json em:`n$InstallDir`n`nRoda o Instalar.bat primeiro.", 'Steam Status Scheduler', 'OK', 'Warning') | Out-Null
    exit 1
}
$App.Cfg = Load-Config
$App.SteamRunning = Test-SteamRunning
if ($App.Cfg.windows.Count -gt 0) { $App.Selected = 0 }

New-Backdrop
Build-Grid
Refresh-All
Start-Boot
$Ctl.Clock.Text = (Get-Date).ToString('ddd dd/MM  HH:mm:ss')

$Window.Add_ContentRendered({ $FxTimer.Start(); $ClockTimer.Start() })

if ($Screenshot) {
    $shot = New-Object Windows.Threading.DispatcherTimer
    $shot.Interval = [TimeSpan]::FromMilliseconds($ScreenshotDelayMs)
    $shot.Add_Tick({
        $shot.Stop()
        $root = $Ctl.Root
        $rtb = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$root.ActualWidth + 28, [int]$root.ActualHeight + 28, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $dv = New-Object Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawRectangle([Windows.Media.Brushes]::Black, $null, [Windows.Rect]::new(0, 0, $root.ActualWidth + 28, $root.ActualHeight + 28))
        $dc.DrawRectangle([Windows.Media.VisualBrush]::new($root), $null, [Windows.Rect]::new(14, 14, $root.ActualWidth, $root.ActualHeight))
        $dc.Close()
        $rtb.Render($dv)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Open($Screenshot, 'Create'); $enc.Save($fs); $fs.Close()
        $App.Dirty = $false; $App.Closing = $true
        $Window.Close()
    })
    $shot.Start()
}

[void]$Window.ShowDialog()
