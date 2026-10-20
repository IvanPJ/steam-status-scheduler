# Configurar.ps1 - Steam Status Scheduler desktop UI (cyberpunk neon)
#
# Native WPF window (ships with every Windows 10/11, no extra runtime) to edit the installed
# config.json, see the service state, the weekly schedule as a drag-to-paint grid, the log,
# and run a live test. Launched by the Start Menu shortcut, Configurar.bat or install.ps1.
#
# Saved as UTF-8 WITH BOM on purpose: PowerShell 5.1 needs the BOM for the accented strings.
# PowerShell variables are case-insensitive: globals are $App, $Ctl, $Br (never 1-letter names).

[CmdletBinding()]
param(
    [string]$Screenshot,           # debug: render the window to this PNG after a delay and exit
    [int]$ScreenshotDelayMs = 4000,
    [switch]$Demo                  # docs: sample schedule and sample library instead of the real ones
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing

$InstallDir = Join-Path $env:LOCALAPPDATA 'SteamStatusScheduler'
$ConfigPath = Join-Path $InstallDir 'config.json'
$Version    = 'v2.0'
. (Join-Path $PSScriptRoot 'Tarefas.ps1')

$DayNamesEn = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
$DayNamesPt = @('SEG', 'TER', 'QUA', 'QUI', 'SEX', 'SÁB', 'DOM')
$Statuses   = @('invisible', 'offline', 'away', 'busy', 'online')
$StatusPt   = @{ invisible = 'INVISÍVEL'; offline = 'OFFLINE'; away = 'AUSENTE'; busy = 'OCUPADO'; online = 'ONLINE' }
$StatusHex  = @{ invisible = '#FF2BD6'; offline = '#FF3B5C'; away = '#F5FF3B'; busy = '#FF9A3B'; online = '#00F0FF' }

$Conv = New-Object Windows.Media.BrushConverter
function Brush([string]$Hex) { return $Conv.ConvertFromString($Hex) }
function Color([string]$Hex) { return [Windows.Media.ColorConverter]::ConvertFromString($Hex) }
$Br = @{
    Pink = Brush '#FF2BD6'; Cyan = Brush '#00F0FF'; Yellow = Brush '#F5FF3B'; Red = Brush '#FF3B5C'
    Text = Brush '#F2E9FF'; Dim = Brush '#8A78B0'; Faint = Brush '#4A3A6B'; Dark = Brush '#0A0014'
    Cell = Brush '#1C1030'; CellAlt = Brush '#251640'; RowSel = Brush '#2A0B40'; RowHover = Brush '#1A0A2C'
    Clear = [Windows.Media.Brushes]::Transparent; White = Brush '#FFFFFF'; Star = Brush '#E8DFFF'
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
    $cfg = @{ defaultStatus = 'online'; windows = New-Object System.Collections.ArrayList }
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
        defaultStatus = $Cfg.defaultStatus
        windows       = @($Cfg.windows | ForEach-Object {
            [ordered]@{ name = $_.name; days = @($_.days); start = $_.start; end = $_.end; status = $_.status }
        })
    }
    $json = $out | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($ConfigPath, $json, (New-Object Text.UTF8Encoding $true))
}

