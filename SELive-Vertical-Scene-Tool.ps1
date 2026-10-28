<#
.SYNOPSIS
  SE.Live Vertical Canvas Scene Tool - duplicate, rename, delete and restore scenes on SE.Live
  multistreaming canvases. v3 "surgical": it never rewrites the whole file, it only
  splices in (or touches) the bytes of the scene involved. Every other byte stays identical.

.DESCRIPTION
  Double-click "SELive Scene Tool.bat" (same folder; it opens the window with no console) and the tool:
    1. gracefully closes OBS if it is running (so SE.Live saves fresh state)
    2. auto-detects your SE.Live "composition" files (or lets you browse to one)
    3. lets you Duplicate / Rename / Delete scenes or restore a backup, as many times as you like
    4. runs with an automatic backup and deep validation (if anything looks wrong, the file is NOT touched)
    5. reopens OBS when you close the window

  IMPORTANT - read the README: the first scene of a canvas needs a name used nowhere else
  in OBS (SE.Live adds " 1" otherwise; the tool checks it), and duplicates need names not
  already used on that canvas.

  Command-line usage (optional, no windows):
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -List
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Scene "Valorant" -NewName "Apex"
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Scene "Valorant" -NewName "Apex|Fortnite|Variety"
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Rename -Scene "Old Name" -NewName "New Name"
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Delete -Scene "Old test"
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -RestoreFrom "<file>.json.bak_20261028_111506188"

.NOTES
  Version 3.0 (surgical) - built and tested for SE.Live 26.9.4.994 (obs-streamelements-core)
  on OBS Studio 33.0.0, October 2026. Other SE.Live versions are flagged in the window, and the
  tool stops if the composition file format is not the one it knows.
  Unofficial community tool. Not affiliated with StreamElements or the OBS Project.
  A backup is always created before writing. Use at your own risk. License: MIT.
#>
param(
    [string]$File,
    [string]$Canvas,
    [string]$Scene,
    [string[]]$NewName,
    [switch]$Rename,
    [switch]$Delete,
    [switch]$AtEnd,
    [string]$RestoreFrom,
    [switch]$List,
    [switch]$NoGui,
    [switch]$NoRestart,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$script:ToolVersion  = '3.0'
$script:TestedSELive = '26.9.4.994'
$script:TestedObs    = '33.0.0'
$script:PtrPattern   = 'ptr\([0-9A-Fa-f]{16}\)'
$script:GuiMode      = -not ($NoGui -or $List)
$script:ObsExe       = $null
$script:Rng          = New-Object System.Random

$script:ScriptPath    = $PSCommandPath
$script:ToolIcon      = $null
$script:MainWindow    = $null
$script:BusyWindow    = $null
$script:BusyCancelled = $false
$script:ObsWasRunning = $false

if ($script:GuiMode) {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    # Own taskbar identity, so Windows shows the tool's icon instead of grouping it under PowerShell.
    try {
        Add-Type -Namespace SELiveSceneTool -Name Shell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
'@
        [void][SELiveSceneTool.Shell]::SetCurrentProcessExplicitAppUserModelID('SELive.SceneTool')
    } catch { }
}

# ------------------------------------------------------------------ #
#  0. Look & feel (WPF, dark theme in the style of the SE.Live dock) #
# ------------------------------------------------------------------ #
# Kept ASCII-only on purpose: Windows PowerShell 5.1 reads a BOM-less script as ANSI, so every
# non-ASCII glyph below is written as a XAML character reference (&#x....;) or built with [char].
$script:XamlResources = @'
<SolidColorBrush x:Key="Bg" Color="#14161F"/>
<SolidColorBrush x:Key="Surface" Color="#1C1F2C"/>
<SolidColorBrush x:Key="Surface2" Color="#252A3B"/>
<SolidColorBrush x:Key="Line" Color="#2F3549"/>
<SolidColorBrush x:Key="Sel" Color="#2B3760"/>
<SolidColorBrush x:Key="Fg" Color="#E9EBF3"/>
<SolidColorBrush x:Key="Muted" Color="#8F96AD"/>
<SolidColorBrush x:Key="Accent" Color="#4F6EF7"/>
<SolidColorBrush x:Key="Danger" Color="#E5484D"/>

<Style x:Key="BtnBase" TargetType="Button">
  <Setter Property="Foreground" Value="White"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Padding" Value="18,9"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.86"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.7"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.38"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
  <Setter Property="Background" Value="{StaticResource Accent}"/>
</Style>
<Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource BtnBase}">
  <Setter Property="Background" Value="{StaticResource Danger}"/>
</Style>
<Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource BtnBase}">
  <Setter Property="Background" Value="{StaticResource Surface}"/>
  <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="Foreground" Value="{StaticResource Fg}"/>
  <Setter Property="FontWeight" Value="Normal"/>
</Style>
<Style x:Key="Chrome" TargetType="Button">
  <Setter Property="Foreground" Value="{StaticResource Muted}"/>
  <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
  <Setter Property="FontSize" Value="10"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="Transparent" CornerRadius="6" Width="34" Height="28">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="bd" Property="Background" Value="{StaticResource Surface2}"/>
            <Setter Property="Foreground" Value="{StaticResource Fg}"/>
          </Trigger>
          <MultiTrigger>
            <MultiTrigger.Conditions>
              <Condition Property="IsMouseOver" Value="True"/>
              <Condition Property="Tag" Value="close"/>
            </MultiTrigger.Conditions>
            <Setter TargetName="bd" Property="Background" Value="{StaticResource Danger}"/>
            <Setter Property="Foreground" Value="White"/>
          </MultiTrigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="Tab" TargetType="RadioButton">
  <Setter Property="Foreground" Value="{StaticResource Muted}"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="RadioButton">
        <Border x:Name="bd" Background="Transparent" CornerRadius="7" Padding="6,8">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
            <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ContentPresenter VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="bd" Property="Background" Value="{StaticResource Surface2}"/>
            <Setter Property="Foreground" Value="{StaticResource Fg}"/>
          </Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="bd" Property="Background" Value="{StaticResource Accent}"/>
            <Setter Property="Foreground" Value="White"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="CheckBox">
  <Setter Property="Foreground" Value="{StaticResource Fg}"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="CheckBox">
        <StackPanel Orientation="Horizontal" Background="Transparent">
          <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="#4A5170"
                  Background="{StaticResource Surface}" VerticalAlignment="Center">
            <Path x:Name="tick" Data="M 3.5,8.5 L 6.8,11.8 L 12.8,5" Stroke="White" StrokeThickness="2" Visibility="Collapsed"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
          </Border>
          <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/>
            <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
            <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="TextBox">
  <Setter Property="Foreground" Value="{StaticResource Fg}"/>
  <Setter Property="CaretBrush" Value="{StaticResource Fg}"/>
  <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="TextBox">
        <Border x:Name="bd" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                CornerRadius="8" Padding="8,7">
          <ScrollViewer x:Name="PART_ContentHost" VerticalScrollBarVisibility="Auto"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ScrollBar">
  <Setter Property="Width" Value="8"/>
  <Setter Property="MinWidth" Value="8"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ScrollBar">
        <Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="{TemplateBinding Orientation}">
          <Track.Thumb>
            <Thumb>
              <Thumb.Template>
                <ControlTemplate TargetType="Thumb"><Border Background="#3A4058" CornerRadius="3" Margin="2"/></ControlTemplate>
              </Thumb.Template>
            </Thumb>
          </Track.Thumb>
        </Track>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ComboBoxItem">
  <Setter Property="Foreground" Value="{StaticResource Fg}"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ComboBoxItem">
        <Border x:Name="bd" Background="Transparent" CornerRadius="6" Padding="10,7"><ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource Surface2}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource Sel}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ComboBox">
  <Setter Property="Foreground" Value="{StaticResource Fg}"/>
  <Setter Property="Height" Value="38"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ComboBox">
        <Grid>
          <ToggleButton Focusable="False" ClickMode="Press"
                        IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
            <ToggleButton.Template>
              <ControlTemplate TargetType="ToggleButton">
                <Border x:Name="b" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8">
                  <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{StaticResource Muted}"
                             HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,13,0"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </ToggleButton.Template>
          </ToggleButton>
          <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" Margin="13,0,34,0" VerticalAlignment="Center"/>
          <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
            <Border Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8"
                    Margin="0,4,0,0" Padding="4" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
              <ScrollViewer MaxHeight="240"><ItemsPresenter/></ScrollViewer>
            </Border>
          </Popup>
        </Grid>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ListBox">
  <Setter Property="Background" Value="{StaticResource Surface}"/>
  <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
  <Setter Property="Foreground" Value="{StaticResource Fg}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ListBox">
        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="5">
          <ScrollViewer Focusable="False" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
        </Border>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ListBoxItem">
  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ListBoxItem">
        <Border x:Name="bd" Background="Transparent" CornerRadius="7" Padding="11,8" Margin="0,1">
          <ContentPresenter/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource Surface2}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource Sel}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="Caption" TargetType="TextBlock">
  <Setter Property="Foreground" Value="{StaticResource Muted}"/>
  <Setter Property="FontSize" Value="11"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Margin" Value="2,16,0,7"/>
</Style>
'@

# Window shell shared by every window: borderless, rounded, with a soft shadow and a draggable title bar.
$script:XamlShell = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SE.Live Scene Tool" Width="{{WIDTH}}" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" FontFamily="Segoe UI" FontSize="13" Foreground="#E9EBF3"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>{{RES}}</Window.Resources>
  <Border Margin="16" Background="{StaticResource Bg}" BorderBrush="#262B3D" BorderThickness="1" CornerRadius="14">
    <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.55" Color="Black"/></Border.Effect>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <Grid x:Name="TitleBar" Background="Transparent" Height="46">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
          <Border Width="22" Height="22" CornerRadius="6" Background="{StaticResource Accent}">
            <TextBlock Text="&#xE8C8;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="{{TITLE}}" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,9,0">
          <Button x:Name="btnMin" Style="{StaticResource Chrome}" Content="&#xE921;" Visibility="{{MINVIS}}" ToolTip="Minimize"/>
          <Button x:Name="btnClose" Style="{StaticResource Chrome}" Content="&#xE8BB;" Tag="close" ToolTip="Close" Margin="2,0,0,0"/>
        </StackPanel>
      </Grid>
      <ContentControl Grid.Row="1">{{BODY}}</ContentControl>
    </Grid>
  </Border>