function Test-Config($Cfg) {
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

function Set-SteamStatus([string]$Status) {
    $exe = Get-SssSteamExe
    if ($exe) { Start-Process -FilePath $exe -ArgumentList ('-silent steam://friends/status/' + $Status) | Out-Null }
}
function Test-SteamRunning { return [bool](Get-Process -Name 'steam' -ErrorAction SilentlyContinue) }
function Get-ServiceState {
    # the schedule lives in Windows' Task Scheduler: healthy = two tasks per configured window
    if (-not $App.TaskCheckedAt -or ((Get-Date) - $App.TaskCheckedAt).TotalSeconds -gt 15) {
        $App.TaskCount = (Get-SssTasks).Count
        $App.TaskCheckedAt = Get-Date
    }
    $expected = 0
    foreach ($w in $App.Cfg.windows) { if (@($w.days).Count -gt 0) { $expected += 2 } }
    if ($App.Dirty) { return 'NÃO SALVO' }
    if ($expected -eq 0) { return 'SEM JANELAS' }
    if ($App.TaskCount -eq $expected) { return 'ATIVO' }
    return 'DESSINCRONIZADO'
}
function Get-CurrentMode {
    $ev = Get-NextEvent
    if ($ev -and $ev.kind -eq 'end') { return [string]$ev.window.status }
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

# ====================================================================== xaml

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Steam Status Scheduler" Width="1180" Height="800"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanMinimize" ShowInTaskbar="True"
        FontFamily="Bahnschrift" FontSize="13" Foreground="#F2E9FF"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#00F0FF"/>
      <Setter Property="BorderBrush" Value="#00F0FF"/>
      <Setter Property="Background" Value="#1A00F0FF"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Margin" Value="0,0,12,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform><SkewTransform AngleX="-14"/></Border.RenderTransform>
              <ContentPresenter x:Name="cp" HorizontalAlignment="Center" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
                <ContentPresenter.RenderTransform><SkewTransform AngleX="14"/></ContentPresenter.RenderTransform>
              </ContentPresenter>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{Binding BorderBrush, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter TargetName="cp" Property="TextElement.Foreground" Value="#0A0014"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.75"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.3"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#FF2BD6"/>
      <Setter Property="BorderBrush" Value="#FF2BD6"/>
      <Setter Property="Foreground" Value="#0A0014"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Padding" Value="26,8"/>
    </Style>
    <Style x:Key="BtnIcon" TargetType="Button">
      <Setter Property="Foreground" Value="#8A78B0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="Transparent" Width="34" Height="26">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#33FF2BD6"/>
                <Setter Property="Foreground" Value="#FF2BD6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Chip" TargetType="ToggleButton">
      <Setter Property="Margin" Value="0,0,5,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="bd" Background="#0FFFFFFF" BorderBrush="#3A2A55" BorderThickness="1" Padding="7,3" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform><SkewTransform AngleX="-14"/></Border.RenderTransform>
              <ContentPresenter x:Name="cp" TextElement.Foreground="{TemplateBinding BorderBrush}" HorizontalAlignment="Center" RenderTransformOrigin="0.5,0.5">
                <ContentPresenter.RenderTransform><SkewTransform AngleX="14"/></ContentPresenter.RenderTransform>
              </ContentPresenter>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{Binding BorderBrush, RelativeSource={RelativeSource TemplatedParent}}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{Binding BorderBrush, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{Binding BorderBrush, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter TargetName="cp" Property="TextElement.Foreground" Value="#0A0014"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Tb" TargetType="TextBox">
      <Setter Property="Background" Value="#0F0620"/>
      <Setter Property="Foreground" Value="#F2E9FF"/>
      <Setter Property="BorderBrush" Value="#3A2A55"/>
      <Setter Property="BorderThickness" Value="0,0,0,2"/>
      <Setter Property="CaretBrush" Value="#00F0FF"/>
      <Setter Property="SelectionBrush" Value="#FF2BD6"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#00F0FF"/>
                <Setter TargetName="bd" Property="Background" Value="#160A2E"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Hud" TargetType="ContentControl">
      <Setter Property="Padding" Value="16,14"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContentControl">
            <Grid>
              <Border Background="#B3140726" BorderBrush="#33FF2BD6" BorderThickness="1"/>
              <Path Data="M0,14 L0,0 L14,0" Stroke="#00F0FF" StrokeThickness="2" HorizontalAlignment="Left" VerticalAlignment="Top"/>
              <Path Data="M0,0 L14,0 L14,14" Stroke="#00F0FF" StrokeThickness="2" HorizontalAlignment="Right" VerticalAlignment="Top"/>
              <Path Data="M0,0 L0,14 L14,14" Stroke="#FF2BD6" StrokeThickness="2" HorizontalAlignment="Left" VerticalAlignment="Bottom"/>
              <Path Data="M14,0 L14,14 L0,14" Stroke="#FF2BD6" StrokeThickness="2" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
              <ContentPresenter Margin="{TemplateBinding Padding}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="#8A78B0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="10,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <TextBlock x:Name="tx" Text="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="tx" Property="Foreground" Value="#00F0FF"/>
                <Setter TargetName="tx" Property="TextDecorations" Value="Underline"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#F2E9FF"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8A78B0"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,10,0,4"/>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" Margin="16" BorderBrush="#99FF2BD6" BorderThickness="1">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="#120024" Offset="0"/>
        <GradientStop Color="#0A0014" Offset="0.55"/>
        <GradientStop Color="#05000E" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Border.Effect><DropShadowEffect Color="#FF2BD6" BlurRadius="30" ShadowDepth="0" Opacity="0.45"/></Border.Effect>
    <Grid ClipToBounds="True">
      <Rectangle IsHitTestVisible="False" Opacity="0.5">
        <Rectangle.Fill>
          <DrawingBrush TileMode="Tile" Viewport="0,0,36,36" ViewportUnits="Absolute">
            <DrawingBrush.Drawing>
              <GeometryDrawing>
                <GeometryDrawing.Pen><Pen Brush="#14FF2BD6" Thickness="1"/></GeometryDrawing.Pen>
                <GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,36,36"/></GeometryDrawing.Geometry>
              </GeometryDrawing>
            </DrawingBrush.Drawing>
          </DrawingBrush>
        </Rectangle.Fill>
      </Rectangle>

      <Grid Margin="22,14,22,20">
        <Grid.RowDefinitions><RowDefinition Height="44"/><RowDefinition Height="*"/></Grid.RowDefinitions>

        <Grid x:Name="TitleBar" Background="Transparent">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Rectangle Width="6" Height="22" Fill="#FF2BD6" Margin="0,0,10,0">
              <Rectangle.Effect><DropShadowEffect Color="#FF2BD6" BlurRadius="12" ShadowDepth="0" Opacity="1"/></Rectangle.Effect>
            </Rectangle>
            <TextBlock FontSize="21" FontWeight="Bold" VerticalAlignment="Center">
              <TextBlock.Effect><DropShadowEffect Color="#00F0FF" BlurRadius="14" ShadowDepth="0" Opacity="0.7"/></TextBlock.Effect>
              <Run Text="STEAM" Foreground="#FFFFFF"/><Run Text="//" Foreground="#FF2BD6"/><Run x:Name="TitleRun" Text="STATUS" Foreground="#00F0FF"/>
            </TextBlock>
            <TextBlock x:Name="VersionText" Text="SCHEDULER" Foreground="#8A78B0" FontSize="12" Margin="12,6,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <TextBlock Text="&#9698;&#9700;" Foreground="#FF2BD6" Margin="0,0,10,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="Clock" Text="--:--:--" FontFamily="Cascadia Mono, Consolas" Foreground="#00F0FF" Margin="0,0,20,0" VerticalAlignment="Center"/>
            <Button x:Name="BtnMin" Content="&#8212;" Style="{StaticResource BtnIcon}"/>
            <Button x:Name="BtnClose" Content="&#10005;" Style="{StaticResource BtnIcon}"/>
          </StackPanel>
          <Rectangle Height="1" VerticalAlignment="Bottom">
            <Rectangle.Fill>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                <GradientStop Color="#FF2BD6" Offset="0"/><GradientStop Color="#00F0FF" Offset="0.5"/><GradientStop Color="#00FF2BD6" Offset="1"/>
              </LinearGradientBrush>
            </Rectangle.Fill>
          </Rectangle>
        </Grid>

        <Grid Grid.Row="1" Margin="0,16,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="400"/><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

          <!-- ============ LEFT ============ -->
          <Grid Grid.Column="0">
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <ScrollViewer VerticalScrollBarVisibility="Hidden">
              <StackPanel>
                <ContentControl Style="{StaticResource Hud}" Padding="16,12">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel VerticalAlignment="Center">
                      <StackPanel Orientation="Horizontal">
                        <Ellipse x:Name="SvcDot" Width="9" Height="9" Fill="#8A78B0" Margin="0,0,9,0" VerticalAlignment="Center">
                          <Ellipse.Effect><DropShadowEffect x:Name="SvcGlow" Color="#00F0FF" BlurRadius="10" ShadowDepth="0" Opacity="1"/></Ellipse.Effect>
                        </Ellipse>
                        <TextBlock x:Name="SvcText" Text="verificando..." FontWeight="Bold" FontSize="14"/>
                      </StackPanel>
                      <TextBlock x:Name="SteamText" Text="steam: ..." Foreground="#8A78B0" FontSize="11" Margin="18,3,0,0"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                      <Button x:Name="BtnStart" Content="CORRIGIR" Style="{StaticResource Btn}" BorderBrush="#F5FF3B" Foreground="#F5FF3B" Background="#1AF5FF3B" Visibility="Collapsed"/>
                      <Button x:Name="BtnLog" Content="AGENDA" Style="{StaticResource Btn}" Margin="0"/>
                    </StackPanel>
                  </Grid>
                </ContentControl>

                <ContentControl Style="{StaticResource Hud}">
                  <StackPanel>
                    <TextBlock Style="{StaticResource H}"><Run Text="01 " Foreground="#FF2BD6"/><Run Text="//  JANELAS DE HORÁRIO"/></TextBlock>
                    <ScrollViewer MaxHeight="138" VerticalScrollBarVisibility="Hidden"><StackPanel x:Name="WindowList"/></ScrollViewer>
                    <TextBlock x:Name="EmptyHint" Text="nenhuma janela ainda. arraste na grade da semana ou clique em + NOVA" Foreground="#8A78B0" TextWrapping="Wrap" Margin="0,0,0,8"/>
                    <StackPanel Orientation="Horizontal" Margin="4,8,0,0">
                      <Button x:Name="BtnNew" Content="+ NOVA" Style="{StaticResource Btn}"/>
                      <Button x:Name="BtnDup" Content="DUPLICAR" Style="{StaticResource Btn}"/>
                      <Button x:Name="BtnDel" Content="REMOVER" Style="{StaticResource Btn}" BorderBrush="#FF3B5C" Foreground="#FF3B5C" Background="#1AFF3B5C" Margin="0"/>
                    </StackPanel>
                  </StackPanel>
                </ContentControl>

                <ContentControl Style="{StaticResource Hud}" x:Name="EditorSection">
                  <StackPanel>
                    <TextBlock Style="{StaticResource H}" Margin="0,0,0,2"><Run Text="02 " Foreground="#FF2BD6"/><Run Text="//  EDITAR JANELA"/></TextBlock>
                    <TextBlock Text="NOME" Style="{StaticResource Label}"/>
                    <TextBox x:Name="TbName" Style="{StaticResource Tb}"/>
                    <Grid>
                      <TextBlock Text="DIAS" Style="{StaticResource Label}"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,0,4">
                        <Button x:Name="BtnWeekdays" Content="seg a sex" Style="{StaticResource Link}"/>
                        <Button x:Name="BtnWeekend" Content="fim de semana" Style="{StaticResource Link}"/>
                        <Button x:Name="BtnAllDays" Content="todos" Style="{StaticResource Link}"/>
                      </StackPanel>
                    </Grid>
                    <WrapPanel x:Name="DaysPanel" Margin="4,0,0,0"/>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock Text="INÍCIO" Style="{StaticResource Label}"/>
                        <TextBox x:Name="TbStart" Style="{StaticResource Tb}"/>
                      </StackPanel>
                      <StackPanel Grid.Column="2">
                        <TextBlock Text="FIM" Style="{StaticResource Label}"/>
                        <TextBox x:Name="TbEnd" Style="{StaticResource Tb}"/>
                      </StackPanel>
                    </Grid>
                    <TextBlock Text="STATUS DURANTE A JANELA" Style="{StaticResource Label}"/>
                    <WrapPanel x:Name="StatusPanel" Margin="4,0,0,0"/>
                  </StackPanel>
                </ContentControl>

                <ContentControl Style="{StaticResource Hud}">
                  <StackPanel>
                    <TextBlock Style="{StaticResource H}"><Run Text="03 " Foreground="#FF2BD6"/><Run Text="//  FORA DAS JANELAS, VOLTAR PRA"/></TextBlock>
                    <WrapPanel x:Name="DefaultPanel" Margin="4,0,0,0"/>
                  </StackPanel>
                </ContentControl>
              </StackPanel>
            </ScrollViewer>

            <Grid Grid.Row="1" Margin="0,4,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Button x:Name="BtnSave" Content="SALVAR" Style="{StaticResource BtnPrimary}" Margin="6,0,14,0"/>
              <Button x:Name="BtnTest" Grid.Column="1" Content="TESTAR 45s" Style="{StaticResource Btn}" Padding="16,8" FontSize="14"/>
              <TextBlock x:Name="MsgText" Grid.Column="2" Text="" Foreground="#8A78B0" TextWrapping="Wrap" VerticalAlignment="Center" FontSize="11" Margin="6,0,0,0"/>
            </Grid>
          </Grid>

          <!-- ============ RIGHT ============ -->
          <Grid Grid.Column="2">
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

            <ContentControl Style="{StaticResource Hud}" Padding="0">
              <Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid Margin="26,20,26,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Text="AGORA, PELA PROGRAMAÇÃO" Foreground="#8A78B0" FontSize="11"/>
                    <Grid Margin="0,2,0,0">
                      <TextBlock x:Name="StatusPink" Text="..." FontSize="54" FontWeight="Bold" Foreground="#FF2BD6" Opacity="0.85"/>
                      <TextBlock x:Name="StatusCyan" Text="..." FontSize="54" FontWeight="Bold" Foreground="#00F0FF" Opacity="0.85"/>
                      <TextBlock x:Name="StatusMain" Text="..." FontSize="54" FontWeight="Bold" Foreground="#FFFFFF">
                        <TextBlock.Effect><DropShadowEffect x:Name="ModeGlow" Color="#FF2BD6" BlurRadius="26" ShadowDepth="0" Opacity="0.9"/></TextBlock.Effect>
                      </TextBlock>
                    </Grid>
                    <TextBlock x:Name="ModeSub" Text="" Foreground="#C9B8F0" FontSize="13" Margin="2,0,0,0"/>
                    <TextBlock Text="durante a janela, o status é reenviado pra steam a cada 1 minuto" Foreground="#6B5A8A" FontSize="10" Margin="2,3,0,0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" HorizontalAlignment="Right">
                    <TextBlock x:Name="NextLabel" Text="PRÓXIMA JANELA" Foreground="#8A78B0" FontSize="11" HorizontalAlignment="Right"/>
                    <TextBlock x:Name="NextText" Text="..." FontSize="15" HorizontalAlignment="Right" Margin="0,4,0,0"/>
                    <TextBlock x:Name="CountText" Text="" FontFamily="Cascadia Mono, Consolas" FontSize="30" FontWeight="Bold" Foreground="#00F0FF" HorizontalAlignment="Right" Margin="0,2,0,0">
                      <TextBlock.Effect><DropShadowEffect Color="#00F0FF" BlurRadius="16" ShadowDepth="0" Opacity="0.8"/></TextBlock.Effect>
                    </TextBlock>
                    <Button x:Name="BtnApply" Content="APLICAR AGORA" Style="{StaticResource Btn}" HorizontalAlignment="Right" Margin="0,6,4,0" Padding="12,4" FontSize="12"
                            ToolTip="Manda pra Steam o status que a programação pede neste momento"/>
                  </StackPanel>
                </Grid>

                <Border Grid.Row="1" Margin="22,12,22,10" BorderBrush="#2A1A45" BorderThickness="0,1,0,1" Background="#66050010">
                  <Grid>
                    <Canvas x:Name="Game" ClipToBounds="True"/>
                    <StackPanel x:Name="TestPanel" Visibility="Collapsed" VerticalAlignment="Center" Margin="60,0">
                      <TextBlock x:Name="TestText" Text="" HorizontalAlignment="Center" FontWeight="Bold" FontSize="15" Foreground="#FFFFFF"/>
                      <Border BorderBrush="#FF2BD6" BorderThickness="1" Height="8" Margin="0,6,0,0" Background="#CC0A0014">
                        <Rectangle x:Name="TestBar" Fill="#FF2BD6" HorizontalAlignment="Left" Width="0"/>
                      </Border>
                    </StackPanel>
                  </Grid>
                </Border>

                <Grid Grid.Row="2" Margin="22,0,22,16">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="1.1*"/><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="0.8*"/><ColumnDefinition Width="0.8*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="3" Margin="0,0,0,0">
                    <TextBlock Text="ESPAÇO EM DISCO" Foreground="#8A78B0" FontSize="10"/>
                    <TextBlock x:Name="InfoPersona" Text="..." FontWeight="Bold" FontSize="14" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                  <StackPanel Grid.Column="0" Margin="0,0,10,0">
                    <TextBlock Text="JOGANDO AGORA" Foreground="#8A78B0" FontSize="10"/>
                    <TextBlock x:Name="InfoRunning" Text="..." FontWeight="Bold" FontSize="14" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Margin="0,0,10,0">
                    <TextBlock Text="ÚLTIMO JOGO" Foreground="#8A78B0" FontSize="10"/>
                    <TextBlock x:Name="InfoLast" Text="..." FontWeight="Bold" FontSize="14" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2" Margin="0,0,10,0">
                    <TextBlock Text="BIBLIOTECA" Foreground="#8A78B0" FontSize="10"/>
                    <TextBlock x:Name="InfoLibrary" Text="..." FontWeight="Bold" FontSize="14" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                </Grid>
              </Grid>
            </ContentControl>

            <ContentControl Grid.Row="1" Style="{StaticResource Hud}" Margin="0" Padding="16,12,16,14">
              <Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid.ColumnDefinitions><ColumnDefinition Width="42"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.ColumnSpan="2" Style="{StaticResource H}"><Run Text="04 " Foreground="#FF2BD6"/><Run Text="//  SEMANA"/><Run Text="     arraste numa linha pra criar, clique numa janela pra editar" Foreground="#8A78B0" FontWeight="Normal" FontSize="11"/></TextBlock>
                <Canvas x:Name="HourLabels" Grid.Row="1" Grid.Column="1" Height="16"/>
                <StackPanel x:Name="DayLabels" Grid.Row="2" Grid.Column="0"/>
                <Canvas x:Name="WeekCanvas" Grid.Row="2" Grid.Column="1" Background="Transparent" Cursor="Cross" HorizontalAlignment="Left"/>
              </Grid>
            </ContentControl>
          </Grid>
        </Grid>
      </Grid>

      <Rectangle IsHitTestVisible="False" Opacity="0.18">
        <Rectangle.Fill>
          <DrawingBrush TileMode="Tile" Viewport="0,0,3,3" ViewportUnits="Absolute">
            <DrawingBrush.Drawing>
              <GeometryDrawing Brush="#000000"><GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,3,1"/></GeometryDrawing.Geometry></GeometryDrawing>
            </DrawingBrush.Drawing>
          </DrawingBrush>
        </Rectangle.Fill>
      </Rectangle>

      <Border x:Name="Toast" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,40"
              Background="#F00A0014" BorderBrush="#FF2BD6" BorderThickness="1" Padding="22,10" RenderTransformOrigin="0.5,0.5">
        <Border.RenderTransform><SkewTransform AngleX="-12"/></Border.RenderTransform>
        <Border.Effect><DropShadowEffect x:Name="ToastGlow" Color="#FF2BD6" BlurRadius="24" ShadowDepth="0" Opacity="0.9"/></Border.Effect>
        <TextBlock x:Name="ToastText" Text="" FontWeight="Bold" FontSize="14" RenderTransformOrigin="0.5,0.5">
          <TextBlock.RenderTransform><SkewTransform AngleX="12"/></TextBlock.RenderTransform>
        </TextBlock>
      </Border>

      <Grid x:Name="LogOverlay" Visibility="Collapsed" Background="#E6050010">
        <ContentControl Style="{StaticResource Hud}" Width="800" MaxHeight="540" Padding="20,16" Margin="0">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <TextBlock Style="{StaticResource H}"><Run Text="AGENDA " Foreground="#FF2BD6"/><Run Text="//  TAREFAS NO AGENDADOR DO WINDOWS"/></TextBlock>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
              <TextBlock x:Name="LogText" FontFamily="Cascadia Mono, Consolas" FontSize="12" TextWrapping="NoWrap"/>
            </ScrollViewer>
            <Button Grid.Row="2" x:Name="BtnLogClose" Content="FECHAR" Style="{StaticResource Btn}" HorizontalAlignment="Right" Margin="0,12,0,0"/>
          </Grid>
        </ContentControl>
      </Grid>

      <Grid x:Name="Boot" Background="#0A0014" Cursor="Hand">
        <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
          <TextBlock FontSize="54" FontWeight="Bold" HorizontalAlignment="Center">
            <TextBlock.Effect><DropShadowEffect Color="#FF2BD6" BlurRadius="30" ShadowDepth="0" Opacity="1"/></TextBlock.Effect>
            <Run Text="STEAM" Foreground="#FFFFFF"/><Run Text="//" Foreground="#FF2BD6"/><Run Text="STATUS" Foreground="#00F0FF"/>
          </TextBlock>
          <TextBlock x:Name="BootText" FontFamily="Cascadia Mono, Consolas" FontSize="13" Foreground="#00F0FF" Margin="0,22,0,0" Width="460" Height="140"/>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

# ====================================================================== build window

$App = @{
    Cfg = $null; Selected = -1; Dirty = $false; Loading = $false
    TaskCount = 0; TaskCheckedAt = $null
    DragDay = -1; DragStart = -1; DragEnd = -1; Cells = $null; DayLbl = @(); NowLine = $null
    Testing = $false; TestLeft = 0; Tick = 0; ClockTick = 0
    BootText = ''; BootPos = 0; BootDone = $false; BootStart = $null
    Rnd = New-Object Random; SteamRunning = $false; Closing = $false; ToastUntil = $null
    Mode = ''; Pong = $null; Steam = $null
    Accent = [Windows.Media.SolidColorBrush]::new((Color '#FF2BD6')); Accent2 = [Windows.Media.SolidColorBrush]::new((Color '#00F0FF')); Glitch = 0
}
$Ctl = @{}

$reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($n in @('Root','TitleBar','TitleRun','VersionText','Clock','BtnMin','BtnClose','SvcDot','SvcGlow','SvcText','SteamText','BtnStart','BtnLog',
                 'WindowList','EmptyHint','BtnNew','BtnDup','BtnDel','EditorSection','TbName','DaysPanel','BtnWeekdays','BtnWeekend','BtnAllDays',
                 'TbStart','TbEnd','StatusPanel','DefaultPanel','MsgText','BtnSave','BtnTest','Game','BtnApply','InfoPersona','InfoRunning','InfoLast','InfoLibrary','StatusPink','StatusCyan','StatusMain',
                 'ModeGlow','ModeSub','NextLabel','NextText','CountText','TestPanel','TestText','TestBar','HourLabels','DayLabels','WeekCanvas',
                 'Toast','ToastGlow','ToastText','LogOverlay','LogText','BtnLogClose','Boot','BootText')) {
    $Ctl[$n] = $Window.FindName($n)
    if ($null -eq $Ctl[$n]) { throw "XAML element not found: $n" }
}
$Ctl.VersionText.Text = 'SCHEDULER  ' + $Version
$Ctl.StatusPink.RenderTransform = [Windows.Media.TranslateTransform]::new(-3, 0)
$Ctl.StatusCyan.RenderTransform = [Windows.Media.TranslateTransform]::new(3, 0)

try {
    $steamExe = Get-SteamExe
    if ($steamExe) {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($steamExe)
        $Window.Icon = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    }
} catch { }

# ---------------------------------------------------------------- ui helpers

function Show-Toast([string]$Text, [string]$Hex = '#FF2BD6') {
    $Ctl.ToastText.Text = $Text
    $Ctl.ToastText.Foreground = Brush '#FFFFFF'
    $Ctl.Toast.BorderBrush = Brush $Hex
    $Ctl.ToastGlow.Color = Color $Hex
    $Ctl.Toast.Visibility = 'Visible'
    $Ctl.Toast.BeginAnimation([Windows.UIElement]::OpacityProperty, [Windows.Media.Animation.DoubleAnimation]::new(0, 1, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(180))))
    $App.ToastUntil = (Get-Date).AddMilliseconds(2600)
}
function Set-Msg([string]$Text, [string]$Hex = '#8A78B0') { $Ctl.MsgText.Text = $Text; $Ctl.MsgText.Foreground = Brush $Hex }
function Set-Dirty([bool]$Value) {
    $App.Dirty = $Value
    if ($Value) {
        $fx = [Windows.Media.Effects.DropShadowEffect]::new()
        $fx.Color = Color '#FF2BD6'; $fx.BlurRadius = 22; $fx.ShadowDepth = 0; $fx.Opacity = 1
        $Ctl.BtnSave.Effect = $fx
        $Ctl.BtnSave.Content = 'SALVAR  *'
    } else {
        $Ctl.BtnSave.Effect = $null
        $Ctl.BtnSave.Content = 'SALVAR'
    }
}
function New-Chip([string]$Text, $Tag, [string]$Hex) {
    $t = New-Object Windows.Controls.Primitives.ToggleButton
    $t.Style = $Window.FindResource('Chip')
    $t.Content = $Text; $t.Tag = $Tag
    $t.BorderBrush = Brush $Hex
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
        $row.Tag = $i; $row.Cursor = 'Hand'; $row.Padding = '10,6'; $row.Margin = '0,0,0,4'
        $row.BorderThickness = '3,0,0,0'
        if ($i -eq $App.Selected) { $row.Background = $Br.RowSel; $row.BorderBrush = $Br.Pink } else { $row.Background = $Br.Clear; $row.BorderBrush = $Br.Faint }
        $g = New-Object Windows.Controls.Grid
        $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = '30'
        $c1 = New-Object Windows.Controls.ColumnDefinition
        $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
        $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
        $num = New-Object Windows.Controls.TextBlock; $num.Text = ('{0:00}' -f ($i + 1)); $num.Foreground = $Br.Dim; $num.VerticalAlignment = 'Center'; $num.FontFamily = 'Cascadia Mono, Consolas'
        $sp = New-Object Windows.Controls.StackPanel
        $t1 = New-Object Windows.Controls.TextBlock; $t1.Text = $w.name; $t1.FontWeight = 'SemiBold'; $t1.FontSize = 14; $t1.Foreground = $Br.Text
        $t2 = New-Object Windows.Controls.TextBlock; $t2.Text = (Format-Days $w.days) + '   ' + $w.start + ' - ' + $w.end; $t2.Foreground = $Br.Dim; $t2.FontSize = 11
        $sp.Children.Add($t1) | Out-Null; $sp.Children.Add($t2) | Out-Null
        $chip = New-Object Windows.Controls.Border; $chip.BorderThickness = 1; $chip.Padding = '8,2'; $chip.VerticalAlignment = 'Center'
        $chip.BorderBrush = $Br[$w.status]; $chip.RenderTransformOrigin = '0.5,0.5'; $chip.RenderTransform = [Windows.Media.SkewTransform]::new(-14, 0)
        $ct = New-Object Windows.Controls.TextBlock; $ct.Text = $StatusPt[$w.status]; $ct.Foreground = $Br[$w.status]; $ct.FontSize = 11; $ct.FontWeight = 'SemiBold'
        $ct.RenderTransformOrigin = '0.5,0.5'; $ct.RenderTransform = [Windows.Media.SkewTransform]::new(14, 0)
        $chip.Child = $ct
        [Windows.Controls.Grid]::SetColumn($sp, 1); [Windows.Controls.Grid]::SetColumn($chip, 2)
        $g.Children.Add($num) | Out-Null; $g.Children.Add($sp) | Out-Null; $g.Children.Add($chip) | Out-Null
        $row.Child = $g
        $row.Add_MouseLeftButtonDown({ Select-Window ([int]$args[0].Tag) })
        $row.Add_MouseEnter({ if ([int]$args[0].Tag -ne $App.Selected) { $args[0].Background = $Br.RowHover } })
        $row.Add_MouseLeave({ if ([int]$args[0].Tag -ne $App.Selected) { $args[0].Background = $Br.Clear } })
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
    $Ctl.TbStart.ClearValue([Windows.Controls.Control]::BorderBrushProperty); $Ctl.TbEnd.ClearValue([Windows.Controls.Control]::BorderBrushProperty)
    foreach ($t in $Ctl.DefaultPanel.Children) { $t.IsChecked = ([string]$t.Tag -eq $App.Cfg.defaultStatus) }
    $App.Loading = $false
}

function Select-Window([int]$Index) { $App.Selected = $Index; Refresh-List; Refresh-Editor; Update-Grid }
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
        $tb.ClearValue([Windows.Controls.Control]::BorderBrushProperty)
        if ($Which -eq 'Start') { $w.start = $text } else { $w.end = $text }
        if ((Test-Time $w.start) -and (Test-Time $w.end) -and ([TimeSpan]$w.end -le [TimeSpan]$w.start)) {
            $Ctl.TbEnd.BorderBrush = $Br.Red; Set-Msg 'o fim precisa ser depois do início' '#FF3B5C'
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

$CellW = 12; $CellH = 20; $GridCols = 48
function Build-Grid {
    $Ctl.WeekCanvas.Width = $GridCols * $CellW; $Ctl.WeekCanvas.Height = 7 * $CellH
    $App.Cells = New-Object 'object[,]' 7, $GridCols
    $lbls = @()
    for ($d = 0; $d -lt 7; $d++) {
        $lbl = New-Object Windows.Controls.TextBlock; $lbl.Text = $DayNamesPt[$d]; $lbl.Height = $CellH; $lbl.Foreground = $Br.Dim; $lbl.FontSize = 11; $lbl.FontWeight = 'SemiBold'
        $Ctl.DayLabels.Children.Add($lbl) | Out-Null; $lbls += $lbl
        for ($c = 0; $c -lt $GridCols; $c++) {
            $r = New-Object Windows.Shapes.Rectangle
            $r.Width = $CellW - 2; $r.Height = $CellH - 5
            [Windows.Controls.Canvas]::SetLeft($r, $c * $CellW); [Windows.Controls.Canvas]::SetTop($r, $d * $CellH + 1)
            $Ctl.WeekCanvas.Children.Add($r) | Out-Null
            $App.Cells[$d, $c] = $r
        }
    }
    $App.DayLbl = $lbls
    foreach ($h in 0, 3, 6, 9, 12, 15, 18, 21, 24) {
        $t = New-Object Windows.Controls.TextBlock; $t.Text = ('{0:00}' -f $h); $t.Foreground = $Br.Dim; $t.FontSize = 10; $t.FontFamily = 'Cascadia Mono, Consolas'
        [Windows.Controls.Canvas]::SetLeft($t, [Math]::Min($h * 2 * $CellW - 6, $GridCols * $CellW - 14)); [Windows.Controls.Canvas]::SetTop($t, 0)
        $Ctl.HourLabels.Children.Add($t) | Out-Null
    }
    $now = New-Object Windows.Shapes.Rectangle
    $now.Width = 2; $now.Height = 7 * $CellH; $now.Fill = $Br.Cyan; $now.IsHitTestVisible = $false
    $fx = [Windows.Media.Effects.DropShadowEffect]::new(); $fx.Color = Color '#00F0FF'; $fx.BlurRadius = 12; $fx.ShadowDepth = 0; $fx.Opacity = 1
    $now.Effect = $fx
    $Ctl.WeekCanvas.Children.Add($now) | Out-Null
    $App.NowLine = $now
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
                $r.Opacity = @(0.45, 1)[[int]($i -eq $App.Selected)]
            } else {
                $r.Fill = @($Br.Cell, $Br.CellAlt)[[int](($c % 12) -lt 6)]; $r.Opacity = 1
            }
            if ($App.DragDay -eq $d -and $c -ge [Math]::Min($App.DragStart, $App.DragEnd) -and $c -le [Math]::Max($App.DragStart, $App.DragEnd)) {
                $r.Fill = $Br.White; $r.Opacity = 0.9
            }
        }
    }
}

function Update-NowLine {
    if (-not $App.NowLine) { return }
    $now = Get-Date
    $today = ([int]$now.DayOfWeek + 6) % 7
    [Windows.Controls.Canvas]::SetLeft($App.NowLine, $now.TimeOfDay.TotalMinutes / 30.0 * $CellW - 1)
    for ($d = 0; $d -lt 7; $d++) { $App.DayLbl[$d].Foreground = @($Br.Dim, $Br.Cyan)[[int]($d -eq $today)] }
}

# ---------------------------------------------------------------- steam info (game library manifests only)
# Deliberately reads ONLY steamapps\*.acf / libraryfolders.vdf and the RunningAppID registry value.
# Never read Steam account/login/user config files: that is what Steam account stealers do,
# and antivirus heuristics (Kaspersky) flag and delete the script for it.

function Read-SteamInfo {
    $info = @{ Games = @{}; Recent = @(); Installed = 0; Bytes = [int64]0 }
    try { $root = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath -replace '/', '\' } catch { return $info }
    $libs = @($root)
    $lf = Join-Path $root 'steamapps\libraryfolders.vdf'
    if (Test-Path $lf) { foreach ($m in [regex]::Matches((Get-Content -Raw $lf), '"path"\s*"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') } }
    $list = New-Object System.Collections.ArrayList
    foreach ($lib in ($libs | Select-Object -Unique)) {
        # a library can live on a drive that is not connected right now: skip it quietly
        $apps = [IO.Path]::Combine($lib, 'steamapps')
        if (-not [IO.Directory]::Exists($apps)) { continue }
        foreach ($f in Get-ChildItem $apps -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
            $txt = Get-Content -Raw $f.FullName
            $id = [regex]::Match($txt, '"appid"\s*"(\d+)"').Groups[1].Value
            $nm = [regex]::Match($txt, '"name"\s*"([^"]+)"').Groups[1].Value
            if (-not $id -or -not $nm -or $nm -match 'Redistributable|Steamworks|Proton|Runtime') { continue }
            $lp = [int64]0; $m = [regex]::Match($txt, '"LastPlayed"\s*"(\d+)"'); if ($m.Success) { $lp = [int64]$m.Groups[1].Value }
            $sz = [int64]0; $m = [regex]::Match($txt, '"SizeOnDisk"\s*"(\d+)"'); if ($m.Success) { $sz = [int64]$m.Groups[1].Value }
            $info.Games[$id] = $nm; $info.Bytes += $sz
            [void]$list.Add([pscustomobject]@{ Name = $nm; LastPlayed = $lp })
        }
    }
    $info.Installed = $info.Games.Count
    $info.Recent = @($list | Where-Object LastPlayed -gt 0 | Sort-Object LastPlayed -Descending | Select-Object -First 2)
    return $info
}

function Format-Ago([int64]$Unix) {
    $d = (Get-Date) - [DateTimeOffset]::FromUnixTimeSeconds($Unix).LocalDateTime
    if ($d.TotalHours -lt 1) { return 'agora há pouco' }
    if ($d.TotalHours -lt 24) { return ('há {0}h' -f [int]$d.TotalHours) }
    if ($d.TotalDays -lt 2) { return 'ontem' }
    return ('há {0} dias' -f [int]$d.TotalDays)
}

function Update-SteamInfo {
    $si = $App.Steam
    if (-not $si) { return }
    $Ctl.InfoLibrary.Text = [string]$si.Installed + ' jogos'
    $Ctl.InfoPersona.Text = ('{0:N0} GB' -f ($si.Bytes / 1GB))
    if ($si.Recent.Count -gt 0) { $Ctl.InfoLast.Text = $si.Recent[0].Name + '  ·  ' + (Format-Ago $si.Recent[0].LastPlayed) } else { $Ctl.InfoLast.Text = 'nenhum' }
    $running = 0
    try { $running = [int](Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).RunningAppID } catch { }
    if ($running -gt 0) {
        $nm = 'app ' + $running; if ($si.Games.ContainsKey([string]$running)) { $nm = $si.Games[[string]$running] }
        $Ctl.InfoRunning.Text = $nm; $Ctl.InfoRunning.Foreground = $Br.Cyan
    } elseif ($App.SteamRunning) {
        $Ctl.InfoRunning.Text = 'nada, steam aberta'; $Ctl.InfoRunning.Foreground = $Br.Text
    } else {
        $Ctl.InfoRunning.Text = 'steam fechada'; $Ctl.InfoRunning.Foreground = $Br.Dim
    }
    if ($App.Pong) {
        $names = @('PLAYER 1', 'CPU')
        if ($si.Recent.Count -ge 1) { $names[0] = $si.Recent[0].Name.ToUpper() }
        if ($si.Recent.Count -ge 2) { $names[1] = $si.Recent[1].Name.ToUpper() }
        for ($k = 0; $k -lt 2; $k++) { if ($names[$k].Length -gt 22) { $names[$k] = $names[$k].Substring(0, 21) + '~' } }
        $App.Pong.LName.Text = $names[0]; $App.Pong.RName.Text = $names[1]
    }
}

# ---------------------------------------------------------------- neon pong, two bots

function New-Glow([string]$Hex, [double]$Blur) {
    $fx = [Windows.Media.Effects.DropShadowEffect]::new(); $fx.Color = Color $Hex; $fx.BlurRadius = $Blur; $fx.ShadowDepth = 0; $fx.Opacity = 1
    return $fx
}
function Add-Shape($Shape) { $App.Pong.Canvas.Children.Add($Shape) | Out-Null; return $Shape }

function Build-Game {
    $cv = $Ctl.Game; $cv.Children.Clear()
    $w = $cv.ActualWidth; $h = $cv.ActualHeight
    if ($w -lt 100 -or $h -lt 80) { return }
    $P = @{ Canvas = $cv; W = $w; H = $h; PW = 8; PH = [Math]::Max(40, $h * 0.22); M = 22; R = 6
            LY = $h / 2; RY = $h / 2; LS = 0; RS = 0; BX = $w / 2; BY = $h / 2; VX = 0; VY = 0
            Wait = 25; LErr = 0; RErr = 0; Trail = New-Object System.Collections.ArrayList; Hist = New-Object System.Collections.ArrayList
            Parts = New-Object System.Collections.ArrayList; Over = 0; Rally = 0 }
    $App.Pong = $P

    $mid = New-Object Windows.Shapes.Line
    $mid.X1 = $w / 2; $mid.X2 = $w / 2; $mid.Y1 = 0; $mid.Y2 = $h; $mid.Stroke = $Br.Faint; $mid.StrokeThickness = 2
    $mid.StrokeDashArray = [Windows.Media.DoubleCollection]::Parse('3 4')
    [void](Add-Shape $mid)

    foreach ($side in 'L', 'R') {
        $isL = [int]($side -eq 'L')
        $sc = New-Object Windows.Controls.TextBlock
        $sc.FontFamily = 'Cascadia Mono, Consolas'; $sc.FontSize = 46; $sc.FontWeight = 'Bold'; $sc.Opacity = 0.22; $sc.Text = '0'
        $sc.Width = 120; $sc.TextAlignment = @('Left', 'Right')[$isL]
        [Windows.Controls.Canvas]::SetLeft($sc, @(($w / 2 + 24), ($w / 2 - 144))[$isL]); [Windows.Controls.Canvas]::SetTop($sc, 4)
        $P[$side + 'Score'] = (Add-Shape $sc)
        $nm = New-Object Windows.Controls.TextBlock
        $nm.FontSize = 10; $nm.FontWeight = 'SemiBold'; $nm.Opacity = 0.7; $nm.Width = 220; $nm.TextAlignment = $sc.TextAlignment
        [Windows.Controls.Canvas]::SetLeft($nm, @(($w / 2 + 24), ($w / 2 - 244))[$isL]); [Windows.Controls.Canvas]::SetTop($nm, 58)
        $P[$side + 'Name'] = (Add-Shape $nm)
    }

    for ($k = 0; $k -lt 9; $k++) {
        $t = New-Object Windows.Shapes.Ellipse
        $d = 2 * $P.R * (1 - $k / 11.0); $t.Width = $d; $t.Height = $d; $t.Fill = $App.Accent; $t.Opacity = 0.5 * (1 - $k / 9.0)
        [void]$P.Trail.Add((Add-Shape $t))
    }
    $lp = New-Object Windows.Shapes.Rectangle; $lp.Width = $P.PW; $lp.Height = $P.PH; $lp.Fill = $App.Accent; $lp.RadiusX = 2; $lp.RadiusY = 2
    $lp.Effect = New-Glow '#FF2BD6' 16; $P.LPad = (Add-Shape $lp)
    $rp = New-Object Windows.Shapes.Rectangle; $rp.Width = $P.PW; $rp.Height = $P.PH; $rp.Fill = $App.Accent2; $rp.RadiusX = 2; $rp.RadiusY = 2
    $rp.Effect = New-Glow '#00F0FF' 16; $P.RPad = (Add-Shape $rp)
    $ball = New-Object Windows.Shapes.Ellipse; $ball.Width = 2 * $P.R; $ball.Height = 2 * $P.R; $ball.Fill = $Br.White
    $ball.Effect = New-Glow '#FFFFFF' 14; $P.Ball = (Add-Shape $ball)

    for ($k = 0; $k -lt 22; $k++) {
        $q = New-Object Windows.Shapes.Rectangle; $q.Width = 3; $q.Height = 3; $q.Visibility = 'Collapsed'
        [void]$P.Parts.Add(@{ Shape = (Add-Shape $q); X = 0; Y = 0; VX = 0; VY = 0; Life = 0 })
    }
    $gg = New-Object Windows.Controls.TextBlock
    $gg.FontSize = 26; $gg.FontWeight = 'Bold'; $gg.Width = $w; $gg.TextAlignment = 'Center'; $gg.Visibility = 'Collapsed'
    $gg.Effect = New-Glow '#FF2BD6' 20
    [Windows.Controls.Canvas]::SetTop($gg, $h / 2 - 18); $P.GG = (Add-Shape $gg)
    Sync-PongColors
    Update-SteamInfo
    Update-Game
}

function Sync-PongColors {
    $P = $App.Pong; if (-not $P) { return }
    $P.LPad.Effect.Color = $App.Accent.Color; $P.RPad.Effect.Color = $App.Accent2.Color
    $P.LScore.Foreground = $App.Accent; $P.RScore.Foreground = $App.Accent2
    $P.LName.Foreground = $App.Accent; $P.RName.Foreground = $App.Accent2
}

function Get-PongTarget([double]$PadX) {
    # where the ball will cross $PadX, folding the bounces off the top and bottom walls
    $P = $App.Pong
    $t = ($PadX - $P.BX) / $P.VX
    $span = $P.H - 2 * $P.R
    $y = ($P.BY - $P.R) + $P.VY * $t
    $y = $y % (2 * $span); if ($y -lt 0) { $y += 2 * $span }
    if ($y -gt $span) { $y = 2 * $span - $y }
    return $y + $P.R
}

function Move-Paddle([string]$Side, [double]$Target) {
    $P = $App.Pong
    $cur = $P[$Side + 'Y']; $max = 3.2 + [Math]::Min(3.0, $P.Rally * 0.25)
    $d = $Target - $cur
    if ([Math]::Abs($d) -gt $max) { $d = [Math]::Sign($d) * $max }
    $P[$Side + 'Y'] = [Math]::Min($P.H - $P.PH / 2, [Math]::Max($P.PH / 2, $cur + $d))
}

function Start-Burst([double]$X, [double]$Y, $Fill) {
    foreach ($q in $App.Pong.Parts) {
        $a = $App.Rnd.NextDouble() * 2 * [Math]::PI; $sp = 1.5 + $App.Rnd.NextDouble() * 5
        $q.X = $X; $q.Y = $Y; $q.VX = [Math]::Cos($a) * $sp; $q.VY = [Math]::Sin($a) * $sp; $q.Life = 18 + $App.Rnd.Next(14)
        $q.Shape.Fill = $Fill; $q.Shape.Visibility = 'Visible'
    }
}

function Serve([int]$Dir) {
    $P = $App.Pong
    $P.BX = $P.W / 2; $P.BY = $P.H * (0.3 + 0.4 * $App.Rnd.NextDouble())
    $P.VX = $Dir * 4.2; $P.VY = (($App.Rnd.NextDouble() * 2) - 1) * 2.6
    $P.Rally = 0; $P.LErr = 0; $P.RErr = 0
}

function Update-Game {
    $P = $App.Pong; if (-not $P) { return }
    $lx = $P.M; $rx = $P.W - $P.M - $P.PW

    if ($P.Over -gt 0) {
        $P.Over--
        if ($P.Over -eq 0) { $P.LS = 0; $P.RS = 0; $P.LScore.Text = '0'; $P.RScore.Text = '0'; $P.GG.Visibility = 'Collapsed'; $P.Wait = 20 }
    } elseif ($P.Wait -gt 0) {
        $P.Wait--
        if ($P.Wait -eq 0) { Serve @(-1, 1)[$App.Rnd.Next(2)] }
    } else {
        $P.BX += $P.VX; $P.BY += $P.VY
        if ($P.BY -lt $P.R) { $P.BY = 2 * $P.R - $P.BY; $P.VY = -$P.VY }
        if ($P.BY -gt $P.H - $P.R) { $P.BY = 2 * ($P.H - $P.R) - $P.BY; $P.VY = -$P.VY }

        # paddle hits: bounce, speed up, angle depends on where it hit; the other bot gets a new aim error
        if ($P.VX -lt 0 -and $P.BX - $P.R -le $lx + $P.PW -and $P.BX -gt $lx -and [Math]::Abs($P.BY - $P.LY) -le $P.PH / 2 + $P.R) {
            $P.BX = $lx + $P.PW + $P.R; $P.VX = [Math]::Min(11, -$P.VX * 1.06); $P.VY += ($P.BY - $P.LY) / ($P.PH / 2) * 2.4; $P.Rally++
            $P.RErr = (($App.Rnd.NextDouble() * 2) - 1) * $P.PH * (0.25 + [Math]::Min(0.6, $P.Rally * 0.05))
        }
        if ($P.VX -gt 0 -and $P.BX + $P.R -ge $rx -and $P.BX -lt $rx + $P.PW -and [Math]::Abs($P.BY - $P.RY) -le $P.PH / 2 + $P.R) {
            $P.BX = $rx - $P.R; $P.VX = [Math]::Max(-11, -$P.VX * 1.06); $P.VY += ($P.BY - $P.RY) / ($P.PH / 2) * 2.4; $P.Rally++
            $P.LErr = (($App.Rnd.NextDouble() * 2) - 1) * $P.PH * (0.25 + [Math]::Min(0.6, $P.Rally * 0.05))
        }
        $P.VY = [Math]::Max(-7, [Math]::Min(7, $P.VY))

        $scored = ''
        if ($P.BX -lt -12) { $P.RS++; $P.RScore.Text = [string]$P.RS; Start-Burst 4 $P.BY $App.Accent2; $scored = 'R' }
        elseif ($P.BX -gt $P.W + 12) { $P.LS++; $P.LScore.Text = [string]$P.LS; Start-Burst ($P.W - 4) $P.BY $App.Accent; $scored = 'L' }
        if ($scored) {
            $P.BX = $P.W / 2; $P.BY = $P.H / 2; $P.VX = 0; $P.VY = 0; $P.Wait = 28
            if ($P.LS -ge 7 -or $P.RS -ge 7) {
                $lw = [int]($P.LS -ge 7)
                $P.GG.Text = 'GG  //  ' + @($P.RName.Text, $P.LName.Text)[$lw] + ' VENCEU'
                $P.GG.Foreground = @($App.Accent2, $App.Accent)[$lw]
                $P.GG.Visibility = 'Visible'; $P.Over = 90; $P.Wait = 0
            }
        }
    }

    # bots: track the predicted crossing point when the ball comes their way, drift to center otherwise
    if ($P.VX -lt 0) { Move-Paddle 'L' ((Get-PongTarget ($lx + $P.PW)) + $P.LErr); Move-Paddle 'R' ($P.H / 2) }
    elseif ($P.VX -gt 0) { Move-Paddle 'R' ((Get-PongTarget $rx) + $P.RErr); Move-Paddle 'L' ($P.H / 2) }

    [Windows.Controls.Canvas]::SetLeft($P.LPad, $lx); [Windows.Controls.Canvas]::SetTop($P.LPad, $P.LY - $P.PH / 2)
    [Windows.Controls.Canvas]::SetLeft($P.RPad, $rx); [Windows.Controls.Canvas]::SetTop($P.RPad, $P.RY - $P.PH / 2)
    [Windows.Controls.Canvas]::SetLeft($P.Ball, $P.BX - $P.R); [Windows.Controls.Canvas]::SetTop($P.Ball, $P.BY - $P.R)
    $P.Ball.Visibility = @('Visible', 'Hidden')[[int]($P.Wait -gt 0 -or $P.Over -gt 0)]

    [void]$P.Hist.Insert(0, @($P.BX, $P.BY)); if ($P.Hist.Count -gt 18) { $P.Hist.RemoveAt(18) }
    for ($k = 0; $k -lt $P.Trail.Count; $k++) {
        $t = $P.Trail[$k]; $pt = $P.Hist[[Math]::Min($P.Hist.Count - 1, $k * 2 + 1)]
        [Windows.Controls.Canvas]::SetLeft($t, $pt[0] - $t.Width / 2); [Windows.Controls.Canvas]::SetTop($t, $pt[1] - $t.Height / 2)
        $t.Visibility = $P.Ball.Visibility
    }

    foreach ($q in $P.Parts) {
        if ($q.Life -le 0) { continue }
        $q.Life--; $q.X += $q.VX; $q.Y += $q.VY; $q.VY += 0.15; $q.VX *= 0.96
        [Windows.Controls.Canvas]::SetLeft($q.Shape, $q.X); [Windows.Controls.Canvas]::SetTop($q.Shape, $q.Y)
        $q.Shape.Opacity = [Math]::Min(1, $q.Life / 12.0)
        if ($q.Life -le 0) { $q.Shape.Visibility = 'Collapsed' }
    }
}

function Get-Tint($Col) {
    $k = 0.62
    return [Windows.Media.Color]::FromRgb([byte]($Col.R + (255 - $Col.R) * $k), [byte]($Col.G + (255 - $Col.G) * $k), [byte]($Col.B + (255 - $Col.B) * $k))
}
function Set-Accent([string]$Hex) {
    $col = Color $Hex
    $App.Accent.Color = $col
    $other = '#00F0FF'; if ($Hex -eq '#00F0FF') { $other = '#FF2BD6' }
    $App.Accent2.Color = Color $other
    $Ctl.ModeGlow.Color = $col
    Sync-PongColors
}

# ---------------------------------------------------------------- readout

function Update-Readout {
    $mode = Get-CurrentMode
    if ($mode -ne $App.Mode) {
        $App.Mode = $mode
        foreach ($tb in @($Ctl.StatusPink, $Ctl.StatusCyan, $Ctl.StatusMain)) { $tb.Text = $StatusPt[$mode] }
        Set-Accent $StatusHex[$mode]
        $sub = 'visível pros amigos'
        if ($mode -eq 'invisible') { $sub = 'seus amigos te veem como offline' }
        elseif ($mode -eq 'offline') { $sub = 'desconectado do chat de amigos' }
        elseif ($mode -eq 'away') { $sub = 'aparece como ausente' }
        elseif ($mode -eq 'busy') { $sub = 'aparece como ocupado' }
        $Ctl.ModeSub.Text = $sub
    }

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
            $Ctl.NextLabel.Text = 'PRÓXIMA  //  ' + $w.name.ToUpper()
            $Ctl.NextText.Text = $StatusPt[$w.status].ToLower() + '  ' + $ev.when.ToString('ddd HH:mm') + ' - ' + $w.end
        }
        $Ctl.CountText.Text = $cd
    }

    $svc = Get-ServiceState
    $Ctl.BtnStart.Visibility = 'Collapsed'
    if ($svc -eq 'ATIVO') {
        $Ctl.SvcText.Text = 'AGENDAMENTO ATIVO'; $Ctl.SvcText.Foreground = $Br.Cyan; $Ctl.SvcDot.Fill = $Br.Cyan; $Ctl.SvcGlow.Color = Color '#00F0FF'
    } elseif ($svc -eq 'NÃO SALVO' -or $svc -eq 'SEM JANELAS') {
        $Ctl.SvcText.Text = $svc; $Ctl.SvcText.Foreground = $Br.Yellow; $Ctl.SvcDot.Fill = $Br.Yellow; $Ctl.SvcGlow.Color = Color '#F5FF3B'
    } else {
        $Ctl.SvcText.Text = 'DESATUALIZADO'; $Ctl.SvcText.Foreground = $Br.Red; $Ctl.SvcDot.Fill = $Br.Red; $Ctl.SvcGlow.Color = Color '#FF3B5C'
        $Ctl.BtnStart.Visibility = 'Visible'
    }
    $Ctl.SteamText.Text = @('steam fechada', 'steam rodando')[[int]$App.SteamRunning]
    if ($svc -eq 'DESSINCRONIZADO') { $Ctl.SteamText.Text = 'as tarefas do windows não batem com o config' }
    elseif ($svc -eq 'NÃO SALVO') { $Ctl.SteamText.Text = 'salve pra atualizar a agenda do windows' }
}

# ---------------------------------------------------------------- log

function Show-Log {
    $Ctl.LogText.Inlines.Clear()
    $tasks = Get-SssTasks
    if ($tasks.Count -eq 0) {
        $Ctl.LogText.Inlines.Add((New-Object Windows.Documents.Run 'nenhuma tarefa agendada. salve as janelas pra criar.'))
    }
    $head = New-Object Windows.Documents.Run (('{0,-34} {1,-18} {2,-18} {3}' -f 'TAREFA', 'PRÓXIMA', 'ÚLTIMA', 'STATUS') + "`n")
    $head.Foreground = $Br.Dim; $Ctl.LogText.Inlines.Add($head)
    foreach ($t in ($tasks | Sort-Object TaskName)) {
        $info = $t | Get-ScheduledTaskInfo
        $next = '-'; if ($info.NextRunTime) { $next = $info.NextRunTime.ToString('ddd dd/MM HH:mm') }
        $last = 'nunca'; if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $last = $info.LastRunTime.ToString('ddd dd/MM HH:mm') }
        $arg = [string]$t.Actions[0].Arguments
        $status = $arg.Substring($arg.LastIndexOf('/') + 1)
        $name = $t.TaskName; if ($name.Length -gt 33) { $name = $name.Substring(0, 32) + '~' }
        $run = New-Object Windows.Documents.Run (('{0,-34} {1,-18} {2,-18} {3}' -f $name, $next, $last, $status) + "`n")
        $run.Foreground = $Br.Text
        if ($Br.ContainsKey($status)) { $run.Foreground = $Br[$status] }
        $Ctl.LogText.Inlines.Add($run)
    }
    $Ctl.LogOverlay.Visibility = 'Visible'
}