</Window>
'@

function New-ToolWindow([string]$Title, [string]$Body, [int]$Width, [bool]$Minimizable) {
    $minVis = if ($Minimizable) { 'Visible' } else { 'Collapsed' }
    $xaml = $script:XamlShell.Replace('{{RES}}', $script:XamlResources).Replace('{{BODY}}', $Body).
        Replace('{{TITLE}}', $Title).Replace('{{WIDTH}}', [string]($Width + 32)).Replace('{{MINVIS}}', $minVis)
    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    $w.FindName('TitleBar').Add_MouseLeftButtonDown({ try { [System.Windows.Window]::GetWindow($this).DragMove() } catch { } })
    $w.FindName('btnMin').Add_Click({ [System.Windows.Window]::GetWindow($this).WindowState = 'Minimized' })
    $w.FindName('btnClose').Add_Click({ [System.Windows.Window]::GetWindow($this).Close() })
    $w.Add_KeyDown({ if ($_.Key -eq 'Escape') { $this.Close() } })
    $icon = Get-ToolIcon
    if ($icon) { $w.Icon = $icon }
    return $w
}

# The app icon (accent square with a "copy" glyph), drawn once and reused for windows and the Desktop shortcut.
function Get-ToolIcon {
    if ($script:ToolIcon) { return $script:ToolIcon }
    try {
        $size = 256
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $grad = New-Object System.Windows.Media.LinearGradientBrush(
            [System.Windows.Media.Color]::FromRgb(0x6A, 0x86, 0xFF), [System.Windows.Media.Color]::FromRgb(0x3F, 0x5B, 0xE6), 90.0)
        $dc.DrawRoundedRectangle($grad, $null, (New-Object System.Windows.Rect(8, 8, 240, 240)), 56, 56)
        $tf = New-Object System.Windows.Media.Typeface('Segoe MDL2 Assets')
        $ft = New-Object System.Windows.Media.FormattedText([string][char]0xE8C8, [Globalization.CultureInfo]::InvariantCulture,
            [System.Windows.FlowDirection]::LeftToRight, $tf, 128.0, [System.Windows.Media.Brushes]::White, 1.0)
        $dc.DrawText($ft, (New-Object System.Windows.Point((($size - $ft.Width) / 2), (($size - $ft.Height) / 2))))
        $dc.Close()
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($size, $size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($dv)
        $bmp.Freeze()
        $script:ToolIcon = $bmp
    } catch { $script:ToolIcon = $null }
    return $script:ToolIcon
}

$script:Kinds = @{
    info     = @{ Color = '#4F6EF7'; Glyph = 0xE946; Title = 'SE.Live Scene Tool' }
    question = @{ Color = '#4F6EF7'; Glyph = 0xE9CE; Title = 'Please confirm' }
    warn     = @{ Color = '#F2A93B'; Glyph = 0xE7BA; Title = 'Heads up' }
    error    = @{ Color = '#E5484D'; Glyph = 0xEA39; Title = 'Something went wrong' }
    ok       = @{ Color = '#2FBF84'; Glyph = 0xE73E; Title = 'Done' }
}

function New-Brush([string]$Hex, [byte]$Alpha = 255) {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($Alpha, $c.R, $c.G, $c.B))
}

# A dark message box. $Buttons[0] is the main action (red when $Danger), the others are secondary.
# Returns the label of the button that was clicked ('' if the window was closed).
function Show-Dialog([string]$Message, [string]$Kind = 'info', [string[]]$Buttons = @('OK'), [string]$Title, [switch]$Danger) {
    $k = $script:Kinds[$Kind]
    if (-not $Title) { $Title = $k.Title }
    $body = @'
<StackPanel Margin="24,2,24,22">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border x:Name="iconBg" Width="38" Height="38" CornerRadius="19" VerticalAlignment="Top">
      <TextBlock x:Name="icon" FontFamily="Segoe MDL2 Assets" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <StackPanel Grid.Column="1" Margin="14,0,0,0">
      <TextBlock x:Name="title" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,1,0,6"/>
      <TextBlock x:Name="msg" TextWrapping="Wrap" Foreground="#B8BDCE" LineHeight="20"/>
    </StackPanel>
  </Grid>
  <StackPanel x:Name="buttons" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0"/>
</StackPanel>
'@
    $w = New-ToolWindow 'SE.Live Scene Tool' $body 440 $false
    $w.FindName('iconBg').Background = New-Brush $k.Color 0x2A
    $w.FindName('icon').Foreground   = New-Brush $k.Color
    $w.FindName('icon').Text         = [string][char]$k.Glyph
    $w.FindName('title').Text        = $Title
    $w.FindName('msg').Text          = $Message
    $panel = $w.FindName('buttons')
    for ($i = $Buttons.Count - 1; $i -ge 1; $i--) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $Buttons[$i]; $b.Style = $w.FindResource('Ghost'); $b.IsCancel = $true
        $b.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
        $b.Add_Click({ $win = [System.Windows.Window]::GetWindow($this); $win.Tag = [string]$this.Content; $win.Close() })
        [void]$panel.Children.Add($b)
    }
    $main = New-Object System.Windows.Controls.Button
    $main.Content = $Buttons[0]; $main.IsDefault = $true
    $main.Style = if ($Danger) { $w.FindResource('DangerBtn') } else { $w.FindResource('Primary') }
    $main.Add_Click({ $win = [System.Windows.Window]::GetWindow($this); $win.Tag = [string]$this.Content; $win.Close() })
    [void]$panel.Children.Add($main)
    if ($script:MainWindow -and $script:MainWindow.IsVisible) {
        $w.Owner = $script:MainWindow; $w.WindowStartupLocation = 'CenterOwner'
    } else {
        $w.WindowStartupLocation = 'CenterScreen'; $w.Topmost = $true
    }
    $w.Add_ContentRendered({ $this.Activate() })
    [void]$w.ShowDialog()
    return [string]$w.Tag
}

# Small non-modal "please wait" window, kept responsive by Wait-Ms while the tool waits for OBS.
function Show-Busy([string]$Text) {
    if (-not $script:GuiMode) { return }
    if (-not $script:BusyWindow) {
        $body = @'
<StackPanel Margin="24,4,24,22">
  <TextBlock x:Name="text" TextWrapping="Wrap" LineHeight="20" Foreground="#B8BDCE"/>
  <ProgressBar IsIndeterminate="True" Height="4" Margin="0,16,0,0" Foreground="#4F6EF7" Background="#252A3B" BorderThickness="0"/>
  <Button x:Name="cancel" Content="Cancel" Style="{StaticResource Ghost}" HorizontalAlignment="Right" Margin="0,18,0,0"/>
</StackPanel>
'@
        $script:BusyWindow = New-ToolWindow 'SE.Live Scene Tool' $body 420 $true
        $script:BusyWindow.WindowStartupLocation = 'CenterScreen'
        $script:BusyWindow.FindName('cancel').Add_Click({ $script:BusyCancelled = $true })
        $script:BusyWindow.Add_Closed({ $script:BusyCancelled = $true })
        $script:BusyWindow.Show()
        $script:BusyWindow.Activate()
    }
    $script:BusyWindow.FindName('text').Text = $Text
    Wait-Ms 60
}

function Hide-Busy {
    if ($script:BusyWindow) {
        $w = $script:BusyWindow; $script:BusyWindow = $null
        $w.Close()
        $script:BusyCancelled = $false
    }
}

# Sleep that keeps the windows responsive (painting, clicks on Cancel) while the tool waits.
function Wait-Ms([int]$Ms) {
    if (-not $script:GuiMode) { Start-Sleep -Milliseconds $Ms; return }
    $end = (Get-Date).AddMilliseconds($Ms)
    do {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
        Start-Sleep -Milliseconds 25
        if ($script:BusyCancelled) { Hide-Busy; exit 0 }
    } while ((Get-Date) -lt $end)
}

function Show-ErrorBox([string]$Msg) {
    if ($script:GuiMode) { [void](Show-Dialog $Msg 'error') }
    else { Write-Host "ERROR: $Msg" -ForegroundColor Red }
}

function Show-InfoBox([string]$Msg) {
    if ($script:GuiMode) { [void](Show-Dialog $Msg 'ok') }
    else { Write-Host $Msg -ForegroundColor Green }
}

function Confirm-Box([string]$Msg, [string]$Yes = 'Yes', [string]$No = 'Cancel') {
    return ((Show-Dialog $Msg 'question' @($Yes, $No)) -eq $Yes)
}

# Started from the launcher there is no console, so nothing may fail silently: any error that is not
# handled elsewhere ends up in a dialog.
trap {
    $text = $_.Exception.Message
    if ($script:GuiMode) {
        Hide-Busy
        try { [void](Show-Dialog "$text`n`n(at line $($_.InvocationInfo.ScriptLineNumber))" 'error') } catch { }
    } else { Write-Host "ERROR: $text" -ForegroundColor Red }
    exit 1
}

# ------------------------------------------------------------------ #
#  1. OBS process handling                                           #
# ------------------------------------------------------------------ #
function Get-ObsProcess { return @(Get-Process -Name obs64, obs32 -ErrorAction SilentlyContinue) }

function Wait-ObsExit([int]$Seconds) {
    $limite = (Get-Date).AddSeconds($Seconds)
    while ((Get-ObsProcess).Count -gt 0 -and (Get-Date) -lt $limite) {
        Wait-Ms 400
    }
    return ((Get-ObsProcess).Count -eq 0)
}

function Close-Obs {
    $procs = Get-ObsProcess
    if ($procs[0].Path) { $script:ObsExe = $procs[0].Path }
    # An OBS started "as administrator" hides its path from us, and Windows blocks a normal
    # process from closing an elevated one: in that case only the user can close it.
    $elevated = @($procs | Where-Object { -not $_.Path }).Count -gt 0
    if (-not $elevated) {
        Show-Busy "Closing OBS...`nIf OBS asks for a confirmation, answer it there."
        foreach ($p in $procs) {
            if (-not $p.CloseMainWindow()) {
                # Main window hidden (minimized to tray): a plain taskkill still asks it to close gracefully.
                & taskkill.exe /PID $p.Id 2>&1 | Out-Null
            }
        }
        if (Wait-ObsExit 45) { return }
    }
    if ($elevated) { $why = "OBS is running as administrator, so Windows does not let this tool close it." }
    else           { $why = "OBS did not close within 45 seconds (maybe a confirmation dialog is open)." }
    if (-not $script:GuiMode) { throw "$why Close OBS yourself (File > Exit) and run the tool again." }
    Show-Busy "$why`n`nClose OBS yourself (File > Exit): the tool continues by itself as soon as OBS is gone."
    while (-not (Wait-ObsExit 3600)) { }
}

function Wait-FilesSettled([string]$Dir) {
    # SE.Live writes its compositions while OBS shuts down: wait until nothing in the folder changes anymore.
    Show-Busy "Waiting for SE.Live to finish saving..."
    Wait-Ms 1000
    $prev = $null
    for ($k = 0; $k -lt 20; $k++) {
        $sig = (Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
        if ($sig -eq $prev) { return }
        $prev = $sig
        Wait-Ms 750
    }
}

function Get-ObsExePath {
    if ($script:ObsExe -and (Test-Path -LiteralPath $script:ObsExe)) { return $script:ObsExe }
    $cands = @()
    foreach ($key in @('HKLM:\SOFTWARE\OBS Studio', 'HKLM:\SOFTWARE\WOW6432Node\OBS Studio')) {
        $reg = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($reg -and $reg.'(default)') { $cands += (Join-Path $reg.'(default)' 'bin\64bit\obs64.exe') }
    }
    $cands += "$env:ProgramFiles\obs-studio\bin\64bit\obs64.exe"
    $cands += "${env:ProgramFiles(x86)}\obs-studio\bin\64bit\obs64.exe"
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

function Start-Obs {
    $exe = Get-ObsExePath
    if ($exe) {
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Path $exe -Parent)
        return $true
    }
    return $false
}

# ------------------------------------------------------------------ #
#  2. Raw read/write and composition file discovery                  #
# ------------------------------------------------------------------ #
function Get-CompositionDir {
    $dir = $env:APPDATA
    foreach ($seg in @('obs-studio','plugin_config','obs-streamelements-core','scoped_config_storage','streamelements_multi-streaming','compositions')) {
        $dir = Join-Path $dir $seg
    }
    return $dir
}

function Get-SELiveVersion([string]$CompositionPath) {
    # compositions -> streamelements_multi-streaming -> scoped_config_storage -> obs-streamelements-core
    try {
        $root = Split-Path (Split-Path (Split-Path (Split-Path $CompositionPath -Parent) -Parent) -Parent) -Parent
        $ini  = Join-Path $root 'obs-streamelements-core.ini'
        $m = Select-String -LiteralPath $ini -Pattern '^Version=(\d{4})(\d{2})(\d{2})(\d{6})\s*$' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) {
            $g = $m.Matches[0].Groups
            return ('{0}.{1}.{2}.{3}' -f ([int]$g[1].Value % 100), [int]$g[2].Value, [int]$g[3].Value, [int]$g[4].Value)
        }
    } catch { }
    return $null
}

function Read-Composition([string]$Path) {
    $item   = Get-Item -LiteralPath $Path
    $bytes  = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $offset = 0; if ($hasBom) { $offset = 3 }
    $text   = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, $offset, $bytes.Length - $offset)
    return [pscustomobject]@{ Text = $text; HasBom = $hasBom; Stamp = $item.LastWriteTimeUtc; Length = $item.Length }
}

function Write-Composition([string]$Path, [string]$Text, [bool]$HasBom) {
    # Write next to the original, then swap it in: a crash mid-write can never leave a half-written composition.
    $tmp = "$Path.tmp_$PID"
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($HasBom)))
    [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
}

# PowerShell unrolls a one-scene result into a single object, which in Windows PowerShell 5.1 has no
# .Count: callers that count or index the list must wrap the call in @( ) (a one-scene canvas was
# otherwise reported as "scene not found").
function Get-SceneList($Parsed) { return @(@($Parsed.scenes) | Where-Object { $null -ne $_ }) }

function Test-CompositionFormat($Parsed) {
    # Returns $null when the file looks like the format this tool was built for, otherwise the reason.
    if (-not $Parsed.PSObject.Properties['scenes']) { return "no 'scenes' list" }
    foreach ($s in (Get-SceneList $Parsed)) {
        if (-not ([string]$s.id -match "^$($script:PtrPattern)$")) { return "a scene id is not in the expected ptr(...) format" }
        if (-not ($s.name -is [string]))                         { return "a scene has no name" }
        if (-not $s.PSObject.Properties['active'])                { return "scene '$($s.name)' has no 'active' flag" }
        foreach ($src in @(@($s.sources) | Where-Object { $null -ne $_ })) {
            if (-not ([string]$src.id -match "^$($script:PtrPattern)$")) { return "source '$($src.name)' in scene '$($s.name)' has an unexpected id" }
        }
    }
    return $null
}

function Get-Canvases([object[]]$Files) {
    $list = @()
    foreach ($f in $Files) {
        try {
            $comp = Read-Composition $f.FullName
            $dati = ConvertFrom-Json -InputObject $comp.Text
            if ($dati.PSObject.Properties['scenes']) {
                $nome = if ($dati.name) { [string]$dati.name } else { $f.BaseName }
                $list += [pscustomobject]@{
                    Name = $nome; Path = $f.FullName; Dati = $dati; Testo = $comp.Text; HasBom = $comp.HasBom
                    Stamp = $comp.Stamp; Length = $comp.Length; FormatIssue = (Test-CompositionFormat $dati)
                }
            }
        } catch { }
    }
    return ,$list
}