# ---------------------------------------------------------------- boot

function Start-Boot {
    $svc = Get-ServiceState
    $steamWord = @('FECHADA', 'ONLINE')[[int]$App.SteamRunning]
    $App.BootStart = Get-Date
    $lines = @(
        "> agendador do windows ............ $svc",
        "> steam.exe ....................... $steamWord",
        "> janelas carregadas .............. $($App.Cfg.windows.Count)",
        "> usuário ......................... $env:USERNAME",
        "> sistema pronto_"
    )
    $App.BootText = ($lines -join "`n"); $App.BootPos = 0
}
function Finish-Boot {
    if ($App.BootDone) { return }
    $App.BootDone = $true
    $anim = [Windows.Media.Animation.DoubleAnimation]::new(1, 0, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(450)))
    $anim.Add_Completed({ $Ctl.Boot.Visibility = 'Collapsed' })
    $Ctl.Boot.BeginAnimation([Windows.UIElement]::OpacityProperty, $anim)
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
            try { [void](Sync-SssTasks -Windows $App.Cfg.windows -DefaultStatus $App.Cfg.defaultStatus) } catch { }
        }
    }
    $App.Closing = $true
})
$Ctl.Boot.Add_MouseLeftButtonDown({ Finish-Boot })
$Ctl.BtnLog.Add_Click({ Show-Log })
$Ctl.BtnLogClose.Add_Click({ $Ctl.LogOverlay.Visibility = 'Collapsed' })
$Ctl.LogOverlay.Add_MouseLeftButtonDown({ if ($args[1].OriginalSource -eq $Ctl.LogOverlay) { $Ctl.LogOverlay.Visibility = 'Collapsed' } })
$Ctl.BtnStart.Add_Click({
    try {
        $n = Sync-SssTasks -Windows $App.Cfg.windows -DefaultStatus $App.Cfg.defaultStatus
        $App.TaskCheckedAt = $null; Update-Readout
        Show-Toast "$n tarefas recriadas no agendador" '#00F0FF'
    } catch { Show-Toast $_.Exception.Message '#FF3B5C' }
})
$Ctl.BtnNew.Add_Click({ New-WindowAt 5 12 23 'invisible'; Show-Toast 'janela criada: ajusta nome, dias e horário' })
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
    Show-Toast ('removida: ' + $w.name) '#FF3B5C'
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
    $t = New-Chip $DayNamesPt[$d] $d '#00F0FF'
    $t.Add_Checked({ Apply-Days }); $t.Add_Unchecked({ Apply-Days })
    $Ctl.DaysPanel.Children.Add($t) | Out-Null
}
foreach ($st in $Statuses) {
    $t = New-Chip $StatusPt[$st] $st $StatusHex[$st]
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

    $t2 = New-Chip $StatusPt[$st] $st $StatusHex[$st]
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
    if ($err) { Set-Msg $err '#FF3B5C'; Show-Toast $err '#FF3B5C'; return }
    Save-Config $App.Cfg
    try {
        $Window.Cursor = 'Wait'
        $n = Sync-SssTasks -Windows $App.Cfg.windows -DefaultStatus $App.Cfg.defaultStatus
    } catch {
        $Window.Cursor = $null
        Set-Msg $_.Exception.Message '#FF3B5C'; Show-Toast 'salvei o config, mas não consegui agendar' '#FF3B5C'; return
    }
    $Window.Cursor = $null
    $App.TaskCheckedAt = $null
    $applied = Invoke-SssApplyNow -Windows $App.Cfg.windows -DefaultStatus $App.Cfg.defaultStatus
    Set-Dirty $false; Set-Msg ('salvo às ' + (Get-Date).ToString('HH:mm:ss') + '. ' + $n + ' tarefas no agendador do windows')
    Update-Readout
    Show-Toast 'SALVO  //  agenda atualizada no Windows' '#00F0FF'
})