# ------------------------------------------------------------------ #
#  3. Surgical engine (textual splice, zero global rewrite)          #
# ------------------------------------------------------------------ #
function ConvertTo-JsonEscaped([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if     ($ch -eq '"')  { [void]$sb.Append('\"') }
        elseif ($ch -eq '\')  { [void]$sb.Append('\\') }
        elseif ($ch -eq "`n") { [void]$sb.Append('\n') }
        elseif ($ch -eq "`r") { [void]$sb.Append('\r') }
        elseif ($ch -eq "`t") { [void]$sb.Append('\t') }
        elseif ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Get-SceneSpans([string]$Text) {
    $n = $Text.Length
    $depth = 0; $inStr = $false; $esc = $false; $strStart = -1
    $arrStart = -1; $arrEnd = -1; $arrDepth = -1
    $curStart = -1
    $spans = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $n; $i++) {
        $c = $Text[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') {
                $inStr = $false
                if ($arrStart -lt 0 -and $depth -eq 1) {
                    $tok = $Text.Substring($strStart + 1, $i - $strStart - 1)
                    if ($tok -eq 'scenes') {
                        $j = $i + 1
                        while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
                        if ($j -lt $n -and $Text[$j] -eq ':') {
                            $j++
                            while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
                            if ($j -lt $n -and $Text[$j] -eq '[') { $arrStart = $j; $arrDepth = $depth }
                        }
                    }
                }
            }
            continue
        }
        if ($c -eq '"') { $inStr = $true; $esc = $false; $strStart = $i; continue }
        if ($c -eq '{') {
            $depth++
            if ($arrStart -ge 0 -and $arrEnd -lt 0 -and $curStart -lt 0 -and $depth -eq ($arrDepth + 2) -and $i -gt $arrStart) { $curStart = $i }
            continue
        }
        if ($c -eq '}') {
            $depth--
            if ($curStart -ge 0 -and $depth -eq ($arrDepth + 1)) {
                [void]$spans.Add([pscustomobject]@{ Start = $curStart; End = $i })
                $curStart = -1
            }
            continue
        }
        if ($c -eq '[') { $depth++; continue }
        if ($c -eq ']') {
            $depth--
            if ($arrStart -ge 0 -and $arrEnd -lt 0 -and $depth -eq $arrDepth) { $arrEnd = $i }
            continue
        }
    }
    if ($arrStart -lt 0 -or $arrEnd -lt 0) { throw "Unexpected structure: 'scenes' array not found in the file." }
    return [pscustomobject]@{ ArrayStart = $arrStart; ArrayEnd = $arrEnd; Spans = @($spans) }
}

function Get-KeyValueSpans([string]$SceneText) {
    $n = $SceneText.Length
    $result = @{}
    $i = 1
    $depth = 1
    while ($i -lt $n -and $depth -ge 1) {
        $c = $SceneText[$i]
        if ([char]::IsWhiteSpace($c) -or $c -eq ',') { $i++; continue }
        if ($c -eq '}') { $depth--; $i++; continue }
        if ($depth -eq 1 -and $c -eq '"') {
            $ks = $i; $i++
            while ($i -lt $n) {
                if ($SceneText[$i] -eq '\') { $i += 2; continue }
                if ($SceneText[$i] -eq '"') { break }
                $i++
            }
            $key = $SceneText.Substring($ks + 1, $i - $ks - 1)
            $i++
            while ($i -lt $n -and [char]::IsWhiteSpace($SceneText[$i])) { $i++ }
            if ($i -ge $n -or $SceneText[$i] -ne ':') { throw "Unexpected scene structure (missing ':' after key '$key')." }
            $i++
            while ($i -lt $n -and [char]::IsWhiteSpace($SceneText[$i])) { $i++ }
            $vs = $i
            $vc = $SceneText[$i]
            if ($vc -eq '"') {
                $i++
                while ($i -lt $n) {
                    if ($SceneText[$i] -eq '\') { $i += 2; continue }
                    if ($SceneText[$i] -eq '"') { break }
                    $i++
                }
                $ve = $i; $i++
            } elseif ($vc -eq '{' -or $vc -eq '[') {
                $d2 = 0; $s2 = $false; $e2 = $false
                while ($i -lt $n) {
                    $cc = $SceneText[$i]
                    if ($s2) {
                        if ($e2) { $e2 = $false }
                        elseif ($cc -eq '\') { $e2 = $true }
                        elseif ($cc -eq '"') { $s2 = $false }
                    } elseif ($cc -eq '"') { $s2 = $true }
                    elseif ($cc -eq '{' -or $cc -eq '[') { $d2++ }
                    elseif ($cc -eq '}' -or $cc -eq ']') { $d2--; if ($d2 -eq 0) { break } }
                    $i++
                }
                $ve = $i; $i++
            } else {
                while ($i -lt $n -and $SceneText[$i] -ne ',' -and $SceneText[$i] -ne '}') { $i++ }
                $ve = $i - 1
                while ($ve -gt $vs -and [char]::IsWhiteSpace($SceneText[$ve])) { $ve-- }
            }
            if (-not $result.ContainsKey($key)) {
                $result[$key] = [pscustomobject]@{ Start = $vs; End = $ve }
            }
            continue
        }
        $i++
    }
    foreach ($k in @('name','active','id')) {
        if (-not $result.ContainsKey($k)) { throw "Unexpected scene structure (key '$k' not found)." }
    }
    return $result
}

function Update-Span([string]$Text, $Span, [string]$New) {
    return $Text.Remove($Span.Start, $Span.End - $Span.Start + 1).Insert($Span.Start, $New)
}

function Find-SceneIndex($Parsed, [string]$SceneName) {
    $scenes = @(Get-SceneList $Parsed)
    $idx = -1
    for ($k = 0; $k -lt $scenes.Count; $k++) {
        if ($scenes[$k].name -ceq $SceneName) {
            if ($idx -ge 0) { throw "More than one scene is named '$SceneName'." }
            $idx = $k
        }
    }
    if ($idx -lt 0) { throw ("Scene '{0}' not found. Available scenes: {1}" -f $SceneName, (($scenes | ForEach-Object { $_.name }) -join ', ')) }
    return $idx
}

function Assert-ValidNewName($Parsed, [string]$TargetName, [string]$Except) {
    if ([string]::IsNullOrWhiteSpace($TargetName)) { throw "The new scene name is empty." }
    if ($TargetName -ne $TargetName.Trim()) { throw "The name '$TargetName' starts or ends with spaces." }
    if ($TargetName -match '[\x00-\x1F]') { throw "The name '$TargetName' contains control characters." }
    $clash = @(Get-SceneList $Parsed | Where-Object { $_.name -eq $TargetName -and $_.name -cne $Except })
    if ($clash.Count -gt 0) { throw "A scene named '$($clash[0].name)' already exists on this canvas (names are compared ignoring case)." }
}

# The identities a scene owns: the scene itself and its entries (one per source in the scene).
# Filters are deliberately left out: they belong to the underlying source, which scenes share,
# so SE.Live itself writes the same filter id in every scene that uses that source.
function Get-OwnedIds($Scene) {
    $ids = New-Object System.Collections.ArrayList
    [void]$ids.Add([string]$Scene.id)
    foreach ($src in @(@($Scene.sources) | Where-Object { $null -ne $_ })) { [void]$ids.Add([string]$src.id) }
    return ,$ids
}

# Problems are keyed by ids (not names), so a problem SE.Live itself left in the file is not
# mistaken for a new one after a rename.
function Get-IntegrityProblems($Parsed) {
    $problems = New-Object System.Collections.Generic.List[string]
    $owner = @{}
    foreach ($s in (Get-SceneList $Parsed)) {
        foreach ($id in (Get-OwnedIds $s)) {
            if ($owner.ContainsKey($id)) { $problems.Add("id $id is used twice") }
            else { $owner[$id] = $true }
        }
        foreach ($src in @(@($s.sources) | Where-Object { $null -ne $_ })) {
            if ($src.PSObject.Properties['sceneId'] -and $src.sceneId -ne $s.id) {
                $problems.Add("entry $($src.id) points to another scene")
            }
            if ($Parsed.id -and $src.PSObject.Properties['videoCompositionId'] -and $src.videoCompositionId -ne $Parsed.id) {
                $problems.Add("entry $($src.id) belongs to another canvas")
            }
        }
        if ($Parsed.id -and $s.PSObject.Properties['videoCompositionId'] -and $s.videoCompositionId -ne $Parsed.id) {
            $problems.Add("scene $($s.id) belongs to another canvas")
        }
    }
    $names = @{}
    foreach ($s in (Get-SceneList $Parsed)) {
        $k = ([string]$s.name).ToLowerInvariant()
        if ($names.ContainsKey($k)) { $problems.Add("scene name '$($s.name)' is used twice") } else { $names[$k] = $true }
    }
    return ,$problems
}

function Assert-NoNewProblems($Before, $AfterParsed) {
    $new = @(foreach ($p in (Get-IntegrityProblems $AfterParsed)) { if ($Before -notcontains $p) { $p } })
    if ($new.Count -gt 0) { throw ("Validation failed, operation aborted, file untouched:`n  - " + ($new -join "`n  - ")) }
}

function Get-PtrPrefix([string]$Id) {
    if ($Id -match '^ptr\(([0-9A-Fa-f]{8})[0-9A-Fa-f]{8}\)$') { return $Matches[1].ToUpperInvariant() }
    return '0000026E'
}

function New-UniquePtr($Used, [string]$Prefix) {
    while ($true) {
        # 16-byte aligned, like the real heap addresses SE.Live writes
        $low  = [long]$script:Rng.Next(0x100000, 0x10000000) * 16
        $cand = 'ptr({0}{1:X8})' -f $Prefix, $low
        if ($Used.Add($cand)) { return $cand }
    }
}

function ConvertTo-Canonical($Value) { return (ConvertTo-Json -InputObject $Value -Depth 64 -Compress) }

# Without -AfterScene the copy is appended at the end of the list, otherwise it goes right after that scene.
function Copy-SceneInText([string]$Text, [string]$SceneName, [string]$TargetName, [string]$AfterScene) {
    $parsed = ConvertFrom-Json -InputObject $Text
    $scenes = @(Get-SceneList $parsed)
    $idx    = Find-SceneIndex $parsed $SceneName
    Assert-ValidNewName $parsed $TargetName $null
    $before = Get-IntegrityProblems $parsed

    $layout = Get-SceneSpans $Text
    if (@($layout.Spans).Count -ne $scenes.Count) { throw "Internal inconsistency while reading the file: operation aborted, file untouched." }
    if ($AfterScene) {
        $afterIdx = Find-SceneIndex $parsed $AfterScene
        $insertAt = $layout.Spans[$afterIdx].End + 1
        $copyIdx  = $afterIdx + 1
    } else {
        $insertAt = $layout.ArrayEnd
        $copyIdx  = $scenes.Count
    }
    $span = $layout.Spans[$idx]
    $sceneText = $Text.Substring($span.Start, $span.End - $span.Start + 1)

    $kv = Get-KeyValueSpans $sceneText
    $edits = @(
        [pscustomobject]@{ Span = $kv['name'];   New = '"' + (ConvertTo-JsonEscaped $TargetName) + '"' },
        [pscustomobject]@{ Span = $kv['active']; New = 'false' }
    ) | Sort-Object { $_.Span.Start } -Descending
    foreach ($e in $edits) { $sceneText = Update-Span $sceneText $e.Span $e.New }

    # Fresh identity for the scene and its entries; every occurrence is remapped, so the entries'
    # 'sceneId' back-references follow the new scene id automatically. Filter ids stay shared (see Get-OwnedIds).
    $used = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in [regex]::Matches($Text, $script:PtrPattern)) { [void]$used.Add($m.Value) }
    $owned = Get-OwnedIds $scenes[$idx]
    $prefix = Get-PtrPrefix ([string]$scenes[$idx].id)
    $map = @{}; $reverse = @{}
    foreach ($id in $owned) {
        if (-not $map.ContainsKey($id)) { $map[$id] = New-UniquePtr $used $prefix; $reverse[$map[$id]] = $id }
    }
    $sceneText = [regex]::Replace($sceneText, $script:PtrPattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($m) if ($map.ContainsKey($m.Value)) { $map[$m.Value] } else { $m.Value }
    })

    $newText = $Text.Insert($insertAt, ',' + $sceneText)

    # --- validation: nothing outside the splice moved, the copy is a faithful clone, ids are all unique ---
    if (-not ($newText.StartsWith($Text.Substring(0, $insertAt), [System.StringComparison]::Ordinal) -and
              $newText.EndsWith($Text.Substring($insertAt), [System.StringComparison]::Ordinal))) {
        throw "Validation failed (bytes outside the new scene changed): operation aborted, file untouched."
    }
    $check     = ConvertFrom-Json -InputObject $newText
    $newScenes = @(Get-SceneList $check)
    if ($newScenes.Count -ne ($scenes.Count + 1)) { throw "Validation failed (scene count): operation aborted, file untouched." }
    $copy = $newScenes[$copyIdx]
    if ($copy.name -cne $TargetName -or $copy.active -ne $false) { throw "Validation failed (name/active of the copy): operation aborted, file untouched." }
    $copySources = [regex]::Replace((ConvertTo-Canonical @($copy.sources)), $script:PtrPattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($m) if ($reverse.ContainsKey($m.Value)) { $reverse[$m.Value] } else { $m.Value }
    })
    if ($copySources -cne (ConvertTo-Canonical @($scenes[$idx].sources))) {
        throw "Validation failed (the copy differs from the original): operation aborted, file untouched."
    }
    Assert-NoNewProblems $before $check
    return $newText
}

function Rename-SceneInText([string]$Text, [string]$SceneName, [string]$TargetName) {
    $parsed = ConvertFrom-Json -InputObject $Text
    $scenes = @(Get-SceneList $parsed)
    $idx    = Find-SceneIndex $parsed $SceneName
    if ($TargetName -ceq $SceneName) { throw "The new name is identical to the current one." }
    Assert-ValidNewName $parsed $TargetName $SceneName
    $before = Get-IntegrityProblems $parsed

    $layout = Get-SceneSpans $Text
    if (@($layout.Spans).Count -ne $scenes.Count) { throw "Internal inconsistency while reading the file: operation aborted, file untouched." }
    $span = $layout.Spans[$idx]
    $kv = Get-KeyValueSpans ($Text.Substring($span.Start, $span.End - $span.Start + 1))
    $absStart = $span.Start + $kv['name'].Start
    $absLen   = $kv['name'].End - $kv['name'].Start + 1
    $newText  = $Text.Remove($absStart, $absLen).Insert($absStart, '"' + (ConvertTo-JsonEscaped $TargetName) + '"')

    $check     = ConvertFrom-Json -InputObject $newText
    $newScenes = @(Get-SceneList $check)
    if ($newScenes.Count -ne $scenes.Count -or $newScenes[$idx].name -cne $TargetName -or $newScenes[$idx].id -ne $scenes[$idx].id) {
        throw "Validation failed: operation aborted, file untouched."
    }
    Assert-NoNewProblems $before $check
    return $newText
}

function Remove-SceneInText([string]$Text, [string]$SceneName) {
    $parsed = ConvertFrom-Json -InputObject $Text
    $scenes = @(Get-SceneList $parsed)
    $idx    = Find-SceneIndex $parsed $SceneName
    if ($scenes.Count -le 1) { throw "'$SceneName' is the only scene of this canvas: it cannot be deleted." }
    if ($scenes[$idx].active) { throw "'$SceneName' is the active scene of the canvas. Switch the canvas to another scene in OBS first, then delete it." }
    $before = Get-IntegrityProblems $parsed

    $layout = Get-SceneSpans $Text
    if (@($layout.Spans).Count -ne $scenes.Count) { throw "Internal inconsistency while reading the file: operation aborted, file untouched." }
    # Cut the scene together with one separating comma: the one after it, or the one before it if it is the last.
    if ($idx -lt $scenes.Count - 1) { $from = $layout.Spans[$idx].Start;         $to = $layout.Spans[$idx + 1].Start - 1 }
    else                            { $from = $layout.Spans[$idx - 1].End + 1;   $to = $layout.Spans[$idx].End }
    $newText = $Text.Remove($from, $to - $from + 1)

    $check     = ConvertFrom-Json -InputObject $newText
    $expected  = @($scenes | Where-Object { $_.id -ne $scenes[$idx].id } | ForEach-Object { [string]$_.name })
    $remaining = @(Get-SceneList $check | ForEach-Object { [string]$_.name })
    if (($remaining -join "`n") -cne ($expected -join "`n")) { throw "Validation failed: operation aborted, file untouched." }
    Assert-NoNewProblems $before $check
    return $newText
}

# ------------------------------------------------------------------ #
#  4. Operations (backup + safe write)                               #
# ------------------------------------------------------------------ #
function New-BackupFile($Canvas) {
    $stamp  = Get-Date -Format 'yyyyMMdd_HHmmssfff'
    $backup = "$($Canvas.Path).bak_$stamp"
    Copy-Item -LiteralPath $Canvas.Path -Destination $backup
    return $backup
}

function Assert-SafeToWrite($Canvas) {
    if ((Get-ObsProcess).Count -gt 0) {
        throw "OBS is running again: SE.Live would overwrite the change when it closes. Close OBS and retry."
    }
    $now = Get-Item -LiteralPath $Canvas.Path
    if ($now.LastWriteTimeUtc -ne $Canvas.Stamp -or $now.Length -ne $Canvas.Length) {
        throw "The composition file changed after the tool read it (was OBS reopened?). Run the tool again so it works on the latest version."
    }
}

function Save-Composition($Canvas, [string]$NewText) {
    Assert-SafeToWrite $Canvas
    $backup = New-BackupFile $Canvas
    Write-Composition $Canvas.Path $NewText $Canvas.HasBom
    $back = Read-Composition $Canvas.Path
    if ($back.Text -cne $NewText) {
        Copy-Item -LiteralPath $backup -Destination $Canvas.Path -Force
        throw "Read-back check failed: the original file has been put back from the backup."
    }
    $Canvas.Testo = $back.Text; $Canvas.Dati = ConvertFrom-Json -InputObject $back.Text
    $Canvas.Stamp = $back.Stamp; $Canvas.Length = $back.Length
    return $backup
}

function Assert-CanvasUsable($Canvas) {
    if ($Canvas.FormatIssue) {
        throw "This canvas file is not in the format the tool knows ($($Canvas.FormatIssue)). SE.Live probably changed its file format: the tool needs an update. Nothing was changed."
    }
}

function Find-NameReferences($Canvas, [string]$Name) {
    $hits = @()
    try {
        $root = Split-Path -Path (Split-Path -Path (Split-Path -Path $Canvas.Path -Parent) -Parent) -Parent
        if (Test-Path -LiteralPath $root) {
            $altri = Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -ne $Canvas.Path }
            foreach ($f in $altri) {
                if (Select-String -LiteralPath $f.FullName -SimpleMatch -Pattern $Name -Quiet -ErrorAction SilentlyContinue) {
                    $hits += $f.FullName
                }
            }
        }
    } catch { }
    return ,$hits
}

# SE.Live restores the FIRST scene of a canvas by renaming its placeholder scene, and its rename (unlike
# adding a scene) wants a name that no OBS scene/source and no SE.Live scene or scene entry uses yet;
# otherwise it silently appends " 1" (obs-streamelements-core: SEObsSceneManager::ObsSetUniqueSourceName).
# The same rule applies to every rename made from the SE.Live dock.
function Get-ObsRoot([string]$CompositionPath) {
    # compositions -> streamelements_multi-streaming -> scoped_config_storage -> obs-streamelements-core -> plugin_config -> obs-studio
    $p = $CompositionPath
    for ($k = 0; $k -lt 6; $k++) { $p = Split-Path -Path $p -Parent }
    return $p
}

function Get-TakenNames($Canvas) {
    if ($script:TakenCache.ContainsKey($Canvas.Path)) { return $script:TakenCache[$Canvas.Path] }
    $taken = @{}   # lower-case name -> where it is used
    try {
        $root = Get-ObsRoot $Canvas.Path
        $ini  = Join-Path $root 'user.ini'
        if (-not (Test-Path -LiteralPath $ini)) { $ini = Join-Path $root 'global.ini' }
        $m = Select-String -LiteralPath $ini -Pattern '^SceneCollectionFile=(.+)$' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) {
            $leaf = $m.Matches[0].Groups[1].Value.Trim()
            if ($leaf -notlike '*.json') { $leaf += '.json' }
            $coll = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'basic\scenes') $leaf)))
            foreach ($s in @(@($coll.sources) + @($coll.groups) | Where-Object { $null -ne $_ })) {
                $k = ([string]$s.name).ToLowerInvariant()
                if (-not $taken.ContainsKey($k)) { $taken[$k] = "the OBS scene/source '$($s.name)'" }
            }
        }
    } catch { }
    foreach ($c in $script:AllCanvases) {
        foreach ($s in (Get-SceneList $c.Dati)) {
            $k = ([string]$s.name).ToLowerInvariant()
            if ($c.Path -ne $Canvas.Path -and -not $taken.ContainsKey($k)) { $taken[$k] = "scene '$($s.name)' on canvas '$($c.Name)'" }
            foreach ($src in @(@($s.sources) | Where-Object { $null -ne $_ })) {
                $k = ([string]$src.name).ToLowerInvariant()
                if (-not $taken.ContainsKey($k)) { $taken[$k] = "source '$($src.name)' on canvas '$($c.Name)'" }
            }
        }
    }
    $script:TakenCache[$Canvas.Path] = $taken
    return $taken
}

# $null when $Name is safe as the first scene of $Canvas, otherwise where else it is used.
function Get-FirstSceneClash($Canvas, [string]$Name) {
    $taken = Get-TakenNames $Canvas
    $k = $Name.ToLowerInvariant()
    if ($taken.ContainsKey($k)) { return $taken[$k] }
    return $null
}

function Get-SafeFirstSceneName($Canvas, [string]$Name) {
    # The first scene itself is the one being renamed, so its current name does not count as taken.
    $own = @(Get-SceneList $Canvas.Dati | Select-Object -Skip 1 | ForEach-Object { ([string]$_.name).ToLowerInvariant() })
    $base = "$Name - Vertical"
    $cand = $base; $n = 1
    while ((Get-FirstSceneClash $Canvas $cand) -or ($own -contains $cand.ToLowerInvariant())) { $n++; $cand = "$base $n" }
    return $cand
}

function Get-FirstSceneWarning($Canvas, [string]$Name) {
    $where = Get-FirstSceneClash $Canvas $Name
    if (-not $where) { return '' }
    return "The first scene '$Name' has the same name as $where, so SE.Live shows it as '$Name 1'. Give it a name used nowhere else in OBS, e.g. '$(Get-SafeFirstSceneName $Canvas $Name)'."
}