$Ctl.BtnApply.Add_Click({
    if (-not (Test-SteamRunning)) { Show-Toast 'a Steam não está aberta' '#FF3B5C'; return }
    $st = Invoke-SssApplyNow -Windows $App.Cfg.windows -DefaultStatus $App.Cfg.defaultStatus -IncludeDefault
    if ($st) { Show-Toast ('status aplicado: ' + $StatusPt[$st]) $StatusHex[$st] }
})

$Ctl.BtnTest.Add_Click({
    if ($App.Testing) { return }
    if (-not (Test-SteamRunning)) { Show-Toast 'a Steam não está aberta' '#FF3B5C'; return }
    $App.Testing = $true; $App.TestLeft = 45
    Set-SteamStatus 'invisible'
    $Ctl.TestPanel.Visibility = 'Visible'; $Ctl.BtnTest.IsEnabled = $false
    $Ctl.TestText.Text = 'TESTE  //  INVISÍVEL POR 45s'
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
    $d = $App.DragDay; $a = [Math]::Min($App.DragStart, $App.DragEnd); $z = [Math]::Max($App.DragStart, $App.DragEnd)
    $App.DragDay = -1
    $existing = Get-WindowIndexAt $d $a
    if ($a -eq $z -and $existing -ge 0) { Select-Window $existing; return }
    New-WindowAt $d $a $z 'invisible'
    Show-Toast ('nova janela  ' + $DayNamesPt[$d] + '  ' + (Format-Time ($a * 30)) + ' - ' + (Format-Time ([Math]::Min(($z + 1) * 30, 1439))))
})