function Split-Names([string[]]$Names) {
    return ,@($Names | ForEach-Object { $_ -split "\||`r?`n" } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Invoke-SceneDuplicate($Canvas, [string]$SceneName, [string[]]$TargetNames, [bool]$AfterOriginal = $true) {
    Assert-CanvasUsable $Canvas
    if ($TargetNames.Count -eq 0) { throw "Type at least one name for the copy." }
    $seen = @{}
    foreach ($t in $TargetNames) {
        if ($seen.ContainsKey($t.ToLowerInvariant())) { throw "The name '$t' is in the list twice." }
        $seen[$t.ToLowerInvariant()] = $true
    }
    $text = $Canvas.Testo
    # Each copy goes after the previous one, so a batch keeps the order it was typed in.
    $anchor = if ($AfterOriginal) { $SceneName } else { $null }
    foreach ($t in $TargetNames) {
        $text = Copy-SceneInText $text $SceneName $t $anchor
        if ($AfterOriginal) { $anchor = $t }
    }
    return [pscustomobject]@{ Backup = (Save-Composition $Canvas $text); Warnings = @() }
}

function Invoke-SceneRename($Canvas, [string]$SceneName, [string]$TargetName) {
    Assert-CanvasUsable $Canvas
    if ((Find-SceneIndex $Canvas.Dati $SceneName) -eq 0) {
        $where = Get-FirstSceneClash $Canvas $TargetName
        if ($where) {
            throw ("'$SceneName' is the first scene of the canvas, and SE.Live gives the first scene a name used nowhere else in OBS. " +
                   "'$TargetName' is already $where, so SE.Live would show '$TargetName 1'. Use a different name, e.g. '$(Get-SafeFirstSceneName $Canvas $TargetName)'.")
        }
    }
    $text = Rename-SceneInText $Canvas.Testo $SceneName $TargetName
    $backup = Save-Composition $Canvas $text
    return [pscustomobject]@{ Backup = $backup; Warnings = (Find-NameReferences $Canvas $SceneName); Note = '' }
}

function Invoke-SceneDelete($Canvas, [string]$SceneName) {
    Assert-CanvasUsable $Canvas
    $wasFirst = (Find-SceneIndex $Canvas.Dati $SceneName) -eq 0
    $text = Remove-SceneInText $Canvas.Testo $SceneName
    $backup = Save-Composition $Canvas $text
    $note = ''
    if ($wasFirst) {
        $next = [string](Get-SceneList $Canvas.Dati)[0].name
        $warn = Get-FirstSceneWarning $Canvas $next
        if ($warn) { $note = "`n`nNOTE: '$next' is now the first scene. $warn" }
    }
    return [pscustomobject]@{ Backup = $backup; Warnings = @(); Note = $note }
}

function Get-Backups($Canvas) {
    $dir  = Split-Path -Path $Canvas.Path -Parent
    $leaf = Split-Path -Path $Canvas.Path -Leaf
    $items = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter "$leaf.bak_*" -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $when = $f.LastWriteTime
        if ($f.Name -match '\.bak_(\d{8}_\d{6})') {
            $when = [datetime]::ParseExact($Matches[1], 'yyyyMMdd_HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $scenes = $null
        try { $scenes = @(Get-SceneList (ConvertFrom-Json -InputObject (Read-Composition $f.FullName).Text) | ForEach-Object { [string]$_.name }) } catch { }
        $items += [pscustomobject]@{ Path = $f.FullName; When = $when; Scenes = $scenes }
    }
    return ,$items
}

function Format-Backup($b) {
    $what = if ($null -eq $b.Scenes) { 'unreadable' } else { '{0} scenes' -f $b.Scenes.Count }
    return ('{0:yyyy-MM-dd HH:mm:ss}  ({1})' -f $b.When, $what)
}

function Invoke-BackupRestore($Canvas, [string]$BackupPath) {
    if (-not (Test-Path -LiteralPath $BackupPath)) { throw "Backup not found: $BackupPath" }
    $bk = Read-Composition $BackupPath
    $bkData = ConvertFrom-Json -InputObject $bk.Text
    if (-not $bkData.PSObject.Properties['scenes']) { throw "That file is not a valid composition backup." }
    if ($Canvas.Dati.id -and $bkData.id -and $bkData.id -ne $Canvas.Dati.id) { throw "That backup belongs to a different canvas." }
    Assert-SafeToWrite $Canvas
    $backup = New-BackupFile $Canvas   # the current state stays restorable too
    $tmp = "$($Canvas.Path).tmp_$PID"
    Copy-Item -LiteralPath $BackupPath -Destination $tmp -Force
    [System.IO.File]::Replace($tmp, $Canvas.Path, [NullString]::Value)
    return [pscustomobject]@{ Backup = $backup; Scenes = @(Get-SceneList $bkData | ForEach-Object { [string]$_.name }) }
}

function Format-Warnings($Warnings) {
    if (-not $Warnings -or $Warnings.Count -eq 0) { return '' }
    $list = ($Warnings | ForEach-Object { Split-Path -Path $_ -Leaf }) -join "`n  - "
    return "`n`nNOTE: the old name also appears in other SE.Live files:`n  - $list`nIf this scene was linked (Link Scene), re-check the link in OBS."
}

# ------------------------------------------------------------------ #
#  5. Startup: close OBS, find the canvases                          #
# ------------------------------------------------------------------ #
if ($File) {
    if (-not (Test-Path -LiteralPath $File)) { Show-ErrorBox "File not found: $File"; exit 1 }
    $File = (Resolve-Path -LiteralPath $File).ProviderPath
    $compDir = Split-Path -Path $File -Parent
} else {
    $compDir = Get-CompositionDir
}

if (-not $List -and (Get-ObsProcess).Count -gt 0) {
    if (-not $script:GuiMode -and -not $Force) {
        Show-ErrorBox "OBS is running. Close it first, or add -Force to let the tool close it gracefully."
        exit 1
    }
    if ($script:GuiMode -and -not (Confirm-Box ("OBS needs to be closed: SE.Live saves the canvas scenes when OBS shuts down, " +
            "and would overwrite any change made while it runs.`n`nThe tool can reopen OBS when you are done.") 'Close OBS' 'Cancel')) {
        exit 0
    }
    $script:ObsWasRunning = $true
    try { Close-Obs } catch { Hide-Busy; Show-ErrorBox $_.Exception.Message; exit 1 }
    Wait-FilesSettled $compDir
    Hide-Busy
}

if ($File) {
    $percorsi = @(Get-Item -LiteralPath $File)
} else {
    $percorsi = @(Get-ChildItem -LiteralPath $compDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($percorsi.Count -eq 0 -and $script:GuiMode -and
        (Confirm-Box "No SE.Live canvas files found in:`n$compDir`n`nIs SE.Live installed, with at least one canvas?`n`nYou can also pick a canvas file yourself (e.g. for a portable OBS)." 'Browse...' 'Cancel')) {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'SE.Live composition (*.json)|*.json'
        $dlg.Title  = 'Pick an SE.Live composition file (...\streamelements_multi-streaming\compositions\*.json)'
        if ($dlg.ShowDialog()) { $percorsi = @(Get-Item -LiteralPath $dlg.FileName) }
    }
    if ($percorsi.Count -eq 0) {
        Show-ErrorBox "No composition files found in:`n$compDir`n`nIs SE.Live installed, and have you created at least one canvas?"
        exit 1
    }
}

$canvasList = Get-Canvases $percorsi
if ($canvasList.Count -eq 0) {
    Show-ErrorBox "Found some files, but none contain scenes in a recognizable format. If SE.Live changed its file format, this tool may need an update."
    exit 1
}
$seVersion = Get-SELiveVersion $canvasList[0].Path
$script:AllCanvases = $canvasList
$script:TakenCache  = @{}

# ------------------------------------------------------------------ #
#  6a. Command-line mode                                             #
# ------------------------------------------------------------------ #
if ($List) {
    if ((Get-ObsProcess).Count -gt 0) { Write-Host "(OBS is running: unsaved dock changes are not in the files yet)" -ForegroundColor Yellow }
    Write-Host "SE.Live Scene Tool v$($script:ToolVersion) - built for SE.Live $($script:TestedSELive) on OBS $($script:TestedObs)"
    if (-not $seVersion) {
        Write-Host "Installed SE.Live version: not detected" -ForegroundColor Yellow
    } elseif ($seVersion -eq $script:TestedSELive) {
        Write-Host "Installed SE.Live version: $seVersion (the tested one)" -ForegroundColor Green
    } else {
        Write-Host "Installed SE.Live version: $seVersion - different from the tested $($script:TestedSELive): the format checks still protect your files" -ForegroundColor Yellow
    }
    foreach ($c in $canvasList) {
        Write-Host ""
        Write-Host "Canvas '$($c.Name)'  ->  $($c.Path)" -ForegroundColor Cyan
        if ($c.FormatIssue) { Write-Host "  unsupported format: $($c.FormatIssue)" -ForegroundColor Red }
        foreach ($s in (Get-SceneList $c.Dati)) {
            $mark = if ($s.active) { '*' } else { ' ' }
            Write-Host ("  {0} {1}  ({2} sources)" -f $mark, $s.name, @(@($s.sources) | Where-Object { $null -ne $_ }).Count)
        }
        $first = @(Get-SceneList $c.Dati)
        if ($first.Count -gt 0) {
            $warn = Get-FirstSceneWarning $c ([string]$first[0].name)
            if ($warn) { Write-Host "  WARNING: $warn" -ForegroundColor Yellow }
        }
        Write-Host ("  backups: {0}" -f (Get-Backups $c).Count)
    }
    exit 0
}

if (-not $script:GuiMode) {
    $target = $canvasList[0]
    if ($Canvas) {
        $target = @($canvasList | Where-Object { $_.Name -eq $Canvas }) | Select-Object -First 1
        if (-not $target) { Show-ErrorBox ("Canvas '$Canvas' not found. Canvases: " + (($canvasList | ForEach-Object { $_.Name }) -join ', ')); exit 1 }
    } elseif ($canvasList.Count -gt 1) {
        $list2 = ($canvasList | ForEach-Object { "$($_.Name) -> $($_.Path)" }) -join "`n"
        Show-ErrorBox "More than one canvas found, pick one with -Canvas <name> or -File <path>:`n$list2"
        exit 1
    }
    $names = Split-Names $NewName
    try {
        if ($RestoreFrom) {
            $res = Invoke-BackupRestore -Canvas $target -BackupPath $RestoreFrom
            $msg = "Done! Canvas '$($target.Name)' restored ($($res.Scenes.Count) scenes: $($res.Scenes -join ', '))."
        } elseif ($Delete) {
            if (-not $Scene) { throw "-Delete needs -Scene." }
            $res = Invoke-SceneDelete -Canvas $target -SceneName $Scene
            $msg = "Done! Scene '$Scene' deleted.$($res.Note)"
        } else {
            if (-not $Scene -or $names.Count -eq 0) { throw "In -NoGui mode you must pass -Scene and -NewName (or -Delete, -RestoreFrom, -List)." }
            if ($Rename) {
                if ($names.Count -ne 1) { throw "-Rename takes exactly one new name." }
                $res = Invoke-SceneRename -Canvas $target -SceneName $Scene -TargetName $names[0]
                $msg = "Done! Scene '$Scene' renamed to '$($names[0])'.$($res.Note)"
            } else {
                $res = Invoke-SceneDuplicate -Canvas $target -SceneName $Scene -TargetNames $names -AfterOriginal (-not $AtEnd)
                $msg = "Done! Scene '$Scene' duplicated as: $($names -join ', ')."
            }
        }
    } catch {
        Show-ErrorBox $_.Exception.Message
        exit 1
    }
    Write-Host ""
    Write-Host $msg -ForegroundColor Green
    Write-Host "Backup of the previous state: $($res.Backup)"
    $warn = Format-Warnings $res.Warnings
    if ($warn) { Write-Host $warn -ForegroundColor Yellow }
    if (-not $NoRestart -and $script:ObsExe) { [void](Start-Obs) }
    exit 0
}

# ------------------------------------------------------------------ #
#  6b. GUI mode                                                      #
# ------------------------------------------------------------------ #
$mainBody = @'
<Grid Margin="24,0,24,0">
  <Grid.RowDefinitions>
    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>
  <TextBlock x:Name="Heading" FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="22" FontWeight="SemiBold"/>
  <TextBlock x:Name="SubHeading" Grid.Row="1" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,0" LineHeight="19"/>

  <Border Grid.Row="2" Background="{StaticResource Surface}" CornerRadius="10" Padding="4" Margin="0,18,0,0">
    <UniformGrid Columns="4">
      <RadioButton x:Name="tabDuplicate" GroupName="mode" Style="{StaticResource Tab}" Tag="&#xE8C8;" Content="Duplicate" IsChecked="True"/>
      <RadioButton x:Name="tabRename" GroupName="mode" Style="{StaticResource Tab}" Tag="&#xE8AC;" Content="Rename"/>
      <RadioButton x:Name="tabDelete" GroupName="mode" Style="{StaticResource Tab}" Tag="&#xE74D;" Content="Delete"/>
      <RadioButton x:Name="tabBackups" GroupName="mode" Style="{StaticResource Tab}" Tag="&#xE81C;" Content="Backups"/>
    </UniformGrid>
  </Border>

  <TextBlock Grid.Row="3" Text="CANVAS" Style="{StaticResource Caption}"/>
  <ComboBox Grid.Row="4" x:Name="cmbCanvas"/>

  <TextBlock Grid.Row="5" x:Name="lblList" Style="{StaticResource Caption}"/>
  <ListBox Grid.Row="6" x:Name="lstItems" MinHeight="120">
    <ListBox.ItemTemplate>
      <DataTemplate>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Ellipse Width="8" Height="8" Fill="{Binding Dot}" VerticalAlignment="Center" Margin="0,0,11,0"/>
          <StackPanel Grid.Column="1">
            <TextBlock Text="{Binding Title}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="{Binding Sub}" Foreground="#8F96AD" FontSize="11.5" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
          <Border Grid.Column="2" Visibility="{Binding BadgeVis}" Background="#2F3549" CornerRadius="5" Padding="7,2"
                  VerticalAlignment="Center" Margin="8,0,0,0">
            <TextBlock Text="{Binding Badge}" FontSize="10" FontWeight="SemiBold" Foreground="#B8BDCE"/>
          </Border>
        </Grid>
      </DataTemplate>
    </ListBox.ItemTemplate>
  </ListBox>

  <StackPanel Grid.Row="7" x:Name="pnlName">
    <TextBlock x:Name="lblName" Style="{StaticResource Caption}"/>
    <TextBox x:Name="txtName" TextWrapping="Wrap" MaxHeight="110"/>
  </StackPanel>

  <Border Grid.Row="8" x:Name="hintCard" CornerRadius="8" BorderThickness="1" Padding="12,10" Margin="0,16,0,0">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="hintIcon" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,2,10,0" VerticalAlignment="Top"/>
      <TextBlock x:Name="hintText" Grid.Column="1" TextWrapping="Wrap" LineHeight="19"/>
    </Grid>
  </Border>

  <StackPanel Grid.Row="9" Margin="2,16,0,0">
    <CheckBox x:Name="chkAfter" Content="Place the copies right after the original" IsChecked="True" Margin="0,0,0,10"/>
    <CheckBox x:Name="chkReopen"/>
  </StackPanel>

  <Border Grid.Row="10" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Margin="-24,20,-24,0" Padding="24,14,24,18">
    <Grid>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Ellipse x:Name="verDot" Width="8" Height="8" Margin="0,0,8,0"/>
        <TextBlock x:Name="verText" Foreground="{StaticResource Muted}" FontSize="11.5" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="btnShortcut" Style="{StaticResource Ghost}" Padding="11,9" Margin="0,0,8,0"
                ToolTip="Create a Desktop shortcut that opens the tool without any console window">
          <TextBlock Text="&#xE71B;" FontFamily="Segoe MDL2 Assets" FontSize="13"/>
        </Button>
        <Button x:Name="btnAction" Style="{StaticResource Primary}" MinWidth="120"/>
      </StackPanel>
    </Grid>
  </Border>
</Grid>
'@

$script:MainWindow = New-ToolWindow 'SE.Live Scene Tool' $mainBody 540 $true
$script:MainWindow.WindowStartupLocation = 'CenterScreen'
# Fixed height, so switching tabs does not make the window jump: the scene list takes the free space.
$script:MainWindow.SizeToContent = 'Manual'
$script:MainWindow.Height = 840
$ui = @{}
foreach ($n in @('Heading','SubHeading','tabDuplicate','tabRename','tabDelete','tabBackups','cmbCanvas','lblList','lstItems',
                 'pnlName','lblName','txtName','hintCard','hintIcon','hintText','chkAfter','chkReopen','verDot','verText',
                 'btnShortcut','btnAction')) {
    $ui[$n] = $script:MainWindow.FindName($n)
}

$script:Mode        = 'duplicate'
$script:Changed     = $false
$script:LastDefault = ''
$script:Backups     = @()
$script:Refreshing  = $false   # true while the list is rebuilt, so selection events don't fire half-way
$script:Dot         = [string][char]0x00B7

$script:ModeText = @{
    duplicate = @{ Head = 'Duplicate a scene'; Action = 'Duplicate'; List = 'SCENE TO COPY'
                   Sub  = 'Copies a scene of the canvas with all its sources, positions, crops and filters.'
                   Name = "NAME OF THE COPY  $($script:Dot)  ONE PER LINE FOR SEVERAL" }
    rename    = @{ Head = 'Rename a scene'; Action = 'Rename'; List = 'SCENE TO RENAME'; Name = 'NEW NAME'
                   Sub  = 'Changes the name of a scene in the canvas file.' }
    delete    = @{ Head = 'Delete a scene'; Action = 'Delete'; List = 'SCENE TO DELETE'
                   Sub  = 'Removes a scene from the canvas; its sources stay in OBS.' }
    backups   = @{ Head = 'Restore a backup'; Action = 'Restore'; List = "BACKUPS  $($script:Dot)  NEWEST FIRST"
                   Sub  = 'Every change saves a backup first. Pick one to put the canvas back as it was.' }
}

function Get-CurrentCanvas { return $canvasList[$ui.cmbCanvas.SelectedIndex] }

function Set-Hint([string]$Kind, [string]$Text) {
    if (-not $Text) { $ui.hintCard.Visibility = 'Collapsed'; return }
    $k = $script:Kinds[$Kind]
    $ui.hintCard.Visibility  = 'Visible'
    $ui.hintCard.Background  = New-Brush $k.Color 0x1C
    $ui.hintCard.BorderBrush = New-Brush $k.Color 0x50
    $ui.hintIcon.Foreground  = New-Brush $k.Color
    $ui.hintIcon.Text        = [string][char]$k.Glyph
    $ui.hintText.Text        = $Text
}

function New-ListItem([string]$Key, [string]$Title, [string]$Sub, [string]$Dot, [string]$Badge) {
    $vis = if ($Badge) { 'Visible' } else { 'Collapsed' }
    return [pscustomobject]@{ Key = $Key; Title = $Title; Sub = $Sub; Dot = $Dot; Badge = $Badge; BadgeVis = $vis }
}

function Get-SceneItems($Canvas) {
    $scenes = @(Get-SceneList $Canvas.Dati)
    $items = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $scenes.Count; $i++) {
        $s = $scenes[$i]
        $n = @(@($s.sources) | Where-Object { $null -ne $_ }).Count
        $sub = if ($n -eq 1) { '1 source' } else { "$n sources" }
        if ($s.active) { $sub += "  $($script:Dot)  active scene" }
        $dot   = if ($s.active) { '#2FBF84' } else { '#3A4058' }
        $badge = if ($i -eq 0) { 'FIRST' } else { '' }
        [void]$items.Add((New-ListItem ([string]$s.name) ([string]$s.name) $sub $dot $badge))
    }
    return ,$items
}

function Get-BackupItems($Canvas) {
    $script:Backups = Get-Backups $Canvas
    $items = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $script:Backups.Count; $i++) {
        $b = $script:Backups[$i]
        if ($null -eq $b.Scenes) { $sub = 'unreadable' }
        else {
            $plural = if ($b.Scenes.Count -eq 1) { '' } else { 's' }
            $sub = "$($b.Scenes.Count) scene$plural  $($script:Dot)  $($b.Scenes -join ', ')"
        }
        $title = $b.When.ToString('d MMM yyyy, HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        $badge = if ($i -eq 0) { 'LATEST' } else { '' }
        [void]$items.Add((New-ListItem $b.Path $title $sub '#3A4058' $badge))
    }
    return ,$items
}

# Hint, default name and button state for the current mode and selection.
function Update-Context {
    $canvas = Get-CurrentCanvas
    $sel    = $ui.lstItems.SelectedItem
    $idx    = $ui.lstItems.SelectedIndex
    $scenes = @(Get-SceneList $canvas.Dati)
    $ui.btnAction.IsEnabled = ($null -ne $sel)

    if ($sel -and ($script:Mode -eq 'duplicate' -or $script:Mode -eq 'rename')) {
        if ($script:Mode -eq 'rename') {
            $default = $sel.Key
            # A first scene that SE.Live shows as "<name> 1": offer a name that will stick.
            if ($idx -eq 0 -and (Get-FirstSceneClash $canvas $default)) { $default = Get-SafeFirstSceneName $canvas $default }
        } else {
            $default = "$($sel.Key) - Copy"
        }
        if ($ui.txtName.Text -eq $script:LastDefault -or [string]::IsNullOrWhiteSpace($ui.txtName.Text)) { $ui.txtName.Text = $default }
        $script:LastDefault = $default
    }

    switch ($script:Mode) {
        'duplicate' { Set-Hint 'info' 'Use names not already used on this canvas. For several copies at once, write one name per line.' }
        'rename' {
            if ($idx -eq 0) {
                $warn = if ($sel) { Get-FirstSceneWarning $canvas $sel.Key } else { '' }
                if ($warn) { Set-Hint 'warn' $warn }
                else { Set-Hint 'info' "This is the first scene: its name must not be used anywhere else in OBS (scenes or sources), otherwise SE.Live adds ' 1'. The tool checks it for you." }
            } else {
                Set-Hint 'info' "Names also used on the main canvas are fine here. Renaming from the SE.Live dock is different: there SE.Live would add ' 1'."
            }
        }
        'delete' {
            if ($idx -ge 0 -and $scenes[$idx].active) {
                Set-Hint 'warn' 'This is the active scene of the canvas. Switch the canvas to another scene in OBS first, then delete it.'
                $ui.btnAction.IsEnabled = $false
            } elseif ($scenes.Count -le 1) {
                Set-Hint 'warn' 'This is the only scene of the canvas, so it cannot be deleted.'
                $ui.btnAction.IsEnabled = $false
            } else {
                Set-Hint 'info' 'The scene is removed from the canvas; its sources stay in OBS. A backup is saved first, so you can bring it back from Backups.'
            }
        }
        'backups' {
            if ($script:Backups.Count -eq 0) {
                Set-Hint 'info' 'No backups yet for this canvas: the tool saves one before every change.'
            } elseif ($idx -ge 0 -and $null -eq $script:Backups[$idx].Scenes) {
                Set-Hint 'error' 'This backup cannot be read.'
                $ui.btnAction.IsEnabled = $false
            } elseif ($idx -ge 0) {
                Set-Hint 'info' ("Scenes in this backup: " + ($script:Backups[$idx].Scenes -join ', ') + ". The current state is backed up first, so a restore can be undone too.")
            }
        }
    }
    if ($canvas.FormatIssue -and $script:Mode -ne 'backups') {
        Set-Hint 'error' "This canvas file is not in the format the tool knows ($($canvas.FormatIssue)). SE.Live probably changed something: the tool needs an update."
        $ui.btnAction.IsEnabled = $false
    }
}

function Update-List([string]$SelectKey) {
    $canvas = Get-CurrentCanvas
    if ($script:Mode -eq 'backups') { $items = Get-BackupItems $canvas } else { $items = Get-SceneItems $canvas }
    $script:Refreshing = $true
    $ui.lstItems.ItemsSource = $items
    $pick = 0
    if ($SelectKey) {
        for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].Key -ceq $SelectKey) { $pick = $i; break } }
    }
    if ($items.Count -gt 0) {
        $ui.lstItems.SelectedIndex = $pick
        $ui.lstItems.ScrollIntoView($ui.lstItems.SelectedItem)
    }
    $script:Refreshing = $false
    Update-Context
}

function Set-Mode([string]$Mode) {
    # Keep the same scene selected when moving between the scene tabs.
    $keep = $null
    if ($script:Mode -ne 'backups' -and $Mode -ne 'backups' -and $ui.lstItems.SelectedItem) { $keep = $ui.lstItems.SelectedItem.Key }
    $script:Mode = $Mode
    $t = $script:ModeText[$Mode]
    $ui.Heading.Text      = $t.Head
    $ui.SubHeading.Text   = $t.Sub
    $ui.lblList.Text      = $t.List
    $ui.btnAction.Content = $t.Action
    $hasName = ($Mode -eq 'duplicate' -or $Mode -eq 'rename')
    $ui.pnlName.Visibility  = if ($hasName) { 'Visible' } else { 'Collapsed' }
    $ui.lblName.Text        = $t.Name
    $ui.txtName.AcceptsReturn = ($Mode -eq 'duplicate')
    $ui.txtName.MinHeight   = if ($Mode -eq 'duplicate') { 64 } else { 0 }
    $ui.chkAfter.Visibility = if ($Mode -eq 'duplicate') { 'Visible' } else { 'Collapsed' }
    $style = if ($Mode -eq 'delete') { 'DangerBtn' } else { 'Primary' }
    $ui.btnAction.Style = $script:MainWindow.FindResource($style)
    $ui.txtName.Text = ''
    $script:LastDefault = ''
    Update-List $keep
}