# ---------------------------------------------------------------- timers

$FxTimer = New-Object Windows.Threading.DispatcherTimer
$FxTimer.Interval = [TimeSpan]::FromMilliseconds(40)
$FxTimer.Add_Tick({
    $App.Tick++
    if (-not $App.BootDone) {
        $elapsed = ((Get-Date) - $App.BootStart).TotalMilliseconds
        $msPerChar = 9; if ($Screenshot) { $msPerChar = 3 }
        $target = [Math]::Min($App.BootText.Length, [int]($elapsed / $msPerChar))
        if ($target -ne $App.BootPos) { $App.BootPos = $target; $Ctl.BootText.Text = $App.BootText.Substring(0, $App.BootPos) }
        if ($App.BootPos -ge $App.BootText.Length -and $elapsed -gt ($App.BootText.Length * $msPerChar + 500)) { Finish-Boot }
    }
    Update-Game
    # chromatic aberration on the big status word: calm drift + a glitch burst every few seconds
    $pk = $Ctl.StatusPink.RenderTransform; $cy = $Ctl.StatusCyan.RenderTransform
    if ($App.Glitch -gt 0) {
        $App.Glitch--
        $pk.X = -2 - $App.Rnd.Next(10); $pk.Y = $App.Rnd.Next(-3, 4)
        $cy.X = 2 + $App.Rnd.Next(10); $cy.Y = $App.Rnd.Next(-3, 4)
        $Ctl.StatusMain.Opacity = @(1, 0.55)[$App.Rnd.Next(2)]
    } else {
        $ph = $App.Tick / 14.0
        $pk.X = -2.5 - 1.2 * [Math]::Sin($ph); $pk.Y = 0
        $cy.X = 2.5 + 1.2 * [Math]::Sin($ph + 1.3); $cy.Y = 0
        $Ctl.StatusMain.Opacity = 1
        if ($App.Rnd.Next(90) -eq 0) { $App.Glitch = 4 + $App.Rnd.Next(4) }
    }
    if ($App.Tick % 75 -eq 0) {
        $chars = 'STATUS'.ToCharArray(); $glyph = '#%&@$01/\<>'
        $i = $App.Rnd.Next($chars.Length); $chars[$i] = $glyph[$App.Rnd.Next($glyph.Length)]
        $Ctl.TitleRun.Text = New-Object string (,$chars)
    } elseif ($App.Tick % 75 -eq 3) { $Ctl.TitleRun.Text = 'STATUS' }
    if ($App.Tick % 15 -eq 0) { $Ctl.SvcDot.Opacity = @(1, 0.3)[[int]($Ctl.SvcDot.Opacity -gt 0.5)] }
    if ($App.ToastUntil -and (Get-Date) -gt $App.ToastUntil) { $Ctl.Toast.Visibility = 'Collapsed'; $App.ToastUntil = $null }
})