function Update-CanvasFromDisk($Canvas) {
    $comp = Read-Composition $Canvas.Path
    $Canvas.Testo  = $comp.Text
    $Canvas.Dati   = ConvertFrom-Json -InputObject $comp.Text
    $Canvas.HasBom = $comp.HasBom
    $Canvas.Stamp  = $comp.Stamp
    $Canvas.Length = $comp.Length
    $Canvas.FormatIssue = Test-CompositionFormat $Canvas.Dati
}

function Invoke-Action {
    $canvas = Get-CurrentCanvas
    $sel = $ui.lstItems.SelectedItem
    if (-not $sel -or -not $ui.btnAction.IsEnabled) { return }
    try {
        $kind = 'ok'
        $select = $sel.Key
        switch ($script:Mode) {
            'duplicate' {
                $names = Split-Names @($ui.txtName.Text)
                $res = Invoke-SceneDuplicate -Canvas $canvas -SceneName $sel.Key -TargetNames $names -AfterOriginal ([bool]$ui.chkAfter.IsChecked)
                if ($names.Count -eq 1) { $msg = "'$($names[0])' created from '$($sel.Key)'." }
                else { $msg = "$($names.Count) copies of '$($sel.Key)' created: $($names -join ', ')." }
            }
            'rename' {
                $names = Split-Names @($ui.txtName.Text)
                if ($names.Count -ne 1) { throw 'Type exactly one new name.' }
                $res = Invoke-SceneRename -Canvas $canvas -SceneName $sel.Key -TargetName $names[0]
                $msg = "'$($sel.Key)' renamed to '$($names[0])'."
                $select = $names[0]
            }
            'delete' {
                $answer = Show-Dialog "Delete '$($sel.Key)' from canvas '$($canvas.Name)'?`n`nIts sources stay in OBS, and a backup is saved first." `
                    'question' @('Delete', 'Cancel') 'Delete this scene?' -Danger
                if ($answer -ne 'Delete') { return }
                $res = Invoke-SceneDelete -Canvas $canvas -SceneName $sel.Key
                $msg = "'$($sel.Key)' deleted."
                $select = $null
            }
            'backups' {
                $b = $script:Backups[$ui.lstItems.SelectedIndex]
                $answer = Show-Dialog ("Put canvas '$($canvas.Name)' back the way it was on $($sel.Title)?`n`nScenes after the restore: " + ($b.Scenes -join ', ')) `
                    'question' @('Restore', 'Cancel') 'Restore this backup?'
                if ($answer -ne 'Restore') { return }
                $res = Invoke-BackupRestore -Canvas $canvas -BackupPath $b.Path
                Update-CanvasFromDisk $canvas
                $msg = "Canvas restored ($($res.Scenes.Count) scenes)."
                $select = $null
            }
        }
        $script:Changed = $true
        $script:TakenCache = @{}
        $msg += "`nBackup of the previous state: " + (Split-Path -Path $res.Backup -Leaf)
        if ($res.Note) { $msg += $res.Note; $kind = 'warn' }
        if ($res.Warnings -and @($res.Warnings).Count -gt 0) { $msg += Format-Warnings $res.Warnings }
        $ui.txtName.Text = ''
        $script:LastDefault = ''
        Update-List $select
        Set-Hint $kind $msg
    } catch {
        Set-Hint 'error' $_.Exception.Message
    }
}

# Writes the app icon as a PNG-in-ICO file (supported since Windows Vista) for the Desktop shortcut.
function Save-ToolIco([string]$Path) {
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create((Get-ToolIcon)))
    $ms = New-Object System.IO.MemoryStream
    $enc.Save($ms)
    $png = $ms.ToArray()
    $bw = New-Object System.IO.BinaryWriter([System.IO.File]::Create($Path))
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)                    # header: icon file, 1 image
        $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0)       # 256x256, no palette
        $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)
        $bw.Write($png)
    } finally { $bw.Close() }
}

# The shortcut starts PowerShell through a headless console host, so no console window ever appears.
function New-DesktopShortcut {
    $dir = Split-Path -Path $script:ScriptPath -Parent
    $ico = Join-Path $dir 'SELive-Scene-Tool.ico'
    Save-ToolIco $ico
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'SE.Live Scene Tool.lnk'
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
    $lnk.TargetPath       = Join-Path $env:WINDIR 'System32\conhost.exe'
    $lnk.Arguments        = "--headless powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File `"$($script:ScriptPath)`""
    $lnk.WorkingDirectory = $dir
    $lnk.IconLocation     = "$ico,0"
    $lnk.Description      = 'Duplicate, rename and manage SE.Live canvas scenes'
    $lnk.Save()
    return $lnkPath
}

# --- static texts ---
if (-not $seVersion) {
    $ui.verDot.Fill = New-Brush '#8F96AD'
    $ui.verText.Text = "SE.Live version not detected  $($script:Dot)  built for $($script:TestedSELive)"
} elseif ($seVersion -eq $script:TestedSELive) {
    $ui.verDot.Fill = New-Brush '#2FBF84'
    $ui.verText.Text = "SE.Live $seVersion  $($script:Dot)  tested version"
} else {
    $ui.verDot.Fill = New-Brush '#F2A93B'
    $ui.verText.Text = "SE.Live $seVersion  $($script:Dot)  not tested (built for $($script:TestedSELive))"
}
$ui.verText.ToolTip = "Tool v$($script:ToolVersion), built and tested for SE.Live $($script:TestedSELive) on OBS $($script:TestedObs)"
if ($script:ObsWasRunning) { $ui.chkReopen.Content = 'Reopen OBS when I close this window'; $ui.chkReopen.IsChecked = $true }
else                       { $ui.chkReopen.Content = 'Start OBS when I close this window';  $ui.chkReopen.IsChecked = $false }
foreach ($c in $canvasList) { [void]$ui.cmbCanvas.Items.Add($c.Name) }

# --- events ---
$ui.cmbCanvas.Add_SelectionChanged({ Update-List $null })
$ui.lstItems.Add_SelectionChanged({ if (-not $script:Refreshing) { Update-Context } })
$ui.tabDuplicate.Add_Checked({ Set-Mode 'duplicate' })
$ui.tabRename.Add_Checked({ Set-Mode 'rename' })
$ui.tabDelete.Add_Checked({ Set-Mode 'delete' })
$ui.tabBackups.Add_Checked({ Set-Mode 'backups' })
$ui.btnAction.Add_Click({ Invoke-Action })
$ui.txtName.Add_KeyDown({ if ($_.Key -eq 'Return' -and $script:Mode -eq 'rename') { Invoke-Action } })
$ui.btnShortcut.Add_Click({
    try {
        [void](New-DesktopShortcut)
        Set-Hint 'ok' "Shortcut 'SE.Live Scene Tool' created on your Desktop: it opens the tool with no console window at all."
    } catch { Set-Hint 'error' "Could not create the shortcut: $($_.Exception.Message)" }
})
$script:MainWindow.Add_ContentRendered({ $this.Activate() })
$script:MainWindow.Add_Closing({
    if ($ui.chkReopen.IsChecked -and -not (Start-Obs)) {
        [void](Show-Dialog 'Could not find the OBS executable: please start OBS yourself.' 'warn')
    }
})

$ui.cmbCanvas.SelectedIndex = 0
Set-Mode 'duplicate'
[void]$script:MainWindow.ShowDialog()