$ClockTimer = New-Object Windows.Threading.DispatcherTimer
$ClockTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
$ClockTimer.Add_Tick({
    $Ctl.Clock.Text = (Get-Date).ToString('ddd dd/MM  HH:mm:ss').ToUpper()
    $App.ClockTick++
    if ($App.ClockTick % 3 -eq 0) { $App.SteamRunning = Test-SteamRunning; Update-SteamInfo }
    Update-Readout
    Update-NowLine
    if ($App.Testing) {
        $App.TestLeft--
        $Ctl.TestText.Text = ('TESTE  //  INVISÍVEL  //  volta pra online em {0}s' -f $App.TestLeft)
        $Ctl.TestBar.Width = [Math]::Max(0, (45 - $App.TestLeft) / 45.0 * ($Ctl.TestBar.Parent.ActualWidth - 2))
        if ($App.TestLeft -le 0) {
            Set-SteamStatus 'online'
            $App.Testing = $false; $Ctl.TestPanel.Visibility = 'Collapsed'; $Ctl.BtnTest.IsEnabled = $true
            Show-Toast 'teste concluído: de volta pra online' '#00F0FF'
        }
    }
})

# ---------------------------------------------------------------- go

if (-not (Test-Path $ConfigPath)) {
    [Windows.MessageBox]::Show("Não achei o config.json em:`n$InstallDir`n`nRoda o Instalar.bat primeiro.", 'Steam Status Scheduler', 'OK', 'Warning') | Out-Null
    exit 1
}
$App.Cfg = Load-Config
if ($Demo) {
    $App.Cfg = @{ defaultStatus = 'online'; windows = New-Object System.Collections.ArrayList }
    [void]$App.Cfg.windows.Add(@{ name = 'jogar sozinho'; days = @('Saturday', 'Sunday'); start = '06:00'; end = '12:00'; status = 'invisible' })
    [void]$App.Cfg.windows.Add(@{ name = 'noite de foco'; days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday'); start = '20:00'; end = '23:30'; status = 'busy' })
}
$App.SteamRunning = Test-SteamRunning
if ($App.Cfg.windows.Count -gt 0) { $App.Selected = 0 }

Build-Grid
Refresh-All
Update-NowLine
Start-Boot
$Ctl.Clock.Text = (Get-Date).ToString('ddd dd/MM  HH:mm:ss').ToUpper()

$Window.Add_ContentRendered({
    try { $App.Steam = Read-SteamInfo } catch { }
    if ($Demo) {
        $App.Steam = @{ Games = @{}; Installed = 48; Bytes = [int64]1.2TB
            Recent = @([pscustomobject]@{ Name = 'Hollow Knight'; LastPlayed = [DateTimeOffset]::Now.AddHours(-3).ToUnixTimeSeconds() },
                       [pscustomobject]@{ Name = 'Hades'; LastPlayed = [DateTimeOffset]::Now.AddDays(-2).ToUnixTimeSeconds() }) }
    }
    Build-Game; $FxTimer.Start(); $ClockTimer.Start()
})

if ($Screenshot) {
    $shot = New-Object Windows.Threading.DispatcherTimer
    $shot.Interval = [TimeSpan]::FromMilliseconds($ScreenshotDelayMs)
    $shot.Add_Tick({
        $shot.Stop()
        $root = $Ctl.Root
        $wd = [int]$root.ActualWidth + 32; $ht = [int]$root.ActualHeight + 32
        $rtb = [Windows.Media.Imaging.RenderTargetBitmap]::new($wd, $ht, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $dv = New-Object Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawRectangle([Windows.Media.Brushes]::Black, $null, [Windows.Rect]::new(0, 0, $wd, $ht))
        $dc.DrawRectangle([Windows.Media.VisualBrush]::new($root), $null, [Windows.Rect]::new(16, 16, $root.ActualWidth, $root.ActualHeight))
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
