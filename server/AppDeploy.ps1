#requires -Version 5.1
<#
  PC2Go App Installer - portable remote deployment tool
  Runs entirely from PowerShell 5.1 + WPF (both in-box on Win10/11).
  Delivered via:  powershell -NoP -EP Bypass -C "irm https://YOUR-SERVER/go | iex"
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://apps.example.com',
    [switch]$KeepCache,
    # set on the relaunched copy so a failed elevation cannot loop forever
    [switch]$NoSelfElevate
)

$ErrorActionPreference = 'Stop'
$AppTitle = 'PC2Go App Installer'
# bumped on every change, shown in the title bar - so "is the new code actually running?"
# is a question you can answer by looking at the window instead of guessing
$BuildTag = 'build 50'

# Always run under Windows PowerShell 5.1 (in-box on Win10/11) - the BITS cmdlets and WPF
# behave natively there. If launched from PowerShell 7 (pwsh), hand off transparently.
if ($PSVersionTable.PSEdition -eq 'Core') {
    if (-not $PSCommandPath) { throw 'Run this via the go bootstrap (or save to a file) when using PowerShell 7.' }
    $winPS = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $handoffArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -BaseUrl `"$BaseUrl`""
    if ($KeepCache) { $handoffArgs += ' -KeepCache' }
    Start-Process -FilePath $winPS -WindowStyle Hidden -ArgumentList $handoffArgs
    return
}

# TLS 1.2+ regardless of OS defaults (3072 = Tls12, 12288 = Tls13 where supported)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288 } catch {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 }

# ---------- one UAC prompt, at the start, and only when it is the SAME user ----------
# Elevating the whole GUI means one consent prompt when the tool opens, and nothing after it:
# every install, every file moved into place, every after-install run happens inside that one
# session.
#
# It is only safe when the elevated process is the same USER. If the person at the keyboard is
# a local administrator, UAC shows a consent prompt and the token changes but the account does
# not - %LocalAppData%, %AppData%, %UserProfile% and HKCU all stay theirs. If they are a
# standard user, UAC asks for somebody else's credentials, the process runs as THAT account,
# and every per-user thing this tool does - the installed-programs scan, the preference
# toggles, profile migration, the download cache - would silently read and write the wrong
# profile. That is why this is a decision made at runtime and not an assumption.
#
# Declining is not fatal: the tool carries on unelevated exactly as before, and the elevated
# worker asks for its own prompt when a batch actually starts.
function Test-IsAdminMember {
    # Ask the GROUP, not the token. The obvious implementation walks
    # WindowsIdentity.GetCurrent().Groups looking for S-1-5-32-544, and it is wrong: on a
    # filtered (unelevated) token that SID may be marked deny-only OR absent altogether -
    # measured absent on a machine whose user is definitely an administrator. The token
    # describes what this process may do right now, which is a different question from
    # whether the account is an administrator.
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($m in @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop)) {
            if ($m.SID.Value -eq $me) { return $true }
        }
        return $false
    } catch { }
    # Get-LocalGroupMember is Windows 10+ and can fail on odd group states; fall back to the
    # ADSI view, which is older than any machine this will run on
    try {
        $meName = [Security.Principal.WindowsIdentity]::GetCurrent().Name   # DOMAIN\user
        $short = $meName.Split('\')[-1]
        $grp = [ADSI]"WinNT://./Administrators,group"
        foreach ($m in @($grp.psbase.Invoke('Members'))) {
            $n = $m.GetType().InvokeMember('Name', 'GetProperty', $null, $m, $null)
            if ($n -eq $short) { return $true }
        }
    } catch { }
    return $false
}

$script:Elevated = $false
try {
    $script:Elevated = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

if (-not $script:Elevated -and -not $NoSelfElevate -and (Test-IsAdminMember)) {
    $relaunch = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
                "-BaseUrl `"$BaseUrl`" -NoSelfElevate"
    if ($KeepCache) { $relaunch += ' -KeepCache' }
    try {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                      -Verb RunAs -WindowStyle Hidden -ArgumentList $relaunch
        return    # the elevated copy takes over; this one has nothing left to do
    } catch {
        # declined, or elevation unavailable - carry on exactly as before
    }
}

# ---------- one instance at a time ----------
# Every instance shares ONE queue file in LOCALAPPDATA, and the elevated worker reads it as a
# stream. Two copies running at once means two workers consuming that queue: they take each
# other's items, collide on the same install - which fails it with "installer exit code 1" -
# and neither ever reaches the end marker, so the batch hangs and the technician is left with a
# window that never finishes. Measured, not imagined: it is what the GUI harness reproduced.
#
# Nothing on screen would warn them either. The tool is pasted in as a one-liner, the GUI
# launches detached, and the console it was typed into is usually closed straight away - so
# running it twice looks like the reasonable thing to do when the first window is behind others.
#
# Taken AFTER the self-elevation block on purpose: the unelevated launcher returns above this
# line, so it never holds the mutex the elevated copy is about to need.
$script:AppMutex = New-Object Threading.Mutex($false, 'Local\PC2GoAppInstaller')
$script:HaveMutex = $false
try { $script:HaveMutex = $script:AppMutex.WaitOne(0) }
catch [Threading.AbandonedMutexException] {
    # the previous instance died without releasing it - the queue is nobody's, so it is ours
    $script:HaveMutex = $true
}
if (-not $script:HaveMutex) {
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [void][Windows.MessageBox]::Show(
            "PC2Go App Installer is already running on this machine." + [Environment]::NewLine + [Environment]::NewLine +
            "Both copies would share one download queue, which corrupts installs and leaves the " +
            "batch unable to finish. Switch to the window that is already open.",
            'Already running')
    } catch {
        Write-Host 'PC2Go App Installer is already running on this machine.'
    }
    return
}

# Session cache lives in LOCALAPPDATA so partial downloads survive reboots; fully removed on clean exit
$script:CacheDir  = Join-Path $env:LOCALAPPDATA 'PC2GoDeploy'
New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
$script:QueuePath  = Join-Path $script:CacheDir 'queue.jsonl'
$script:StatusPath = Join-Path $script:CacheDir 'status.jsonl'
$script:WorkerPath = Join-Path $script:CacheDir 'worker.ps1'
$script:ManifestCache = Join-Path $script:CacheDir 'apps.json'

# Hide the console window so only the GUI is visible
Add-Type -Namespace Native -Name ConsoleUtil -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
[void][Native.ConsoleUtil]::ShowWindow([Native.ConsoleUtil]::GetConsoleWindow(), 0)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing

# cached app logos live beside the session data and are removed with it
$script:IconDir = Join-Path $script:CacheDir 'icons'
New-Item -ItemType Directory -Force -Path $script:IconDir | Out-Null

# Typed item with change notification so the list updates live.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Globalization;
public class AppItem : INotifyPropertyChanged {
    public string Id; public string Url; public string Sha256; public string SilentArgs;
    public string[] VerifyPaths; public long SizeBytes; public string FileName;
    // For a .zip package: the installer to run inside it, e.g. "Build\setup.exe". Empty for
    // a plain installer. Its presence is also what tells the disk check to budget for the
    // unpacked copy as well as the download.
    public string Entry;
    // Free text from the catalog shown to the technician once the app is installed:
    // the serial to type, the licence server to point at, the reboot that has to
    // happen before it will launch. Buried in a README nobody opens, it may as well
    // not exist - so it is put on screen at the end of the batch instead.
    public string Instructions;
    public string UnCommand; public string UnArgs; public string DetectPath;
    public string[] CleanPaths; public string[] CleanReg; public string[] CleanTokens;
    public string[] CleanHosts;   // domains to strip from the hosts file
    // Set when the elevated worker reports that an install failed with files already on
    // disk. It is what promotes a failed row into the leftover scan, so the same deep
    // clean that follows an uninstall also runs after a broken install.
    public bool Dirty;
    // Whether the product was already on disk BEFORE this batch ran. A failed UPGRADE
    // leaves the previous, working copy behind under the very paths the catalog lists as
    // cleanup targets, so nothing may be pre-ticked for deletion in that case.
    public bool PreExisting;
    // Folders that did not exist before this app's installer ran, observed by comparing the
    // machine with itself. On a failure these are the debris, known rather than guessed; on a
    // success they say where the product actually installed.
    public string[] CreatedPaths;
    public string RegKey; public bool IsSilent;
    public string Source { get; set; }   // "Catalog" (vendor tool) or "Installed"
    public string OrigState;             // preference toggles: the state read off the machine
    public object PostInstall;           // catalog "postInstall" steps, run after a verified install
    // Real logo (extracted from the exe, or downloaded from the catalog); when present the
    // vector category glyph is hidden and the coloured tile turns transparent.
    // This MUST raise PropertyChanged: the icon pump assigns it after the row is already
    // on screen, and a plain auto-property leaves WPF showing an empty image box until
    // something forces the item containers to regenerate.
    private object _iconImage;
    public object IconImage { get { return _iconImage; } set { _iconImage = value; Raise("IconImage"); } }
    private string _glyphVis = "Visible";
    public string GlyphVis { get { return _glyphVis; } set { _glyphVis = value; Raise("GlyphVis"); } }
    // brand letter mark drawn by the tool itself - no download, no reading the local PC
    private string _iconText = "";
    public string IconText { get { return _iconText; } set { _iconText = value; Raise("IconText"); } }
    private string _textVis = "Collapsed";
    public string TextVis { get { return _textVis; } set { _textVis = value; Raise("TextVis"); } }
    private string _imgVis = "Collapsed";
    public string ImgVis { get { return _imgVis; } set { _imgVis = value; Raise("ImgVis"); } }
    public string Name { get; set; }
    public string Version { get; set; }
    public string Size { get; set; }
    public string Publisher { get; set; }
    public string Category { get; set; }
    public string IconData { get; set; }
    // also set late by the icon pump (the tile turns transparent behind a real logo)
    private string _iconBg;
    public string IconBg { get { return _iconBg; } set { _iconBg = value; Raise("IconBg"); } }
    private bool _sel;
    public bool IsSelected { get { return _sel; } set { _sel = value; Raise("IsSelected"); } }
    private string _status = "";
    public string Status { get { return _status; } set { _status = value; Raise("Status"); } }
    private string _fg = "#FF8A8A94";
    public string StatusFg { get { return _fg; } set { _fg = value; Raise("StatusFg"); } }
    private double _prog;
    public double Progress { get { return _prog; } set { _prog = value; Raise("Progress"); RingData = ArcPath(value); } }
    private string _progVis = "Collapsed";
    public string ProgressVis { get { return _progVis; } set { _progVis = value; Raise("ProgressVis"); } }
    private string _spinVis = "Collapsed";
    public string SpinnerVis { get { return _spinVis; } set { _spinVis = value; Raise("SpinnerVis"); } }
    private string _ring = "M 13,3";
    public string RingData { get { return _ring; } set { _ring = value; Raise("RingData"); } }
    private string _ringTrack = "Collapsed";
    public string RingTrackVis { get { return _ringTrack; } set { _ringTrack = value; Raise("RingTrackVis"); } }
    private string _badgeVis = "Collapsed";
    public string BadgeVis { get { return _badgeVis; } set { _badgeVis = value; Raise("BadgeVis"); } }
    private string _badgeBg = "#FF22C55E";
    public string BadgeBg { get { return _badgeBg; } set { _badgeBg = value; Raise("BadgeBg"); } }
    private string _badgeData = "M 0,0";
    public string BadgeData { get { return _badgeData; } set { _badgeData = value; Raise("BadgeData"); } }
    // App Store-style ring: arc from 12 o'clock, sweeping clockwise with progress
    private static string ArcPath(double pct) {
        if (pct <= 0.5) return "M 13,3";
        if (pct > 99.5) pct = 99.5;
        double ang = pct / 100.0 * 360.0;
        double rad = (ang - 90.0) * Math.PI / 180.0;
        double x = 13 + 10 * Math.Cos(rad), y = 13 + 10 * Math.Sin(rad);
        int large = ang > 180 ? 1 : 0;
        return string.Format(CultureInfo.InvariantCulture, "M 13,3 A 10,10 0 {0} 1 {1:F2},{2:F2}", large, x, y);
    }
    public event PropertyChangedEventHandler PropertyChanged;
    private void Raise(string n) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
}
public class WipeItem {
    public string OwnerId { get; set; }   // which app this leftover belongs to
    public string OwnerName { get; set; } // grouping header in the preview
    public string Kind { get; set; }       // FOLDER|EMPTY|REG|SERVICE|TASK|HOSTS|SHORTCUT|TEMP|FOUND|AUTORUN
    public string Type { get; set; }       // file|reg|regvalue|service|task|hosts  (for the worker)
    public string Path { get; set; }
    // for a regvalue target, Path is the KEY and this is the value inside it. An autostart
    // entry is a value, so the key alone neither identifies nor removes it.
    public string Name { get; set; }
    public long SizeBytes { get; set; }
    public string SizeText { get; set; }
    public bool Del { get; set; }          // checked = will be deleted
    private bool _shared;
    // component shared with sibling products of the same suite - removing it breaks them
    public bool Shared { get { return _shared; } set { _shared = value; } }
    public string SharedVis { get { return _shared ? "Visible" : "Collapsed"; } }
}
'@

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC2Go App Installer" Height="680" Width="1040"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanMinimize" Opacity="0"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="#FFE9E9EE"
        TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True">
  <Window.Resources>

    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Width" Value="42"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#22FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CloseBtn" TargetType="Button" BasedOn="{StaticResource IconBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#FFE1344B"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TabActive" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,7"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="#FF3D7EF0" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TabIdle" TargetType="Button">
      <Setter Property="Foreground" Value="#FF9A9AA6"/>
      <Setter Property="Padding" Value="16,7"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#22FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#FFD6D6DE"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Margin" Value="10,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="#FF2C2C33" BorderBrush="#FF3C3C45" BorderThickness="1"
                    CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#FF35353E"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="B" Property="Background" Value="#FF26262C"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#FF6A6A74"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AccentBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="Margin" Value="10,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                  <GradientStop Color="#FF4C8DFF" Offset="0"/>
                  <GradientStop Color="#FF2F6BE4" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#FF5A97FF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="B" Property="Background" Value="#FF2A60CE"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="B" Property="Background" Value="#FF33333B"/>
                <Setter Property="Foreground" Value="#FF6A6A74"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SearchBox" TargetType="TextBox">
      <Setter Property="Foreground" Value="#FFE9E9EE"/>
      <Setter Property="CaretBrush" Value="#FFE9E9EE"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="#FF2C2C33" CornerRadius="9" BorderThickness="1" BorderBrush="#FF3C3C45">
              <ScrollViewer x:Name="PART_ContentHost" Margin="11,0,8,0" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border Background="#30FFFFFF" CornerRadius="3" Width="6" Margin="1,0"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ThinProgress" TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" Background="#2AFFFFFF" CornerRadius="3"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="3">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#FF4C8DFF" Offset="0"/>
                    <GradientStop Color="#FF7DB0FF" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- compact winutil-style row -->
    <Style x:Key="RowCheck" TargetType="CheckBox">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="R" CornerRadius="8" Padding="9,7" Background="Transparent" Margin="0,1">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <Border x:Name="Check" Grid.Column="0" Width="17" Height="17" CornerRadius="5"
                        BorderThickness="1.5" BorderBrush="#FF5A5A66" Background="Transparent"
                        VerticalAlignment="Center">
                  <Path x:Name="Tick" Data="M 3.5,8.5 L 6.5,11.5 L 12.5,4.5" Stroke="White" StrokeThickness="2"
                        StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                        Visibility="Collapsed" Stretch="None"/>
                </Border>

                <Border Grid.Column="1" Width="26" Height="26" CornerRadius="8" Margin="10,0,0,0"
                        Background="{Binding IconBg}" VerticalAlignment="Center">
                  <Grid>
                    <Path Data="{Binding IconData}" Stroke="White" StrokeThickness="1.5"
                          StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                          Width="14" Height="14" Stretch="Uniform" Opacity="0.95"
                          Visibility="{Binding GlyphVis}"/>
                    <TextBlock Text="{Binding IconText}" Visibility="{Binding TextVis}"
                               Foreground="White" FontSize="11.5" FontWeight="Bold"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Image Source="{Binding IconImage}" Width="24" Height="24" Stretch="Uniform"
                           Visibility="{Binding ImgVis}" RenderOptions.BitmapScalingMode="HighQuality"/>
                  </Grid>
                </Border>

                <TextBlock Grid.Column="2" Text="{Binding Name}" FontSize="12.5" Margin="10,0,8,0"
                           VerticalAlignment="Center" Foreground="#FFEDEDF2" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Column="3" Text="{Binding Size}" FontSize="11" Foreground="#FF74747E"
                           VerticalAlignment="Center"/>

                <!-- App Store-style per-app indicator: progress ring / spinner / result badge -->
                <Grid Grid.Column="4" Grid.RowSpan="2" Width="26" Height="26" Margin="10,0,0,0"
                      VerticalAlignment="Center">
                  <Ellipse Margin="3" Stroke="#2AFFFFFF" StrokeThickness="2.5" Visibility="{Binding RingTrackVis}"/>
                  <Path Data="{Binding RingData}" Stroke="#FF4C8DFF" StrokeThickness="2.5"
                        StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="None"
                        Visibility="{Binding RingTrackVis}"/>
                  <Path Data="M 13,3 A 10,10 0 0 1 23,13" Stroke="#FF8FB8FF" StrokeThickness="2.5"
                        StrokeStartLineCap="Round" Stretch="None" Visibility="{Binding SpinnerVis}"
                        RenderTransformOrigin="0.5,0.5">
                    <Path.RenderTransform><RotateTransform/></Path.RenderTransform>
                    <Path.Triggers>
                      <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                        <BeginStoryboard>
                          <Storyboard>
                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)"
                                             From="0" To="360" Duration="0:0:0.9" RepeatBehavior="Forever"/>
                          </Storyboard>
                        </BeginStoryboard>
                      </EventTrigger>
                    </Path.Triggers>
                  </Path>
                  <Border CornerRadius="13" Background="{Binding BadgeBg}" Visibility="{Binding BadgeVis}">
                    <Path Data="{Binding BadgeData}" Stroke="White" StrokeThickness="2.2"
                          StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Stretch="None"/>
                  </Border>
                </Grid>

                <DockPanel Grid.Row="1" Grid.Column="2" Grid.ColumnSpan="2" Margin="10,3,0,0">
                  <DockPanel.Style>
                    <Style TargetType="DockPanel">
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding Status}" Value="">
                          <Setter Property="Visibility" Value="Collapsed"/>
                        </DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </DockPanel.Style>
                  <TextBlock Text="{Binding Status}" FontSize="11" FontWeight="SemiBold"
                             Foreground="{Binding StatusFg}" TextWrapping="Wrap"
                             ToolTip="{Binding Status}"/>
                </DockPanel>

                <ProgressBar Grid.Row="2" Grid.ColumnSpan="4" Style="{StaticResource ThinProgress}"
                             Height="3" Margin="0,6,0,0" Minimum="0" Maximum="100"
                             Value="{Binding Progress, Mode=OneWay}" Visibility="{Binding ProgressVis}"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="R" Property="Background" Value="#1AFFFFFF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Check" Property="Background" Value="#FF3D7EF0"/>
                <Setter TargetName="Check" Property="BorderBrush" Value="#FF3D7EF0"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
                <Setter TargetName="R" Property="Background" Value="#153D7EF0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- uninstall row: name + publisher/version, silent-vs-UI badge, result indicator -->
    <Style x:Key="UnRow" TargetType="CheckBox">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="R" CornerRadius="8" Padding="9,7" Background="Transparent" Margin="2,1">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <Border x:Name="Check" Grid.Column="0" Width="17" Height="17" CornerRadius="5"
                        BorderThickness="1.5" BorderBrush="#FF5A5A66" Background="Transparent"
                        VerticalAlignment="Center">
                  <Path x:Name="Tick" Data="M 3.5,8.5 L 6.5,11.5 L 12.5,4.5" Stroke="White" StrokeThickness="2"
                        StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                        Visibility="Collapsed" Stretch="None"/>
                </Border>

                <Border Grid.Column="1" Width="26" Height="26" CornerRadius="8" Margin="10,0,0,0"
                        Background="{Binding IconBg}" VerticalAlignment="Center">
                  <Grid>
                    <Path Data="{Binding IconData}" Stroke="White" StrokeThickness="1.5"
                          StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                          Width="14" Height="14" Stretch="Uniform" Opacity="0.95"
                          Visibility="{Binding GlyphVis}"/>
                    <TextBlock Text="{Binding IconText}" Visibility="{Binding TextVis}"
                               Foreground="White" FontSize="11.5" FontWeight="Bold"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Image Source="{Binding IconImage}" Width="24" Height="24" Stretch="Uniform"
                           Visibility="{Binding ImgVis}" RenderOptions.BitmapScalingMode="HighQuality"/>
                  </Grid>
                </Border>

                <StackPanel Grid.Column="2" Margin="10,0,8,0" VerticalAlignment="Center">
                  <TextBlock Text="{Binding Name}" FontSize="12.5" Foreground="#FFEDEDF2"
                             TextTrimming="CharacterEllipsis" ToolTip="{Binding Name}"/>
                  <TextBlock FontSize="10.5" Foreground="#FF74747E" TextTrimming="CharacterEllipsis" Margin="0,2,0,0">
                    <Run Text="{Binding Publisher}"/><Run Text=" "/><Run Text="{Binding Version}"/><Run Text="  "/><Run Text="{Binding Size}"/>
                  </TextBlock>
                </StackPanel>

                <Grid Grid.Column="3" Width="22" Height="22" VerticalAlignment="Center">
                  <Path Data="M 11,2 A 9,9 0 0 1 20,11" Stroke="#FF8FB8FF" StrokeThickness="2.2"
                        StrokeStartLineCap="Round" Stretch="None" Visibility="{Binding SpinnerVis}"
                        RenderTransformOrigin="0.5,0.5">
                    <Path.RenderTransform><RotateTransform/></Path.RenderTransform>
                    <Path.Triggers>
                      <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                        <BeginStoryboard>
                          <Storyboard>
                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)"
                                             From="0" To="360" Duration="0:0:0.9" RepeatBehavior="Forever"/>
                          </Storyboard>
                        </BeginStoryboard>
                      </EventTrigger>
                    </Path.Triggers>
                  </Path>
                  <Border CornerRadius="11" Background="{Binding BadgeBg}" Visibility="{Binding BadgeVis}">
                    <Path Data="{Binding BadgeData}" Stroke="White" StrokeThickness="2"
                          StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                          Width="14" Height="14" Stretch="Uniform"/>
                  </Border>
                </Grid>

                <TextBlock Grid.Row="1" Grid.Column="2" Grid.ColumnSpan="2" Text="{Binding Status}"
                           FontSize="11" FontWeight="SemiBold" Foreground="{Binding StatusFg}"
                           TextWrapping="Wrap" Margin="10,3,0,0" ToolTip="{Binding Status}">
                  <TextBlock.Style>
                    <Style TargetType="TextBlock">
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding Status}" Value="">
                          <Setter Property="Visibility" Value="Collapsed"/>
                        </DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </TextBlock.Style>
                </TextBlock>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="R" Property="Background" Value="#1AFFFFFF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Check" Property="Background" Value="#FFE1344B"/>
                <Setter TargetName="Check" Property="BorderBrush" Value="#FFE1344B"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
                <Setter TargetName="R" Property="Background" Value="#15E1344B"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- firewall row: the state has to be readable at a glance, so it gets a badge rather
         than a coloured icon tile - once a real program icon loads, the tile is transparent
         and any colour on it is gone. -->
    <Style x:Key="FwRow" TargetType="CheckBox">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="R" CornerRadius="8" Padding="9,7" Background="Transparent" Margin="2,2">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <Border x:Name="Check" Grid.Column="0" Width="16" Height="16" CornerRadius="5"
                        BorderThickness="1.5" BorderBrush="#FF5A5A66" Background="Transparent"
                        VerticalAlignment="Center">
                  <Path x:Name="Tick" Data="M 3.5,8 L 6,10.5 L 12,4" Stroke="White" StrokeThickness="2"
                        StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                        Visibility="Collapsed" Stretch="None"/>
                </Border>

                <Grid Grid.Column="1" Width="24" Height="24" Margin="10,0,0,0" VerticalAlignment="Center">
                  <Border CornerRadius="6" Background="{Binding IconBg}"/>
                  <Path Data="{Binding IconData}" Stroke="White" StrokeThickness="1.4"
                        Width="13" Height="13" Stretch="Uniform" Opacity="0.9"
                        Visibility="{Binding GlyphVis}"/>
                  <Image Source="{Binding IconImage}" Width="22" Height="22" Stretch="Uniform"
                         Visibility="{Binding ImgVis}" RenderOptions.BitmapScalingMode="HighQuality"/>
                </Grid>

                <StackPanel Grid.Column="2" Margin="10,0,8,0" VerticalAlignment="Center">
                  <TextBlock Text="{Binding Name}" FontSize="12.5" Foreground="#FFEDEDF2"
                             TextTrimming="CharacterEllipsis" ToolTip="{Binding Name}"/>
                  <TextBlock Text="{Binding Publisher}" FontSize="10.5" Foreground="#FF74747E" Margin="0,2,0,0"
                             TextTrimming="CharacterEllipsis" ToolTip="{Binding Publisher}"/>
                </StackPanel>

                <!-- "what exactly is covered?" - a rule count you cannot inspect is a number
                     you have to take on faith. Click routes up to the list, which opens the
                     detail dialog; a Button inside the template handles its own click, so it
                     does not toggle the tick. -->
                <Button Grid.Column="3" Width="22" Height="22" Margin="0,0,8,0" VerticalAlignment="Center"
                        Style="{StaticResource IconBtn}" ToolTip="Show the executables this covers">
                  <TextBlock Text="&#x2026;" FontSize="14" FontWeight="Bold" Foreground="#FF9A9AA6"
                             VerticalAlignment="Center" HorizontalAlignment="Center" Margin="0,-6,0,0"/>
                </Button>

                <Border Grid.Column="4" CornerRadius="5" Padding="7,3" Background="{Binding BadgeBg}"
                        VerticalAlignment="Center">
                  <TextBlock Text="{Binding Size}" FontSize="10" Foreground="White" FontWeight="SemiBold"/>
                  <Border.Style>
                    <Style TargetType="Border">
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding Size}" Value="">
                          <Setter Property="Visibility" Value="Collapsed"/>
                        </DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </Border.Style>
                </Border>

                <TextBlock Grid.Row="1" Grid.Column="2" Grid.ColumnSpan="3" Text="{Binding Status}"
                           FontSize="10.5" FontWeight="SemiBold" Foreground="{Binding StatusFg}"
                           TextWrapping="Wrap" Margin="10,3,0,0">
                  <TextBlock.Style>
                    <Style TargetType="TextBlock">
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding Status}" Value="">
                          <Setter Property="Visibility" Value="Collapsed"/>
                        </DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </TextBlock.Style>
                </TextBlock>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="R" Property="Background" Value="#1AFFFFFF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Check" Property="Background" Value="#FF3D7EF0"/>
                <Setter TargetName="Check" Property="BorderBrush" Value="#FF3D7EF0"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
                <Setter TargetName="R" Property="Background" Value="#153D7EF0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Icon-only launcher tile. Fixed square so every one lands on the same grid, name on
         hover instead of under it - fourteen wrapped captions turned a launcher into a form. -->
    <Style x:Key="IconTile" TargetType="Button">
      <Setter Property="Width" Value="60"/>
      <Setter Property="Height" Value="60"/>
      <Setter Property="Margin" Value="5"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="10" Background="#FF2C2C33" BorderBrush="#FF3C3C45"
                    BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#FF35353E"/>
                <Setter TargetName="B" Property="BorderBrush" Value="#FF3D7EF0"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="B" Property="Background" Value="#FF23232A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- account row, Windows-settings style: a round avatar with the initial, the name, and
         a description line. Roomy and clickable rather than a dense checklist, because you
         act on ONE account at a time here. -->
    <Style x:Key="AcctRow" TargetType="CheckBox">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="R" CornerRadius="10" Padding="14,11" Background="#FF232329" Margin="2,3"
                    BorderThickness="1" BorderBrush="#FF2E2E36">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Width="40" Height="40" CornerRadius="20" Background="{Binding IconBg}"
                        VerticalAlignment="Center">
                  <TextBlock Text="{Binding IconText}" Foreground="White" FontSize="17" FontWeight="SemiBold"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>

                <StackPanel Grid.Column="1" Margin="14,0,10,0" VerticalAlignment="Center">
                  <TextBlock Text="{Binding Name}" FontSize="14" Foreground="#FFEDEDF2"
                             TextTrimming="CharacterEllipsis"/>
                  <TextBlock Text="{Binding Publisher}" FontSize="11.5" Foreground="#FF8A8A94" Margin="0,3,0,0"
                             TextTrimming="CharacterEllipsis" ToolTip="{Binding Publisher}"/>
                  <TextBlock Text="{Binding Status}" FontSize="11" FontWeight="SemiBold" Margin="0,3,0,0"
                             Foreground="{Binding StatusFg}" TextWrapping="Wrap">
                    <TextBlock.Style>
                      <Style TargetType="TextBlock">
                        <Style.Triggers>
                          <DataTrigger Binding="{Binding Status}" Value="">
                            <Setter Property="Visibility" Value="Collapsed"/>
                          </DataTrigger>
                        </Style.Triggers>
                      </Style>
                    </TextBlock.Style>
                  </TextBlock>
                </StackPanel>

                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                  <Border CornerRadius="5" Padding="7,3" Background="#FF33333B" Margin="0,0,10,0"
                          VerticalAlignment="Center">
                    <TextBlock Text="{Binding Size}" FontSize="10.5" Foreground="#FFB9CFF6" FontWeight="SemiBold"/>
                  </Border>
                  <Path Data="M 0,0 L 6,6 L 0,12" Stroke="#FF6E6E7A" StrokeThickness="1.8"
                        StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="None" VerticalAlignment="Center"/>
                </StackPanel>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="R" Property="Background" Value="#FF2C2C34"/>
                <Setter TargetName="R" Property="BorderBrush" Value="#FF3D7EF0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- tweak row: no icon tile and no size column, so twice as many fit on screen.
         A 3px accent bar (bound to IconBg) keeps the CAUTION group visually distinct
         for the cost of three pixels. -->
    <Style x:Key="TweakRow" TargetType="CheckBox">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="R" CornerRadius="7" Padding="8,5" Background="Transparent" Margin="2,1">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <Border x:Name="Check" Grid.Column="0" Width="16" Height="16" CornerRadius="5"
                        BorderThickness="1.5" BorderBrush="#FF5A5A66" Background="Transparent"
                        VerticalAlignment="Center">
                  <Path x:Name="Tick" Data="M 3.5,8 L 6,10.5 L 12,4" Stroke="White" StrokeThickness="2"
                        StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                        Visibility="Collapsed" Stretch="None"/>
                </Border>

                <Rectangle Grid.Column="1" Width="3" Height="15" RadiusX="1.5" RadiusY="1.5"
                           Fill="{Binding IconBg}" Margin="9,0,0,0" VerticalAlignment="Center"/>

                <TextBlock Grid.Column="2" Text="{Binding Name}" FontSize="12" Margin="9,0,8,0"
                           VerticalAlignment="Center" Foreground="#FFEDEDF2"
                           TextTrimming="CharacterEllipsis" ToolTip="{Binding Name}"/>

                <Grid Grid.Column="3" Width="20" Height="20" VerticalAlignment="Center">
                  <Path Data="M 10,2 A 8,8 0 0 1 18,10" Stroke="#FF8FB8FF" StrokeThickness="2"
                        StrokeStartLineCap="Round" Stretch="None" Visibility="{Binding SpinnerVis}"
                        RenderTransformOrigin="0.5,0.5">
                    <Path.RenderTransform><RotateTransform/></Path.RenderTransform>
                    <Path.Triggers>
                      <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                        <BeginStoryboard>
                          <Storyboard>
                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)"
                                             From="0" To="360" Duration="0:0:0.9" RepeatBehavior="Forever"/>
                          </Storyboard>
                        </BeginStoryboard>
                      </EventTrigger>
                    </Path.Triggers>
                  </Path>
                  <Border CornerRadius="10" Background="{Binding BadgeBg}" Visibility="{Binding BadgeVis}">
                    <Path Data="{Binding BadgeData}" Stroke="White" StrokeThickness="2"
                          StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                          Width="13" Height="13" Stretch="Uniform"/>
                  </Border>
                </Grid>

                <TextBlock Grid.Row="1" Grid.Column="2" Grid.ColumnSpan="2" Text="{Binding Status}"
                           FontSize="10.5" FontWeight="SemiBold" Foreground="{Binding StatusFg}"
                           TextWrapping="Wrap" Margin="9,2,0,0" ToolTip="{Binding Status}">
                  <TextBlock.Style>
                    <Style TargetType="TextBlock">
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding Status}" Value="">
                          <Setter Property="Visibility" Value="Collapsed"/>
                        </DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </TextBlock.Style>
                </TextBlock>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="R" Property="Background" Value="#1AFFFFFF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Check" Property="Background" Value="#FF3D7EF0"/>
                <Setter TargetName="Check" Property="BorderBrush" Value="#FF3D7EF0"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
                <Setter TargetName="R" Property="Background" Value="#153D7EF0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="RootB" CornerRadius="16" Background="#FF1E1E23" Margin="14" BorderThickness="1"
          BorderBrush="#FF34343C" RenderTransformOrigin="0.5,0.5">
    <Border.RenderTransform>
      <ScaleTransform x:Name="RootScale" ScaleX="0.97" ScaleY="0.97"/>
    </Border.RenderTransform>
    <Border.Effect>
      <DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.55" Color="Black"/>
    </Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- top bar: logo, tabs, search, window buttons -->
      <!-- DockPanel, not a Grid: with a Grid the left and right groups sit in the same cell
           and silently overlap once the tab row grows. Docked right wins its space first. -->
      <!-- Two rows: identity + search + window buttons on top, tabs on their own line
           underneath. With seven tabs they no longer fight the search box for space. -->
      <Grid Grid.Row="0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
      <DockPanel x:Name="TitleBar" Grid.Row="0" Height="54" Background="Transparent" LastChildFill="False">
        <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" Margin="22,0,0,0" VerticalAlignment="Center">
          <Border Width="32" Height="32" CornerRadius="10" VerticalAlignment="Center">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#FF4C8DFF" Offset="0"/>
                <GradientStop Color="#FF7A5CFF" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <Path Data="M 16,9 L 16,22 M 10,16 L 16,22 L 22,16 M 9,26 L 23,26" Stroke="White" StrokeThickness="2.4"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Stretch="None"/>
          </Border>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="PC2Go App Installer" FontSize="14.5" FontWeight="SemiBold"/>
              <TextBlock x:Name="TxtBuild" Text="" FontSize="10" Foreground="#FF5A5A66"
                         Margin="8,0,0,0" VerticalAlignment="Bottom"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
              <Ellipse x:Name="DotLive" Width="7" Height="7" Fill="#FF6A6A74" VerticalAlignment="Center"/>
              <TextBlock x:Name="TxtCatalogInfo" Text="Connecting..." FontSize="11" Foreground="#FF80808C"
                         Margin="6,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </StackPanel>
        </StackPanel>
        <Button x:Name="BtnWinClose" DockPanel.Dock="Right" Style="{StaticResource CloseBtn}"
                Margin="0,0,12,0" VerticalAlignment="Center">
          <Path Data="M 0,0 L 10,10 M 10,0 L 0,10" Stroke="#FFCFCFD8" StrokeThickness="1.4"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="None"/>
        </Button>
        <Button x:Name="BtnMin" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" VerticalAlignment="Center">
          <Rectangle Width="11" Height="1.4" Fill="#FFCFCFD8"/>
        </Button>
        <Grid DockPanel.Dock="Right" Width="240" Height="34" Margin="14,0,10,0" VerticalAlignment="Center">
          <TextBox x:Name="TxtSearch" Style="{StaticResource SearchBox}" VerticalContentAlignment="Center"/>
          <TextBlock x:Name="HintSearch" Text="Search..." Foreground="#FF6E6E7A" FontSize="12"
                     Margin="12,0,0,0" VerticalAlignment="Center" HorizontalAlignment="Left"
                     IsHitTestVisible="False"/>
          <Button x:Name="BtnSearchClear" Width="26" Height="26" HorizontalAlignment="Right"
                  Margin="0,0,4,0" Style="{StaticResource IconBtn}" Visibility="Collapsed">
            <Path Data="M 0,0 L 8,8 M 8,0 L 0,8" Stroke="#FF9A9AA6" StrokeThickness="1.4"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="None"/>
          </Button>
        </Grid>
      </DockPanel>

      <Border Grid.Row="1" BorderBrush="#FF2A2A31" BorderThickness="0,0,0,1" Padding="18,0,18,8">
        <StackPanel Orientation="Horizontal">
          <Button x:Name="BtnTabInstall" Content="Install" Style="{StaticResource TabActive}"/>
          <Button x:Name="BtnTabUn" Content="Uninstall" Style="{StaticResource TabIdle}"/>
          <Button x:Name="BtnTabTweak" Content="Tweaks" Style="{StaticResource TabIdle}"/>
          <Button x:Name="BtnTabUsers" Content="User Accounts" Style="{StaticResource TabIdle}"/>
          <Button x:Name="BtnTabMigrate" Content="Data Migration" Style="{StaticResource TabIdle}"/>
          <Button x:Name="BtnTabFw" Content="Firewall" Style="{StaticResource TabIdle}"/>
          <Button x:Name="BtnTabTools" Content="Toolbox" Style="{StaticResource TabIdle}"/>
          <Button x:Name="BtnTabLog" Content="Activity Log" Style="{StaticResource TabIdle}"/>
        </StackPanel>
      </Border>
      </Grid>

      <!-- install tab: 3-column grouped checklist -->
      <Grid x:Name="PanelInstall" Grid.Row="1" Margin="18,2,18,0">
        <TextBlock x:Name="EmptyInstall" Visibility="Collapsed" Foreground="#FF6E6E7A" FontSize="13"
                   HorizontalAlignment="Center" VerticalAlignment="Center" TextAlignment="Center"/>
        <ScrollViewer VerticalScrollBarVisibility="Auto">
        <ItemsControl x:Name="ListApps">
          <ItemsControl.ItemsPanel>
            <ItemsPanelTemplate>
              <UniformGrid Columns="3" VerticalAlignment="Top"/>
            </ItemsPanelTemplate>
          </ItemsControl.ItemsPanel>
          <ItemsControl.GroupStyle>
            <GroupStyle>
              <GroupStyle.HeaderTemplate>
                <DataTemplate>
                  <StackPanel Orientation="Horizontal" Margin="10,8,0,7">
                    <Rectangle Width="3" Height="14" Fill="#FF3D7EF0" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
                    <TextBlock Text="{Binding Name}" FontSize="12.5" FontWeight="Bold" Foreground="#FFB9CFF6"
                               Margin="8,0,6,0" VerticalAlignment="Center"/>
                    <TextBlock Text="{Binding ItemCount}" FontSize="11" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
                  </StackPanel>
                </DataTemplate>
              </GroupStyle.HeaderTemplate>
              <GroupStyle.ContainerStyle>
                <Style TargetType="GroupItem">
                  <Setter Property="Margin" Value="4,0,12,10"/>
                </Style>
              </GroupStyle.ContainerStyle>
            </GroupStyle>
          </ItemsControl.GroupStyle>
          <ItemsControl.ItemTemplate>
            <DataTemplate>
              <CheckBox Style="{StaticResource RowCheck}"
                        IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}"/>
            </DataTemplate>
          </ItemsControl.ItemTemplate>
        </ItemsControl>
        </ScrollViewer>
      </Grid>

      <!-- uninstall tab: two inventories behind sub-tabs, each scanned on first visit -->
      <Grid x:Name="PanelUn" Grid.Row="1" Visibility="Collapsed" Margin="18,2,18,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="4,4,0,8">
          <Button x:Name="BtnSubDesktop" Content="Desktop programs" Style="{StaticResource TabActive}"/>
          <Button x:Name="BtnSubStore" Content="Microsoft Store apps" Style="{StaticResource TabIdle}"/>
          <Button x:Name="BtnRescan" Content="Rescan" Style="{StaticResource TabIdle}"/>
        </StackPanel>

        <TextBlock x:Name="EmptyUn" Grid.Row="1" Visibility="Collapsed" Foreground="#FF6E6E7A" FontSize="13"
                   HorizontalAlignment="Center" VerticalAlignment="Center" TextAlignment="Center"/>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
        <StackPanel>

          <!-- scanning indicator: enumeration + icon extraction takes a few seconds -->
          <StackPanel x:Name="LoadUn" Visibility="Collapsed" HorizontalAlignment="Center" Margin="0,50,0,0">
            <Grid Width="34" Height="34" HorizontalAlignment="Center">
              <Ellipse Stroke="#22FFFFFF" StrokeThickness="3"/>
              <Path Data="M 17,1.5 A 15.5,15.5 0 0 1 32.5,17" Stroke="#FF4C8DFF" StrokeThickness="3"
                    StrokeStartLineCap="Round" Stretch="None" RenderTransformOrigin="0.5,0.5">
                <Path.RenderTransform><RotateTransform/></Path.RenderTransform>
                <Path.Triggers>
                  <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                    <BeginStoryboard>
                      <Storyboard>
                        <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)"
                                         From="0" To="360" Duration="0:0:0.85" RepeatBehavior="Forever"/>
                      </Storyboard>
                    </BeginStoryboard>
                  </EventTrigger>
                </Path.Triggers>
              </Path>
            </Grid>
            <TextBlock x:Name="TxtLoadUn" Text="Scanning installed programs..." FontSize="13"
                       Foreground="#FFD6D6DE" HorizontalAlignment="Center" Margin="0,14,0,0"/>
            <TextBlock x:Name="TxtLoadUn2" Text="" FontSize="11.5"
                       Foreground="#FF74747E" HorizontalAlignment="Center" Margin="0,5,0,0"/>
          </StackPanel>

          <ItemsControl x:Name="ListUn">
            <ItemsControl.GroupStyle>
              <GroupStyle>
                <GroupStyle.HeaderTemplate>
                  <DataTemplate>
                    <StackPanel Orientation="Horizontal" Margin="10,10,0,7">
                      <Rectangle Width="3" Height="14" Fill="#FF3D7EF0" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
                      <TextBlock Text="{Binding Name}" FontSize="12.5" FontWeight="Bold" Foreground="#FFB9CFF6"
                                 Margin="8,0,6,0" VerticalAlignment="Center"/>
                      <TextBlock Text="{Binding ItemCount}" FontSize="11" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
                    </StackPanel>
                  </DataTemplate>
                </GroupStyle.HeaderTemplate>
                <!-- the panel must sit on the GROUP: with grouping on, the ItemsControl's
                     own ItemsPanel would arrange the sections themselves, not the apps -->
                <GroupStyle.Panel>
                  <ItemsPanelTemplate>
                    <UniformGrid Columns="2" VerticalAlignment="Top"/>
                  </ItemsPanelTemplate>
                </GroupStyle.Panel>
              </GroupStyle>
            </ItemsControl.GroupStyle>
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <CheckBox Style="{StaticResource UnRow}"
                          IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}"/>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
        </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- tweaks tab: winutil-style system tweaks, applied by the elevated worker -->
      <Grid x:Name="PanelTweak" Grid.Row="1" Visibility="Collapsed" Margin="18,2,18,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- presets: one click to a sensible selection, so nobody hand-ticks 38 rows -->
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="4,4,0,8">
          <Button x:Name="BtnPreStandard" Content="Standard" Style="{StaticResource TabIdle}"/>
          <Button x:Name="BtnPreMinimal" Content="Minimal" Style="{StaticResource TabIdle}"/>
          <Button x:Name="BtnPreAdvanced" Content="Advanced" Style="{StaticResource TabIdle}"/>
          <Border Width="1" Height="18" Background="#FF3C3C45" Margin="10,0,4,0" VerticalAlignment="Center"/>
          <Button x:Name="BtnPreClear" Content="Clear" Style="{StaticResource TabIdle}"/>
          <Button x:Name="BtnDetect" Content="Detect Applied" Style="{StaticResource TabIdle}"/>
          <TextBlock x:Name="TxtTweakHint" Text="" FontSize="11" Foreground="#FF74747E"
                     VerticalAlignment="Center" Margin="14,0,0,0"/>
        </StackPanel>

        <!-- two columns: the tweak groups stack down the left, preferences fill the right -->
        <Grid Grid.Row="1">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <TextBlock x:Name="EmptyTweak" Grid.Column="0" Visibility="Collapsed" Foreground="#FF6E6E7A" FontSize="13"
                     HorizontalAlignment="Center" VerticalAlignment="Center" TextAlignment="Center"/>
          <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto" Margin="0,0,8,0">
            <ItemsControl x:Name="ListTweak">
              <ItemsControl.GroupStyle>
                <GroupStyle>
                  <GroupStyle.HeaderTemplate>
                    <DataTemplate>
                      <StackPanel Orientation="Horizontal" Margin="10,10,0,7">
                        <Rectangle Width="3" Height="14" Fill="#FF3D7EF0" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
                        <TextBlock Text="{Binding Name}" FontSize="12.5" FontWeight="Bold" Foreground="#FFB9CFF6"
                                   Margin="8,0,6,0" VerticalAlignment="Center"/>
                        <TextBlock Text="{Binding ItemCount}" FontSize="11" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
                      </StackPanel>
                    </DataTemplate>
                  </GroupStyle.HeaderTemplate>
                  <!-- one column: Essential and Advanced stack as a single list -->
                  <GroupStyle.Panel>
                    <ItemsPanelTemplate>
                      <UniformGrid Columns="1" VerticalAlignment="Top"/>
                    </ItemsPanelTemplate>
                  </GroupStyle.Panel>
                </GroupStyle>
              </ItemsControl.GroupStyle>
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <CheckBox Style="{StaticResource TweakRow}"
                            IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}"/>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </ScrollViewer>

          <!-- preferences are TOGGLES: the tick is the state you want the machine in,
               pre-set from what it actually is, so only what you change gets applied -->
          <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto" Margin="8,0,0,0">
            <ItemsControl x:Name="ListPref">
              <ItemsControl.GroupStyle>
                <GroupStyle>
                  <GroupStyle.HeaderTemplate>
                    <DataTemplate>
                      <StackPanel Orientation="Horizontal" Margin="10,10,0,7">
                        <Rectangle Width="3" Height="14" Fill="#FF34D399" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
                        <TextBlock Text="{Binding Name}" FontSize="12.5" FontWeight="Bold" Foreground="#FFB9CFF6"
                                   Margin="8,0,6,0" VerticalAlignment="Center"/>
                        <TextBlock Text="{Binding ItemCount}" FontSize="11" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
                      </StackPanel>
                    </DataTemplate>
                  </GroupStyle.HeaderTemplate>
                  <GroupStyle.Panel>
                    <ItemsPanelTemplate>
                      <UniformGrid Columns="1" VerticalAlignment="Top"/>
                    </ItemsPanelTemplate>
                  </GroupStyle.Panel>
                </GroupStyle>
              </ItemsControl.GroupStyle>
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <CheckBox Style="{StaticResource TweakRow}"
                            IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}"/>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </ScrollViewer>
        </Grid>
      </Grid>

      <!-- users tab: broken-profile repair - make a fresh local admin, then copy the
           user's data into it. Nothing here moves or deletes: the old profile survives
           untouched so a failed migration is never a data-loss event. -->
      <!-- USERS tab: account management and broken-profile repair.
           Two sub-tabs because they are two different jobs on two different objects -
           "manage an account" and "move data between profiles". Putting both on one
           screen made every visit three times more complex than the task in hand. -->
      <!-- USER ACCOUNTS: laid out like the Windows account settings page - one roomy row
           per account, click it to act on it. Account management and data migration are
           different jobs on different objects, so they are separate top-level tabs now. -->
      <Grid x:Name="PanelAccounts" Grid.Row="1" Visibility="Collapsed" Margin="18,8,18,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <DockPanel Grid.Row="0" Margin="4,0,4,10">
          <Button x:Name="BtnNewAccount" DockPanel.Dock="Right" Style="{StaticResource AccentBtn}">
            <StackPanel Orientation="Horizontal">
              <Path Data="M 12,5 L 12,19 M 5,12 L 19,12" Stroke="White" StrokeThickness="2"
                    StrokeStartLineCap="Round" Width="13" Height="13" Stretch="Uniform"/>
              <TextBlock Text="Add Account" Margin="8,0,0,0"/>
            </StackPanel>
          </Button>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Accounts on this PC" FontSize="15" FontWeight="SemiBold" Foreground="#FFEDEDF2"/>
            <TextBlock x:Name="TxtAcctHint" Text="" FontSize="11.5" Foreground="#FF80808C" Margin="0,3,0,0"
                       TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <ItemsControl x:Name="ListAccounts">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <CheckBox Style="{StaticResource AcctRow}"
                            IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}"/>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
            <TextBlock x:Name="EmptyAccounts" Visibility="Collapsed" Foreground="#FF6E6E7A" FontSize="12"
                       TextWrapping="Wrap" Margin="12,16,10,0"/>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- DATA MIGRATION: unchanged for now, just promoted to its own tab -->
      <Grid x:Name="PanelMigrate" Grid.Row="1" Visibility="Collapsed" Margin="18,8,18,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" x:Name="TxtUserHint" Text="" FontSize="11.5" Foreground="#FF80808C"
                   Margin="4,0,4,8" TextWrapping="Wrap"/>

        <Grid Grid.Row="1" Margin="0,0,0,8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <Border Grid.Column="0" CornerRadius="10" Background="#FF232329" BorderBrush="#FF34343C" BorderThickness="1" Padding="4,6">
            <StackPanel>
              <StackPanel Orientation="Horizontal" Margin="10,2,0,4">
                <Rectangle Width="3" Height="13" Fill="#FFF87171" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
                <TextBlock Text="Copy FROM" FontSize="12" FontWeight="Bold" Foreground="#FFB9CFF6" Margin="8,0,6,0"/>
                <TextBlock Text="the broken profile" FontSize="10.5" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
              </StackPanel>
              <ScrollViewer MaxHeight="150" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                  <ItemsControl x:Name="ListSrcUsers">
                    <ItemsControl.ItemTemplate>
                      <DataTemplate>
                        <CheckBox Style="{StaticResource UnRow}"
                                  IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}"/>
                      </DataTemplate>
                    </ItemsControl.ItemTemplate>
                  </ItemsControl>
                  <TextBlock x:Name="EmptySrc" Visibility="Collapsed" Foreground="#FF6E6E7A" FontSize="11.5"
                             TextWrapping="Wrap" Margin="12,8,10,6"/>
                </StackPanel>
              </ScrollViewer>
            </StackPanel>
          </Border>

          <TextBlock Grid.Column="1" Text="&#x2192;" FontSize="22" Foreground="#FF5A5A66"
                     VerticalAlignment="Center" Margin="12,0,12,0"/>

          <Border Grid.Column="2" CornerRadius="10" Background="#FF232329" BorderBrush="#FF34343C" BorderThickness="1" Padding="4,6">
            <StackPanel>
              <StackPanel Orientation="Horizontal" Margin="10,2,0,4">
                <Rectangle Width="3" Height="13" Fill="#FF34D399" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
                <TextBlock Text="Copy TO" FontSize="12" FontWeight="Bold" Foreground="#FFB9CFF6" Margin="8,0,6,0"/>
                <TextBlock Text="the new profile" FontSize="10.5" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
              </StackPanel>
              <ScrollViewer MaxHeight="150" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                  <ItemsControl x:Name="ListDstUsers">
                    <ItemsControl.ItemTemplate>
                      <DataTemplate>
                        <CheckBox Style="{StaticResource UnRow}"
                                  IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}"/>
                      </DataTemplate>
                    </ItemsControl.ItemTemplate>
                  </ItemsControl>
                  <TextBlock x:Name="EmptyDst" Visibility="Collapsed" Foreground="#FF6E6E7A" FontSize="11.5"
                             TextWrapping="Wrap" Margin="12,8,10,6"/>
                </StackPanel>
              </ScrollViewer>
            </StackPanel>
          </Border>
        </Grid>

        <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <ItemsControl x:Name="ListMigrate">
              <ItemsControl.GroupStyle>
                <GroupStyle>
                  <GroupStyle.HeaderTemplate>
                    <DataTemplate>
                      <StackPanel Orientation="Horizontal" Margin="10,6,0,6">
                        <Rectangle Width="3" Height="14" Fill="#FF3D7EF0" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
                        <TextBlock Text="{Binding Name}" FontSize="12" FontWeight="Bold" Foreground="#FFB9CFF6"
                                   Margin="8,0,6,0" VerticalAlignment="Center"/>
                        <TextBlock Text="{Binding ItemCount}" FontSize="11" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
                      </StackPanel>
                    </DataTemplate>
                  </GroupStyle.HeaderTemplate>
                  <GroupStyle.Panel>
                    <ItemsPanelTemplate><UniformGrid Columns="2" VerticalAlignment="Top"/></ItemsPanelTemplate>
                  </GroupStyle.Panel>
                </GroupStyle>
              </ItemsControl.GroupStyle>
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <CheckBox Style="{StaticResource TweakRow}"
                            IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}"/>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
            <TextBlock x:Name="EmptyMigrate" Visibility="Collapsed" Foreground="#FF6E6E7A" FontSize="12"
                       TextWrapping="Wrap" Margin="12,20,10,0" HorizontalAlignment="Center" TextAlignment="Center"/>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- FIREWALL: blocked on the left, everything else on the right. The split IS the
           organisation - a single list with filter pills meant the three programs you care
           about were buried among sixty you do not, and you had to click to see either.
           Stray rules that belong to no installed program sit at the END of the right
           column, because they are cleanup, not something you would choose to block. -->
      <Grid x:Name="PanelFw" Grid.Row="1" Visibility="Collapsed" Margin="18,2,18,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <DockPanel Grid.Row="0" Margin="4,4,0,8">
          <Button x:Name="BtnFwRescan" DockPanel.Dock="Right" Content="Rescan" Style="{StaticResource TabIdle}"/>
          <TextBlock x:Name="TxtFwHint" Text="" FontSize="11" Foreground="#FF74747E"
                     VerticalAlignment="Center" TextWrapping="Wrap"/>
        </DockPanel>

        <StackPanel x:Name="LoadFw" Grid.Row="1" Visibility="Collapsed" HorizontalAlignment="Center"
                    VerticalAlignment="Top" Margin="0,60,0,0">
          <Grid Width="34" Height="34" HorizontalAlignment="Center">
            <Ellipse Stroke="#22FFFFFF" StrokeThickness="3"/>
            <Path Data="M 17,1.5 A 15.5,15.5 0 0 1 32.5,17" Stroke="#FF4C8DFF" StrokeThickness="3"
                  StrokeStartLineCap="Round" Stretch="None" RenderTransformOrigin="0.5,0.5">
              <Path.RenderTransform><RotateTransform/></Path.RenderTransform>
              <Path.Triggers>
                <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                  <BeginStoryboard><Storyboard>
                    <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)"
                                     From="0" To="360" Duration="0:0:0.85" RepeatBehavior="Forever"/>
                  </Storyboard></BeginStoryboard>
                </EventTrigger>
              </Path.Triggers>
            </Path>
          </Grid>
          <TextBlock x:Name="TxtLoadFw" Text="Reading firewall rules..." FontSize="13"
                     Foreground="#FFD6D6DE" HorizontalAlignment="Center" Margin="0,14,0,0"/>
        </StackPanel>

        <Grid x:Name="FwSplit" Grid.Row="1">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <!-- left: blocked -->
          <Border Grid.Column="0" CornerRadius="10" Background="#FF232329" BorderBrush="#FF34343C"
                  BorderThickness="1" Margin="0,0,6,0" Padding="4,8">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="10,0,0,6">
                <Rectangle Width="3" Height="14" Fill="#FFF87171" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
                <TextBlock x:Name="TxtFwBlockedHdr" Text="Blocked" FontSize="12.5" FontWeight="Bold"
                           Foreground="#FFB9CFF6" Margin="8,0,6,0" VerticalAlignment="Center"/>
                <TextBlock Text="no internet access" FontSize="10.5" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
              </StackPanel>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                  <ItemsControl x:Name="ListFw">
                    <ItemsControl.GroupStyle>
                      <GroupStyle>
                        <GroupStyle.HeaderTemplate>
                          <DataTemplate>
                            <StackPanel Orientation="Horizontal" Margin="10,10,0,5">
                              <Rectangle Width="3" Height="12" Fill="#FFF59E0B" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
                              <TextBlock Text="{Binding Name}" FontSize="11.5" FontWeight="Bold" Foreground="#FFB9CFF6"
                                         Margin="8,0,6,0" VerticalAlignment="Center"/>
                              <TextBlock Text="{Binding ItemCount}" FontSize="10.5" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
                            </StackPanel>
                          </DataTemplate>
                        </GroupStyle.HeaderTemplate>
                      </GroupStyle>
                    </ItemsControl.GroupStyle>
                    <ItemsControl.ItemTemplate>
                      <DataTemplate>
                        <CheckBox Style="{StaticResource FwRow}"
                                  IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}"/>
                      </DataTemplate>
                    </ItemsControl.ItemTemplate>
                  </ItemsControl>
                  <TextBlock x:Name="EmptyFw" Visibility="Collapsed" Foreground="#FF6E6E7A" FontSize="11.5"
                             TextWrapping="Wrap" Margin="12,14,10,0"/>
                </StackPanel>
              </ScrollViewer>
            </Grid>
          </Border>

          <!-- right: everything else, with the stray rules grouped at the bottom -->
          <Border Grid.Column="1" CornerRadius="10" Background="#FF232329" BorderBrush="#FF34343C"
                  BorderThickness="1" Margin="6,0,0,0" Padding="4,8">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="10,0,0,6">
                <Rectangle Width="3" Height="14" Fill="#FF64748B" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
                <TextBlock x:Name="TxtFwOpenHdr" Text="Not blocked" FontSize="12.5" FontWeight="Bold"
                           Foreground="#FFB9CFF6" Margin="8,0,6,0" VerticalAlignment="Center"/>
                <TextBlock Text="tick to block" FontSize="10.5" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
              </StackPanel>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                  <ItemsControl x:Name="ListFwOpen">
                    <ItemsControl.ItemTemplate>
                      <DataTemplate>
                        <CheckBox Style="{StaticResource FwRow}"
                                  IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}"/>
                      </DataTemplate>
                    </ItemsControl.ItemTemplate>
                  </ItemsControl>
                  <TextBlock x:Name="EmptyFwOpen" Visibility="Collapsed" Foreground="#FF6E6E7A" FontSize="11.5"
                             TextWrapping="Wrap" Margin="12,14,10,0"/>
                </StackPanel>
              </ScrollViewer>
            </Grid>
          </Border>
        </Grid>
      </Grid>

      <!-- TOOLBOX: repair actions on the left, shortcuts to the legacy Windows panels on the
           right. Two different interaction models on purpose - a fix is queued and run
           elevated with the rest of a batch, whereas a panel just opens, so ticking one and
           pressing Apply would be nonsense. -->
      <Grid x:Name="PanelTools" Grid.Row="1" Visibility="Collapsed" Margin="18,8,18,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto" Margin="0,0,8,0">
          <StackPanel>
            <ItemsControl x:Name="ListFix">
              <ItemsControl.GroupStyle>
                <GroupStyle>
                  <GroupStyle.HeaderTemplate>
                    <DataTemplate>
                      <StackPanel Orientation="Horizontal" Margin="10,6,0,6">
                        <Rectangle Width="3" Height="14" Fill="#FF3D7EF0" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
                        <TextBlock Text="{Binding Name}" FontSize="12" FontWeight="Bold" Foreground="#FFB9CFF6"
                                   Margin="8,0,6,0" VerticalAlignment="Center"/>
                        <TextBlock Text="{Binding ItemCount}" FontSize="11" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
                      </StackPanel>
                    </DataTemplate>
                  </GroupStyle.HeaderTemplate>
                  <GroupStyle.Panel>
                    <ItemsPanelTemplate><UniformGrid Columns="1" VerticalAlignment="Top"/></ItemsPanelTemplate>
                  </GroupStyle.Panel>
                </GroupStyle>
              </ItemsControl.GroupStyle>
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <CheckBox Style="{StaticResource TweakRow}"
                            IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}"/>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </StackPanel>
        </ScrollViewer>

        <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto" Margin="8,0,0,0">
          <StackPanel>
            <StackPanel Orientation="Horizontal" Margin="10,6,0,6">
              <Rectangle Width="3" Height="14" Fill="#FF34D399" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
              <TextBlock Text="Legacy Windows Panels" FontSize="12" FontWeight="Bold" Foreground="#FFB9CFF6"
                         Margin="8,0,6,0" VerticalAlignment="Center"/>
              <TextBlock Text="hover for the name, click to open" FontSize="10.5" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
            </StackPanel>
            <WrapPanel x:Name="PanelGrid" Orientation="Horizontal" Margin="6,4,0,0"/>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- AutoLogon needs credentials, so it gets its own dialog rather than a checkbox -->
      <Border x:Name="AutoLogonOverlay" Grid.Row="0" Grid.RowSpan="3" CornerRadius="16" Background="#DD0E0E12"
              Visibility="Collapsed">
        <Border CornerRadius="14" Background="#FF2A2A31" BorderThickness="1" BorderBrush="#FF3C3C45"
                Width="470" Padding="28,24" VerticalAlignment="Center" HorizontalAlignment="Center">
          <StackPanel>
            <TextBlock Text="Set up automatic sign-in" FontSize="17" FontWeight="SemiBold"/>
            <TextBlock Text="This PC will sign in as the account below every time it starts, with no prompt."
                       FontSize="11.5" Foreground="#FF80808C" Margin="0,6,0,0" TextWrapping="Wrap"/>

            <TextBlock Text="Account name" FontSize="11.5" Foreground="#FFB6B6C0" Margin="0,18,0,5"/>
            <Grid Height="34">
              <TextBox x:Name="TxtAlUser" Style="{StaticResource SearchBox}" VerticalContentAlignment="Center"/>
              <TextBlock x:Name="HintAlUser" Text="an existing local account" Foreground="#FF6E6E7A"
                         FontSize="11.5" Margin="12,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>

            <TextBlock Text="Password" FontSize="11.5" Foreground="#FFB6B6C0" Margin="0,12,0,5"/>
            <Grid Height="34">
              <TextBox x:Name="TxtAlPw" Style="{StaticResource SearchBox}" VerticalContentAlignment="Center"/>
              <TextBlock x:Name="HintAlPw" Text="blank if the account has none" Foreground="#FF6E6E7A"
                         FontSize="11.5" Margin="12,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>

            <Border CornerRadius="8" Background="#33F59E0B" BorderBrush="#FFF59E0B" BorderThickness="1"
                    Padding="12,10" Margin="0,16,0,0">
              <TextBlock TextWrapping="Wrap" FontSize="11.5" Foreground="#FFFBBF24"
                         Text="Windows stores this password in the registry in CLEAR TEXT, readable by any administrator on the machine. Anyone who reaches the keyboard is signed in as this user. Only use it on a kiosk or a machine that is already physically secured."/>
            </Border>

            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
              <Button x:Name="BtnAlCancel" Content="Cancel" Style="{StaticResource GhostBtn}" Padding="22,8"/>
              <Button x:Name="BtnAlOk" Content="Enable" Style="{StaticResource AccentBtn}" Padding="26,8"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Border>

      <!-- log tab -->
      <Border x:Name="PanelLog" Grid.Row="1" Visibility="Collapsed" Margin="22,6,22,4"
              CornerRadius="10" Background="#FF17171B" BorderThickness="1" BorderBrush="#FF2A2A31">
        <!-- RichTextBox, not TextBox: each line is coloured by severity, and a TextBox has a
             single Foreground for the whole control. The window-level implicit ScrollBar
             style still applies inside it. -->
        <RichTextBox x:Name="TxtLog" IsReadOnly="True" IsDocumentEnabled="False" BorderThickness="0"
                     Background="Transparent" Foreground="#FF93C99B" FontFamily="Cascadia Mono, Consolas"
                     FontSize="12" Padding="14,10" VerticalScrollBarVisibility="Auto"
                     HorizontalScrollBarVisibility="Disabled"/>
      </Border>

      <!-- bottom bar -->
      <Grid Grid.Row="2" Margin="22,10,22,18">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel x:Name="RowNow" Grid.Row="0" Orientation="Horizontal" Margin="2,0,2,8" Visibility="Collapsed">
          <Ellipse x:Name="DotNow" Width="9" Height="9" Fill="#FF6A6A74" VerticalAlignment="Center"/>
          <TextBlock x:Name="TxtNow" Text="" FontSize="12.5" FontWeight="SemiBold" Foreground="#FFD6D6DE"
                     Margin="9,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <Grid x:Name="RowProgress" Grid.Row="1" Margin="2,0,2,10" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <ProgressBar x:Name="BarOverall" Style="{StaticResource ThinProgress}" Height="5" Minimum="0" Maximum="100"
                       VerticalAlignment="Center"/>
          <TextBlock x:Name="TxtOverall" Grid.Column="1" Text="" FontSize="11" Foreground="#FF80808C"
                     Margin="12,0,0,0" VerticalAlignment="Center"/>
        </Grid>
        <DockPanel Grid.Row="2">
          <TextBlock x:Name="TxtStatus" Text="Ready" Foreground="#FF80808C" VerticalAlignment="Center" FontSize="12"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnPause" Content="Pause" Style="{StaticResource GhostBtn}" Visibility="Collapsed"/>
            <Button x:Name="BtnCancel" Content="Cancel" Style="{StaticResource GhostBtn}" Visibility="Collapsed"/>
            <Button x:Name="BtnRefresh" Style="{StaticResource GhostBtn}">
              <StackPanel Orientation="Horizontal">
                <Path Data="M 4,10 A 8,8 0 0 1 18.5,7 M 18.5,2.5 L 18.5,7 L 14,7 M 20,14 A 8,8 0 0 1 5.5,17 M 5.5,21.5 L 5.5,17 L 10,17"
                      Stroke="#FFD6D6DE" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                      Width="15" Height="15" Stretch="Uniform"/>
                <TextBlock Text="Refresh" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnInstall" Style="{StaticResource AccentBtn}">
              <StackPanel Orientation="Horizontal">
                <Path Data="M 12,3 L 12,14 M 6.5,8.5 L 12,14 L 17.5,8.5 M 4,19 L 20,19" Stroke="White"
                      StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                      Width="15" Height="15" Stretch="Uniform"/>
                <TextBlock x:Name="TxtInstallBtn" Text="Install Selected" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnCopyLog" Content="Copy" Style="{StaticResource GhostBtn}"
                    Visibility="Collapsed"/>
            <Button x:Name="BtnSaveLog" Content="Save Log..." Style="{StaticResource GhostBtn}"
                    Visibility="Collapsed"/>
            <Button x:Name="BtnFwRemoveAll" Content="Remove ALL blocks" Style="{StaticResource GhostBtn}"
                    Foreground="#FFF87171" Visibility="Collapsed"
                    ToolTip="Deletes every outbound block rule this tool can account for, including ones left by other scripts."/>
            <Button x:Name="BtnRunFix" Content="Run Selected" Style="{StaticResource AccentBtn}"
                    Visibility="Collapsed"/>
            <Button x:Name="BtnFwUnblock" Content="Unblock Selected" Style="{StaticResource GhostBtn}"
                    Visibility="Collapsed"/>
            <Button x:Name="BtnFwBlock" Content="Block Internet Access" Style="{StaticResource AccentBtn}"
                    Visibility="Collapsed"/>
            <Button x:Name="BtnMigrate" Content="Copy Profile Data" Style="{StaticResource AccentBtn}"
                    Visibility="Collapsed"/>
            <Button x:Name="BtnTweakUndo" Content="Undo Selected" Style="{StaticResource GhostBtn}"
                    Visibility="Collapsed"/>
            <Button x:Name="BtnTweakApply" Style="{StaticResource AccentBtn}" Visibility="Collapsed">
              <StackPanel Orientation="Horizontal">
                <Path Data="M 5,13 L 10,18 L 19,6" Stroke="White" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                      Width="15" Height="15" Stretch="Uniform"/>
                <TextBlock Text="Apply Tweaks" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnForce" Content="Force Remove" Style="{StaticResource GhostBtn}"
                    Visibility="Collapsed"/>
            <Button x:Name="BtnUninstall" Content="Uninstall Selected" Style="{StaticResource AccentBtn}"
                    Visibility="Collapsed"/>
          </StackPanel>
        </DockPanel>
      </Grid>

      <!-- deep-clean preview overlay: the kill list, reviewed before anything is deleted -->
      <Border x:Name="WipeOverlay" Grid.Row="0" Grid.RowSpan="3" CornerRadius="16" Background="#DD0E0E12"
              Visibility="Collapsed">
        <Border CornerRadius="14" Background="#FF2A2A31" BorderThickness="1" BorderBrush="#FF3C3C45"
                Width="620" MaxHeight="520" Padding="26,22" VerticalAlignment="Center" HorizontalAlignment="Center">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Leftovers found" FontSize="16" FontWeight="SemiBold"/>
            <TextBlock x:Name="TxtWipeSub" Grid.Row="1" Text="" Foreground="#FFB6B6C0" TextWrapping="Wrap"
                       Margin="0,8,0,12" FontSize="12.5"/>
            <Border Grid.Row="2" CornerRadius="9" Background="#FF17171B" BorderThickness="1" BorderBrush="#FF33333B">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="4">
                <ItemsControl x:Name="ListWipe">
                  <ItemsControl.GroupStyle>
                    <GroupStyle>
                      <GroupStyle.HeaderTemplate>
                        <DataTemplate>
                          <StackPanel Orientation="Horizontal" Margin="8,10,0,4">
                            <Rectangle Width="3" Height="12" Fill="#FFF87171" RadiusX="1.5" RadiusY="1.5" VerticalAlignment="Center"/>
                            <TextBlock Text="{Binding Name}" FontSize="11.5" FontWeight="Bold" Foreground="#FFE9E9EE"
                                       Margin="7,0,6,0" VerticalAlignment="Center"/>
                            <TextBlock Text="{Binding ItemCount}" FontSize="10.5" Foreground="#FF6E6E7A" VerticalAlignment="Center"/>
                          </StackPanel>
                        </DataTemplate>
                      </GroupStyle.HeaderTemplate>
                    </GroupStyle>
                  </ItemsControl.GroupStyle>
                  <ItemsControl.ItemTemplate>
                    <DataTemplate>
                      <Grid Margin="8,4">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="Auto"/>
                          <ColumnDefinition Width="Auto"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <CheckBox Grid.Column="0" IsChecked="{Binding Del, Mode=TwoWay}" VerticalAlignment="Center"/>
                        <Border Grid.Column="1" CornerRadius="4" Padding="5,1" Margin="8,0,0,0" Background="#FF33333B"
                                VerticalAlignment="Center" Width="62">
                          <TextBlock Text="{Binding Kind}" FontSize="9.5" Foreground="#FFB9CFF6" FontWeight="SemiBold"
                                     HorizontalAlignment="Center"/>
                        </Border>
                        <StackPanel Grid.Column="2" Margin="8,0,8,0" VerticalAlignment="Center">
                          <TextBlock Text="{Binding Path}" FontSize="11.5" Foreground="#FFD6D6DE"
                                     TextTrimming="CharacterEllipsis" ToolTip="{Binding Path}"/>
                          <TextBlock Text="shared with other products of this suite - removing it can break them"
                                     FontSize="10" Foreground="#FFFBBF24" Visibility="{Binding SharedVis}"
                                     TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                        <TextBlock Grid.Column="3" Text="{Binding SizeText}" FontSize="11" Foreground="#FF80808C"
                                   VerticalAlignment="Center"/>
                      </Grid>
                    </DataTemplate>
                  </ItemsControl.ItemTemplate>
                </ItemsControl>
              </ScrollViewer>
            </Border>
            <DockPanel Grid.Row="3" Margin="0,16,0,0">
              <TextBlock Text="Checked = known app data, will be deleted. Unchecked = name match only, tick to include."
                         Foreground="#FF80808C" FontSize="11" VerticalAlignment="Center" TextWrapping="Wrap" MaxWidth="300"/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="BtnWipeSkip" Content="Skip cleanup" Style="{StaticResource GhostBtn}"/>
                <Button x:Name="BtnWipeGo" Content="Wipe checked" Style="{StaticResource AccentBtn}"/>
              </StackPanel>
            </DockPanel>
          </Grid>
        </Border>
      </Border>

      <!-- Add Account dialog: the fields belong in the popup, not permanently occupying the
           top of the tab where they are noise 99% of the time. -->
      <Border x:Name="NewUserOverlay" Grid.Row="0" Grid.RowSpan="3" CornerRadius="16" Background="#DD0E0E12"
              Visibility="Collapsed">
        <Border CornerRadius="14" Background="#FF2A2A31" BorderThickness="1" BorderBrush="#FF3C3C45"
                Width="460" Padding="28,24" VerticalAlignment="Center" HorizontalAlignment="Center">
          <StackPanel>
            <TextBlock Text="Add an account" FontSize="17" FontWeight="SemiBold"/>
            <TextBlock Text="Created as a local account on this PC." FontSize="11.5" Foreground="#FF80808C" Margin="0,6,0,0"/>

            <TextBlock Text="Sign-in name" FontSize="11.5" Foreground="#FFB6B6C0" Margin="0,18,0,5"/>
            <Grid Height="34">
              <TextBox x:Name="TxtNewUser" Style="{StaticResource SearchBox}" VerticalContentAlignment="Center"/>
              <TextBlock x:Name="HintNewUser" Text="also the C:\Users folder name" Foreground="#FF6E6E7A"
                         FontSize="11.5" Margin="12,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>

            <TextBlock Text="Display name" FontSize="11.5" Foreground="#FFB6B6C0" Margin="0,12,0,5"/>
            <Grid Height="34">
              <TextBox x:Name="TxtNewFull" Style="{StaticResource SearchBox}" VerticalContentAlignment="Center"/>
              <TextBlock x:Name="HintNewFull" Text="blank = same as sign-in name" Foreground="#FF6E6E7A"
                         FontSize="11.5" Margin="12,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>

            <TextBlock Text="Password" FontSize="11.5" Foreground="#FFB6B6C0" Margin="0,12,0,5"/>
            <Grid Height="34">
              <TextBox x:Name="TxtNewPw" Style="{StaticResource SearchBox}" VerticalContentAlignment="Center"/>
              <TextBlock x:Name="HintNewPw" Text="blank = no password" Foreground="#FF6E6E7A"
                         FontSize="11.5" Margin="12,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>
            <TextBlock Text="Shown as you type on purpose - you are setting this to hand to the client, not entering a secret."
                       FontSize="10.5" Foreground="#FF6E6E7A" TextWrapping="Wrap" Margin="0,5,0,0"/>

            <CheckBox x:Name="ChkNewAdmin" Content="Administrator (not a standard user)" IsChecked="True"
                      Foreground="#FFD6D6DE" FontSize="12" Margin="0,14,0,0"/>

            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
              <Button x:Name="BtnNewUserCancel" Content="Cancel" Style="{StaticResource GhostBtn}" Padding="22,8"/>
              <Button x:Name="BtnNewUserOk" Content="Create" Style="{StaticResource AccentBtn}" Padding="26,8"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Border>

      <!-- Per-account actions: opened by clicking a row, the way the Windows account page
           drills into one user rather than showing every verb against a list. -->
      <Border x:Name="AcctOverlay" Grid.Row="0" Grid.RowSpan="3" CornerRadius="16" Background="#DD0E0E12"
              Visibility="Collapsed">
        <Border CornerRadius="14" Background="#FF2A2A31" BorderThickness="1" BorderBrush="#FF3C3C45"
                Width="440" Padding="26,22" VerticalAlignment="Center" HorizontalAlignment="Center">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Border Width="46" Height="46" CornerRadius="23" Background="#FF3D7EF0" VerticalAlignment="Center">
                <TextBlock x:Name="TxtAcctInitial" Text="" Foreground="White" FontSize="19" FontWeight="SemiBold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="TxtAcctName" Text="" FontSize="16" FontWeight="SemiBold"/>
                <TextBlock x:Name="TxtAcctMeta" Text="" FontSize="11.5" Foreground="#FF8A8A94" Margin="0,3,0,0"
                           TextWrapping="Wrap" MaxWidth="330"/>
              </StackPanel>
            </StackPanel>

            <Border Height="1" Background="#FF3C3C45" Margin="0,18,0,14"/>

            <Button x:Name="BtnActAdmin" Content="Make Administrator" Style="{StaticResource GhostBtn}"
                    HorizontalContentAlignment="Left" Margin="0,0,0,7" Padding="14,10"/>
            <Button x:Name="BtnActStandard" Content="Make Standard user" Style="{StaticResource GhostBtn}"
                    HorizontalContentAlignment="Left" Margin="0,0,0,7" Padding="14,10"/>
            <Button x:Name="BtnActPw" Content="Reset password" Style="{StaticResource GhostBtn}"
                    HorizontalContentAlignment="Left" Margin="0,0,0,7" Padding="14,10"/>
            <Button x:Name="BtnActToggle" Content="Disable account" Style="{StaticResource GhostBtn}"
                    HorizontalContentAlignment="Left" Margin="0,0,0,7" Padding="14,10"/>
            <Button x:Name="BtnActLocal" Content="Replace with a local admin" Style="{StaticResource GhostBtn}"
                    HorizontalContentAlignment="Left" Margin="0,0,0,7" Padding="14,10"/>
            <Button x:Name="BtnActDelete" Content="Delete account" Style="{StaticResource GhostBtn}"
                    HorizontalContentAlignment="Left" Foreground="#FFF87171" Margin="0,0,0,7" Padding="14,10"/>

            <Button x:Name="BtnAcctClose" Content="Close" Style="{StaticResource AccentBtn}"
                    HorizontalAlignment="Right" Margin="0,12,0,0" Padding="26,8"/>
          </StackPanel>
        </Border>
      </Border>

      <!-- What a row actually covers. A rule count you cannot inspect is a number you have
           to take on faith - and for an unblocked app this doubles as a preview of exactly
           what pressing Block would create. -->
      <Border x:Name="FwDetailOverlay" Grid.Row="0" Grid.RowSpan="3" CornerRadius="16" Background="#DD0E0E12"
              Visibility="Collapsed">
        <Border CornerRadius="14" Background="#FF2A2A31" BorderThickness="1" BorderBrush="#FF3C3C45"
                Width="660" MaxHeight="540" Padding="26,22" VerticalAlignment="Center" HorizontalAlignment="Center">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock x:Name="TxtFwDetailTitle" Grid.Row="0" Text="" FontSize="16" FontWeight="SemiBold"/>
            <TextBlock x:Name="TxtFwDetailSub" Grid.Row="1" Text="" Foreground="#FF8A8A94" FontSize="11.5"
                       Margin="0,6,0,12" TextWrapping="Wrap"/>
            <Border Grid.Row="2" CornerRadius="9" Background="#FF17171B" BorderThickness="1" BorderBrush="#FF33333B">
              <TextBox x:Name="TxtFwDetail" IsReadOnly="True" BorderThickness="0" Background="Transparent"
                       Foreground="#FFD6D6DE" FontFamily="Cascadia Mono, Consolas" FontSize="11.5"
                       Padding="12,10" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                       TextWrapping="NoWrap"/>
            </Border>
            <DockPanel Grid.Row="3" Margin="0,14,0,0">
              <TextBlock Text="Select and copy any path you need." Foreground="#FF6E6E7A" FontSize="11"
                         VerticalAlignment="Center"/>
              <Button x:Name="BtnFwDetailClose" Content="Close" Style="{StaticResource AccentBtn}"
                      HorizontalAlignment="Right" Padding="26,8"/>
            </DockPanel>
          </Grid>
        </Border>
      </Border>

      <!-- modal overlay -->
      <Border x:Name="Overlay" Grid.Row="0" Grid.RowSpan="3" CornerRadius="16" Background="#CC121216"
              Visibility="Collapsed">
        <Border CornerRadius="14" Background="#FF2A2A31" BorderThickness="1" BorderBrush="#FF3C3C45"
                Width="400" Padding="28,24" VerticalAlignment="Center" HorizontalAlignment="Center">
          <StackPanel>
            <TextBlock x:Name="TxtOverlayTitle" Text="" FontSize="16" FontWeight="SemiBold"/>
            <TextBlock x:Name="TxtOverlayMsg" Text="" Foreground="#FFB6B6C0" TextWrapping="Wrap"
                       Margin="0,10,0,0" FontSize="12.5" LineHeight="19"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
              <Button x:Name="BtnOverlayCancel" Content="Cancel" Style="{StaticResource GhostBtn}"
                      Visibility="Collapsed" Padding="22,8"/>
              <Button x:Name="BtnOverlayOk" Content="OK" Style="{StaticResource AccentBtn}" Padding="26,8"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Border>
    </Grid>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$window.Title = "$AppTitle - $BuildTag"
$missing = @()
foreach ($n in 'ListApps','BarOverall','TxtOverall','TxtLog','TxtStatus','TxtCatalogInfo','BtnRefresh','BtnInstall',
               'TitleBar','BtnMin','BtnWinClose','Overlay','TxtOverlayTitle','TxtOverlayMsg','BtnOverlayOk',
               'DotLive','TxtSearch','HintSearch','BtnTabInstall','BtnTabLog','PanelInstall','PanelLog',
               'BtnTabUn','PanelUn','ListUn','BtnPause','BtnCancel','BtnUninstall','TxtNow','DotNow','TxtInstallBtn',
               'WipeOverlay','TxtWipeSub','ListWipe','BtnWipeSkip','BtnWipeGo',
               'LoadUn','TxtLoadUn','TxtLoadUn2','BtnSubDesktop','BtnSubStore','BtnRescan',
               'BtnSearchClear','EmptyInstall','EmptyUn','BtnForce','BtnOverlayCancel','RowNow','RowProgress',
               'BtnTabTweak','PanelTweak','ListTweak','BtnTweakApply','EmptyTweak','BtnTweakUndo',
               'BtnPreStandard','BtnPreMinimal','BtnPreAdvanced','BtnPreClear','BtnDetect','TxtTweakHint','ListPref',
               'BtnTabUsers','TxtNewUser','HintNewUser','TxtNewFull','HintNewFull',
               'TxtUserHint','ListSrcUsers','ListDstUsers','ListMigrate',
               'BtnCopyLog','BtnSaveLog',
               'BtnTabFw','PanelFw','ListFw','EmptyFw','LoadFw','TxtLoadFw','TxtFwHint',
               'BtnFwRescan','BtnFwRemoveAll','BtnFwBlock','BtnFwUnblock','ListFwOpen','EmptyFwOpen','TxtFwBlockedHdr','TxtFwOpenHdr','FwSplit',
               'FwDetailOverlay','TxtFwDetailTitle','TxtFwDetailSub','TxtFwDetail','BtnFwDetailClose',
               'EmptySrc','EmptyDst','ListAccounts','EmptyAccounts','EmptyMigrate','TxtNewPw','HintNewPw',
               'PanelAccounts','PanelMigrate','BtnTabMigrate','BtnNewAccount','TxtAcctHint','BtnMigrate',
               'BtnTabTools','PanelTools','ListFix','PanelGrid','BtnRunFix',
               'AutoLogonOverlay','TxtAlUser','HintAlUser','TxtAlPw','HintAlPw','BtnAlCancel','BtnAlOk',
               'NewUserOverlay','ChkNewAdmin','BtnNewUserCancel','BtnNewUserOk',
               'AcctOverlay','TxtAcctInitial','TxtAcctName','TxtAcctMeta','BtnAcctClose',
               'BtnActAdmin','BtnActStandard','BtnActPw','BtnActToggle','BtnActLocal','BtnActDelete',
               'TxtBuild') {
    $el = $window.FindName($n)
    if (-not $el) { $missing += $n }
    Set-Variable -Name $n -Value $el
}
# A name that fails to resolve surfaces later as a confusing "null-valued expression"
# somewhere unrelated, so fail loudly and immediately instead.
if ($missing.Count) {
    [void][Windows.MessageBox]::Show(
        "These UI elements were not found in the XAML:`n`n$($missing -join ', ')`n`nThe layout and the code are out of sync.",
        $AppTitle)
}

$TxtBuild.Text = $BuildTag

$script:Items = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
# two separate inventories, each scanned only when its sub-tab is first opened
$script:UnItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:UnStore = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:TweakItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:PrefItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:FixItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:FwItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:AccountItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:SrcUsers = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:DstUsers = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:MigrateItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:WipeFindings = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:ScanLabel = ''
$script:CancelPath = Join-Path $script:CacheDir 'cancel.flag'
$script:LastManifest = $null
$script:UnDirty = $true
$script:StoreDirty = $true
$script:UnSubTab = 'Desktop'
$script:SearchText = ''
$script:View = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
$script:View.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Category'))
$script:View.Filter = [Predicate[object]]{
    param($o)
    if ([string]::IsNullOrWhiteSpace($script:SearchText)) { return $true }
    $q = $script:SearchText
    $ci = [StringComparison]::OrdinalIgnoreCase
    return ((('' + $o.Name).IndexOf($q, $ci) -ge 0) -or
            (('' + $o.Publisher).IndexOf($q, $ci) -ge 0) -or
            (('' + $o.Category).IndexOf($q, $ci) -ge 0))
}
# the uninstall list can hold hundreds of programs, so it gets the same live search
$unFilter = [Predicate[object]]{
    param($o)
    if ([string]::IsNullOrWhiteSpace($script:SearchText)) { return $true }
    # plain substring, not -like: program names are full of [ ] * ? characters that
    # -like would treat as wildcards and silently match nothing
    $q = $script:SearchText
    $ci = [StringComparison]::OrdinalIgnoreCase
    return ((('' + $o.Name).IndexOf($q, $ci) -ge 0) -or
            (('' + $o.Publisher).IndexOf($q, $ci) -ge 0))
}
$script:UnView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:UnItems)
$script:UnView.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Category'))
$script:UnView.Filter = $unFilter
$script:StoreView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:UnStore)
$script:StoreView.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Category'))
$script:StoreView.Filter = $unFilter
$script:TweakView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:TweakItems)
$script:TweakView.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Category'))
$script:TweakView.Filter = $unFilter
$script:PrefView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:PrefItems)
$script:PrefView.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Category'))
$script:PrefView.Filter = $unFilter

# leftovers group under the app that owns them, so attribution is obvious in the preview
$script:WipeView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:WipeFindings)
$script:WipeView.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'OwnerName'))

# Bind the controls to the VIEWS, not the raw collections. Handing an ItemsControl a
# plain collection lets it build its own view, so the filter applied here would change
# the counts while the visible list kept showing everything.
$ListApps.ItemsSource = $script:View
$ListUn.ItemsSource = $script:UnView
$ListWipe.ItemsSource = $script:WipeView
$ListTweak.ItemsSource = $script:TweakView
$ListPref.ItemsSource = $script:PrefView
$script:MigrateView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:MigrateItems)
$script:MigrateView.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Category'))
# An account can never be both ends of a copy, so each list hides whatever the other one
# has selected. On a machine with a single account that means Copy TO is genuinely empty
# until a second account exists - which is the truth, and far clearer than listing the
# same name twice and rejecting it later.
$script:SrcPick = ''
$script:DstPick = ''
$script:SrcView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:SrcUsers)
$script:SrcView.Filter = [Predicate[object]]{
    param($o)
    return -not ($script:DstPick -and ('' + $o.Name) -eq $script:DstPick)
}
$script:DstView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:DstUsers)
$script:DstView.Filter = [Predicate[object]]{
    param($o)
    return -not ($script:SrcPick -and ('' + $o.Name) -eq $script:SrcPick)
}
$ListSrcUsers.ItemsSource = $script:SrcView
$ListDstUsers.ItemsSource = $script:DstView
$ListAccounts.ItemsSource = $script:AccountItems
# Two views over ONE collection: blocked on the left, everything else on the right. A single
# item is only ever in one of them, so the two lists cannot disagree about an app's state.
# $unFilter is a [Predicate[object]] DELEGATE - it must be .Invoke()d, never called with &.
# LEFT = everything with active block rules. Stray rules belong here, not on the right: they
# ARE blocks, and the only thing you ever do to them is unblock - the same action as the rest
# of this column. On the right their presence was a lie about the machine's state, and the
# column's own button (Block) had to refuse them, which is the tell that they were misplaced.
# Source sorts the stray group to the bottom: '1' programs, '2' strays.
$script:FwView = New-Object Windows.Data.CollectionViewSource
$script:FwView.Source = $script:FwItems
$script:FwView.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Category'))
$script:FwView.SortDescriptions.Add((New-Object ComponentModel.SortDescription 'Source', 'Ascending'))
$script:FwView.SortDescriptions.Add((New-Object ComponentModel.SortDescription 'Name', 'Ascending'))
$script:FwView.View.Filter = [Predicate[object]]{
    param($o)
    if (-not $o.IsSilent) { return $false }
    return $unFilter.Invoke($o)
}
# RIGHT = programs with no rules at all, the only things Block can act on
$script:FwOpenSrc = New-Object Windows.Data.CollectionViewSource
$script:FwOpenSrc.Source = $script:FwItems
$script:FwOpenSrc.SortDescriptions.Add((New-Object ComponentModel.SortDescription 'Name', 'Ascending'))
$script:FwOpenSrc.View.Filter = [Predicate[object]]{
    param($o)
    if ($o.IsSilent) { return $false }
    return $unFilter.Invoke($o)
}
$ListFw.ItemsSource = $script:FwView.View
$ListFwOpen.ItemsSource = $script:FwOpenSrc.View
$script:FixView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:FixItems)
$script:FixView.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Category'))
$script:FixView.Filter = $unFilter
$ListFix.ItemsSource = $script:FixView
$ListMigrate.ItemsSource = $script:MigrateView

# vector icon library: category -> glyph path data, tile color
$IconMap = @{
    cad     = @('M12,4 L20,20 L4,20 Z M12,12 L12,20', '#FFCE6A32')
    media   = @('M9,5.5 L19,12 L9,18.5 Z', '#FF8B5CF6')
    archive = @('M4,8 L12,4 L20,8 L20,16 L12,20 L4,16 Z M4,8 L12,12 L20,8 M12,12 L12,20', '#FF14B8A6')
    office  = @('M7,3 L14,3 L18,7 L18,21 L7,21 Z M14,3 L14,7 L18,7', '#FF3B82F6')
    dev     = @('M9,7 L4,12 L9,17 M15,7 L20,12 L15,17', '#FF22C55E')
    net     = @('M12,3 A9,9 0 1 1 11.99,3 M3.8,9 L20.2,9 M3.8,15 L20.2,15 M12,3 C8,8.5 8,15.5 12,21 M12,3 C16,8.5 16,15.5 12,21', '#FF0EA5E9')
    photo   = @('M4,8 L8,8 L10,5 L14,5 L16,8 L20,8 L20,19 L4,19 Z M12,10.5 A3,3 0 1 1 11.99,10.5', '#FF31A8FF')
    design  = @('M12,3 L15,10 L12,21 L9,10 Z M9,10 L15,10', '#FFFF9A00')
    video   = @('M4,5 L20,5 L20,19 L4,19 Z M8,5 L8,19 M16,5 L16,19 M4,9.5 L8,9.5 M4,14.5 L8,14.5 M16,9.5 L20,9.5 M16,14.5 L20,14.5', '#FF9999FF')
    tweak   = @('M4,7 L20,7 M4,12 L20,12 M4,17 L20,17 M9,7 A2,2 0 1 1 8.99,7 M15,12 A2,2 0 1 1 14.99,12 M8,17 A2,2 0 1 1 7.99,17', '#FF3D7EF0')
    default = @('M4,4 L10,4 L10,10 L4,10 Z M14,4 L20,4 L20,10 L14,10 Z M4,14 L10,14 L10,20 L4,20 Z M14,14 L20,14 L20,20 L14,20 Z', '#FF64748B')
}

# ---------- helpers ----------

# One FlowDocument with ONE paragraph: a paragraph per line would inject its default margin
# between every entry and double the log's height.
$script:LogPara = $null
$script:LogLines = 0
$script:LogMaxLines = 500

# Order matters. "Batch complete: 0 completed, 1 failed" contains both "complete" and "failed",
# and it is a failure - so failure is tested first and wins.
function Get-LogKind([string]$Message) {
    # "0 failed" is how a CLEAN batch reports itself. Matching the bare word would paint
    # every successful summary red, so zero-counts are neutralised before anything else.
    $m = $Message -replace '(?i)\b0 (failed|failures?|errors?|could not be removed)\b', ''
    if ($m -match '(?i)(\bfailed\b|\bfailure\b|\berror\b|\brefused\b|\bdenied\b|\bdeclined\b|could not|cannot|unable|not found|invalid|mismatch|aborted)') { return 'fail' }
    if ($m -match '(?i)(\bskipped\b|\bcancelled\b|\bwarning\b|\balready\b|nothing to do|\bkept\b|unavailable|unreachable|offline|not detectable|left untouched|\breboot\b|\brestart\b|no connection)') { return 'warn' }
    if ($m -match '(?i)\b(installed|applied|uninstalled|cleaned|reverted|created|removed|added|complete|completed|success|started|enabled|disabled)\b') { return 'ok' }
    return 'info'
}

$script:LogPalette = @{
    fail = '#FFF87171'   # red
    warn = '#FFFBBF24'   # amber
    ok   = '#FF6EE7A0'   # green
    info = '#FF93C99B'
    time = '#FF5A5A66'   # timestamp, deliberately dimmer than any message
}

function Add-Log([string]$Message) {
    if (-not $script:LogPara) {
        $script:LogPara = New-Object Windows.Documents.Paragraph
        $script:LogPara.Margin = New-Object Windows.Thickness 0
        $script:LogPara.LineHeight = 15
        $doc = New-Object Windows.Documents.FlowDocument $script:LogPara
        $doc.PagePadding = New-Object Windows.Thickness 0
        $doc.FontFamily = $TxtLog.FontFamily
        $doc.FontSize = $TxtLog.FontSize
        $TxtLog.Document = $doc
    }
    try {
        $kind = Get-LogKind $Message
        $ts = New-Object Windows.Documents.Run ("[{0}] " -f (Get-Date -Format 'HH:mm:ss'))
        $ts.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($script:LogPalette['time'])
        $msg = New-Object Windows.Documents.Run $Message
        $msg.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($script:LogPalette[$kind])
        if ($kind -eq 'fail') { $msg.FontWeight = 'SemiBold' }
        [void]$script:LogPara.Inlines.Add($ts)
        [void]$script:LogPara.Inlines.Add($msg)
        [void]$script:LogPara.Inlines.Add((New-Object Windows.Documents.LineBreak))
        $script:LogLines++
        # a long support session must not grow the document without bound: drop the oldest
        # entries (3 inlines each) once past the cap
        while ($script:LogLines -gt $script:LogMaxLines -and $script:LogPara.Inlines.Count -ge 3) {
            for ($i = 0; $i -lt 3; $i++) { $script:LogPara.Inlines.Remove($script:LogPara.Inlines.FirstInline) }
            $script:LogLines--
        }
        $TxtLog.ScrollToEnd()
    } catch {
        # the log must never be the thing that breaks a deployment
    }
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Update-UI {
    # Pump the dispatcher so the window stays responsive during synchronous work.
    # [void] matters: Dispatcher.Invoke returns a value, and without it every pump
    # emits $null into the caller's output stream - which silently poisons the return
    # value of any function that calls this while building a list.
    [void]$window.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::Background, [Action]{})
}

# status text palette (winutil-style flat colored text, no pills)
$StatusPalette = @{
    neutral = '#FFB8B8C2'
    active  = '#FF8FB8FF'
    ready   = '#FF5EEAD4'
    warn    = '#FFFBBF24'
    ok      = '#FF6EE7A0'
    fail    = '#FFF87171'
}
function Set-Status([object]$Item, [string]$Text, [string]$Kind = 'neutral') {
    $Item.StatusFg = $StatusPalette[$Kind]
    $Item.Status = $Text
}

# per-app indicator states (App Store style): empty ring -> filling ring -> spinner -> badge
function Set-Ring([object]$Item, [string]$State) {
    switch ($State) {
        'queued'   { $Item.Progress = 0; $Item.RingTrackVis = 'Visible'; $Item.SpinnerVis = 'Collapsed'; $Item.BadgeVis = 'Collapsed' }
        'download' { $Item.RingTrackVis = 'Visible'; $Item.SpinnerVis = 'Collapsed'; $Item.BadgeVis = 'Collapsed' }
        'busy'     { $Item.RingTrackVis = 'Collapsed'; $Item.SpinnerVis = 'Visible'; $Item.BadgeVis = 'Collapsed' }
        'ok'       { $Item.RingTrackVis = 'Collapsed'; $Item.SpinnerVis = 'Collapsed'
                     $Item.BadgeBg = '#FF22C55E'; $Item.BadgeData = 'M 8,13.5 L 11.5,17 L 18,9.5'; $Item.BadgeVis = 'Visible' }
        'fail'     { $Item.RingTrackVis = 'Collapsed'; $Item.SpinnerVis = 'Collapsed'
                     $Item.BadgeBg = '#FFEF4444'; $Item.BadgeData = 'M 9.5,9.5 L 16.5,16.5 M 16.5,9.5 L 9.5,16.5'; $Item.BadgeVis = 'Visible' }
        'warn'     { $Item.RingTrackVis = 'Collapsed'; $Item.SpinnerVis = 'Collapsed'
                     $Item.BadgeBg = '#FFF59E0B'; $Item.BadgeData = 'M 13,7.5 L 13,14 M 13,17 L 13,17.01'; $Item.BadgeVis = 'Visible' }
        default    { $Item.RingTrackVis = 'Collapsed'; $Item.SpinnerVis = 'Collapsed'; $Item.BadgeVis = 'Collapsed' }
    }
}

# The search is sticky across every tab on purpose: type a name once, then flip between
# Install / Desktop / Store to find where it lives. Each tab therefore has to report its
# own match count, and an empty list has to say WHY it is empty.
function Update-SearchCount {
    $q = $script:SearchText
    $searching = -not [string]::IsNullOrWhiteSpace($q)

    # counts are only knowable for lists that have actually been scanned
    $nInstall = @($script:View).Count
    $nDesk = $(if ($script:UnDirty) { $null } else { @($script:UnView).Count })
    $nStore = $(if ($script:StoreDirty) { $null } else { @($script:StoreView).Count })

    # counts ride on the tab itself - a separate count line was one more thing to read
    # for information the tab can carry silently
    $nTweak = @($script:TweakView).Count

    $lbl = { param($base, $n) if ($null -eq $n) { $base } else { "$base   $n" } }
    $BtnTabInstall.Content = $(if ($searching) { & $lbl 'Install' $nInstall } else { 'Install' })
    $unTotal = $null
    if ($searching -and ($null -ne $nDesk -or $null -ne $nStore)) { $unTotal = [int]$nDesk + [int]$nStore }
    $BtnTabUn.Content = & $lbl 'Uninstall' $unTotal
    $BtnTabTweak.Content = $(if ($searching) { & $lbl 'Tweaks' $nTweak } else { 'Tweaks' })
    $BtnSubDesktop.Content = & $lbl 'Desktop programs' $nDesk
    $BtnSubStore.Content = & $lbl 'Microsoft Store apps' $nStore

    # empty-state text, so "nothing here" never looks like a broken list
    $EmptyInstall.Visibility = 'Collapsed'
    $EmptyUn.Visibility = 'Collapsed'
    $EmptyTweak.Visibility = 'Collapsed'
    if ($searching -and $PanelTweak.Visibility -eq 'Visible' -and $nTweak -eq 0) {
        $EmptyTweak.Text = "No tweak matching `"$q`"."
        $EmptyTweak.Visibility = 'Visible'
    }
    if ($searching -and $PanelInstall.Visibility -eq 'Visible' -and $nInstall -eq 0) {
        $EmptyInstall.Text = "No app matching `"$q`" in the catalog.`n`nTry the Uninstall tab to see if it is already installed."
        $EmptyInstall.Visibility = 'Visible'
    }
    if ($PanelUn.Visibility -eq 'Visible') {
        $store = ($script:UnSubTab -eq 'Store')
        $n = $(if ($store) { $nStore } else { $nDesk })
        if ($searching -and $n -eq 0) {
            $other = $(if ($store) { 'Desktop programs' } else { 'Microsoft Store apps' })
            $EmptyUn.Text = "No program matching `"$q`" in this list.`n`nCheck the $other tab - the count is shown on each tab."
            $EmptyUn.Visibility = 'Visible'
        }
    }

    if ($script:Phase -notin 'Idle', 'Done') { return }
    if ($searching -and $PanelInstall.Visibility -eq 'Visible') {
        $TxtStatus.Text = "$nInstall of $($script:Items.Count) apps match `"$q`""
    } else {
        Update-Dash
    }
}

# The bottom bar carries three different things; each only earns its place sometimes.
# The live stage line and progress bar belong to a running batch, and the catalog
# summary belongs to the Install tab - showing it over the Uninstall list is just wrong.
function Update-Dash {
    # bulk selection changes (a preset, Clear, a sync) suppress this and refresh once at
    # the end - otherwise 38 checkbox events each rebuild the whole dashboard
    if ($script:SuspendDash) { return }
    $running = ($script:Phase -in 'Download', 'Install')
    # Progress belongs to the tab that started the work. A download bar sitting under the
    # Tweaks list is just noise, and worse, it reads as if the tweaks are downloading.
    $onOwner = ($script:BatchTab -eq 'Install' -and $PanelInstall.Visibility -eq 'Visible') -or
               ($script:BatchTab -eq 'Un' -and $PanelUn.Visibility -eq 'Visible') -or
               ($script:BatchTab -eq 'Tweak' -and $PanelTweak.Visibility -eq 'Visible') -or
               ($script:BatchTab -eq 'Users' -and $PanelAccounts.Visibility -eq 'Visible') -or
               ($script:BatchTab -eq 'Migrate' -and $PanelMigrate.Visibility -eq 'Visible') -or
               ($script:BatchTab -eq 'Fw' -and $PanelFw.Visibility -eq 'Visible') -or
               ($script:BatchTab -eq 'Tools' -and $PanelTools.Visibility -eq 'Visible')
    $RowNow.Visibility = $(if (($running -or $script:Phase -eq 'Done') -and $onOwner) { 'Visible' } else { 'Collapsed' })
    $RowProgress.Visibility = $(if ($running -and $onOwner) { 'Visible' } else { 'Collapsed' })
    if ($running) {
        # the batch owns the status line only on its own tab; elsewhere show that tab's own
        if (-not $onOwner) { $TxtStatus.Text = '' }
        return
    }

    if ($PanelInstall.Visibility -eq 'Visible') {
        $sel = @($script:Items | Where-Object { $_.IsSelected })
        $sum = 0; if ($sel.Count) { $sum = ($sel | Measure-Object -Property SizeBytes -Sum).Sum }
        $TxtStatus.Text = "$($script:Items.Count) apps available    |    $($sel.Count) selected  ($(Format-Size $sum))"
    } elseif ($PanelUn.Visibility -eq 'Visible') {
        $n = @(@($script:UnItems) + @($script:UnStore) | Where-Object { $_.IsSelected }).Count
        $TxtStatus.Text = $(if ($n) { "$n selected for removal" } else { '' })
    } elseif ($PanelTweak.Visibility -eq 'Visible') {
        $n = @($script:TweakItems | Where-Object { $_.IsSelected }).Count
        $p = 0
        # while a sync is running every toggle is being rewritten, so counting mid-flight
        # would report changes the technician never made
        if (-not $script:PrefSyncing) { $p = @(Get-PendingPrefs).Count }
        $bits = @()
        if ($n) { $bits += "$n tweak(s) selected" }
        if ($p) { $bits += "$p preference change(s) pending" }
        $TxtStatus.Text = $(if ($bits.Count) { $bits -join '    |    ' } else { "$($script:TweakItems.Count) tweaks, $($script:PrefItems.Count) preferences" })
    } elseif ($PanelTools.Visibility -eq 'Visible') {
        $n = @($script:FixItems | Where-Object { $_.IsSelected }).Count
        $TxtStatus.Text = $(if ($n) { "$n fix(es) selected" } else { "$($script:FixItems.Count) fixes, $($script:PanelDefs.Count) panels" })
    } elseif ($PanelFw.Visibility -eq 'Visible') {
        $sel = @($script:FwItems | Where-Object { $_.IsSelected })
        $blk = @($sel | Where-Object { $_.IsSilent }).Count
        $TxtStatus.Text = $(if ($sel.Count) { "$($sel.Count) selected  ($blk already blocked, $($sel.Count - $blk) not)" }
                            else { "$(@($script:FwItems | Where-Object { $_.IsSilent }).Count) of $($script:FwItems.Count) program(s) blocked" })
    } elseif ($PanelMigrate.Visibility -eq 'Visible') {
        $src = Get-SelectedUser $script:SrcUsers
        $dst = Get-SelectedUser $script:DstUsers
        $n = @($script:MigrateItems | Where-Object { $_.IsSelected }).Count
        if ($src -and $dst) { $TxtStatus.Text = "$($src.Name)  ->  $($dst.Name)    |    $n item(s) to copy" }
        elseif ($src) { $TxtStatus.Text = "From $($src.Name) - now pick a destination account" }
        else { $TxtStatus.Text = 'Pick the profile to copy FROM' }
    } else {
        $TxtStatus.Text = ''
    }
}

# Turn a System.Drawing.Bitmap / icon file / png stream into a frozen WPF ImageSource.
function ConvertTo-WpfImage([byte[]]$Bytes) {
    try {
        $ms = New-Object IO.MemoryStream(, $Bytes)
        $bi = New-Object Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.StreamSource = $ms
        $bi.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.EndInit()
        $bi.Freeze()      # frozen = safe to hand to the UI thread and cheap to render
        return $bi
    } catch { return $null }
}

# Catalog logo, from the on-disk cache ONLY - instant. A missing file is fetched by the
# background icon pump instead, so a cold cache never stalls the UI thread on the network
# (with no icons hosted yet, the old inline fetch cost one failed request per app per launch).
function Get-CachedCatalogIcon([string]$Url, [string]$Id) {
    if (-not $Url) { return $null }
    try {
        $ext = [IO.Path]::GetExtension(([Uri]$Url).LocalPath); if (-not $ext) { $ext = '.png' }
        $cache = Join-Path $script:IconDir "$Id$ext"
        if (Test-Path -LiteralPath $cache) {
            return ConvertTo-WpfImage ([IO.File]::ReadAllBytes($cache))
        }
    } catch {}
    return $null
}

function Set-AppIcon([object]$Item, [object]$Image) {
    if (-not $Image) { return }
    $Item.IconImage = $Image
    $Item.IconBg = '#00000000'    # let the real logo stand on its own
    $Item.GlyphVis = 'Collapsed'
    $Item.TextVis = 'Collapsed'   # a real logo replaces the letter-mark placeholder
    $Item.ImgVis = 'Visible'
}

# ---------- background icon pump ----------
# Icons used to be fetched and extracted inline while lists were being built, which put
# network latency and per-exe icon extraction on the UI thread - the bulk of both the
# catalog load and the "Scanning installed programs" wait. Rows now appear immediately;
# one background runspace resolves images and the dispatcher timer applies them as they
# arrive. Frozen bitmaps are the one WPF object that can safely cross threads.
$script:IconJobs    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:IconResults = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:IconState   = [hashtable]::Synchronized(@{ Stop = $false })

function Request-Icon([object]$Item, [string]$Kind, [hashtable]$Data) {
    $Data['Item'] = $Item
    $Data['Kind'] = $Kind
    $script:IconJobs.Enqueue($Data)
}

# Same pump, but the result lands on a bare Image control rather than an AppItem - used by
# the toolbox buttons, which are built in code and have no view model behind them.
function Request-IconTarget([object]$Image, [string]$Kind, [hashtable]$Data) {
    $Data['Target'] = $Image
    $Data['Kind'] = $Kind
    $script:IconJobs.Enqueue($Data)
}

# runs on the UI thread (called from the dispatcher timer), so Set-AppIcon's
# PropertyChanged events fire where WPF needs them
function Drain-IconResults {
    $r = $null
    while ($script:IconResults.TryDequeue([ref]$r)) {
        try {
            if ($r.Target) { $r.Target.Source = $r.Image } else { Set-AppIcon $r.Item $r.Image }
        } catch {}
        $r = $null
    }
}

$script:IconPS = [powershell]::Create()
[void]$script:IconPS.AddScript({
    param($Jobs, $Results, $State, $IconDir)
    Add-Type -AssemblyName PresentationCore, WindowsBase, System.Xaml, System.Drawing

    function ConvertTo-FrozenImage([byte[]]$Bytes) {
        try {
            $ms = New-Object IO.MemoryStream(, $Bytes)
            $bi = New-Object Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.StreamSource = $ms
            $bi.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi.EndInit()
            $bi.Freeze()      # frozen = detached from this thread, safe to hand to the UI
            return $bi
        } catch { return $null }
    }

    # ExtractAssociatedIcon only handles .exe. Control-panel applets are DLLs (.cpl) and
    # .msc files carry no icon at all, so those need ExtractIconEx against a specific
    # module and index - which is also how Explorer draws them.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class IconEx {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[] small, int count);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
}
'@ -ErrorAction SilentlyContinue

    function Get-ModuleIcon([string]$File, [int]$Index) {
        if (-not (Test-Path -LiteralPath $File)) { return $null }
        $lg = New-Object IntPtr[] 1
        $sm = New-Object IntPtr[] 1
        try {
            [void][IconEx]::ExtractIconEx($File, $Index, $lg, $sm, 1)
            $h = $lg[0]; if ($h -eq [IntPtr]::Zero) { $h = $sm[0] }
            if ($h -eq [IntPtr]::Zero) { return $null }
            $ico = [Drawing.Icon]::FromHandle($h)
            $bmp = $ico.ToBitmap()
            $ms = New-Object IO.MemoryStream
            $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
            $bytes = $ms.ToArray()
            $ms.Dispose(); $bmp.Dispose(); $ico.Dispose()
            return ConvertTo-FrozenImage $bytes
        } catch { return $null }
        finally {
            # these are real GDI handles - leaking one per row would exhaust the desktop heap
            foreach ($x in @($lg[0], $sm[0])) { if ($x -ne [IntPtr]::Zero) { [void][IconEx]::DestroyIcon($x) } }
        }
    }

    # same extraction Explorer uses; DisplayIcon values may carry a ",index" suffix
    function Get-ExeIcon([string]$Source) {
        if (-not $Source) { return $null }
        $path = $Source.Trim('"')
        if ($path -match '^(.*?),\s*-?\d+\s*$') { $path = $Matches[1] }
        $path = [Environment]::ExpandEnvironmentVariables($path.Trim('"'))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        try {
            if ([IO.Path]::GetExtension($path) -eq '.ico') {
                return ConvertTo-FrozenImage ([IO.File]::ReadAllBytes($path))
            }
            $ico = [Drawing.Icon]::ExtractAssociatedIcon($path)
            if (-not $ico) { return $null }
            $bmp = $ico.ToBitmap()
            $ms = New-Object IO.MemoryStream
            $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
            $bytes = $ms.ToArray()
            $ms.Dispose(); $bmp.Dispose(); $ico.Dispose()
            return ConvertTo-FrozenImage $bytes
        } catch { return $null }
    }

    while (-not $State.Stop) {
        $job = $null
        if (-not $Jobs.TryDequeue([ref]$job)) { Start-Sleep -Milliseconds 150; continue }
        $img = $null
        try {
            switch ($job.Kind) {
                # catalog logo: download once into the cache; a failure leaves a .miss
                # marker so a dead URL costs one attempt per session, not one per row
                'url' {
                    $ext = [IO.Path]::GetExtension(([Uri]$job.Url).LocalPath); if (-not $ext) { $ext = '.png' }
                    $cache = Join-Path $IconDir "$($job.Id)$ext"
                    $miss  = Join-Path $IconDir "$($job.Id).miss"
                    if (-not (Test-Path -LiteralPath $cache) -and -not (Test-Path -LiteralPath $miss)) {
                        try {
                            Invoke-WebRequest -Uri $job.Url -OutFile $cache -UseBasicParsing -TimeoutSec 10
                        } catch {
                            Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
                            Set-Content -LiteralPath $miss -Value '' -ErrorAction SilentlyContinue
                        }
                    }
                    if (Test-Path -LiteralPath $cache) { $img = ConvertTo-FrozenImage ([IO.File]::ReadAllBytes($cache)) }
                }
                # desktop program: try DisplayIcon first, then the uninstaller exe
                'exe' {
                    foreach ($src in @($job.Sources)) {
                        $img = Get-ExeIcon $src
                        if ($img) { break }
                    }
                }
                # control-panel applet or shell module, by explicit file + index
                'module' {
                    foreach ($src in @($job.Sources)) {
                        $f = [string]$src.file
                        if ($f -notmatch '[\\/]') { $f = Join-Path $env:SystemRoot "System32\$f" }
                        $img = Get-ModuleIcon ([Environment]::ExpandEnvironmentVariables($f)) ([int]$src.index)
                        if ($img) { break }
                    }
                }
                # Store package: logo asset from the package's own folder, exact name
                # first, then the scale-qualified variants (Logo.scale-200.png)
                'store' {
                    if ($job.Location -and (Test-Path -LiteralPath $job.Location)) {
                        $full = Join-Path $job.Location $job.Logo
                        if (Test-Path -LiteralPath $full) {
                            $img = ConvertTo-FrozenImage ([IO.File]::ReadAllBytes($full))
                        } else {
                            $dir = Split-Path $full -Parent
                            $base = [IO.Path]::GetFileNameWithoutExtension($full)
                            if (Test-Path -LiteralPath $dir) {
                                $cand = @(Get-ChildItem -LiteralPath $dir -Filter "$base*.png" -File -ErrorAction SilentlyContinue |
                                          Sort-Object Length -Descending | Select-Object -First 1)
                                if ($cand.Count) { $img = ConvertTo-FrozenImage ([IO.File]::ReadAllBytes($cand[0].FullName)) }
                            }
                        }
                    }
                }
            }
        } catch { $img = $null }
        if ($img) { $Results.Enqueue(@{ Item = $job.Item; Target = $job.Target; Image = $img }) }
    }
})
[void]$script:IconPS.AddArgument($script:IconJobs)
[void]$script:IconPS.AddArgument($script:IconResults)
[void]$script:IconPS.AddArgument($script:IconState)
[void]$script:IconPS.AddArgument($script:IconDir)
$script:IconHandle = $script:IconPS.BeginInvoke()

# Registry paths arrive in two shapes: short (HKLM\...) from the catalog and long
# (HKEY_LOCAL_MACHINE\...) from PSPath. Normalise both to PowerShell drive syntax.
function ConvertTo-PSRegPath([string]$Path) {
    return ($Path -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM:\' `
                  -replace '^HKEY_CURRENT_USER\\', 'HKCU:\' `
                  -replace '^HKEY_CLASSES_ROOT\\', 'HKCR:\' `
                  -replace '^HKLM\\', 'HKLM:\' `
                  -replace '^HKCU\\', 'HKCU:\' `
                  -replace '^HKCR\\', 'HKCR:\')
}

function Get-FolderSize([string]$Path) {
    # .NET enumeration, not a Get-ChildItem pipeline: an order of magnitude faster on
    # big trees, and reparse points are skipped so a junction can never loop the walk.
    $sum = [long]0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($dir)) {
                try { $sum += (New-Object IO.FileInfo $f).Length } catch {}
            }
            foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) {
                try {
                    $di = New-Object IO.DirectoryInfo $d
                    if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($d) }
                } catch {}
            }
        } catch {}
    }
    return $sum
}

# Never offer these for deletion, no matter what a token matches. These are OS or
# shared-vendor roots: wiping %ProgramFiles%\Adobe would take out every other Adobe
# app on the machine, which is exactly the mistake that turns a support call into an
# incident. Curated per-app paths from the catalog are the safe way to reach inside them.
$script:ProtectedPaths = @(
    $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
    $env:AppData, $env:LocalAppData, $env:Public, $env:UserProfile,
    (Join-Path $env:LocalAppData 'Temp'), (Join-Path $env:SystemRoot 'Temp'),
    (Split-Path $env:UserProfile),
    # shared VENDOR roots: these hold sibling products. Removing AutoCAD must never
    # offer up %ProgramFiles%\Autodesk, because Revit lives inside it.
    (Join-Path $env:ProgramFiles 'Adobe'), (Join-Path ${env:ProgramFiles(x86)} 'Adobe'),
    (Join-Path $env:ProgramFiles 'Autodesk'), (Join-Path ${env:ProgramFiles(x86)} 'Autodesk'),
    (Join-Path $env:ProgramFiles 'Common Files'), (Join-Path ${env:ProgramFiles(x86)} 'Common Files'),
    (Join-Path $env:ProgramData 'Adobe'), (Join-Path $env:ProgramData 'Autodesk'),
    (Join-Path $env:AppData 'Adobe'), (Join-Path $env:AppData 'Autodesk'),
    (Join-Path $env:LocalAppData 'Adobe'), (Join-Path $env:LocalAppData 'Autodesk'),
    (Join-Path $env:ProgramData 'Microsoft'), (Join-Path $env:AppData 'Microsoft'),
    (Join-Path $env:LocalAppData 'Microsoft')
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() }

# Components deliberately shared between products of the same suite. Autodesk leaves
# these behind on purpose because Revit/Inventor need them; Adobe the same for CC.
# A technician clicking "select all" would otherwise break the remaining products.
$script:SharedComponentHints = @(
    'AdskLicensing', 'Autodesk Licensing', 'Autodesk Desktop App', 'Autodesk Material',
    'Autodesk Shared', 'Autodesk Identity', 'Autodesk Access', 'Autodesk Genuine',
    'Adobe Creative Cloud', 'Adobe Genuine', 'AdobeGCClient', 'Adobe Common',
    'CCXProcess', 'Adobe Desktop Common', 'Adobe Notification'
)

# Wise-style leftover scan: explicit paths/keys from the catalog + token-matched
# top-level folders in the usual residue locations + empty leftover folders.
# Catalog-declared targets are pre-checked; fuzzy token matches are listed but
# UNchecked, so a heuristic guess never deletes anything without a deliberate click.
# $PreCheck controls only the CURATED targets - the paths and keys the catalog names
# outright. After an uninstall they are certain rubbish and arrive ticked. After a failed
# install they are not: if the app was already on the machine, the same folder holds the
# working copy's data. Token matches are never pre-ticked either way.
function Scan-Leftovers([object]$Item, [bool]$PreCheck = $true) {
    $found = @{}   # keyed by lowercased path to dedupe
    # this walk covers every user profile, the registry, services and tasks - easily
    # tens of seconds, so it narrates each stage instead of freezing silently
    $stage = {
        param($what)
        $TxtNow.Text = "$script:ScanLabel  -  $what"
        $DotNow.Fill = '#FF4C8DFF'
        Update-UI
    }
    $add = {
        param($kind, $type, $path, $preChecked, $name)
        # dedupe key: registry paths are normalised first, so the same key found as
        # HKCU\... (curated) and HKEY_CURRENT_USER\... (token scan) is listed only once.
        # A regvalue is keyed on key AND value, or two autostart entries in one key would
        # collapse into a single row.
        $k = $(if ($type -eq 'reg') { (ConvertTo-PSRegPath $path).ToLower() }
               elseif ($type -eq 'regvalue') { (ConvertTo-PSRegPath $path).ToLower() + '::' + ('' + $name).ToLower() }
               else { $path.ToLower() })
        if ($found.ContainsKey($k)) { return }
        $sz = 0
        if ($type -eq 'file') {
            $exp = [Environment]::ExpandEnvironmentVariables($path)
            if ($script:ProtectedPaths -contains $exp.TrimEnd('\').ToLower()) { return }
            if (-not (Test-Path -LiteralPath $exp)) { return }
            if (Test-Path -LiteralPath $exp -PathType Container) {
                $sz = Get-FolderSize $exp
                $empty = -not @(Get-ChildItem -LiteralPath $exp -Force -ErrorAction SilentlyContinue).Count
                if ($empty) { $kind = 'EMPTY' }
            } else { try { $sz = (Get-Item -LiteralPath $exp -Force).Length } catch {} }
        } elseif ($type -eq 'regvalue') {
            $rk = ConvertTo-PSRegPath $path
            if (-not (Test-Path -LiteralPath $rk)) { return }
            # the key surviving means nothing - the value is what starts the app
            if ($null -eq (Get-ItemProperty -LiteralPath $rk -Name $name -ErrorAction SilentlyContinue)) { return }
        } elseif ($type -eq 'reg') {
            $rk = ConvertTo-PSRegPath $path
            if (-not (Test-Path -LiteralPath $rk)) { return }
        } elseif ($type -eq 'service') {
            if (-not (Get-Service -Name $path -ErrorAction SilentlyContinue)) { return }
        } elseif ($type -eq 'task') {
            $leaf = Split-Path $path -Leaf
            $tp = Split-Path $path -Parent
            # Get-ScheduledTask wants the folder WITH its trailing separator - '\PC2GoTest'
            # finds nothing where '\PC2GoTest\' finds the task
            if (-not $tp.EndsWith('\')) { $tp += '\' }
            $ok = $false
            try { $ok = [bool](Get-ScheduledTask -TaskName $leaf -TaskPath $tp -ErrorAction Stop) } catch { $ok = $false }
            if (-not $ok) { return }
        } elseif ($type -eq 'hosts') {
            # the line was read straight out of the hosts file a moment ago, so it exists by
            # construction - re-reading the whole file once per line would be the only way to
            # check it again, for nothing
        } else {
            # an unknown type is not listed as though it were understood
            return
        }
        $w = New-Object WipeItem
        $w.OwnerId = $Item.Id; $w.OwnerName = $Item.Name
        $w.Kind = $kind; $w.Type = $type; $w.Path = $path; $w.Name = ('' + $name)
        $w.SizeBytes = $sz
        # a regvalue shows the entry's own name where a size would go - every autostart entry
        # shares one key path, so without it two rows read identically
        $w.SizeText = switch ($type) { 'reg' { 'key' } 'regvalue' { ('' + $name) } 'service' { 'service' } 'task' { 'task' } 'hosts' { 'line' } default { Format-Size $sz } }
        $w.Del = [bool]$preChecked
        # Suite-shared components stay behind on purpose - Revit and the rest of the CC
        # apps depend on them. Never pre-check, and say so loudly in the preview.
        foreach ($h in $script:SharedComponentHints) {
            if ($path -like "*$h*") { $w.Del = $false; $w.Shared = $true; break }
        }
        $found[$k] = $w
    }

    # 0. folders that did not exist before this install ran. Not a name match and not a
    #    catalog guess - the machine was compared with itself - so they are pre-checked
    #    whatever $PreCheck says: a folder that appeared during this batch cannot be the
    #    previous install's working copy.
    foreach ($p in @($Item.CreatedPaths)) { if ($p) { & $add 'CREATED' 'file' $p $true } }

    # 1. curated targets from the catalog - exact, so pre-checked unless the caller says
    #    the product may have been on this machine before the batch touched it
    foreach ($p in @($Item.CleanPaths)) { if ($p) { & $add 'FOLDER' 'file' $p $PreCheck } }
    foreach ($r in @($Item.CleanReg))   { if ($r) { & $add 'REG' 'reg' $r $PreCheck } }

    $tokens = @($Item.CleanTokens) | Where-Object { $_ -and $_.Length -ge 4 }
    if (-not $tokens.Count) { return @($found.Values) }

    # 2. app data under EVERY user profile, not just the technician's. A per-user
    #    folder left in another profile is the classic "it came back" leftover.
    & $stage 'user profiles and program folders'
    $userRoots = @()
    $usersDir = Split-Path $env:UserProfile
    foreach ($prof in @(Get-ChildItem -LiteralPath $usersDir -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($prof.Name -in 'Default', 'Default User', 'All Users', 'Public') { continue }
        $userRoots += @(
            (Join-Path $prof.FullName 'AppData\Roaming'),
            (Join-Path $prof.FullName 'AppData\Local'),
            (Join-Path $prof.FullName 'AppData\Local\Temp'),
            (Join-Path $prof.FullName 'AppData\LocalLow'),
            (Join-Path $prof.FullName 'Documents')
        )
    }
    $roots = @($env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)},
               (Join-Path $env:SystemRoot 'Temp'),
               (Join-Path $env:Public 'Documents'), (Join-Path $env:Public 'Desktop'),
               "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
               "$env:AppData\Microsoft\Windows\Start Menu\Programs",
               "$env:Public\Desktop") + $userRoots |
             Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    foreach ($root in $roots) {
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
            foreach ($t in $tokens) {
                if ($d.Name -notlike "*$t*") { continue }
                $kind = 'FOUND'
                if ($d.Extension -eq '.lnk') { $kind = 'SHORTCUT' }
                & $add $kind 'file' $d.FullName $false
                break
            }
        }
    }

    # 3. deep temp sweep: loose files an installer scattered into the temp dirs
    & $stage 'temp files'
    foreach ($tmp in @($env:TEMP, (Join-Path $env:SystemRoot 'Temp')) | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $tmp)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $tmp -File -Force -ErrorAction SilentlyContinue)) {
            foreach ($t in $tokens) {
                if ($f.Name -like "*$t*") { & $add 'TEMP' 'file' $f.FullName $false; break }
            }
        }
    }

    # 4. registry traces beyond the app's own key
    & $stage 'registry'
    $regRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node', 'HKCU:\SOFTWARE'
    )
    foreach ($rr in $regRoots) {
        if (-not (Test-Path -LiteralPath $rr)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $rr -ErrorAction SilentlyContinue)) {
            foreach ($t in $tokens) {
                if ($k.PSChildName -like "*$t*") {
                    & $add 'REG' 'reg' (($k.PSPath) -replace '^Microsoft\.PowerShell\.Core\\Registry::', '') $false
                    break
                }
            }
        }
    }

    # 4b. Autostart entries are registry VALUES, not sub-keys, so the sweep above walks
    #     straight past them: the product is removed and still launches itself at every login,
    #     pointing at an executable that is no longer there. Matched on the value's NAME or on
    #     its command line, because a Run entry is as often called "Updater" as it is called
    #     after the product it starts.
    & $stage 'autostart entries'
    $runRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($rr in $runRoots) {
        if (-not (Test-Path -LiteralPath $rr)) { continue }
        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $rr -ErrorAction Stop } catch { continue }
        foreach ($pv in @($props.PSObject.Properties)) {
            # PSPath, PSParentPath, PSChildName, PSDrive, PSProvider are the provider's own
            # bookkeeping, not entries anybody registered
            if ($pv.Name -like 'PS*') { continue }
            $data = '' + $pv.Value
            foreach ($t in $tokens) {
                if ($pv.Name -like "*$t*" -or $data -like "*$t*") {
                    & $add 'AUTORUN' 'regvalue' $rr $false $pv.Name
                    break
                }
            }
        }
    }

    # 5. services and scheduled tasks the app registered
    & $stage 'services and scheduled tasks'
    foreach ($svc in @(Get-Service -ErrorAction SilentlyContinue)) {
        foreach ($t in $tokens) {
            if ($svc.Name -like "*$t*" -or $svc.DisplayName -like "*$t*") {
                & $add 'SERVICE' 'service' $svc.Name $false
                break
            }
        }
    }
    try {
        foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            foreach ($t in $tokens) {
                if ($task.TaskName -like "*$t*" -or $task.TaskPath -like "*$t*") {
                    & $add 'TASK' 'task' ($task.TaskPath + $task.TaskName) $false
                    break
                }
            }
        }
    } catch {}

    # 6. hosts file lines - activation blocks left behind here break a later clean
    #    reinstall, and they are invisible in every normal uninstaller
    & $stage 'hosts file'
    $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $domains = @($Item.CleanHosts) | Where-Object { $_ }
    if ($domains.Count -and (Test-Path -LiteralPath $hostsFile)) {
        foreach ($line in @(Get-Content -LiteralPath $hostsFile -ErrorAction SilentlyContinue)) {
            $trimmed = $line.Trim()
            if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
            foreach ($dom in $domains) {
                if ($trimmed -like "*$dom*") { & $add 'HOSTS' 'hosts' $trimmed $PreCheck; break }
            }
        }
    }
    return @($found.Values)
}

function Show-Overlay([string]$Title, [string]$Message) {
    $script:ConfirmAction = $null
    $BtnOverlayCancel.Visibility = 'Collapsed'
    $BtnOverlayOk.Content = 'OK'
    $TxtOverlayTitle.Text = $Title
    $TxtOverlayMsg.Text = $Message
    $Overlay.Opacity = 0
    $Overlay.Visibility = 'Visible'
    $a = New-Object Windows.Media.Animation.DoubleAnimation 0, 1, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(220)))
    $Overlay.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
}

# Same overlay, but with a Cancel and a callback - used for genuinely destructive choices.
#
# CALLERS MUST PASS ({ ... }.GetNewClosure()), NOT a bare { ... }.
# PowerShell scriptblocks are not closures. This callback is stored and invoked later, from
# BtnOverlayOk, by which time the click handler's scope is gone - so every local it referenced
# ($a, $sel, $enable...) reads as $null. That shipped once: "Disable" reached the elevated
# worker with an empty user name and was refused. GetNewClosure has to be called at the
# DEFINITION site; calling it in here would capture this function's scope instead and change
# nothing. test-closures.ps1 fails the build if a call site forgets.
#
# One limit, measured rather than assumed: the closure binds to a new dynamic module, so a
# callback can still CALL the script-scope Start-* helpers - verified under -File, the way
# go.ps1 launches this - but $script: read INSIDE the block resolves to that module's own
# empty scope. So pass locals to a helper and never read $script: state from the callback.
# The test enforces that too.
function Show-Confirm([string]$Title, [string]$Message, [scriptblock]$OnConfirm) {
    Show-Overlay $Title $Message
    $script:ConfirmAction = $OnConfirm
    $BtnOverlayCancel.Visibility = 'Visible'
    $BtnOverlayOk.Content = 'Continue'
}

# One elevated worker and one queue file serve the whole tool, so a second batch genuinely
# cannot start until the current one finishes. That applies ONLY to buttons that queue
# work - selecting, searching, scanning and detecting stay live throughout, because a
# technician waiting on a 30 GB download should be able to line up the next job meanwhile.
# Returns $true (and explains) when the caller must not proceed; a button that just sits
# there doing nothing reads as broken.
function Test-BatchBusy {
    if ($script:Phase -notin 'Download', 'Install') { return $false }
    $what = switch ($script:BatchTab) {
        'Un'    { 'A removal batch is still running.' }
        'Tweak' { 'A tweak batch is still running.' }
        default { 'Apps are still downloading or installing.' }
    }
    Show-Overlay 'Still busy' ("$what`n`n" +
        "One elevated worker handles the whole queue, so a second batch cannot start until this one finishes - " +
        "that is also what keeps it to a single UAC prompt.`n`n" +
        'Your selection is kept, so you can carry on ticking and press this again when the batch ends.')
    return $true
}

# Narrower guard for the tweak list itself. Selecting and detecting are harmless while apps
# download, but during a TWEAK batch those same rows are carrying live status from the
# worker - rewriting their ticks and status text underneath it would erase the progress
# the technician is reading.
function Test-TweakListBusy {
    if ($script:Phase -in 'Download', 'Install' -and $script:BatchTab -eq 'Tweak') {
        Show-Overlay 'Tweaks are running' ("These rows are showing live progress from the elevated worker right now, " +
            "so the selection is held until the batch finishes.`n`nEverything else stays available in the meantime.")
        return $true
    }
    return $false
}

function Select-Tab([string]$Which) {
    $PanelInstall.Visibility = 'Collapsed'; $PanelUn.Visibility = 'Collapsed'; $PanelLog.Visibility = 'Collapsed'
    $PanelTweak.Visibility = 'Collapsed'
    $PanelAccounts.Visibility = 'Collapsed'
    $PanelMigrate.Visibility = 'Collapsed'
    $BtnTabMigrate.Style = $window.FindResource('TabIdle')
    $PanelFw.Visibility = 'Collapsed'
    $PanelTools.Visibility = 'Collapsed'
    $BtnTabTools.Style = $window.FindResource('TabIdle')
    $BtnRunFix.Visibility = 'Collapsed'
    $BtnTabFw.Style = $window.FindResource('TabIdle')
    $BtnFwBlock.Visibility = 'Collapsed'; $BtnFwUnblock.Visibility = 'Collapsed'; $BtnFwRemoveAll.Visibility = 'Collapsed'
    $BtnCopyLog.Visibility = 'Collapsed'; $BtnSaveLog.Visibility = 'Collapsed'
    $BtnTabInstall.Style = $window.FindResource('TabIdle')
    $BtnTabUn.Style = $window.FindResource('TabIdle')
    $BtnTabTweak.Style = $window.FindResource('TabIdle')
    $BtnTabUsers.Style = $window.FindResource('TabIdle')
    $BtnTabLog.Style = $window.FindResource('TabIdle')
    $BtnInstall.Visibility = 'Collapsed'; $BtnUninstall.Visibility = 'Collapsed'; $BtnForce.Visibility = 'Collapsed'
    $BtnRefresh.Visibility = 'Collapsed'
    $BtnTweakApply.Visibility = 'Collapsed'; $BtnTweakUndo.Visibility = 'Collapsed'
    $BtnMigrate.Visibility = 'Collapsed'
    switch ($Which) {
        'Install' {
            $PanelInstall.Visibility = 'Visible'
            $BtnTabInstall.Style = $window.FindResource('TabActive')
            $BtnInstall.Visibility = 'Visible'
            $BtnRefresh.Visibility = 'Visible'
        }
        'Un' {
            $PanelUn.Visibility = 'Visible'
            $BtnTabUn.Style = $window.FindResource('TabActive')
            $BtnUninstall.Visibility = 'Visible'
            $BtnForce.Visibility = 'Visible'
            Select-UnTab $script:UnSubTab
        }
        'Tweak' {
            $PanelTweak.Visibility = 'Visible'
            $BtnTabTweak.Style = $window.FindResource('TabActive')
            $BtnTweakApply.Visibility = 'Visible'
            $BtnTweakUndo.Visibility = 'Visible'
        }
        'Users' {
            $PanelAccounts.Visibility = 'Visible'
            $BtnTabUsers.Style = $window.FindResource('TabActive')
            # accounts change under us constantly (one was just created, someone signed in)
            # so the list is built on first visit rather than at startup
            if (-not $script:UsersLoaded) { $script:UsersLoaded = $true; Load-Users }
        }
        'Migrate' {
            $PanelMigrate.Visibility = 'Visible'
            $BtnTabMigrate.Style = $window.FindResource('TabActive')
            $BtnMigrate.Visibility = 'Visible'
            if (-not $script:UsersLoaded) { $script:UsersLoaded = $true; Load-Users }
        }
        'Tools' {
            $PanelTools.Visibility = 'Visible'
            $BtnTabTools.Style = $window.FindResource('TabActive')
            $BtnRunFix.Visibility = 'Visible'
            if (-not $script:ToolsLoaded) { $script:ToolsLoaded = $true; Load-Toolbox }
        }
        'Fw' {
            $PanelFw.Visibility = 'Visible'
            $BtnTabFw.Style = $window.FindResource('TabActive')
            $BtnFwBlock.Visibility = 'Visible'
            $BtnFwUnblock.Visibility = 'Visible'
            $BtnFwRemoveAll.Visibility = 'Visible'
            # rules change outside this tool, so the list is rebuilt whenever it is stale
            if ($script:FwDirty) { Load-Firewall }
        }
        default {
            $PanelLog.Visibility = 'Visible'
            $BtnTabLog.Style = $window.FindResource('TabActive')
            $BtnCopyLog.Visibility = 'Visible'
            $BtnSaveLog.Visibility = 'Visible'
        }
    }
    # explicit: during a running batch Update-SearchCount returns before reaching this,
    # and the progress rows have to be hidden or shown for the tab just switched to
    Update-Dash
    Update-SearchCount
}

# Split a registry UninstallString into an executable and its arguments.
# Handles quoted paths, bare paths with spaces, and MSI product codes.
function Parse-UninstallString([string]$Raw) {
    $Raw = ('' + $Raw).Trim()
    if (-not $Raw) { return $null }
    # MSI: "MsiExec.exe /I{GUID}" or "/X{GUID}" -> force a silent removal
    if ($Raw -match '(?i)msiexec(\.exe)?["\s]*.*?[/-]\s*[IX]\s*(\{[0-9A-F\-]{36}\})') {
        return @{ exe = 'msiexec.exe'; args = "/x $($Matches[2]) /qn /norestart"; silent = $true }
    }
    if ($Raw.StartsWith('"')) {
        $end = $Raw.IndexOf('"', 1)
        if ($end -gt 0) {
            return @{ exe = $Raw.Substring(1, $end - 1); args = $Raw.Substring($end + 1).Trim(); silent = $false }
        }
    }
    # unquoted: split at the first .exe boundary so paths with spaces survive
    if ($Raw -match '(?i)^(.*?\.exe)(\s+(.*))?$') {
        return @{ exe = $Matches[1].Trim(); args = ('' + $Matches[3]).Trim(); silent = $false }
    }
    return @{ exe = $Raw; args = ''; silent = $false }
}

# Wise-style discovery: read the same registry uninstall keys Control Panel uses,
# across 64-bit, 32-bit (WOW6432Node) and per-user hives.
function Get-InstalledPrograms {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $seen = @{}
    $n = 0
    $out = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($k in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            # keep the spinner turning: icon extraction makes this loop genuinely slow
            if ((++$n % 12) -eq 0) { Update-UI }
            $p = $null
            try { $p = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop } catch { continue }
            $name = Clean-DisplayName $p.DisplayName
            if (-not $name) { continue }
            if ([int]('0' + $p.SystemComponent) -eq 1) { continue }       # hidden system entries
            if ($p.ParentKeyName -or $p.ParentDisplayName) { continue }   # patches/child entries
            if ($p.ReleaseType -match '(?i)update|hotfix|security') { continue }
            $icon = ('' + $p.DisplayIcon).Trim()
            $raw = $p.QuietUninstallString; $quiet = $true
            if (-not $raw) { $raw = $p.UninstallString; $quiet = $false }
            if (-not $raw) { continue }                                    # nothing to run
            $key = ($name + '|' + $p.DisplayVersion).ToLower()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $parsed = Parse-UninstallString $raw
            if (-not $parsed) { continue }
            [void]$out.Add([pscustomobject]@{
                Name        = $name
                Version     = ('' + $p.DisplayVersion).Trim()
                Publisher   = ('' + $p.Publisher).Trim()
                Location    = ('' + $p.InstallLocation).Trim()
                Exe         = $parsed.exe
                Args        = $parsed.args
                Silent      = ($quiet -or $parsed.silent)
                SizeKB      = [int]('0' + $p.EstimatedSize)
                Icon        = $icon
                RegKey      = (('' + $k.PSPath) -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')
            })
        }
    }
    return @($out | Sort-Object Name)
}

# Store display names are usually an "ms-resource:" pointer into the package's compiled
# resource file, not literal text. SHLoadIndirectString is what Explorer and Settings use
# to turn that pointer into the name a human recognises.
Add-Type -MemberDefinition @'
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern int SHLoadIndirectString(string pszSource, System.Text.StringBuilder pszOutBuf,
                                              int cchOutBuf, System.IntPtr ppvReserved);
'@ -Namespace Native -Name ResourceString -ErrorAction SilentlyContinue

# Anything from XML or a native buffer can come back as an array rather than a string -
# a package with several <Application> entries yields an array of names, and a char
# buffer yields an array of characters. PowerShell stringifies arrays by joining with
# spaces, which is what turned XboxIdentityProvider into "X b o x I d e n t i t y ...".
# Never interpolate those values directly; funnel them through here.
function AsText($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [char[]]) { return (-join $Value) }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($v in $Value) { $t = AsText $v; if ($t) { return $t } }
        return ''
    }
    return [string]$Value
}

# Names arrive from several places, and some come back mangled: NUL bytes between the
# letters when a UTF-16 buffer is read a byte at a time, which renders as "X b o x".
# Anything shown to the technician goes through here first.
function Clean-DisplayName($Value) {
    $s = AsText $Value
    # strip NUL, control and zero-width characters - a UTF-16 buffer read a byte at a
    # time leaves a NUL between every letter, which renders as wide letter-spacing
    $s = $s -replace '[\x00-\x1F\x7F-\x9F]', ''
    # zero-width and bidi marks are removed by code point, not by a literal pattern:
    # typing them into the source puts invisible bytes in the file itself
    foreach ($code in 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0xFEFF) {
        $s = $s.Replace([string][char]$code, '')
    }
    # Fullwidth Latin (U+FF21 etc) renders as wide, airy glyphs in a CJK fallback font -
    # visually identical to letter-spacing, but with no spaces to strip. FormKC folds
    # those back to plain ASCII along with other compatibility forms.
    try { $s = $s.Normalize([Text.NormalizationForm]::FormKC) } catch {}
    $s = ($s -replace '\s+', ' ').Trim()
    if (-not $s) { return '' }
    # Detect the same damage in its already-spaced form. Counting single-character
    # tokens is far more forgiving than pattern-matching the whole string, which fails
    # on any name that mixes real words with spaced-out letters.
    $tokens = @($s -split ' ' | Where-Object { $_ })
    if ($tokens.Count -ge 5) {
        $singles = @($tokens | Where-Object { $_.Length -eq 1 }).Count
        if (($singles / $tokens.Count) -ge 0.6) {
            $s = (-join $tokens)
            # -creplace, NOT -replace: PowerShell's -replace is case-INSENSITIVE, so
            # [A-Z] would also match lowercase and this would space out every letter
            $s = ($s -creplace '(?<=[a-z0-9])(?=[A-Z])', ' ').Trim()
        }
    }
    return $s
}

function Resolve-PackageString($Value, [string]$PackageFullName) {
    $Value = AsText $Value
    if (-not $Value) { return '' }
    if ($Value -notlike 'ms-resource:*') { return $Value }
    foreach ($form in @("@{$PackageFullName? $Value}",
                        "@{$PackageFullName?$Value}",
                        "@{$PackageFullName?ms-resource://$PackageFullName/resources/$($Value -replace '^ms-resource:/*','')}")) {
        try {
            $sb = New-Object System.Text.StringBuilder 1024
            if ([Native.ResourceString]::SHLoadIndirectString($form, $sb, $sb.Capacity, [IntPtr]::Zero) -eq 0) {
                $r = Clean-DisplayName $sb.ToString()
                if ($r -and $r -notlike 'ms-resource:*') { return $r }
            }
        } catch {}
    }
    return ''
}

# Microsoft Store / UWP packages. These never appear in Control Panel - only in
# Settings > Installed apps - which is why they get their own section.
function Get-StoreApps {
    $out = New-Object System.Collections.ArrayList
    $pkgs = @()
    try { $pkgs = @(Get-AppxPackage -ErrorAction Stop) } catch { return @() }

    # The Start menu already holds shell-resolved names for every installed app, and
    # reading it needs no access to C:\Program Files\WindowsApps - which is locked to
    # TrustedInstaller, so reading manifests off disk works for some packages and is
    # denied for others. That inconsistency is what produced the garbled names.
    $startNames = @{}
    try {
        foreach ($sa in @(Get-StartApps -ErrorAction Stop)) {
            $fam = ('' + $sa.AppID).Split('!')[0]
            if ($fam -and -not $startNames.ContainsKey($fam)) { $startNames[$fam] = $sa.Name }
        }
    } catch {}

    $i = 0
    foreach ($p in $pkgs) {
        if ($p.IsFramework) { continue }                       # runtime deps, not user apps
        if ($p.NonRemovable) { continue }                      # OS shell pieces, cannot be removed
        if ((++$i % 10) -eq 0) { Update-UI }
        $pkgName = ('' + $p.Name)
        $disp = ''
        $logo = ''
        # 1. shell-resolved Start menu name - correct and cheap
        $fam = ('' + $p.PackageFamilyName)
        if ($fam -and $startNames.ContainsKey($fam)) { $disp = Clean-DisplayName $startNames[$fam] }
        # 2. the manifest via the Appx API, which reads through the ACL barrier
        try {
            $mx = Get-AppxPackageManifest -Package $p.PackageFullName -ErrorAction Stop
            $ve = $mx.Package.Applications.Application.VisualElements
            if (-not $disp) {
                $disp = Clean-DisplayName (Resolve-PackageString (AsText $mx.Package.Properties.DisplayName) $p.PackageFullName)
                if (-not $disp -and $ve) { $disp = Clean-DisplayName (Resolve-PackageString (AsText $ve.DisplayName) $p.PackageFullName) }
            }
            if ($ve) { $logo = AsText $ve.Square44x44Logo; if (-not $logo) { $logo = AsText $ve.Logo } }
        } catch {}
        if (-not $disp) {
            # 3. last resort: tidy the package id, and drop it if it is only machine noise
            $disp = $pkgName -replace '^(Microsoft|MicrosoftWindows|MicrosoftCorporationII|Windows)\.', ''
            $disp = $disp -replace '\.', ' '
            if ($disp -match '^[0-9A-Fa-f]{8}-' -or $disp -match '^[0-9A-Fa-f]{6,}$' -or
                $disp -notmatch '[A-Za-z]{3}') { continue }
            # -creplace is required here: -replace ignores case, so [A-Z] would match
            # every lowercase letter too and split the name into single characters
            $disp = Clean-DisplayName ($disp -creplace '(?<=[a-z0-9])(?=[A-Z])', ' ')
        }
        # internal plumbing rather than anything a technician would uninstall
        if ($disp -match '(?i)winget.*source|^Desktop App Installer$|VCLibs|WindowsAppRuntime|\.NET Native') { continue }
        [void]$out.Add([pscustomobject]@{
            Name        = (Clean-DisplayName $disp)
            Version     = (AsText $p.Version)
            Publisher   = ((AsText $p.Publisher) -replace '^CN=([^,]+).*$', '$1')
            Location    = (AsText $p.InstallLocation)
            Logo        = (AsText $logo)
            PackageFull = ('' + $p.PackageFullName)
            IsSystem    = ($p.SignatureKind -eq 'System')
        })
    }
    return @($out | Sort-Object Name)
}

# Switch between the two inventories, scanning the chosen one only if it is stale.
# Each scan is several seconds (icon extraction dominates), so they stay independent:
# opening the desktop list never waits on Store enumeration.
function Select-UnTab([string]$Which) {
    $script:UnSubTab = $Which
    $store = ($Which -eq 'Store')
    $BtnSubDesktop.Style = $window.FindResource($(if ($store) { 'TabIdle' } else { 'TabActive' }))
    $BtnSubStore.Style   = $window.FindResource($(if ($store) { 'TabActive' } else { 'TabIdle' }))
    # scanning is read-only and safe while apps download/install; refuse only during a
    # removal batch, whose rows live in this very collection (see BtnRescan)
    if ($script:Phase -in 'Download', 'Install' -and $script:BatchTab -ne 'Install') { return }

    $dirty = $(if ($store) { $script:StoreDirty } else { $script:UnDirty })
    if (-not $dirty) {
        # plain if/else, never $(...): a subexpression enumerates a CollectionView and
        # would assign a single item instead of the view itself
        if ($store) { $ListUn.ItemsSource = $script:StoreView } else { $ListUn.ItemsSource = $script:UnView }
        Update-SearchCount
        return
    }
    if ($store) { $script:StoreDirty = $false } else { $script:UnDirty = $false }
    $ListUn.Visibility = 'Collapsed'
    $LoadUn.Visibility = 'Visible'
    $TxtLoadUn.Text = $(if ($store) { 'Scanning Microsoft Store apps...' } else { 'Scanning installed programs...' })
    $TxtLoadUn2.Text = ''
    Update-UI
    try {
        if ($store) { Refresh-UnStore } else { Refresh-UnList $script:LastManifest }
    } catch {
        # surface the real reason instead of taking the window down with us
        $msg = "$($_.Exception.Message)`n`nat $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
        Add-Log "Scan failed: $msg"
        # plain if/else, never $(...): a subexpression enumerates a CollectionView and
        # would assign a single item instead of the view itself
        if ($store) { $ListUn.ItemsSource = $script:StoreView } else { $ListUn.ItemsSource = $script:UnView }
        Show-Overlay 'Could not scan installed programs' $msg
    } finally {
        $LoadUn.Visibility = 'Collapsed'
        $ListUn.Visibility = 'Visible'
        Update-SearchCount   # a freshly scanned list must honour the sticky query
    }
}

function Refresh-UnList([object]$Manifest) {
    # ONE list: exactly what is registered on this machine, discovered from the registry
    # like Wise does. There is no separate "our catalog apps" section - a technician wants
    # the machine's real inventory, not our shop's list bolted on top of it.
    #
    # The curated vendor uninstallers are not lost though: where a catalog entry matches an
    # installed program by name, that program's row quietly upgrades to the vendor tool
    # (Autodesk ODIS, Adobe APRemover) plus its curated cleanup targets, because those
    # remove far more cleanly than a generic registry uninstall string.
    #
    # The list is detached from the UI while it is rebuilt: this scan pumps the dispatcher
    # to keep the spinner alive, and a grouped+filtered CollectionView throws if the
    # collection mutates during that re-entrant pump.
    $ListUn.ItemsSource = $null
    $script:UnItems.Clear()
    $catalogByName = @{}
    foreach ($a in @($Manifest.apps)) {
        if (-not $a.uninstall -or -not $a.name) { continue }
        $detect = [string]$(if ($a.uninstall.detect) { $a.uninstall.detect }
                            elseif (@($a.verifyPaths).Count) { @($a.verifyPaths)[0] } else { '' })
        if (-not $detect) { continue }
        $catalogByName[([string]$a.name).ToLower()] = $a
    }

    $TxtLoadUn.Text = 'Reading installed programs...'
    $TxtLoadUn2.Text = 'Control Panel entries'
    Update-UI
    foreach ($r in @(Get-InstalledPrograms | Where-Object { $_ -and $_.Name })) {
        $u = New-Object AppItem
        $u.Id = "reg-$([Math]::Abs($r.RegKey.GetHashCode()))"
        $u.Name = Clean-DisplayName $r.Name
        $u.Version = Clean-DisplayName $r.Version
        $u.Publisher = Clean-DisplayName $r.Publisher
        $u.Size = $(if ($r.SizeKB -gt 0) { Format-Size ([long]$r.SizeKB * 1KB) } else { '' })
        $u.UnCommand = $r.Exe
        $u.UnArgs = $r.Args
        $u.DetectPath = $r.RegKey     # key vanishing = uninstalled; folder may linger as leftovers
        $u.RegKey = $r.RegKey
        $u.IsSilent = $r.Silent
        $u.Source = $(if ($r.Silent) { 'Silent uninstall' } else { 'Shows installer UI' })
        $u.Category = 'Desktop programs  (Control Panel)'
        $u.IconData = $IconMap['default'][0]
        $u.IconBg = $(if ($r.Silent) { '#FF64748B' } else { '#FF8A6A32' })
        # real logo straight out of the program's own exe, DisplayIcon first - resolved
        # by the background icon pump, so a 300-program scan lists rows immediately
        Request-Icon $u 'exe' @{ Sources = @($r.Icon, $r.Exe) }
        # curated cleanup target: the registry's own InstallLocation, plus its uninstall key
        $paths = @(); if ($r.Location) { $paths = @($r.Location) }
        $u.CleanPaths = $paths
        $u.CleanReg = @($r.RegKey)
        $u.CleanTokens = @($r.Name)
        $u.CleanHosts = @()

        # Same program in our catalog? Use the vendor uninstaller and the curated cleanup
        # targets instead of the registry string - same row, better removal.
        $cat = $catalogByName[([string]$u.Name).ToLower()]
        if ($cat) {
            $detect = [string]$(if ($cat.uninstall.detect) { $cat.uninstall.detect }
                                elseif (@($cat.verifyPaths).Count) { @($cat.verifyPaths)[0] } else { '' })
            if ($detect -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($detect)))) {
                $u.UnCommand = [string]$cat.uninstall.command
                $u.UnArgs = [string]$cat.uninstall.args
                $u.DetectPath = $detect
                $u.IsSilent = $true
                $u.Source = 'Vendor uninstaller'
                if ($cat.cleanup) {
                    # union with what the registry already gave us, never a replacement:
                    # the registry InstallLocation and uninstall key are still real targets
                    $u.CleanPaths  = @(@($u.CleanPaths) + @($cat.cleanup.paths) | Where-Object { $_ } | Select-Object -Unique)
                    $u.CleanReg    = @(@($u.CleanReg) + @($cat.cleanup.registry) | Where-Object { $_ } | Select-Object -Unique)
                    $u.CleanTokens = @(@($u.CleanTokens) + @($cat.cleanup.tokens) | Where-Object { $_ } | Select-Object -Unique)
                    $u.CleanHosts  = @(@($cat.cleanup.hosts) | Where-Object { $_ })
                }
            }
        }
        $script:UnItems.Add($u)
    }
    $ListUn.ItemsSource = $script:UnView    # reattach the filtered view, never the raw collection
}

function Refresh-UnStore {
    # Microsoft Store apps are a separate inventory and a separate scan, so opening the
    # desktop list never waits on Appx enumeration (and vice versa).
    $ListUn.ItemsSource = $null
    $script:UnStore.Clear()
    $TxtLoadUn2.Text = 'Microsoft Store packages'
    Update-UI
    foreach ($s in @(Get-StoreApps | Where-Object { $_ -and $_.Name })) {
        $u = New-Object AppItem
        $u.Id = "appx-$($s.PackageFull)"
        $u.Name = Clean-DisplayName $s.Name
        $u.Version = Clean-DisplayName $s.Version
        $u.Publisher = Clean-DisplayName $s.Publisher
        $u.Size = ''
        $u.UnCommand = 'appx'                 # handled natively by the elevated worker
        $u.UnArgs = $s.PackageFull
        $u.DetectPath = ''
        $u.IsSilent = $true
        $u.Source = $(if ($s.IsSystem) { 'Store app (system)' } else { 'Store app' })
        $u.Category = 'Microsoft Store apps  (Settings > Installed apps)'
        $u.IconData = $IconMap['default'][0]
        $u.IconBg = '#FF7A5CFF'
        # logo asset read off-thread by the icon pump; manifest was already parsed above
        if ($s.Location -and $s.Logo) { Request-Icon $u 'store' @{ Location = $s.Location; Logo = $s.Logo } }
        # Store packages are self-contained; their folder is removed by the platform
        $u.CleanPaths = @()
        $u.CleanReg = @()
        $u.CleanTokens = @($s.Name)
        $script:UnStore.Add($u)
    }
    $ListUn.ItemsSource = $script:StoreView
}

# Turns a failed catalog fetch into something a technician can act on. Three genuinely
# different situations produce the same exception, and only one of them is a network problem:
#   - the server was never configured (the shipped placeholder is still in place)
#   - a local test path is wrong or missing
#   - a real server is actually unreachable
function Get-CatalogFailure([string]$Err) {
    $url = "$BaseUrl/apps.json"
    if ($BaseUrl -match 'apps\.example\.com|YOUR-SERVER') {
        return @{
            Badge = 'No server configured'
            Log   = "No catalog server is configured - BaseUrl is still the placeholder '$BaseUrl'."
            Message = "This copy has no catalog server yet. '$BaseUrl' is the placeholder that ships " +
                      "with the tool, not a real address.`n`n" +
                      "For a real deployment, set `$BaseUrl in go.ps1 to your server and publish with " +
                      "tools\Publish-Release.ps1.`n`n" +
                      "To test locally against the catalog in this folder, start it with:`n" +
                      '  -BaseUrl "file:///C:/path/to/App-Installer/server"'
        }
    }
    if ($BaseUrl -match '^file:') {
        $local = $BaseUrl -replace '^file:///', '' -replace '/', '\'
        return @{
            Badge = 'Catalog not found'
            Log   = "Local catalog not found at $local\apps.json - $Err"
            Message = "No apps.json was found at:`n  $local`n`nCheck the path is right and that " +
                      "apps.json is in that folder."
        }
    }
    return @{
        Badge = 'No connection'
        Log   = "Cannot reach $url - $Err"
        Message = "The catalog server could not be reached:`n  $url`n`n$Err`n`n" +
                  "Check the connection, then use Refresh."
    }
}

function Load-Catalog {
    $script:Items.Clear()
    $manifest = $null
    try {
        # A byte-order mark on apps.json breaks Invoke-RestMethod's own JSON parsing, and it
        # does so in two different ways depending on the response: sometimes it hands back the
        # raw STRING, sometimes it throws. The string case is the dangerous one - $manifest.apps
        # is then $null, @($null) is a ONE-element array, and the loop below builds a single
        # blank row under a green "Live catalog", which is the worst way to fail because
        # nothing about it looks wrong.
        #
        # A BOM is easy to get by accident: Set-Content -Encoding UTF8 on 5.1 writes one, and so
        # does Notepad. The catalog is still perfectly good JSON underneath, so fetch the bytes
        # and parse them rather than making a technician hunt for an invisible character.
        try {
            $manifest = Invoke-RestMethod -Uri "$BaseUrl/apps.json" -UseBasicParsing -TimeoutSec 30
            if ($manifest -is [string]) { $manifest = $manifest.TrimStart([char]0xFEFF) | ConvertFrom-Json }
        } catch {
            $raw = (Invoke-WebRequest -Uri "$BaseUrl/apps.json" -UseBasicParsing -TimeoutSec 30).Content
            if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }
            $manifest = ('' + $raw).TrimStart([char]0xFEFF) | ConvertFrom-Json
        }
        # and a catalog with no apps array is not a catalog; say so instead of showing nothing
        if (-not $manifest -or -not $manifest.apps) { throw 'the catalog has no apps array' }
        ($manifest | ConvertTo-Json -Depth 6) | Set-Content -Path $script:ManifestCache -Encoding UTF8
        $TxtCatalogInfo.Text = 'Live catalog'
        $DotLive.Fill = '#FF34D399'
    } catch {
        if (Test-Path $script:ManifestCache) {
            $manifest = Get-Content $script:ManifestCache -Raw | ConvertFrom-Json
            $TxtCatalogInfo.Text = 'Offline copy'
            $DotLive.Fill = '#FFFBBF24'
            Add-Log "Server unreachable - using cached catalog. ($($_.Exception.Message))"
        } else {
            # Name the actual cause. "no offline copy exists" describes a missing cache file,
            # which is a CONSEQUENCE - it says nothing about why the fetch failed, and sends
            # someone hunting for a file that was never supposed to be there on a first run.
            $why = Get-CatalogFailure $_.Exception.Message
            $TxtCatalogInfo.Text = $why.Badge
            $DotLive.Fill = '#FFF87171'
            Add-Log $why.Log
            $TxtStatus.Text = $why.Badge
            Show-Overlay 'No application catalog' $why.Message
            return
        }
    }
    # Where-Object, because @() around a $null property yields a one-element array of nothing,
    # and that one element becomes a row with no name, no size and no way to explain itself
    foreach ($a in @(@($manifest.apps) | Where-Object { $_ })) {
        $item = New-Object AppItem
        $item.Id = $a.id; $item.Name = $a.name; $item.Version = $a.version
        $item.Url = $a.url; $item.Sha256 = ('' + $a.sha256).ToUpper()
        $item.SilentArgs = $a.silentArgs
        $item.Entry = [string]$a.entry      # set only for .zip packages
        $item.Instructions = [string]$a.instructions
        $item.VerifyPaths = @($a.verifyPaths)
        $item.SizeBytes = [long]$a.sizeBytes
        $item.Size = Format-Size $item.SizeBytes
        $item.FileName = [IO.Path]::GetFileName(([Uri]$a.url).LocalPath)
        $item.PostInstall = $a.postInstall
        # The catalog's cleanup block is read on the INSTALL side too, not just when the
        # app is being removed: an install that dies half-way leaves the same debris an
        # uninstaller would, and this is the only description of it we have. The app's own
        # name joins the tokens so a catalog entry with no cleanup block still scans.
        if ($a.cleanup) {
            $item.CleanPaths = @(@($a.cleanup.paths)    | Where-Object { $_ } | Select-Object -Unique)
            $item.CleanReg   = @(@($a.cleanup.registry) | Where-Object { $_ } | Select-Object -Unique)
            $item.CleanHosts = @(@($a.cleanup.hosts)    | Where-Object { $_ })
        }
        $item.CleanTokens = @(@(@($a.cleanup.tokens) + $a.name) | Where-Object { $_ } | Select-Object -Unique)
        $item.Publisher = [string]$a.publisher
        $item.Category = [string]$(if ($a.category) { $a.category } elseif ($a.publisher) { $a.publisher } else { 'Apps' })
        $iconKey = 'default'; if ($a.icon -and $IconMap.ContainsKey([string]$a.icon)) { $iconKey = [string]$a.icon }
        $item.IconData = $IconMap[$iconKey][0]
        $item.IconBg   = $IconMap[$iconKey][1]
        if ($a.iconColor) { $item.IconBg = [string]$a.iconColor }
        # Real vendor logo from the catalog server, downloaded once and cached on disk so
        # later launches are instant. The letter mark is only a placeholder for entries
        # that have no image yet, so a missing file never leaves a blank tile.
        if ($a.iconText) {
            $item.IconText = [string]$a.iconText
            $item.TextVis = 'Visible'
            $item.GlyphVis = 'Collapsed'
        }
        if ($a.iconUrl) {
            $img = Get-CachedCatalogIcon ([string]$a.iconUrl) ([string]$a.id)
            if ($img) { Set-AppIcon $item $img }
            else { Request-Icon $item 'url' @{ Url = [string]$a.iconUrl; Id = [string]$a.id } }
        }
        $item.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'IsSelected') { Update-Dash } })
        $script:Items.Add($item)
    }
    Add-Log "Catalog loaded: $($script:Items.Count) applications."
    $script:LastManifest = $manifest
    $script:UnDirty = $true
    Update-Dash
}

# Mints a fresh download URL for one app by re-fetching the catalog.
#
# Catalog servers may hand out time-limited signed URLs, and a BITS job outlives them:
# the job survives reboots and BITS retries it for up to 90 days, while a signed link is
# good for hours or days. A download suspended over a weekend therefore wakes up to a
# 403 that no amount of retrying will fix, because the URL itself is dead rather than
# the server. Re-fetching the catalog issues a new one.
#
# Only the URL is taken from the refreshed entry. If the SHA-256 has changed the app was
# republished mid-download, and continuing would append new bytes onto an old partial
# file - so the refresh is refused and the download fails honestly instead.
function Get-FreshCatalogUrl([object]$Item) {
    try {
        $m = Invoke-RestMethod -Uri "$BaseUrl/apps.json" -UseBasicParsing -TimeoutSec 30
        $entry = @($m.apps) | Where-Object { $_.id -eq $Item.Id } | Select-Object -First 1
        if (-not $entry -or -not $entry.url) {
            Add-Log "Catalog refresh: $($Item.Name) is no longer in the catalog."
            return $null
        }
        if (('' + $entry.sha256).ToUpper() -ne ('' + $Item.Sha256).ToUpper()) {
            Add-Log "Catalog refresh: $($Item.Name) was republished with a different SHA-256 - not switching URLs mid-download."
            return $null
        }
        return [string]$entry.url
    } catch {
        Add-Log "Catalog refresh failed for $($Item.Name): $($_.Exception.Message)"
        return $null
    }
}

# Apps whose URL has already been refreshed once this session, so an endlessly 403-ing
# server cannot put the downloader in a refresh loop.
$script:UrlRefreshed = @{}

# ---------- tweaks ----------
# Winutil-style system tweaks. The list is built into the tool rather than fetched, so it
# works offline and cannot be changed by whoever controls the catalog server. Every entry
# is applied by the elevated worker through the same one-UAC queue the installs use.
#
# 'caution' entries remove software or change network/OS behaviour: they are grouped
# separately, never pre-selected, and the tech confirms an extra dialog before they run.
$script:TweakDefs = @(
    # --- Essential ---
    @{ id = 'activityhistory'; name = 'Activity History - Disable';        hint = 'policy' }
    @{ id = 'bitlocker';       name = 'BitLocker - Disable';               hint = 'policy' }
    @{ id = 'consumerfeatures';name = 'ConsumerFeatures - Disable';        hint = 'policy' }
    @{ id = 'deliveryopt';     name = 'Delivery Optimization - Disable';   hint = 'policy' }
    @{ id = 'diskcleanup';     name = 'Disk Cleanup - Run';                hint = 'runs' }
    @{ id = 'endtask';         name = 'End Task With Right Click - Enable';hint = 'registry' }
    @{ id = 'folderdiscovery'; name = 'File Explorer Automatic Folder Discovery - Disable'; hint = 'registry' }
    @{ id = 'hibernation';     name = 'Hibernation - Disable';             hint = 'power' }
    @{ id = 'location';        name = 'Location Tracking - Disable';       hint = 'policy' }
    @{ id = 'storesearch';     name = 'Microsoft Store Recommended Search Results - Disable'; hint = 'policy' }
    @{ id = 'devicecompanion'; name = 'Prevent Device Companion Apps';     hint = 'policy' }
    @{ id = 'restorepoint';    name = 'Restore Point - Create';            hint = 'runs first' }
    @{ id = 'servicesmanual';  name = 'Services - Set to Manual';          hint = 'services' }
    @{ id = 'startlayout';     name = 'Start Menu Previous Layout - Enable'; hint = 'registry' }
    @{ id = 'telemetry';       name = 'Telemetry - Disable';               hint = 'policy' }
    @{ id = 'tempfiles';       name = 'Temporary Files - Remove';          hint = 'deletes' }
    @{ id = 'widgets';         name = 'Widgets - Remove';                  hint = 'removes' }
    @{ id = 'wpbt';            name = 'Windows Platform Binary Table (WPBT) - Disable'; hint = 'registry' }
    # --- Advanced (CAUTION) ---
    @{ id = 'adobeblock';      name = 'Adobe URL Block List - Enable';     hint = 'hosts';    caution = $true }
    @{ id = 'backgroundapps';  name = 'Background Apps - Disable';         hint = 'policy';   caution = $true }
    @{ id = 'bravedebloat';    name = 'Brave Browser - Debloat';           hint = 'policy';   caution = $true }
    @{ id = 'utctime';         name = 'Date & Time - Set Time to UTC';     hint = 'registry'; caution = $true }
    @{ id = 'reservedstorage'; name = 'Disable Reserved Storage';          hint = 'dism';     caution = $true }
    @{ id = 'explorerhome';    name = 'File Explorer Home and Gallery - Disable'; hint = 'registry'; caution = $true }
    @{ id = 'fullscreenopt';   name = 'Fullscreen Optimizations - Disable';hint = 'registry'; caution = $true }
    @{ id = 'ipv6disable';     name = 'IPv6 - Disable';                    hint = 'network';  caution = $true }
    @{ id = 'ipv4prefer';      name = 'IPv6 Set IPv4 as Preferred';        hint = 'network';  caution = $true }
    @{ id = 'edgedebloat';     name = 'Microsoft Edge - Debloat';          hint = 'policy';   caution = $true }
    @{ id = 'edgeremove';      name = 'Microsoft Edge - Remove';           hint = 'removes';  caution = $true }
    @{ id = 'onedriveremove';  name = 'Microsoft OneDrive - Remove';       hint = 'removes';  caution = $true }
    @{ id = 'razerdisable';    name = 'Razer Software Auto-Install - Disable'; hint = 'policy'; caution = $true }
    @{ id = 'rdpwarnings';     name = 'RDP Unsigned File Warnings - Disable'; hint = 'registry'; caution = $true }
    @{ id = 'rightclickmenu';  name = 'Right-Click Menu Previous Layout - Enable'; hint = 'registry'; caution = $true }
    @{ id = 'storagesense';    name = 'Storage Sense - Disable';           hint = 'registry'; caution = $true }
    @{ id = 'traynotify';      name = 'System Tray Notifications & Calendar - Disable'; hint = 'registry'; caution = $true }
    @{ id = 'teredo';          name = 'Teredo - Disable';                  hint = 'network';  caution = $true }
    @{ id = 'visualeffects';   name = 'Visual Effects - Set to Best Performance'; hint = 'registry'; caution = $true }
    @{ id = 'windowsai';       name = 'Windows AI - Disable And Remove';   hint = 'removes';  caution = $true }
)

function Load-Tweaks {
    $script:TweakItems.Clear()
    foreach ($t in $script:TweakDefs) {
        $item = New-Object AppItem
        $item.Id = "tweak-$($t.id)"
        $item.Name = $t.name
        $item.Size = ''
        $item.Publisher = 'System tweak'
        $item.UnArgs = $t.id          # the worker switches on this
        $item.IsSilent = -not $t.caution
        # IconBg is the 3px accent bar on the row - the only visual the tweak list keeps
        if ($t.caution) {
            $item.Category = 'Advanced Tweaks   CAUTION'
            $item.IconBg = '#FFF59E0B'
        } else {
            $item.Category = 'Essential Tweaks'
            $item.IconBg = '#FF3D7EF0'
        }
        $item.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'IsSelected') { Update-Dash } })
        $script:TweakItems.Add($item)
    }
    Add-Log "Tweaks available: $($script:TweakItems.Count) ($(@($script:TweakDefs | Where-Object { -not $_.caution }).Count) essential, $(@($script:TweakDefs | Where-Object { $_.caution }).Count) advanced)."
}

# ---------- toolbox: repair actions and legacy panels ----------
# Fixes run elevated through the same one-UAC queue as everything else. Panels are just
# shortcuts, launched unelevated straight from the GUI - Windows elevates them itself if
# they need it, and routing them through the worker would cost a pointless UAC prompt.
$script:FixDefs = @(
    @{ id = 'autologon';  name = 'AutoLogon - Run';                group = 'Fixes'
       hint = 'sign in automatically at boot - asks for the account' }
    @{ id = 'netreset';   name = 'Network - Reset';                group = 'Fixes'
       hint = 'winsock + TCP/IP stack, DNS cache, DHCP lease. Needs a reboot' }
    @{ id = 'ntp';        name = 'NTP Server - Enable';            group = 'Fixes'
       hint = 'point the clock at time.windows.com and resync now' }
    @{ id = 'sfc';        name = 'System Corruption Scan - Run';   group = 'Fixes'
       hint = 'sfc /scannow then DISM RestoreHealth - can take 30 minutes' }
    @{ id = 'wureset';    name = 'Windows Update - Reset';         group = 'Fixes'
       hint = 'clears the update cache and re-registers the services' }
    @{ id = 'winget';     name = 'WinGet - Reinstall';             group = 'Fixes'
       hint = 're-register App Installer, then fetch it if that fails' }
    @{ id = 'openssh';    name = 'OpenSSH Server - Enable';        group = 'Remote Access'
       hint = 'installs sshd, starts it, opens port 22 - a remote way in' }
)

# name -> what to launch, plus where its real Windows icon lives. Most .cpl applets carry
# their own icon at index 0; the exceptions are measured, not guessed:
#   firewall.cpl  is a stub with no icon  -> FirewallControlPanel.dll
#   compmgmt.msc  is XML, .msc never has one -> mmcndmgr.dll, the MMC node manager
$script:PanelDefs = @(
    @{ name = 'Computer Management';        cmd = 'compmgmt.msc'; icon = 'mmcndmgr.dll' }
    @{ name = 'Control Panel';              cmd = 'control.exe' }
    @{ name = 'Programs and Features';      cmd = 'appwiz.cpl' }
    @{ name = 'Network Connections';        cmd = 'ncpa.cpl' }
    @{ name = 'Windows Defender Firewall';  cmd = 'firewall.cpl'; icon = 'FirewallControlPanel.dll' }
    @{ name = 'System Properties';          cmd = 'sysdm.cpl' }
    @{ name = 'Power Panel';                cmd = 'powercfg.cpl' }
    @{ name = 'Sound Settings';             cmd = 'mmsys.cpl' }
    @{ name = 'Mouse Properties';           cmd = 'main.cpl' }
    @{ name = 'Printer Panel';              cmd = 'control.exe'; args = 'printers'; icon = 'printui.dll' }
    @{ name = 'Region';                     cmd = 'intl.cpl' }
    @{ name = 'Time and Date';              cmd = 'timedate.cpl' }
    @{ name = 'Security and Maintenance';   cmd = 'wscui.cpl' }
    @{ name = 'Windows Restore';            cmd = 'rstrui.exe' }
)

function Load-Toolbox {
    $script:FixItems.Clear()
    foreach ($d in $script:FixDefs) {
        $item = New-Object AppItem
        $item.Id = "fix-$($d.id)"
        $item.Name = $d.name
        $item.UnArgs = $d.id
        $item.Size = ''
        $item.Publisher = [string]$d.hint
        $item.Category = [string]$d.group
        $item.IsSilent = $true
        $item.IconBg = $(if ($d.group -eq 'Remote Access') { '#FFF59E0B' } else { '#FF3D7EF0' })
        $item.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'IsSelected') { Update-Dash } })
        $script:FixItems.Add($item)
    }

    # Buttons are built in code so each can carry its own command in .Tag. A handler that
    # closed over the loop variable would fire with the LAST command for every button -
    # the same trap that broke the confirm dialogs.
    $PanelGrid.Children.Clear()
    foreach ($p in $script:PanelDefs) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $window.FindResource('IconTile')
        # the name lives in the tooltip - the tile itself stays a clean square
        $b.ToolTip = [string]$p.name

        # 32px is the icon's native size, so it renders crisp rather than resampled
        $img = New-Object Windows.Controls.Image
        $img.Width = 32; $img.Height = 32
        $img.Stretch = 'Uniform'
        [Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
        $b.Content = $img

        $b.Tag = @{ cmd = [string]$p.cmd; args = [string]$p.args; name = [string]$p.name }
        $b.Add_Click({ param($s, $e) Start-LegacyPanel $s.Tag })
        [void]$PanelGrid.Children.Add($b)

        # the real Windows icon, pulled off-thread; the button appears immediately either way
        $src = @()
        if ($p.icon) { $src += @{ file = [string]$p.icon; index = 0 } }
        $src += @{ file = [string]$p.cmd; index = 0 }
        $src += @{ file = 'shell32.dll'; index = 21 }      # generic control-panel icon
        Request-IconTarget $img 'module' @{ Sources = $src }
    }
    Add-Log "Toolbox: $($script:FixItems.Count) fix(es), $($script:PanelDefs.Count) legacy panel(s)."
}

function Start-LegacyPanel([hashtable]$P) {
    try {
        if ($P.args) { Start-Process -FilePath ([string]$P.cmd) -ArgumentList ([string]$P.args) }
        else { Start-Process -FilePath ([string]$P.cmd) }
        Add-Log "Opened $($P.name)."
    } catch {
        Add-Log "Could not open $($P.name): $($_.Exception.Message)"
        Show-Overlay "Could not open $($P.name)" $_.Exception.Message
    }
}

function Start-FixBatch([object[]]$Sel, [hashtable]$Extra) {
    foreach ($s in $Sel) { Set-Status $s 'Queued' 'neutral'; Set-Ring $s 'queued' }
    $script:Pending = @($Sel)
    $script:BatchTab = 'Tools'
    $script:HadFailures = $false
    $script:WorkerStarted = $false
    $script:EndQueued = $false
    $script:Paused = $false
    $script:AwaitingScan = $false
    Remove-Item -LiteralPath $script:QueuePath, $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
    if (-not (Start-Worker)) { Abort-Batch 'elevation declined'; return }
    foreach ($s in $Sel) {
        $e = @{ id = $s.Id; action = 'fix'; fix = [string]$s.UnArgs }
        if ($Extra) { foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] } }
        Add-Content -Path $script:QueuePath -Value ($e | ConvertTo-Json -Compress) -Encoding UTF8
    }
    Add-Content -Path $script:QueuePath -Value '{"end":true}' -Encoding UTF8
    $script:EndQueued = $true
    $script:Phase = 'Install'
    $BtnRunFix.IsEnabled = $false
    $BtnInstall.IsEnabled = $false
    $BtnCancel.Visibility = 'Visible'
    $TxtNow.Text = 'Running repairs...'
    $DotNow.Fill = '#FF4C8DFF'
    $RowNow.Visibility = 'Visible'
    $TxtStatus.Text = 'Running repairs...'
    Add-Log "Toolbox batch: $($Sel.Count) fix(es) - $((@($Sel | ForEach-Object { $_.UnArgs })) -join ', ')."
}

# ---------- firewall: block an application's internet access ----------
# Two things the hand-rolled .bat scripts get wrong, fixed by design here:
#
#  * Rules are created in a named GROUP. Windows can then delete every one of them in a
#    single call. Naming rules after the exe path - the usual approach - means removal is
#    a manual hunt, which is how machines end up with dozens of orphaned rules nobody can
#    clear.
#  * Detection reads the machine, not our own bookkeeping. Any outbound block rule whose
#    program sits under an application's install folder counts as blocked, whoever created
#    it, so rules left behind by an earlier script show up here and can be removed.
# The Group is the handle Windows uses to delete every rule in one call, so it is the one
# string that must stay stable. It is also the "Group" column in wf.msc, which is how these
# sort next to Windows' own "Core Networking" and friends.
#
# Renaming it later is safe: unblocking matches rules by the PROGRAM PATH, not by group, so
# rules written under an older name (or by a hand-rolled batch file) are still found and
# removed. That is deliberate - the .bat left 68 orphans precisely because it had no group.
$script:FwGroup = 'PC2Go Application Block'

# Every outbound block rule that names a program, as path -> rule name. One pass over the
# rule table and one over the application filters, joined by InstanceID; enumerating
# filters per rule instead would take minutes on a machine with several hundred rules.
function Get-FirewallBlockMap {
    $map = @{}
    try {
        $filters = @{}
        foreach ($af in @(Get-NetFirewallApplicationFilter -ErrorAction Stop)) {
            $p = ('' + $af.AppPath)
            if (-not $p) { $p = ('' + $af.Program) }
            if ($p -and $p -ne 'Any') { $filters[[string]$af.InstanceID] = $p }
        }
        foreach ($r in @(Get-NetFirewallRule -Direction Outbound -Action Block -ErrorAction Stop)) {
            $p = $filters[[string]$r.InstanceID]
            if (-not $p) { continue }
            $key = $p.ToLower()
            if (-not $map.ContainsKey($key)) { $map[$key] = @() }
            $map[$key] += [pscustomobject]@{ Name = ('' + $r.Name); Display = ('' + $r.DisplayName)
                                             Group = ('' + $r.Group); Enabled = ("$($r.Enabled)" -eq 'True') }
        }
    } catch {
        Add-Log "Firewall rules could not be read: $($_.Exception.Message)"
    }
    return $map
}

# An application is "blocked" if any rule targets an exe inside its install folder.
# How many of the rules about to be deleted were made by something other than this tool.
# Removing them is intended - that is how a legacy batch file's leftovers get cleared - but
# the technician should see the blast radius before agreeing to it.
function Get-ForeignRuleCount([object[]]$Rows) {
    $map = $null
    try { $map = Get-FirewallBlockMap } catch { return 0 }
    $n = 0
    foreach ($row in $Rows) {
        if ($row.RegKey -eq 'unmatched') {
            # names were captured at scan time; look them up in the current map
            $want = @($row.CleanTokens)
            foreach ($k in $map.Keys) {
                foreach ($r in @($map[$k])) {
                    if ($want -contains ('' + $r.Name) -and ('' + $r.Group) -ne $script:FwGroup) { $n++ }
                }
            }
            continue
        }
        $prefix = ([string]$row.UnArgs).TrimEnd('\').ToLower() + '\'
        foreach ($k in $map.Keys) {
            if (-not $k.StartsWith($prefix)) { continue }
            foreach ($r in @($map[$k])) { if (('' + $r.Group) -ne $script:FwGroup) { $n++ } }
        }
    }
    return $n
}

function Get-BlockCountUnder([hashtable]$Map, [string]$Root) {
    if (-not $Root) { return 0 }
    $r = $Root.TrimEnd('\').ToLower()
    if ($r.Length -lt 4) { return 0 }        # refuse to treat "C:\" as an app folder
    $n = 0
    foreach ($k in $Map.Keys) {
        if ($k.StartsWith($r + '\')) { $n += @($Map[$k]).Count }
    }
    return $n
}

# Where an installed program actually lives. InstallLocation is often blank, so fall back
# to the folder of its DisplayIcon or uninstaller - the same trick Explorer uses.
function Resolve-AppRoot([object]$Reg) {
    $loc = ('' + $Reg.Location).Trim().Trim('"')
    if ($loc -and (Test-Path -LiteralPath $loc -PathType Container)) { return $loc.TrimEnd('\') }
    foreach ($cand in @($Reg.Icon, $Reg.Exe)) {
        $p = ('' + $cand).Trim().Trim('"')
        if (-not $p) { continue }
        if ($p -match '^(.*?),\s*-?\d+\s*$') { $p = $Matches[1] }
        $p = [Environment]::ExpandEnvironmentVariables($p.Trim('"'))
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) {
            $dir = Split-Path $p -Parent
            # an uninstaller often sits in a shared folder - only trust a real app dir
            if ($dir -and $dir.Length -gt 3 -and $script:FwProtectedRoots -notcontains $dir.TrimEnd('\').ToLower()) { return $dir.TrimEnd('\') }
        }
    }
    return ''
}

# Blocking anything in here would break Windows itself, or this tool's own downloads.
$script:FwProtectedRoots = @(
    $env:SystemRoot, (Join-Path $env:SystemRoot 'System32'), (Join-Path $env:SystemRoot 'SysWOW64'),
    $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:SystemDrive,
    (Join-Path $env:ProgramFiles 'Common Files'), (Join-Path ${env:ProgramFiles(x86)} 'Common Files'),
    (Join-Path $env:ProgramFiles 'WindowsApps'), $env:UserProfile, $env:LocalAppData, $env:AppData
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() }

# For a rule that matches no installed program, find the folder worth showing: walk up until
# the PARENT is a protected/shared root. C:\Program Files (x86)\Common Files\Adobe\...\HDBox
# becomes ...\Common Files\Adobe - one vendor row instead of a dozen fragments, which is the
# difference between a usable list and noise.
function Get-VendorFolder([string]$ExePath) {
    $dir = ''
    try { $dir = Split-Path $ExePath -Parent } catch { return '' }
    if (-not $dir) { return '' }
    $cur = $dir.TrimEnd('\')
    while ($cur) {
        $parent = ''
        try { $parent = Split-Path $cur -Parent } catch { break }
        if (-not $parent) { break }
        if ($script:FwProtectedRoots -contains $parent.TrimEnd('\').ToLower()) { return $cur }
        $cur = $parent.TrimEnd('\')
        if ($cur.Length -le 3) { break }     # reached the drive root
    }
    return $dir.TrimEnd('\')
}

function Test-FwRootAllowed([string]$Root) {
    if (-not $Root) { return $false }
    $r = $Root.TrimEnd('\').ToLower()
    if ($script:FwProtectedRoots -contains $r) { return $false }
    # never touch anything inside Windows, whatever it claims to be
    $win = $env:SystemRoot.TrimEnd('\').ToLower()
    if ($r -eq $win -or $r.StartsWith($win + '\')) { return $false }
    return $true
}

function Load-Firewall {
    $FwSplit.Visibility = 'Collapsed'
    $LoadFw.Visibility = 'Visible'
    $TxtLoadFw.Text = 'Reading firewall rules...'
    Update-UI
    $script:FwItems.Clear()
    try {
        $map = Get-FirewallBlockMap
        $script:FwMap = $map
        $TxtLoadFw.Text = 'Matching against installed programs...'
        Update-UI
        $ruleTotal = 0
        foreach ($k in $map.Keys) { $ruleTotal += @($map[$k]).Count }

        $seen = @{}
        $matchedRoots = @()
        $matchedRules = 0
        foreach ($r in @(Get-InstalledPrograms | Where-Object { $_ -and $_.Name })) {
            $root = Resolve-AppRoot $r
            if (-not $root) { continue }
            if (-not (Test-FwRootAllowed $root)) { continue }
            $key = $root.ToLower()
            if ($seen.ContainsKey($key)) { continue }     # several entries share one folder
            $seen[$key] = $true
            $n = Get-BlockCountUnder $map $root
            $matchedRules += $n
            if ($n) { $matchedRoots += ($key + '\') }

            $u = New-Object AppItem
            $u.Id = "fw-$([Math]::Abs($key.GetHashCode()))"
            $u.Name = Clean-DisplayName $r.Name
            $u.Publisher = $root
            $u.Version = Clean-DisplayName $r.Publisher
            # badge, not a coloured tile: the real program icon replaces the tile entirely
            $u.Size = $(if ($n) { "BLOCKED  $n" } else { '' })
            $u.BadgeBg = '#FFF87171'
            $u.UnArgs = $root
            $u.DetectPath = "$n"
            $u.IsSilent = ($n -gt 0)
            $u.Category = $(if ($n) { 'Blocked - no internet access' } else { 'Not blocked' })
            $u.Source = '1'
            $u.IconBg = $(if ($n) { '#FFF87171' } else { '#FF64748B' })
            $u.IconData = $IconMap['default'][0]
            # the program's own icon, same as the Uninstall tab - a wall of identical
            # placeholder glyphs made this list unreadable
            Request-Icon $u 'exe' @{ Sources = @($r.Icon, $r.Exe) }
            $u.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'IsSelected') { Update-Dash } })
            $script:FwItems.Add($u)
        }
        # Whatever is left belongs to no installed program - typically a shared vendor tree
        # such as Common Files\Adobe. Previously these were only a number in the hint line and
        # could not be removed from the UI at all, which is precisely the orphan problem that
        # made the old batch file's rules unmanageable. Group them by vendor folder and list
        # them as ordinary rows so they can be selected and cleared like anything else.
        $unmatched = @{}
        foreach ($k in $map.Keys) {
            $isMatched = $false
            foreach ($mr in $matchedRoots) { if ($k.StartsWith($mr)) { $isMatched = $true; break } }
            if ($isMatched) { continue }
            $vendor = Get-VendorFolder $k
            if (-not $vendor) { $vendor = $k }
            $vk = $vendor.ToLower()
            if (-not $unmatched.ContainsKey($vk)) { $unmatched[$vk] = @{ Path = $vendor; Rules = @() } }
            $unmatched[$vk].Rules += @($map[$k])
        }
        foreach ($vk in ($unmatched.Keys | Sort-Object)) {
            $grp = $unmatched[$vk]
            $rules = @($grp.Rules)
            $u = New-Object AppItem
            $u.Id = "fwx-$([Math]::Abs($vk.GetHashCode()))"
            $u.Name = Split-Path $grp.Path -Leaf
            $u.Publisher = $grp.Path
            $u.Version = 'no installed program claims this folder'
            $u.Size = "ORPHAN  $($rules.Count)"
            $u.BadgeBg = '#FFF59E0B'
            $u.UnArgs = $grp.Path
            $u.DetectPath = "$($rules.Count)"
            $u.IsSilent = $true
            # the exact rule names to delete - these rows cannot go through the root-based
            # worker action, because that deliberately refuses shared roots
            $u.CleanTokens = @($rules | ForEach-Object { [string]$_.Name })
            $u.RegKey = 'unmatched'
            $u.Category = 'Stray rules - no installed program owns these'
            $u.Source = '2'
            $u.IconBg = '#FFF59E0B'
            $u.IconData = $IconMap['default'][0]
            # no installed program owns these, so take the icon from a blocked executable
            # itself - it still identifies the vendor at a glance
            $firstExe = @($map.Keys | Where-Object { $_.StartsWith($vk + '\') } | Select-Object -First 1)
            if ($firstExe.Count) { Request-Icon $u 'exe' @{ Sources = @($firstExe[0]) } }
            $u.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'IsSelected') { Update-Dash } })
            $script:FwItems.Add($u)
        }

        # Count the orphans directly. Deriving them as total-minus-matched double-counts any
        # rule sitting under two nested install roots, which can under-report or go negative.
        $orphans = 0
        foreach ($vk in $unmatched.Keys) { $orphans += @($unmatched[$vk].Rules).Count }
        $TxtFwHint.Text = "$ruleTotal outbound block rule(s) on this machine"
        if ($orphans -gt 0) { $TxtFwHint.Text += "; $orphans belong to no installed program - see the Unmatched section" }
        Add-Log "Firewall: $($script:FwItems.Count) row(s), $ruleTotal outbound block rule(s), $(@($script:FwItems | Where-Object { $_.IsSilent }).Count) blocked, $orphans unmatched."
    } catch {
        Add-Log "Firewall scan failed: $($_.Exception.Message)"
        Show-Overlay 'Could not read firewall rules' $_.Exception.Message
    } finally {
        $LoadFw.Visibility = 'Collapsed'
        $FwSplit.Visibility = 'Visible'
        $script:FwDirty = $false
        try { $script:FwView.View.Refresh(); $script:FwOpenSrc.View.Refresh() } catch {}
        Update-FwFilters
        Update-FwEmpty
        Update-Dash
    }
}

# Headers carry the counts now that the two columns replace the filter pills.
function Update-FwFilters {
    $blocked = @($script:FwItems | Where-Object { $_.IsSilent -and $_.RegKey -ne 'unmatched' }).Count
    $open = @($script:FwItems | Where-Object { -not $_.IsSilent }).Count
    $orph = @($script:FwItems | Where-Object { $_.RegKey -eq 'unmatched' }).Count
    $TxtFwBlockedHdr.Text = "Blocked   $blocked" + $(if ($orph) { "   +   $orph stray" })
    $TxtFwOpenHdr.Text = "Not blocked   $open"
    $BtnFwRemoveAll.IsEnabled = (($blocked + $orph) -gt 0)
}

# What a row covers, exactly. For something already blocked this lists the executables that
# have rules; for an untouched program it is a PREVIEW of what pressing Block would create,
# which is the same list the worker will enumerate.
function Show-FwDetail([object]$Row) {
    if (-not $Row) { return }
    $root = ([string]$Row.UnArgs).TrimEnd('\')
    $blocked = [bool]$Row.IsSilent
    $stray = ($Row.RegKey -eq 'unmatched')
    $lines = @()
    $n = 0

    if ($blocked) {
        # from the map captured during the scan - no second enumeration of the rule table
        $prefix = $root.ToLower() + '\'
        $paths = @()
        if ($script:FwMap) {
            foreach ($k in $script:FwMap.Keys) {
                if ($k -eq $root.ToLower() -or $k.StartsWith($prefix)) { $paths += $k }
            }
        }
        # one line per executable, not per rule - that is what a technician reads

        foreach ($k in ($paths | Sort-Object)) {
            $rules = @($script:FwMap[$k])
            $mine = @($rules | Where-Object { ('' + $_.Group) -eq $script:FwGroup }).Count
            $tag = $(if ($mine -eq $rules.Count) { 'this tool' } elseif ($mine -eq 0) { 'another tool' } else { 'mixed' })
            $lines += ("{0}    ({1} rule(s), {2})" -f $k, $rules.Count, $tag)
        }
        $TxtFwDetailTitle.Text = "$($Row.Name) - blocked"
        $TxtFwDetailSub.Text = $(if ($stray) {
                "$($paths.Count) executable(s) under $root have outbound block rules, but no installed program owns this folder. Unblocking removes them."
            } else {
                "$($paths.Count) executable(s) under $root currently have outbound block rules."
            })
    } else {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) {
            $TxtFwDetailTitle.Text = "$($Row.Name)"
            $TxtFwDetailSub.Text = "The install folder no longer exists: $root"
            $TxtFwDetail.Text = ''
            $FwDetailOverlay.Visibility = 'Visible'
            return
        }
        $exes = @()
        try { $exes = @([IO.Directory]::EnumerateFiles($root, '*.exe', 'AllDirectories')) } catch {}
        $cap = 400
        $shown = @($exes | Sort-Object | Select-Object -First $cap)
        foreach ($e in $shown) { $lines += $e }
        if ($exes.Count -gt $cap) { $lines += ''; $lines += "... and $($exes.Count - $cap) more (list truncated for display; all of them would be blocked)" }
        $TxtFwDetailTitle.Text = "$($Row.Name) - not blocked"
        $TxtFwDetailSub.Text = "Pressing Block Internet Access would create one outbound rule for each of these $($exes.Count) executable(s) under $root."
    }

    if (-not $lines.Count) { $lines = @('(nothing found)') }
    $TxtFwDetail.Text = ($lines -join "`r`n")
    $FwDetailOverlay.Opacity = 0
    $FwDetailOverlay.Visibility = 'Visible'
    $a = New-Object Windows.Media.Animation.DoubleAnimation 0, 1, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(160)))
    $FwDetailOverlay.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
}

function Update-FwEmpty {
    $searching = [bool]$script:SearchText
    $nB = @($script:FwView.View).Count
    $EmptyFw.Visibility = 'Collapsed'
    if ($nB -eq 0) {
        $EmptyFw.Text = $(if ($searching) { "Nothing blocked matches `"$($script:SearchText)`"." }
                          else { "Nothing is blocked.`n`nTick a program on the right, then press Block Internet Access." })
        $EmptyFw.Visibility = 'Visible'
    }
    $nO = @($script:FwOpenSrc.View).Count
    $EmptyFwOpen.Visibility = 'Collapsed'
    if ($nO -eq 0) {
        $EmptyFwOpen.Text = $(if ($searching) { "Nothing here matches `"$($script:SearchText)`"." }
                              else { 'Every installed program already has block rules.' })
        $EmptyFwOpen.Visibility = 'Visible'
    }
}

# ---------- users: broken-profile repair ----------
# The classic fix for a corrupt profile: stand up a clean local admin and move the user's
# data across. Two rules make it safe to run on a client machine.
#
# 1. Nothing is moved or deleted. Files are COPIED and verified; the broken profile stays
#    exactly where it is, so a failed run costs disk space, never data.
# 2. AppData is not migrated by default. A profile is usually broken BECAUSE of something
#    in AppData - a damaged NTUSER.DAT, a wrecked browser or Outlook profile - so copying
#    it wholesale carries the fault into the new account and defeats the whole exercise.
#    The few things worth rescuing from it are offered individually, unticked.

# Every user profile registered on this machine. ProfileList is the authority, not the
# folder names under C:\Users - a renamed account keeps its original folder, so the two
# disagree on exactly the machines this feature exists for.
function Get-UserProfiles {
    $out = @()
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    if (-not (Test-Path $root)) { return $out }
    foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $sid = $k.PSChildName
        # S-1-5-21-... is a real user account; 18/19/20 are SYSTEM and the service accounts
        if ($sid -notlike 'S-1-5-21-*') { continue }
        $path = ('' + (Get-ItemProperty -LiteralPath $k.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath).Trim()
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        $name = Split-Path $path -Leaf
        try {
            $acct = (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value
            if ($acct) { $name = ($acct -replace '^.*\\', '') }
        } catch {}   # orphaned SID: the folder name is the best label left
        $out += [pscustomobject]@{ Sid = $sid; Name = $name; Path = $path; HasProfile = $true }
    }
    return @($out | Sort-Object Name)
}

# Who is actually in Administrators. Read by the well-known SID because the group name is
# localised, and returned as both SIDs and names because the net.exe fallback only has names.
function Get-AdminMembers {
    $sids = @{}; $names = @{}
    try {
        foreach ($m in @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)) {
            $s = ('' + $m.SID.Value); if ($s) { $sids[$s] = $true }
            $n = (('' + $m.Name) -replace '^.*\\', ''); if ($n) { $names[$n.ToLower()] = $true }
        }
    } catch {
        # Get-LocalGroupMember throws outright if the group holds an orphaned SID - a
        # common state on machines that were once domain-joined. net.exe still works.
        try {
            $grp = ((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value -replace '^.*\\', '')
            $seen = $false
            foreach ($line in @(& "$env:SystemRoot\System32\net.exe" localgroup $grp 2>$null)) {
                if ($line -match '^-{3,}') { $seen = $true; continue }
                if (-not $seen) { continue }
                if ($line -match '^The command completed') { continue }
                $n = $line.Trim(); if ($n) { $names[$n.ToLower()] = $true }
            }
        } catch {}
    }
    return @{ Sids = $sids; Names = $names }
}

# Local accounts, including ones created moments ago that have no profile folder yet.
# PrincipalSource is what separates a Microsoft-account sign-in from a real local account;
# it is the thing the technician actually needs to see before deciding to migrate.
function Get-LocalAccounts {
    $out = @()
    $admins = Get-AdminMembers
    # Disabled accounts are included deliberately - re-enabling one is an action offered
    # on this tab, and hiding them would make an account look deleted when it is not.
    try {
        foreach ($u in @(Get-LocalUser -ErrorAction Stop)) {
            $sid = ('' + $u.SID.Value)
            $srcKind = ('' + $u.PrincipalSource)
            $out += [pscustomobject]@{
                Sid = $sid; Name = $u.Name; FullName = ('' + $u.FullName); Enabled = [bool]$u.Enabled
                IsAdmin = ($admins.Sids.ContainsKey($sid) -or $admins.Names.ContainsKey($u.Name.ToLower()))
                # a SID ending -500 is the built-in Administrator, -501 Guest: never removable
                IsBuiltin = ($sid -match '-(500|501|503|504)$')
                Kind = $(if ($srcKind -eq 'MicrosoftAccount') { 'Microsoft account' }
                         elseif ($srcKind -eq 'AzureAD') { 'Entra ID account' }
                         elseif ($srcKind -eq 'ActiveDirectory') { 'domain account' }
                         else { 'local account' })
            }
        }
    } catch {
        try {
            foreach ($line in @(& "$env:SystemRoot\System32\net.exe" user)) {
                if ($line -match '^(The command|User accounts|-----|$)') { continue }
                foreach ($n in ($line -split '\s{2,}')) {
                    $n = $n.Trim()
                    if ($n -and $n -notmatch '^\-+$') {
                        $out += [pscustomobject]@{ Sid = ''; Name = $n; FullName = ''; Enabled = $true
                                                   IsAdmin = $admins.Names.ContainsKey($n.ToLower())
                                                   IsBuiltin = ($n -in 'Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount')
                                                   Kind = 'local account' }
                    }
                }
            }
        } catch {}
    }
    return @($out | Sort-Object Name)
}

# What can be rescued. The first group is plain user data and is ticked by default; the
# second is the handful of AppData items worth keeping, each only listed if it exists,
# and never ticked - that is the deliberate choice the technician has to make.
$script:MigrateDefs = @(
    @{ id = 'Desktop';                 name = 'Desktop';                  safe = $true }
    @{ id = 'Documents';               name = 'Documents';                safe = $true }
    @{ id = 'Downloads';               name = 'Downloads';                safe = $true }
    @{ id = 'Pictures';                name = 'Pictures';                 safe = $true }
    @{ id = 'Videos';                  name = 'Videos';                   safe = $true }
    @{ id = 'Music';                   name = 'Music';                    safe = $true }
    @{ id = 'Favorites';               name = 'Favorites (IE/Edge)';      safe = $true }
    @{ id = 'Links';                   name = 'Links';                    safe = $true }
    @{ id = 'Contacts';                name = 'Contacts';                 safe = $true }
    @{ id = 'Searches';                name = 'Searches';                 safe = $true }
    @{ id = 'OneDrive';                name = 'OneDrive folder';          safe = $true }
    @{ id = 'AppData\Local\Google\Chrome\User Data\Default';        name = 'Chrome profile (bookmarks, history)' }
    @{ id = 'AppData\Local\Microsoft\Edge\User Data\Default';       name = 'Edge profile (bookmarks, history)' }
    @{ id = 'AppData\Roaming\Mozilla\Firefox\Profiles';             name = 'Firefox profiles' }
    @{ id = 'AppData\Local\Microsoft\Outlook';                      name = 'Outlook data files (.ost/.pst)' }
    @{ id = 'AppData\Roaming\Microsoft\Outlook';                    name = 'Outlook settings and signatures' }
    @{ id = 'AppData\Roaming\Microsoft\Sticky Notes';               name = 'Sticky Notes (legacy)' }
    @{ id = 'AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState'; name = 'Sticky Notes (Store app)' }
    @{ id = 'AppData\Roaming\Microsoft\Windows\Templates';          name = 'Office templates' }
    @{ id = 'AppData\Roaming\Microsoft\Signatures';                 name = 'Email signatures' }
)

function Load-Users {
    $profiles = Get-UserProfiles
    $allAccounts = Get-LocalAccounts
    # only enabled accounts can receive a migration - a disabled one cannot sign in to use it
    $accounts = @($allAccounts | Where-Object { $_.Enabled })
    $me = ''
    try { $me = [Environment]::UserName } catch {}

    # every row states its account type and kind outright - "is this admin or standard?"
    # is the whole reason the tab exists, so it should never be something you take on trust
    $describe = {
        param($acct, $path)
        $bits = @()
        $bits += $(if ($acct -and $acct.IsAdmin) { 'Administrator' } elseif ($acct) { 'Standard user' } else { 'no matching account' })
        if ($acct -and $acct.Kind) { $bits += $acct.Kind }
        if ($acct -and $acct.FullName -and $acct.FullName -ne $acct.Name) { $bits += "shown as `"$($acct.FullName)`"" }
        if ($path) { $bits += $path }
        return ($bits -join '  -  ')
    }

    # detach both views before mutating: a bound, filtered CollectionView throws if the
    # collection changes underneath it
    $ListSrcUsers.ItemsSource = $null
    $ListDstUsers.ItemsSource = $null
    $script:SrcPick = ''
    $script:DstPick = ''

    $script:SrcUsers.Clear()
    foreach ($p in $profiles) {
        $acct = @($accounts | Where-Object { $_.Sid -eq $p.Sid -or $_.Name -eq $p.Name })[0]
        $u = New-Object AppItem
        $u.Id = "src-$($p.Sid)"
        $u.Name = $p.Name
        $u.Publisher = (& $describe $acct $p.Path)
        $u.Version = ''
        $u.Size = $(if ($p.Name -eq $me) { 'signed in now' } else { '' })
        $u.UnArgs = $p.Path
        $u.DetectPath = $p.Sid
        $u.IconBg = '#FF8A6A32'
        $u.IconData = $IconMap['default'][0]
        $u.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'IsSelected') { Select-OnlyOne $script:SrcUsers $s } })
        $script:SrcUsers.Add($u)
    }

    $script:DstUsers.Clear()
    foreach ($a in $accounts) {
        $prof = @($profiles | Where-Object { $_.Sid -eq $a.Sid -or $_.Name -eq $a.Name })[0]
        $u = New-Object AppItem
        $u.Id = "dst-$($a.Name)"
        $u.Name = $a.Name
        $u.Publisher = (& $describe $a $(if ($prof) { $prof.Path } else { 'profile folder will be created' }))
        $u.Version = ''
        $u.Size = $(if ($prof) { '' } else { 'new' })
        $u.UnArgs = $(if ($prof) { $prof.Path } else { '' })
        $u.DetectPath = $a.Name
        $u.IconBg = $(if ($prof) { '#FF64748B' } else { '#FF34D399' })
        $u.IconData = $IconMap['default'][0]
        $u.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'IsSelected') { Select-OnlyOne $script:DstUsers $s } })
        $script:DstUsers.Add($u)
    }
    # Accounts sub-tab: every local account including disabled ones, because enabling a
    # disabled account is one of the actions offered here.
    $script:AccountItems.Clear()
    foreach ($a in $allAccounts) {
        $prof = @($profiles | Where-Object { $_.Sid -eq $a.Sid -or $_.Name -eq $a.Name })[0]
        $u = New-Object AppItem
        $u.Id = "acct-$($a.Name)"
        $u.Name = $a.Name
        # description line, the way the Windows account page reads: what it is, then where
        $bits = @($(if ($a.IsAdmin) { 'Administrator' } else { 'Standard user' }))
        if ($a.Kind) { $bits += $a.Kind }
        if ($a.FullName -and $a.FullName -ne $a.Name) { $bits += "shown as `"$($a.FullName)`"" }
        if ($prof) { $bits += $prof.Path } else { $bits += 'no profile folder yet' }
        $u.Publisher = ($bits -join '   -   ')
        $u.Version = ''
        # the badge on the right
        $u.Size = $(if (-not $a.Enabled) { 'DISABLED' } elseif ($a.Name -eq $me) { 'SIGNED IN' }
                    elseif ($a.IsAdmin) { 'ADMIN' } else { 'STANDARD' })
        $u.IconText = $(if ($a.Name) { $a.Name.Substring(0, 1).ToUpper() } else { '?' })
        $u.UnArgs = $a.Name
        $u.DetectPath = $a.Sid
        $u.IsSilent = [bool]$a.Enabled
        $u.RegKey = $(if ($a.IsAdmin) { 'admin' } else { 'standard' })
        $u.IconBg = $(if (-not $a.Enabled) { '#FF4A4A52' } elseif ($a.IsAdmin) { '#FF3D7EF0' } else { '#FF64748B' })
        $u.IconData = $IconMap['default'][0]
        # clicking a row IS the action - open that account's dialog
        $u.add_PropertyChanged({
            param($s, $e)
            if ($e.PropertyName -ne 'IsSelected') { return }
            if ($script:UserSelecting) { return }
            if ($s.IsSelected) { Select-OnlyOne $script:AccountItems $s; Show-AcctDialog $s }
        })
        $script:AccountItems.Add($u)
    }

    $ListSrcUsers.ItemsSource = $script:SrcView
    $ListDstUsers.ItemsSource = $script:DstView
    Add-Log "Users: $($script:SrcUsers.Count) profile(s) on disk, $($script:AccountItems.Count) local account(s), $(@($allAccounts | Where-Object { $_.IsAdmin }).Count) Administrator(s)."

    $TxtAcctHint.Text = "$($script:AccountItems.Count) account(s), $(@($allAccounts | Where-Object { $_.IsAdmin }).Count) administrator(s). Click one to manage it."

    $msa = @($accounts | Where-Object { $_.Kind -eq 'Microsoft account' })
    if ($script:DstUsers.Count -le 1) {
        $TxtUserHint.Text = 'This machine has one account, so there is nowhere to copy to yet. ' +
                            'Step 1: create the new admin here. It appears under Copy TO as soon as it exists.'
    } elseif ($msa.Count) {
        $TxtUserHint.Text = "$(($msa | ForEach-Object { $_.Name }) -join ', ') " +
                            $(if ($msa.Count -eq 1) { 'signs in with a Microsoft account.' } else { 'sign in with Microsoft accounts.' }) +
                            ' Use MS Account -> Local below to convert one, or copy its data into a new local admin.'
    } else {
        $TxtUserHint.Text = 'Step 1: create the account (Administrator, no password, profile folder built immediately). ' +
                            'Then pick a source on the left, a destination in the middle, and what to copy on the right.'
    }
    Update-UserEmptyStates
    Build-MigrateList
}

# Accounts and Migration are separate top-level tabs now, so the old sub-tab switcher is gone.
# Selecting an account row opens its action dialog - the list itself is never multi-select,
# which is why the row template has no checkbox.
function Show-AcctDialog([object]$Acct) {
    if (-not $Acct) { return }
    $script:AcctTarget = $Acct
    $TxtAcctInitial.Text = $Acct.IconText
    $TxtAcctName.Text = $Acct.Name
    $TxtAcctMeta.Text = $Acct.Publisher
    $isAdmin = ($Acct.RegKey -eq 'admin')
    $enabled = [bool]$Acct.IsSilent
    $isBuiltin = ($Acct.DetectPath -match '-(500|501|503|504)$' -or $Acct.Name -in 'Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount')
    $me = ''
    try { $me = [Environment]::UserName } catch {}

    # Only offer what actually applies to THIS account - a dialog full of buttons that
    # refuse when pressed is worse than one that shows the three that work.
    $BtnActAdmin.Visibility    = $(if ($isAdmin) { 'Collapsed' } else { 'Visible' })
    $BtnActStandard.Visibility = $(if ($isAdmin -and -not $isBuiltin) { 'Visible' } else { 'Collapsed' })
    $BtnActToggle.Content      = $(if ($enabled) { 'Disable account' } else { 'Enable account' })
    $BtnActToggle.Visibility   = $(if ($enabled -and $Acct.Name -eq $me) { 'Collapsed' } else { 'Visible' })
    $BtnActLocal.Visibility    = $(if ($Acct.Publisher -like '*Microsoft account*') { 'Visible' } else { 'Collapsed' })
    $BtnActDelete.Visibility   = $(if ($isBuiltin -or $Acct.Name -eq $me) { 'Collapsed' } else { 'Visible' })

    $AcctOverlay.Opacity = 0
    $AcctOverlay.Visibility = 'Visible'
    $a = New-Object Windows.Media.Animation.DoubleAnimation 0, 1, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(180)))
    $AcctOverlay.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
}

function Hide-AcctDialog {
    $AcctOverlay.Visibility = 'Collapsed'
    $script:UserSelecting = $true
    try { foreach ($x in $script:AccountItems) { $x.IsSelected = $false } } finally { $script:UserSelecting = $false }
    $script:AcctTarget = $null
}

function Get-SelectedAccount { return @($script:AccountItems | Where-Object { $_.IsSelected })[0] }

# Every account action needs a target and admin rights. One gate keeps the refusals
# consistent and stops any action running against nothing.
# The dialog is the only place an account action starts now, so the target is whichever row
# opened it. Closing the dialog first stops two modals stacking on top of each other.
function Get-AccountTarget([string]$Verb) {
    $a = $script:AcctTarget
    Hide-AcctDialog
    if (Test-BatchBusy) { return $null }
    if (-not $a) {
        Show-Overlay 'No account selected' "Click the account you want to $Verb."
        return $null
    }
    return $a
}

# Source and destination are single-choice. A checkbox list gives the technician the same
# row layout as everywhere else in the tool, so the ticks behave like radio buttons here.
function Select-OnlyOne([object]$Collection, [object]$Chosen) {
    if ($script:UserSelecting) { return }
    $script:UserSelecting = $true
    try {
        if ($Chosen.IsSelected) {
            foreach ($x in $Collection) { if (-not [object]::ReferenceEquals($x, $Chosen)) { $x.IsSelected = $false } }
        }
        # remember the pick, then refresh the OPPOSITE list so it drops this account.
        # Only the other view is refreshed - refreshing your own during its selection
        # change is what makes a CollectionView throw.
        $isSrc = [object]::ReferenceEquals($Collection, $script:SrcUsers)
        $pick = $(if ($Chosen.IsSelected) { '' + $Chosen.Name } else { '' })
        if ($isSrc) { $script:SrcPick = $pick } else { $script:DstPick = $pick }
        try {
            if ($isSrc) { $script:DstView.Refresh() } else { $script:SrcView.Refresh() }
        } catch {}
    } finally { $script:UserSelecting = $false }
    Update-UserEmptyStates
    Build-MigrateList
}

# Say what to do next instead of showing an empty box. With one account on the machine
# there is no destination yet, and that is exactly the moment to point at the form above.
function Update-UserEmptyStates {
    $nSrc = @($script:SrcView).Count
    $nDst = @($script:DstView).Count

    $EmptyAccounts.Visibility = $(if ($script:AccountItems.Count) { 'Collapsed' } else { 'Visible' })
    if (-not $script:AccountItems.Count) { $EmptyAccounts.Text = 'No local accounts found on this machine.' }
    # one button, two meanings - it must always say what it will actually do
    $selAcct = Get-SelectedAccount

    # the migrate list is empty for two very different reasons - say which
    $EmptyMigrate.Visibility = 'Collapsed'
    if ($script:MigrateItems.Count -eq 0) {
        $EmptyMigrate.Text = $(if ($script:SrcPick) {
                "Nothing to copy from `"$($script:SrcPick)`" - none of the usual data folders exist in that profile."
            } else { "Pick a profile under Copy FROM.`n`nIts folders appear here once selected." })
        $EmptyMigrate.Visibility = 'Visible'
    }

    $EmptySrc.Visibility = 'Collapsed'
    if ($nSrc -eq 0) {
        $EmptySrc.Text = $(if ($script:DstPick) {
                "`"$($script:DstPick)`" is the destination, so it cannot also be the source.`n`nUntick it on the right to choose it here instead."
            } else { 'No user profiles found on this machine.' })
        $EmptySrc.Visibility = 'Visible'
    }

    $EmptyDst.Visibility = 'Collapsed'
    if ($nDst -eq 0) {
        $EmptyDst.Text = $(if ($script:SrcPick) {
                "No other account to copy into.`n`nThis machine has only `"$($script:SrcPick)`", and a profile cannot be copied onto itself.`n`nCreate the new admin using the form above - it will appear here as soon as it exists."
            } else { 'No accounts found.' })
        $EmptyDst.Visibility = 'Visible'
    }
}

function Get-SelectedUser([object]$Collection) {
    return @($Collection | Where-Object { $_.IsSelected })[0]
}

# Rebuild the "what to copy" list for whichever source is selected: only folders that
# actually exist are shown, so the tech is never offered something that is not there.
function Build-MigrateList {
    $src = Get-SelectedUser $script:SrcUsers
    $script:MigrateItems.Clear()
    if (-not $src) {
        Update-Dash
        return
    }
    $root = [string]$src.UnArgs
    foreach ($d in $script:MigrateDefs) {
        $full = Join-Path $root $d.id
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $item = New-Object AppItem
        $item.Id = "mig-$($d.id)"
        $item.Name = $d.name
        $item.UnArgs = $d.id
        $item.Size = ''
        $item.IsSilent = [bool]$d.safe
        $item.Category = $(if ($d.safe) { 'What to copy   -   user data' } else { 'From AppData   -   pick deliberately' })
        $item.IconBg = $(if ($d.safe) { '#FF3D7EF0' } else { '#FFF59E0B' })
        $item.IsSelected = [bool]$d.safe
        $item.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'IsSelected') { Update-Dash } })
        $script:MigrateItems.Add($item)
    }
    Update-Dash
}

# ---------- customize preferences ----------
# These are TOGGLES, not one-shot tweaks: each has an on and an off state, and the tick
# shows what the machine is currently set to. Only preferences the technician actually
# CHANGES are applied, so opening the tab and pressing Apply never rewrites 25 settings.
#
# The table is defined ONCE, here, as source text. The GUI evaluates it for the checkbox
# states, and Start-Worker substitutes the same text into the worker script - so the
# elevated side owns its own copy of the definitions and the queue still carries nothing
# but an id and 'on'/'off'. One source, no drift, and the elevation boundary stays id-gated.
#
#   on / off : registry writes for each state. v = $null means DELETE the value, which is
#              how you restore a Windows default rather than guessing at its number.
#   test     : how to read the current state. abs = the answer when the value is absent,
#              which is what makes "default is on" settings report correctly on a fresh PC.
$script:PrefTableSource = @'
$script:PrefDefs = @(
    @{ id='bsodverbose'; name='BSOD Verbose Mode'
       on =@(@{p='HKLM\SYSTEM\CurrentControlSet\Control\CrashControl'; n='DisplayParameters'; v=1})
       off=@(@{p='HKLM\SYSTEM\CurrentControlSet\Control\CrashControl'; n='DisplayParameters'; v=0})
       test=@{p='HKLM\SYSTEM\CurrentControlSet\Control\CrashControl'; n='DisplayParameters'; v=1} }

    @{ id='darktheme'; name='Dark Theme for Windows'
       on =@(@{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; n='AppsUseLightTheme'; v=0},
             @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; n='SystemUsesLightTheme'; v=0})
       off=@(@{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; n='AppsUseLightTheme'; v=1},
             @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; n='SystemUsesLightTheme'; v=1})
       test=@{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; n='AppsUseLightTheme'; v=0} }

    @{ id='longpaths'; name='Enable Long Paths'
       on =@(@{p='HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'; n='LongPathsEnabled'; v=1})
       off=@(@{p='HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'; n='LongPathsEnabled'; v=0})
       test=@{p='HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'; n='LongPathsEnabled'; v=1} }

    @{ id='fileext'; name='File Explorer File Extensions'
       on =@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='HideFileExt'; v=0})
       off=@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='HideFileExt'; v=1})
       test=@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='HideFileExt'; v=0} }

    @{ id='hiddenfiles'; name='File Explorer Hidden Files'
       on =@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='Hidden'; v=1})
       off=@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='Hidden'; v=2})
       test=@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='Hidden'; v=1} }

    @{ id='gamemode'; name='Game Mode'
       on =@(@{p='HKCU\Software\Microsoft\GameBar'; n='AutoGameModeEnabled'; v=1},
             @{p='HKCU\Software\Microsoft\GameBar'; n='AllowAutoGameMode'; v=1})
       off=@(@{p='HKCU\Software\Microsoft\GameBar'; n='AutoGameModeEnabled'; v=0},
             @{p='HKCU\Software\Microsoft\GameBar'; n='AllowAutoGameMode'; v=0})
       test=@{p='HKCU\Software\Microsoft\GameBar'; n='AutoGameModeEnabled'; v=1; abs=$true} }

    @{ id='lockscreen'; name='Lock Screen - Disable'
       on =@(@{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization'; n='NoLockScreen'; v=1})
       off=@(@{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization'; n='NoLockScreen'; v=$null})
       test=@{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization'; n='NoLockScreen'; v=1} }

    @{ id='logonblur'; name='Logon Screen Acrylic Blur'
       on =@(@{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\System'; n='DisableAcrylicBackgroundOnLogon'; v=0})
       off=@(@{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\System'; n='DisableAcrylicBackgroundOnLogon'; v=1})
       test=@{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\System'; n='DisableAcrylicBackgroundOnLogon'; v=0; abs=$true} }

    @{ id='logonverbose'; name='Logon Verbose Mode'
       on =@(@{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; n='VerboseStatus'; v=1})
       off=@(@{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; n='VerboseStatus'; v=0})
       test=@{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; n='VerboseStatus'; v=1} }

    @{ id='newoutlook'; name='Microsoft Outlook New Version'
       on =@(@{p='HKCU\Software\Microsoft\Office\16.0\Outlook\Preferences'; n='UseNewOutlook'; v=1})
       off=@(@{p='HKCU\Software\Microsoft\Office\16.0\Outlook\Preferences'; n='UseNewOutlook'; v=0})
       test=@{p='HKCU\Software\Microsoft\Office\16.0\Outlook\Preferences'; n='UseNewOutlook'; v=1} }

    @{ id='mouseaccel'; name='Mouse Acceleration'
       on =@(@{p='HKCU\Control Panel\Mouse'; n='MouseSpeed'; v='1'; t='String'},
             @{p='HKCU\Control Panel\Mouse'; n='MouseThreshold1'; v='6'; t='String'},
             @{p='HKCU\Control Panel\Mouse'; n='MouseThreshold2'; v='10'; t='String'})
       off=@(@{p='HKCU\Control Panel\Mouse'; n='MouseSpeed'; v='0'; t='String'},
             @{p='HKCU\Control Panel\Mouse'; n='MouseThreshold1'; v='0'; t='String'},
             @{p='HKCU\Control Panel\Mouse'; n='MouseThreshold2'; v='0'; t='String'})
       test=@{p='HKCU\Control Panel\Mouse'; n='MouseSpeed'; v='1'; abs=$true} }

    @{ id='mpo'; name='Multiplane Overlay'
       on =@(@{p='HKLM\SOFTWARE\Microsoft\Windows\Dwm'; n='OverlayTestMode'; v=$null})
       off=@(@{p='HKLM\SOFTWARE\Microsoft\Windows\Dwm'; n='OverlayTestMode'; v=5})
       test=@{p='HKLM\SOFTWARE\Microsoft\Windows\Dwm'; n='OverlayTestMode'; v=$null; abs=$true} }

    @{ id='numlock'; name='Num Lock on Startup'
       on =@(@{p='Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard'; n='InitialKeyboardIndicators'; v='2'; t='String'},
             @{p='HKCU\Control Panel\Keyboard'; n='InitialKeyboardIndicators'; v='2'; t='String'})
       off=@(@{p='Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard'; n='InitialKeyboardIndicators'; v='0'; t='String'},
             @{p='HKCU\Control Panel\Keyboard'; n='InitialKeyboardIndicators'; v='0'; t='String'})
       test=@{p='Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard'; n='InitialKeyboardIndicators'; v='2'} }

    @{ id='s0network'; name='S0 Sleep Network Connectivity'
       on =@(@{p='HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\F15576E8-98B7-4186-B944-EAFA664402D9'; n='ACSettingIndex'; v=1},
             @{p='HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\F15576E8-98B7-4186-B944-EAFA664402D9'; n='DCSettingIndex'; v=1})
       off=@(@{p='HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\F15576E8-98B7-4186-B944-EAFA664402D9'; n='ACSettingIndex'; v=0},
             @{p='HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\F15576E8-98B7-4186-B944-EAFA664402D9'; n='DCSettingIndex'; v=0})
       test=@{p='HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\F15576E8-98B7-4186-B944-EAFA664402D9'; n='ACSettingIndex'; v=1; abs=$true} }

    @{ id='s3sleep'; name='S3 Sleep'
       on =@(@{p='HKLM\SYSTEM\CurrentControlSet\Control\Power'; n='PlatformAoAcOverride'; v=0})
       off=@(@{p='HKLM\SYSTEM\CurrentControlSet\Control\Power'; n='PlatformAoAcOverride'; v=$null})
       test=@{p='HKLM\SYSTEM\CurrentControlSet\Control\Power'; n='PlatformAoAcOverride'; v=0} }

    @{ id='scrollbars'; name='Scrollbars Always Visible'
       on =@(@{p='HKCU\Control Panel\Accessibility'; n='DynamicScrollbars'; v=0})
       off=@(@{p='HKCU\Control Panel\Accessibility'; n='DynamicScrollbars'; v=1})
       test=@{p='HKCU\Control Panel\Accessibility'; n='DynamicScrollbars'; v=0} }

    @{ id='settingshome'; name='Settings Home Page'
       on =@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; n='SettingsPageVisibility'; v=$null})
       off=@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; n='SettingsPageVisibility'; v='hide:home'; t='String'})
       test=@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; n='SettingsPageVisibility'; v=$null; abs=$true} }

    @{ id='bingsearch'; name='Start Menu Bing Search'
       on =@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search'; n='BingSearchEnabled'; v=1})
       off=@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search'; n='BingSearchEnabled'; v=0})
       test=@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search'; n='BingSearchEnabled'; v=1; abs=$true} }

    @{ id='startrecommend'; name='Start Menu Recommendations'
       on =@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='Start_IrisRecommendations'; v=1})
       off=@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='Start_IrisRecommendations'; v=0})
       test=@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='Start_IrisRecommendations'; v=1; abs=$true} }

    @{ id='stickykeys'; name='Sticky Keys'
       on =@(@{p='HKCU\Control Panel\Accessibility\StickyKeys'; n='Flags'; v='510'; t='String'})
       off=@(@{p='HKCU\Control Panel\Accessibility\StickyKeys'; n='Flags'; v='506'; t='String'})
       test=@{p='HKCU\Control Panel\Accessibility\StickyKeys'; n='Flags'; v='510'; abs=$true} }

    @{ id='batterypct'; name='System Tray Battery Percentage'
       on =@(@{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='ShowBatteryPercentage'; v=1})
       off=@(@{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='ShowBatteryPercentage'; v=0})
       test=@{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='ShowBatteryPercentage'; v=1} }

    @{ id='taskbarcenter'; name='Taskbar Centered Icons'
       on =@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='TaskbarAl'; v=1})
       off=@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='TaskbarAl'; v=0})
       test=@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='TaskbarAl'; v=1; abs=$true} }

    @{ id='taskbarsearch'; name='Taskbar Search Icon'
       on =@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search'; n='SearchboxTaskbarMode'; v=1})
       off=@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search'; n='SearchboxTaskbarMode'; v=0})
       test=@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search'; n='SearchboxTaskbarMode'; v=@(1,2,3); abs=$true} }

    @{ id='taskview'; name='Taskbar Task View Icon'
       on =@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='ShowTaskViewButton'; v=1})
       off=@(@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='ShowTaskViewButton'; v=0})
       test=@{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='ShowTaskViewButton'; v=1; abs=$true} }

    @{ id='windowsnap'; name='Window Snapping'
       on =@(@{p='HKCU\Control Panel\Desktop'; n='WindowArrangementActive'; v='1'; t='String'})
       off=@(@{p='HKCU\Control Panel\Desktop'; n='WindowArrangementActive'; v='0'; t='String'})
       test=@{p='HKCU\Control Panel\Desktop'; n='WindowArrangementActive'; v='1'; abs=$true} }
)
'@
Invoke-Expression $script:PrefTableSource

# Reads a preference's live state. 'abs' carries the answer for a value that is not there
# at all, which is the normal case for anything Windows ships enabled by default - without
# it every untouched setting would read as off.
function Test-Pref([hashtable]$T) {
    $val = Get-RegVal $T.p $T.n
    if ($null -eq $val) { return [bool]$T.abs }
    if ($null -eq $T.v) { return (-not [bool]$T.abs) }
    foreach ($opt in @($T.v)) { if ("$val" -eq "$opt") { return $true } }
    return $false
}

function Load-Prefs {
    $script:PrefItems.Clear()
    foreach ($d in $script:PrefDefs) {
        $item = New-Object AppItem
        $item.Id = "pref-$($d.id)"
        $item.Name = $d.name
        $item.Size = ''
        $item.Publisher = 'Preference'
        $item.UnArgs = $d.id
        $item.IsSilent = $true
        $item.Category = 'Customize Preferences'
        $item.IconBg = '#FF34D399'
        $item.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'IsSelected') { Update-Dash } })
        $script:PrefItems.Add($item)
    }
    Sync-Prefs
    Add-Log "Preferences loaded: $($script:PrefItems.Count) toggles, set from this machine's current state."
}

# Point every toggle at what the machine actually says right now, and remember that reading
# in OrigState. Called on load, from Detect, from Clear and after a batch - so "pending
# changes" always means changes YOU made since the last real read.
function Sync-Prefs {
    $script:PrefSyncing = $true
    $script:SuspendDash = $true
    try {
        foreach ($item in $script:PrefItems) {
            $d = @($script:PrefDefs | Where-Object { $_.id -eq $item.UnArgs })[0]
            if (-not $d) { continue }
            $state = $false
            try { $state = Test-Pref $d.test } catch { $state = $false }
            $item.OrigState = $(if ($state) { 'on' } else { 'off' })
            $item.IsSelected = $state
            Set-Status $item '' 'neutral'
            Set-Ring $item 'none'
        }
    } finally {
        $script:PrefSyncing = $false
        $script:SuspendDash = $false
    }
}

# A preference is only work if its tick no longer matches what the machine said.
# This is compared against the CACHED reading, never the live registry: it runs from
# Update-Dash, which fires on every checkbox change, and re-reading 25 values per tick
# made a preset click (38 changes) do nearly a thousand registry reads and freeze the tab.
function Get-PendingPrefs {
    $out = @()
    foreach ($item in $script:PrefItems) {
        if (-not $item.OrigState) { continue }
        if (($item.OrigState -eq 'on') -ne [bool]$item.IsSelected) { $out += $item }
    }
    return @($out)
}

# ---------- presets ----------
# Hand-ticking 38 rows on every client is how a technician ends up applying the wrong set.
# IPv6 - Disable and IPv6 Set IPv4 as Preferred write the SAME registry value to different
# numbers, so no preset may ever contain both.
$script:TweakPresets = @{
    # safe on any machine: privacy and disk, nothing that changes how Windows behaves
    Minimal  = @('restorepoint', 'telemetry', 'activityhistory', 'consumerfeatures',
                 'deliveryopt', 'location', 'wpbt', 'tempfiles')
    # the recommended build: every Essential plus the advanced items that are reversible
    # and well understood
    Standard = @('restorepoint', 'activityhistory', 'bitlocker', 'consumerfeatures', 'deliveryopt',
                 'diskcleanup', 'endtask', 'folderdiscovery', 'hibernation', 'location',
                 'storesearch', 'devicecompanion', 'servicesmanual', 'startlayout', 'telemetry',
                 'tempfiles', 'widgets', 'wpbt',
                 'backgroundapps', 'storagesense', 'explorerhome', 'rightclickmenu', 'visualeffects')
    # everything, minus ipv4prefer because ipv6disable is the stronger form of the same setting
    Advanced = @($script:TweakDefs | ForEach-Object { $_.id } | Where-Object { $_ -ne 'ipv4prefer' })
}

function Select-TweakPreset([string]$Name) {
    $ids = @($script:TweakPresets[$Name])
    # one dashboard refresh for the whole preset, not one per row
    $script:SuspendDash = $true
    try {
        foreach ($t in $script:TweakItems) { $t.IsSelected = ($ids -contains $t.UnArgs) }
    } finally { $script:SuspendDash = $false }
    $n = @($script:TweakItems | Where-Object { $_.IsSelected }).Count
    $risky = @($script:TweakItems | Where-Object { $_.IsSelected -and -not $_.IsSilent }).Count
    $TxtTweakHint.Text = "$Name preset: $n selected ($risky in CAUTION)"
    Add-Log "$Name preset selected: $n tweak(s), $risky from the CAUTION group."
    Update-Dash
}

# ---------- detection ----------
# Reads the machine's current state to show what is ALREADY applied. Runs in the GUI,
# unelevated: HKLM and service state read fine without admin, and HKCU here is the
# technician's own hive - which is exactly the profile the per-user tweaks target.
# $null means "not a state, an action" (Disk Cleanup, Temp Files, Restore Point) - those
# can never be reported as applied, so they are left alone rather than guessed at.
function Get-RegVal([string]$Path, [string]$Name) {
    try {
        $p = ConvertTo-PSRegPath $Path
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        return (Get-ItemProperty -LiteralPath $p -Name $Name -ErrorAction Stop).$Name
    } catch { return $null }
}
function Test-RegVal([string]$Path, [string]$Name, $Expected) {
    $v = Get-RegVal $Path $Name
    if ($null -eq $v) { return $false }
    return ("$v" -eq "$Expected")
}

$script:TweakTests = @{
    activityhistory = { Test-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0 }
    bitlocker       = { Test-RegVal 'HKLM\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 1 }
    consumerfeatures= { Test-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 }
    deliveryopt     = { Test-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0 }
    diskcleanup     = { $null }
    endtask         = { Test-RegVal 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 1 }
    folderdiscovery = { Test-RegVal 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' 'FolderType' 'NotSpecified' }
    hibernation     = { Test-RegVal 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 0 }
    location        = { Test-RegVal 'HKLM\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration' 'Status' 0 }
    storesearch     = { Test-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 }
    devicecompanion = { Test-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1 }
    restorepoint    = { $null }
    # Only the services that ship as Automatic can prove the tweak ran - the rest are
    # Manual out of the box, so finding them Manual proves nothing.
    servicesmanual  = { $auto = @('DiagTrack', 'MapsBroker', 'PcaSvc', 'TrkWks', 'iphlpsvc')
                        $present = 0; $moved = 0
                        foreach ($n in $auto) {
                            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
                            if (-not $s) { continue }
                            $present++
                            if ($s.StartType -ne 'Automatic') { $moved++ }
                        }
                        if ($present -eq 0) { return $false }
                        return ($moved * 2 -ge $present) }
    startlayout     = { Test-RegVal 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_ShowClassicMode' 1 }
    telemetry       = { Test-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0 }
    tempfiles       = { $null }
    widgets         = { Test-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 }
    wpbt            = { Test-RegVal 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1 }
    adobeblock      = { $h = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
                        if (-not (Test-Path -LiteralPath $h)) { return $false }
                        return [bool](@(Get-Content -LiteralPath $h -ErrorAction SilentlyContinue) -match 'PC2Go Adobe block list') }
    backgroundapps  = { Test-RegVal 'HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1 }
    bravedebloat    = { Test-RegVal 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveRewardsDisabled' 1 }
    utctime         = { Test-RegVal 'HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal' 1 }
    reservedstorage = { $v = Get-RegVal 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves'
                        if ($null -eq $v) { return $false }
                        return ("$v" -eq '0') }
    # The child key being absent only means something if the PARENT exists - on Windows 10
    # and older Windows 11 builds NameSpace_36354489 is not there at all, and treating that
    # as "already applied" would tick a tweak that was never run.
    explorerhome    = { $parent = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_36354489'
                        if (-not (Test-Path -LiteralPath $parent)) { return $false }
                        return (-not (Test-Path -LiteralPath (Join-Path $parent '{f874310e-b6b7-47dc-bc84-b9e6b38f5903}'))) }
    fullscreenopt   = { Test-RegVal 'HKCU\System\GameConfigStore' 'GameDVR_FSEBehavior' 2 }
    ipv6disable     = { Test-RegVal 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 255 }
    ipv4prefer      = { Test-RegVal 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 32 }
    edgedebloat     = { Test-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'PersonalizationReportingEnabled' 0 }
    edgeremove      = { -not (Test-Path -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')) }
    # OneDrive installs per-user OR per-machine depending on the build, so both have to be
    # absent before calling it removed - one missing path alone proves nothing.
    onedriveremove  = { if (Test-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1) { return $true }
                        $paths = @((Join-Path $env:LocalAppData 'Microsoft\OneDrive\OneDrive.exe'),
                                   (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'),
                                   (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive\OneDrive.exe'))
                        return -not (@($paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) }).Count) }
    razerdisable    = { Test-RegVal 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0 }
    rdpwarnings     = { Test-RegVal 'HKCU\Software\Microsoft\Terminal Server Client' 'AuthenticationLevelOverride' 0 }
    rightclickmenu  = { Test-Path -LiteralPath 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' }
    storagesense    = { Test-RegVal 'HKCU\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 0 }
    traynotify      = { Test-RegVal 'HKCU\Software\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1 }
    teredo          = { Test-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\TCPIP\v6Transition' 'Teredo_State' 'Disabled' }
    visualeffects   = { Test-RegVal 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2 }
    windowsai       = { Test-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 }
}

function Invoke-TweakDetect {
    $applied = 0; $notDetectable = 0
    foreach ($t in $script:TweakItems) {
        $test = $script:TweakTests[$t.UnArgs]
        $res = $null
        if ($test) { try { $res = & $test } catch { $res = $null } }
        if ($null -eq $res) {
            # one-shot action, not a state - never claim it is applied
            $t.IsSelected = $false
            Set-Status $t 'one-time action - cannot be detected' 'neutral'
            $notDetectable++
        } elseif ($res) {
            $t.IsSelected = $true
            Set-Status $t 'already applied' 'ok'
            $applied++
        } else {
            $t.IsSelected = $false
            Set-Status $t '' 'neutral'
        }
    }
    # the toggles are a live read of the machine too, so refresh them in the same pass
    Sync-Prefs
    $TxtTweakHint.Text = "$applied already applied, $notDetectable not detectable"
    Add-Log "Detect: $applied tweak(s) already applied on this machine, $notDetectable are one-time actions that cannot be detected. Preferences re-read."
    Update-Dash
}

# Account creation and profile copying both need admin, so they ride the same single-UAC
# worker queue as everything else. One row stands in for the whole operation.
function Start-UserBatch([string]$Action, [hashtable]$Data) {
    $row = New-Object AppItem
    $row.Id = "user-$Action"
    $row.Name = switch ($Action) {
        'newuser'       { "Create account `"$($Data.username)`"" }
        'migrate'       { "Copy profile data to `"$($Data.dstUser)`"" }
        'setadmin'      { $(if ($Data.admin) { "Promote `"$($Data.username)`" to Administrator" } else { "Demote `"$($Data.username)`" to Standard" }) }
        'setpassword'   { "Set password for `"$($Data.username)`"" }
        'toggleacct'    { $(if ($Data.enable) { "Enable `"$($Data.username)`"" } else { "Disable `"$($Data.username)`"" }) }
        'deleteaccount' { "Delete account `"$($Data.username)`"" }
        default         { $Action }
    }
    $row.Category = 'Users'
    $row.IconBg = '#FF3D7EF0'
    Set-Status $row 'Queued' 'neutral'
    Set-Ring $row 'busy'
    $script:UserRow = $row
    $script:Pending = @($row)
    $script:BatchTab = 'Users'
    $script:HadFailures = $false
    $script:WorkerStarted = $false
    $script:EndQueued = $false
    $script:Paused = $false
    $script:AwaitingScan = $false
    Remove-Item -LiteralPath $script:QueuePath, $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
    if (-not (Start-Worker)) {
        Abort-Batch 'elevation declined'
        return
    }
    $entry = @{ id = $row.Id; action = $Action } + $Data | ConvertTo-Json -Compress -Depth 4
    Add-Content -Path $script:QueuePath -Value $entry -Encoding UTF8
    Add-Content -Path $script:QueuePath -Value '{"end":true}' -Encoding UTF8
    $script:EndQueued = $true
    $script:Phase = 'Install'
    $BtnMigrate.IsEnabled = $false
    $BtnNewAccount.IsEnabled = $false
    $BtnInstall.IsEnabled = $false
    $BtnCancel.Visibility = 'Visible'
    $TxtNow.Text = $row.Name
    $DotNow.Fill = '#FF4C8DFF'
    $RowNow.Visibility = 'Visible'
    $TxtStatus.Text = $(if ($Action -eq 'newuser') { 'Creating account...' } else { 'Copying profile data...' })
    Add-Log "$($row.Name) - started."
}

# Several elevated steps behind ONE UAC prompt. The worker already consumes the queue in
# order, so a chain is just N entries before the end marker - each gets its own row and
# reports its own result, and a step that fails does not silently take the rest with it.
# One row per program, so each reports its own rule count. The queue carries only the app
# name and its install folder - the elevated worker does the exe enumeration and re-checks
# the protected-path rules itself rather than trusting a list of paths off the queue.
function Start-FwBatch([string]$Action, [object[]]$Sel) {
    foreach ($s in $Sel) { Set-Status $s 'Queued' 'neutral'; Set-Ring $s 'queued' }
    $script:Pending = @($Sel)
    $script:BatchTab = 'Fw'
    $script:HadFailures = $false
    $script:WorkerStarted = $false
    $script:EndQueued = $false
    $script:Paused = $false
    $script:AwaitingScan = $false
    Remove-Item -LiteralPath $script:QueuePath, $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
    if (-not (Start-Worker)) {
        Abort-Batch 'elevation declined'
        return
    }
    foreach ($s in $Sel) {
        # Unmatched rows live under shared roots the worker's Test-FwRoot refuses by design,
        # so they are removed by explicit rule NAME instead. The worker re-verifies each named
        # rule is an outbound Block rule before touching it.
        $entry = $(if ($Action -eq 'fwunblock' -and $s.RegKey -eq 'unmatched') {
                       @{ id = $s.Id; action = 'fwunblockrules'; app = [string]$s.Name
                          rules = @($s.CleanTokens); folder = [string]$s.UnArgs; group = $script:FwGroup }
                   } else {
                       @{ id = $s.Id; action = $Action; app = [string]$s.Name
                          publisher = [string]$s.Version; build = $BuildTag
                          root = [string]$s.UnArgs; group = $script:FwGroup }
                   }) | ConvertTo-Json -Compress -Depth 4
        Add-Content -Path $script:QueuePath -Value $entry -Encoding UTF8
    }
    Add-Content -Path $script:QueuePath -Value '{"end":true}' -Encoding UTF8
    $script:EndQueued = $true
    $script:Phase = 'Install'
    $BtnFwBlock.IsEnabled = $false
    $BtnFwUnblock.IsEnabled = $false
    $BtnInstall.IsEnabled = $false
    $BtnCancel.Visibility = 'Visible'
    $TxtNow.Text = $(if ($Action -eq 'fwblock') { 'Adding firewall rules...' } else { 'Removing firewall rules...' })
    $DotNow.Fill = '#FF4C8DFF'
    $RowNow.Visibility = 'Visible'
    $TxtStatus.Text = $TxtNow.Text
    $script:FwDirty = $true
    Add-Log "Firewall batch: $Action for $($Sel.Count) program(s)."
}

function Start-UserChain([object[]]$Steps) {
    $rows = @()
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $row = New-Object AppItem
        $row.Id = "chain$($i + 1)"
        $row.Name = [string]$Steps[$i].label
        $row.Category = 'Users'
        $row.IconBg = '#FF3D7EF0'
        Set-Status $row 'Queued' 'neutral'
        Set-Ring $row 'queued'
        $rows += $row
    }
    $script:Pending = $rows
    $script:BatchTab = 'Users'
    $script:HadFailures = $false
    $script:WorkerStarted = $false
    $script:EndQueued = $false
    $script:Paused = $false
    $script:AwaitingScan = $false
    Remove-Item -LiteralPath $script:QueuePath, $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
    if (-not (Start-Worker)) {
        Abort-Batch 'elevation declined'
        return
    }
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $entry = (@{ id = "chain$($i + 1)"; action = [string]$Steps[$i].action } + $Steps[$i].data) | ConvertTo-Json -Compress -Depth 4
        Add-Content -Path $script:QueuePath -Value $entry -Encoding UTF8
    }
    Add-Content -Path $script:QueuePath -Value '{"end":true}' -Encoding UTF8
    $script:EndQueued = $true
    $script:Phase = 'Install'
    $BtnMigrate.IsEnabled = $false
    $BtnNewAccount.IsEnabled = $false
    $BtnInstall.IsEnabled = $false
    $BtnCancel.Visibility = 'Visible'
    $TxtNow.Text = $rows[0].Name
    $DotNow.Fill = '#FF4C8DFF'
    $RowNow.Visibility = 'Visible'
    $TxtStatus.Text = "Running $($Steps.Count) step(s)..."
    Add-Log "User chain started: $($Steps.Count) step(s) - $((@($Steps | ForEach-Object { $_.action })) -join ' -> ')."
}

function Start-TweakUndo([object[]]$Sel) {
    foreach ($s in $Sel) { Set-Status $s 'Queued' 'neutral'; Set-Ring $s 'queued' }
    $script:Pending = @($Sel)
    $script:BatchTab = 'Tweak'
    $script:HadFailures = $false
    $script:WorkerStarted = $false
    $script:EndQueued = $false
    $script:Paused = $false
    $script:AwaitingScan = $false
    Remove-Item -LiteralPath $script:QueuePath, $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
    if (-not (Start-Worker)) {
        Abort-Batch 'elevation declined'
        return
    }
    $sid = ''
    try { $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value } catch {}
    foreach ($s in $Sel) {
        $entry = @{ id = $s.Id; action = 'untweak'; tweak = $s.UnArgs; userSid = $sid } | ConvertTo-Json -Compress
        Add-Content -Path $script:QueuePath -Value $entry -Encoding UTF8
    }
    Add-Content -Path $script:QueuePath -Value '{"end":true}' -Encoding UTF8
    $script:EndQueued = $true
    $script:Phase = 'Install'
    $BtnTweakApply.IsEnabled = $false
    $BtnTweakUndo.IsEnabled = $false
    $BtnInstall.IsEnabled = $false
    $BtnUninstall.IsEnabled = $false
    $BtnRefresh.IsEnabled = $false
    $BtnCancel.Visibility = 'Visible'
    $TxtStatus.Text = 'Undoing tweaks...'
    $TxtNow.Text = 'Undoing tweaks...'
    $DotNow.Fill = '#FF4C8DFF'
    Add-Log "Tweak undo started: $($Sel.Count) tweak(s)."
}

function Start-Tweaks([object[]]$Sel) {
    # A restore point is the undo button for everything else here, so if it was selected
    # it is queued FIRST - after the other tweaks have run it would be worthless.
    $ordered = @($Sel | Where-Object { $_.UnArgs -eq 'restorepoint' }) +
               @($Sel | Where-Object { $_.UnArgs -ne 'restorepoint' })
    foreach ($s in $ordered) { Set-Status $s 'Queued' 'neutral'; Set-Ring $s 'queued' }
    $script:Pending = $ordered
    $script:BatchTab = 'Tweak'
    $script:HadFailures = $false
    $script:WorkerStarted = $false
    $script:EndQueued = $false
    $script:Paused = $false
    $script:AwaitingScan = $false
    Remove-Item -LiteralPath $script:QueuePath, $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
    if (-not (Start-Worker)) {
        Abort-Batch 'elevation declined'
        return
    }
    # The worker runs elevated and may be a DIFFERENT account than the technician's, so
    # HKCU inside it is the wrong hive. Pass the invoking user's SID and let the worker
    # write per-user tweaks into HKEY_USERS\<sid> explicitly.
    $sid = ''
    try { $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value } catch {}
    foreach ($s in $ordered) {
        $entry = $(if ($s.Publisher -eq 'Preference') {
                       @{ id = $s.Id; action = 'pref'; pref = $s.UnArgs
                          state = $(if ($s.IsSelected) { 'on' } else { 'off' }); userSid = $sid }
                   } else {
                       @{ id = $s.Id; action = 'tweak'; tweak = $s.UnArgs; userSid = $sid }
                   }) | ConvertTo-Json -Compress
        Add-Content -Path $script:QueuePath -Value $entry -Encoding UTF8
    }
    Add-Content -Path $script:QueuePath -Value '{"end":true}' -Encoding UTF8
    $script:EndQueued = $true
    $script:Phase = 'Install'
    $BtnTweakApply.IsEnabled = $false
    $BtnInstall.IsEnabled = $false
    $BtnUninstall.IsEnabled = $false
    $BtnRefresh.IsEnabled = $false
    $BtnCancel.Visibility = 'Visible'
    $TxtStatus.Text = 'Applying tweaks...'
    $TxtNow.Text = 'Applying tweaks...'
    $DotNow.Fill = '#FF4C8DFF'
    Add-Log "Tweak batch started: $($ordered.Count) tweak(s)."
}

# Synchronous resumable HTTP download - fallback when the BITS service is unavailable
# Fallback for machines where BITS is unavailable (service disabled by policy, etc).
# BITS gets resume for free; here it has to be built, and three things are load-bearing:
#
#   A short read is NOT end-of-file. A dropped link makes .NET's Read() return 0 exactly
#   like a clean EOF, so without comparing bytes received against Content-Length the loop
#   exits happily and the partial file is promoted to the final name - destroying the
#   .part that resume depends on. A 13 GB download then restarts from zero.
#
#   A stalled socket is worse than a dropped one. Without ReadWriteTimeout a half-open
#   connection blocks Read() forever, and the batch sits at "Downloading 92%" with no
#   error to report and nothing to retry.
#
#   Retry belongs here, not in the caller. The .part file survives between attempts, so
#   each retry resumes instead of restarting.
function Invoke-ResumableDownload([object]$Item, [string]$Dest) {
    $tmp = "$Dest.part"
    $maxAttempts = 5

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $existing = 0
        if (Test-Path $tmp) { $existing = (Get-Item $tmp).Length }

        try {
            $req = [Net.HttpWebRequest]::Create($Item.Url)
            $req.UserAgent = 'PC2GoDeploy/1.0'
            $req.Timeout = 60000            # connect + response headers
            $req.ReadWriteTimeout = 120000  # per-read; kills a half-open socket
            if ($existing -gt 0) { $req.AddRange($existing) }
            $resp = $req.GetResponse()
            try {
                $append = ($existing -gt 0 -and [int]$resp.StatusCode -eq 206)
                if (-not $append) { $existing = 0 }
                $len = $resp.ContentLength
                $total = 0
                if ($len -ge 0) { $total = $len + $existing }
                $mode = 'Create'; if ($append) { $mode = 'Append' }
                $fs = [IO.File]::Open($tmp, $mode)
                $stream = $resp.GetResponseStream()
                try {
                    $buf = New-Object byte[] 1048576
                    $done = $existing; $i = 0
                    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                        $fs.Write($buf, 0, $n); $done += $n
                        if ((++$i % 4) -eq 0) {
                            $pct = 0; if ($total -gt 0) { $pct = [math]::Floor($done * 100 / $total) }
                            Set-Status $Item "Downloading $pct%" 'active'
                            $Item.ProgressVis = 'Visible'
                            $Item.Progress = $pct
                            Update-Overall $pct
                            Update-UI
                        }
                    }
                } finally { $fs.Close(); $stream.Close() }
            } finally { $resp.Close() }

            # The check that turns a silent truncation into a retryable error.
            #
            # The catalog outranks Content-Length. A truncating proxy, a half-finished
            # upload, or the wrong file behind the URL all report a Content-Length that
            # agrees with the short body they send, so believing the server means
            # promoting a partial file as complete. sizeBytes is what we published and
            # what the SHA-256 was taken over, so it is the size that must arrive.
            $expected = $total
            if ($Item.SizeBytes -gt 0) { $expected = [long]$Item.SizeBytes }
            $actual = (Get-Item $tmp).Length
            if ($expected -gt 0 -and $actual -ne $expected) {
                throw "Incomplete download: got $actual of $expected bytes."
            }

            Move-Item -LiteralPath $tmp -Destination $Dest -Force
            return
        } catch {
            # A 403/401 means this URL is dead, not that the server is busy - a signed
            # link that aged out cannot be fixed by waiting, and retrying it just burns
            # every remaining attempt. Mint a fresh URL once, then carry on resuming from
            # the same .part file.
            $we = $_.Exception
            while ($we -and -not ($we -is [Net.WebException])) { $we = $we.InnerException }
            $code = 0
            if ($we -and $we.Response) { $code = [int]$we.Response.StatusCode }

            if (($code -eq 403 -or $code -eq 401) -and -not $script:UrlRefreshed[$Item.Id]) {
                $script:UrlRefreshed[$Item.Id] = $true
                $fresh = Get-FreshCatalogUrl $Item
                if ($fresh) {
                    Add-Log "$($Item.Name): download link had expired - refreshed, resuming."
                    Set-Status $Item 'Link expired - refreshing' 'warn'
                    Update-UI
                    $Item.Url = $fresh
                    $attempt--   # the refresh is not one of the caller's retries
                    continue
                }
            }

            if ($attempt -ge $maxAttempts) { throw }
            $wait = [math]::Min(30, [math]::Pow(2, $attempt))
            $keep = 0; if (Test-Path $tmp) { $keep = (Get-Item $tmp).Length }
            Set-Status $Item "Retrying in ${wait}s (kept $([math]::Round($keep/1MB,1)) MB)" 'active'
            Update-UI
            Start-Sleep -Seconds $wait
        }
    }
}

function Update-Overall([int]$CurrentPct) {
    $total = $script:Pending.Count
    if ($total -eq 0) { return }
    $BarOverall.Value = [math]::Min(100, (($script:DlIndex * 100) + $CurrentPct) / $total)
    $TxtOverall.Text = "$([math]::Floor($BarOverall.Value))%   -   app $([math]::Min($script:DlIndex + 1, $total)) of $total"
}

# ---------- elevated worker (single UAC prompt, pipelined with downloads) ----------
# Launched once, right after the FIRST download completes. Consumes a streaming
# queue file: the GUI appends one JSON line per finished download, then a final
# {"end":true} line. Each file's SHA-256 is verified inside the elevated context
# immediately before execution, so installs overlap the remaining downloads
# without weakening integrity checking.
$workerScript = @'
param([string]$QueueFile, [string]$StatusFile, [string]$CancelFile)
$ErrorActionPreference = 'Continue'

# One JSON line per event, appended and never rewritten. It lives beside the status file
# in the cache folder, which self-deletes on a clean run and is deliberately KEPT after a
# failure - so the log survives exactly when someone needs to ask what happened.
$script:ActivityLog = Join-Path (Split-Path -Parent $StatusFile) 'activity.jsonl'

function Write-Activity([string]$Id, [string]$Phase, [string]$State, [string]$Detail) {
    try {
        $rec = [ordered]@{
            t      = (Get-Date).ToString('o')
            id     = $Id
            phase  = $Phase
            state  = $State
            detail = $Detail
        }
        Add-Content -LiteralPath $script:ActivityLog -Value ($rec | ConvertTo-Json -Compress) -Encoding UTF8
    } catch { }   # logging must never be the reason an install fails
}

# Every abnormal ending arrives as a single number, and reporting it raw tells a technician
# nothing. The distinction that matters is not success versus failure - it is whether the
# machine was LEFT DIRTY, because only then is there anything to roll back.
#
#   -1 (0xFFFFFFFF) is what TerminateProcess leaves behind: Task Manager's End Task, an
#   antivirus killing the installer, or a crash. It always means files were already being
#   written, so it is the dirtiest outcome of all.
#
#   1223 (UAC declined) is the opposite - nothing ran, nothing to clean.
#
# Unknown codes are assumed dirty. Cleaning a machine that did not need it costs a scan;
# leaving a half-installed product costs a support call.
# WHERE DID IT LAND? Answered by comparing the machine with itself, not by guessing from the
# app's name.
#
# The obvious tool is FileSystemWatcher, and it is the wrong one: an installer writing tens of
# thousands of files overruns its buffer and events are dropped SILENTLY, so the record would
# be quietly incomplete - worse than none, because it would still be trusted. A before/after
# snapshot of TOP-LEVEL DIRECTORIES cannot drop anything. It is a few hundred names per root,
# it takes milliseconds, and a product that installed itself always leaves a new folder in one
# of these places.
#
# What it cannot do is say what a file USED to contain, so it can undo a creation but never an
# overwrite. That is what a System Restore point is for.
$script:WatchRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
                       $env:LocalAppData, $env:AppData)
# a test seam, so the harness can point this at a sandbox instead of the real machine
if ($env:PC2GO_WATCH_ROOTS) { $script:WatchRoots = @($env:PC2GO_WATCH_ROOTS -split ';' | Where-Object { $_ }) }

function Get-DirSnapshot {
    $set = @{}
    foreach ($r in $script:WatchRoots) {
        if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue)) {
            $set[$d.FullName.ToLower()] = $d.FullName
        }
    }
    return $set
}

function Get-CreatedDirs($before) {
    $after = Get-DirSnapshot
    return @($after.Keys | Where-Object { -not $before.ContainsKey($_) } | ForEach-Object { $after[$_] })
}

function Get-InstallVerdict([int]$Code) {
    switch ($Code) {
        0     { return @{ Ok = $true;  Dirty = $false; Retry = $false; State = 'Done';      Text = 'installed' } }
        3010  { return @{ Ok = $true;  Dirty = $false; Retry = $false; State = 'Done';      Text = 'installed, reboot required' } }
        1641  { return @{ Ok = $true;  Dirty = $false; Retry = $false; State = 'Done';      Text = 'installed, reboot initiated' } }
        1223  { return @{ Ok = $false; Dirty = $false; Retry = $false; State = 'Blocked';   Text = 'the UAC prompt was declined' } }
        1618  { return @{ Ok = $false; Dirty = $false; Retry = $true;  State = 'Busy';      Text = 'another installation is already running' } }
        1619  { return @{ Ok = $false; Dirty = $false; Retry = $false; State = 'Failed';    Text = 'the package could not be opened' } }
        1620  { return @{ Ok = $false; Dirty = $false; Retry = $false; State = 'Failed';    Text = 'the package could not be verified' } }
        1602  { return @{ Ok = $false; Dirty = $true;  Retry = $false; State = 'Cancelled'; Text = 'cancelled inside the installer' } }
        1603  { return @{ Ok = $false; Dirty = $true;  Retry = $false; State = 'Failed';    Text = 'fatal error during installation' } }
        -1    { return @{ Ok = $false; Dirty = $true;  Retry = $false; State = 'Killed';    Text = 'the installer was terminated (Task Manager, antivirus, or a crash)' } }
        default { return @{ Ok = $false; Dirty = $true; Retry = $false; State = 'Failed';   Text = "installer exit code $Code" } }
    }
}

# Restart Manager is how installers answer "which process has this file open?" - the
# same API behind the "close these applications to continue" prompt. Far more reliable
# than guessing from process paths, and it sees DLLs loaded into other processes.
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class Unlocker {
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool MoveFileEx(string existing, string newName, int flags);

    public static int[] WhoIsLocking(string path) {
        uint handle; var key = Guid.NewGuid().ToString();
        var ids = new List<int>();
        if (RmStartSession(out handle, 0, key) != 0) return ids.ToArray();
        try {
            if (RmRegisterResources(handle, 1, new[] { path }, 0, null, 0, null) != 0) return ids.ToArray();
            uint needed = 0, count = 0, reasons = 0;
            int rc = RmGetList(handle, out needed, ref count, null, ref reasons);
            if (rc == 234 && needed > 0) {          // ERROR_MORE_DATA
                var infos = new RM_PROCESS_INFO[needed];
                count = needed;
                if (RmGetList(handle, out needed, ref count, infos, ref reasons) == 0)
                    for (int i = 0; i < count; i++) ids.Add(infos[i].Process.dwProcessId);
            }
        } finally { RmEndSession(handle); }
        return ids.ToArray();
    }
    // last resort: let the kernel remove it during early boot, before anything loads it
    public static bool DeleteOnReboot(string path) { return MoveFileEx(path, null, 0x4); }
}
"@ -ErrorAction SilentlyContinue

# processes that must never be killed - taking these down takes the machine with them
$script:CriticalProcs = @('system', 'idle', 'csrss', 'wininit', 'winlogon', 'services',
                          'lsass', 'smss', 'svchost', 'dwm', 'fontdrvhost', 'memory compression')

function Unlock-Path([string]$Path) {
    # returns $true if we freed it, $false if the holder could not be touched
    $freed = $false
    try {
        foreach ($procId in @([Unlocker]::WhoIsLocking($Path))) {
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $name = $p.Name.ToLower()
            if ($script:CriticalProcs -contains $name) { continue }
            if ($name -eq 'explorer') {
                # a shell extension is holding it; Explorer relaunches itself
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 800
                $freed = $true
                continue
            }
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            $freed = $true
        }
    } catch {}
    if ($freed) { Start-Sleep -Milliseconds 400 }
    return $freed
}

function Grant-Ownership([string]$Path) {
    # TrustedInstaller or another user owns it, so even admin gets Access Denied
    try {
        & "$env:SystemRoot\System32\takeown.exe" /F $Path /R /D Y 2>&1 | Out-Null
        & "$env:SystemRoot\System32\icacls.exe" $Path /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
        return $true
    } catch { return $false }
}

# Escalating delete: plain -> attributes -> unlock holders -> take ownership ->
# schedule for boot. Returns 'removed', 'reboot' or 'failed'.
function Remove-Stubborn([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'removed' }
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return 'removed' } catch {}
    try {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
        if (Test-Path -LiteralPath $Path -PathType Leaf) { (Get-Item -LiteralPath $Path -Force).Attributes = 'Normal' }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return 'removed'
    } catch {}
    $targets = @($Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $targets += @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                      Select-Object -First 40 -ExpandProperty FullName)
    }
    $any = $false
    foreach ($t in $targets) { if (Unlock-Path $t) { $any = $true } }
    if ($any) {
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return 'removed' } catch {}
    }
    Grant-Ownership $Path | Out-Null
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return 'removed' } catch {}
    # genuinely held by something we must not kill: queue it for the next boot
    $scheduled = $false
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                if ([Unlocker]::DeleteOnReboot($f.FullName)) { $scheduled = $true }
            }
            foreach ($d in @(Get-ChildItem -LiteralPath $Path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                             Sort-Object { $_.FullName.Length } -Descending)) {
                [void][Unlocker]::DeleteOnReboot($d.FullName)
            }
        }
        if ([Unlocker]::DeleteOnReboot($Path)) { $scheduled = $true }
    } catch {}
    if ($scheduled) { return 'reboot' }
    return 'failed'
}
function ConvertTo-PSRegPath([string]$Path) {
    return ($Path -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM:\' `
                  -replace '^HKEY_CURRENT_USER\\', 'HKCU:\' `
                  -replace '^HKEY_CLASSES_ROOT\\', 'HKCR:\' `
                  -replace '^HKLM\\', 'HKLM:\' `
                  -replace '^HKCU\\', 'HKCU:\' `
                  -replace '^HKCR\\', 'HKCR:\')
}
function Write-Status([string]$Id, [string]$State, [string]$Detail, [bool]$Dirty = $false, [string[]]$Created = @()) {
    # $Dirty is the verdict travelling back to the GUI: this failure left files on the
    # machine. The GUI turns it into a leftover scan, so the flag has to be on the wire -
    # the elevated side cannot show the preview itself.
    $rec = @{ id = $Id; state = $State; detail = $Detail; dirty = $Dirty }
    # only when there is something to say - every status line is read and logged, and an empty
    # array on all of them would be noise
    if (@($Created).Count) { $rec['created'] = @($Created) }
    $line = $rec | ConvertTo-Json -Compress
    for ($i = 0; $i -lt 10; $i++) {
        try { Add-Content -LiteralPath $StatusFile -Value $line -Encoding UTF8; break }
        catch { Start-Sleep -Milliseconds 200 }
    }
}
# ---------- post-install steps ----------
# Many products are not finished when the installer exits: a serialisation tool has to run,
# a licence file has to land, a service has to be stopped. Each step is declared per app in
# the catalog and executed here, in order, only after the install has verified.
#
# Two rules. Anything executable is SHA-256 verified first, same as the installer - the queue
# may name a file, never introduce an unverified one. And every step is time-boxed: an
# activation tool that opens a hidden dialog would otherwise hang the whole batch forever,
# since Start-Process -Wait has no timeout.
function Invoke-PostStep($step, [string]$appId, [int]$n, [int]$total) {
    $type = ('' + $step.type).ToLower()
    $label = $(if ($step.name) { [string]$step.name } else { $type })
    Write-Status $appId 'Applying' "post-install $n/$($total): $label"

    switch ($type) {
        'run' {
            $f = [string]$step.file
            # `from` runs a file that came OUT of the package - the activation tool or batch
            # that shipped beside the installer.
            $fromPkg = [bool]$step.from
            if ($fromPkg) {
                if (-not $script:UnpackedDir) {
                    return "step $n ($label): 'from' needs a .zip package - this app is a single installer"
                }
                $f = Join-Path $script:UnpackedDir ([string]$step.from)
            }
            if (-not $f -or -not (Test-Path -LiteralPath $f)) { return "step $n ($label): file missing" }
            if ($fromPkg) {
                # No separate sha256, and that is not a hole: the package's own hash was checked
                # before a single byte was unpacked, so these bytes are already covered by it.
                # A file fetched from a URL has had no such check and still must carry one.
            } elseif ($step.sha256) {
                $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToUpper()
                if ($h -ne ('' + $step.sha256).ToUpper()) { return "step $n ($label): SHA-256 mismatch - not executed" }
            } else {
                return "step $n ($label): refused - no sha256 in the catalog, and unverified files are never run elevated"
            }
            $secs = [int]$step.timeoutSec; if ($secs -le 0) { $secs = 300 }
            $ext = [IO.Path]::GetExtension($f).ToLower()
            $proc = $null
            try {
                if ($ext -in '.bat', '.cmd') {
                    $a = "/c `"$f`""; if ($step.args) { $a += " $($step.args)" }
                    $proc = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList $a -PassThru -WindowStyle Hidden
                } elseif ($ext -eq '.ps1') {
                    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$f`""; if ($step.args) { $a += " $($step.args)" }
                    $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $a -PassThru -WindowStyle Hidden
                } elseif ([string]::IsNullOrWhiteSpace([string]$step.args)) {
                    $proc = Start-Process -FilePath $f -PassThru
                } else {
                    $proc = Start-Process -FilePath $f -ArgumentList ([string]$step.args) -PassThru
                }
            } catch { return "step $n ($label): could not start - $($_.Exception.Message)" }
            if (-not $proc.WaitForExit($secs * 1000)) {
                try { $proc.Kill() } catch {}
                return "step $n ($label): TIMED OUT after $secs s and was killed - it may be waiting on a hidden prompt"
            }
            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) { return "step $n ($label): exit code $($proc.ExitCode)" }
            return $null
        }
        'powershell' {
            # A command from the catalog, run elevated. No file, so nothing to hash - which
            # means the catalog itself is the only thing vouching for it. That is already true
            # of the registry and service steps, but this one is arbitrary code, so it deserves
            # saying plainly: anyone who can change the catalog can run anything on every client
            # this tool touches. Protect the catalog server accordingly.
            $cmd = [string]$step.command
            if (-not $cmd) { return "step $n ($label): no command given" }
            $secs = [int]$step.timeoutSec; if ($secs -le 0) { $secs = 300 }
            # -EncodedCommand rather than -Command: the command is arbitrary text, and quoting
            # it onto a command line is how a stray " or & silently turns into a different
            # command. Base64 has no such edge.
            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
            $proc = $null
            try {
                $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NonInteractive -EncodedCommand $enc" `
                    -PassThru -WindowStyle Hidden
            } catch { return "step $n ($label): could not start - $($_.Exception.Message)" }
            # time-boxed like every other step: a command that waits on input would otherwise
            # hold the whole batch open for ever
            if (-not $proc.WaitForExit($secs * 1000)) {
                try { $proc.Kill() } catch {}
                return "step $n ($label): TIMED OUT after $secs s and was killed - it may be waiting on input"
            }
            if ($proc.ExitCode -ne 0) { return "step $n ($label): exit code $($proc.ExitCode)" }
            return $null
        }
        'kill' {
            # Installers routinely launch the product when they finish, and a running app
            # holds its own files open - so dropping a file into its folder fails with
            # "in use" unless it is closed first. Nothing running is a success, not an error.
            $targets = @()
            $pname = ('' + $step.name) -replace '\.exe$', ''
            if ($pname) { $targets += @(Get-Process -Name $pname -ErrorAction SilentlyContinue) }
            $folder = [Environment]::ExpandEnvironmentVariables([string]$step.folder)
            if ($folder) {
                $fl = $folder.TrimEnd('\')
                if ($fl.Length -lt 8) { return "step $n ($label): folder '$folder' is too broad to kill by" }
                foreach ($pr in @(Get-Process -ErrorAction SilentlyContinue)) {
                    try { if ($pr.Path -and $pr.Path.StartsWith($fl + '\', 'OrdinalIgnoreCase')) { $targets += $pr } } catch {}
                }
            }
            if (-not $pname -and -not $folder) { return "step $n ($label): needs a process name or a folder" }
            $targets = @($targets | Sort-Object Id -Unique)
            if (-not $targets.Count) { return $null }        # nothing was running
            foreach ($pr in $targets) {
                try { $pr.CloseMainWindow() | Out-Null } catch {}
            }
            Start-Sleep -Milliseconds 800
            foreach ($pr in $targets) {
                try { if (-not $pr.HasExited) { Stop-Process -Id $pr.Id -Force -ErrorAction SilentlyContinue } } catch {}
            }
            # give Windows a moment to actually release the file handles, or the copy that
            # follows still fails
            $settle = [int]$step.waitMs; if ($settle -le 0) { $settle = 2000 }
            Start-Sleep -Milliseconds $settle
            $alive = @()
            foreach ($pr in $targets) { try { if (-not $pr.HasExited) { $alive += $pr.ProcessName } } catch {} }
            if ($alive.Count) { return "step $n ($label): could not close $(($alive | Select-Object -Unique) -join ', ')" }
            return $null
        }
        'copy' {
            $f = [string]$step.file
            # `from` names a file INSIDE the package that was just unpacked - the readme, the
            # licence, the plugin that shipped alongside the installer. Nothing extra is
            # downloaded and no second hash is needed: the package's own SHA-256 already
            # covered these exact bytes before anything was unpacked.
            if ($step.from) {
                if (-not $script:UnpackedDir) {
                    return "step $n ($label): 'from' needs a .zip package - this app is a single installer"
                }
                $f = Join-Path $script:UnpackedDir ([string]$step.from)
            }
            $dest = [Environment]::ExpandEnvironmentVariables([string]$step.dest)
            if (-not $f -or -not (Test-Path -LiteralPath $f)) { return "step $n ($label): source file missing" }
            if (-not $dest) { return "step $n ($label): no dest given" }
            if ($step.sha256) {
                $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToUpper()
                if ($h -ne ('' + $step.sha256).ToUpper()) { return "step $n ($label): SHA-256 mismatch - not copied" }
            }
            # "drop it in the app directory": a dest that is a folder keeps the source name,
            # so the catalog does not have to repeat the filename
            if ($dest.EndsWith('\') -or (Test-Path -LiteralPath $dest -PathType Container)) {
                $dest = Join-Path $dest.TrimEnd('\') ([IO.Path]::GetFileName($f))
            }
            try {
                $dir = Split-Path $dest -Parent
                if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            } catch { return "step $n ($label): could not create $dir - $($_.Exception.Message)" }
            # A target that is still locked is the normal failure here, so retry briefly
            # rather than giving up on the first "in use".
            $lastErr = ''
            for ($try = 1; $try -le 4; $try++) {
                try {
                    if (Test-Path -LiteralPath $dest) {
                        try { (Get-Item -LiteralPath $dest -Force).Attributes = 'Normal' } catch {}
                    }
                    Copy-Item -LiteralPath $f -Destination $dest -Force -ErrorAction Stop
                    return $null
                } catch {
                    $lastErr = $_.Exception.Message
                    Start-Sleep -Milliseconds (400 * $try)
                }
            }
            return "step $n ($label): copy to $dest failed after 4 attempts - $lastErr"
        }
        'registry' {
            if (-not $step.path -or -not $step.name) { return "step $n ($label): path or name missing" }
            $vt = [string]$step.valueType; if (-not $vt) { $vt = 'String' }
            try { Set-Reg ([string]$step.path) ([string]$step.name) ([string]$step.value) $vt }
            catch { return "step $n ($label): registry write failed - $($_.Exception.Message)" }
            return $null
        }
        'service' {
            $svc = [string]$step.name
            $act = ('' + $step.action).ToLower()
            if (-not $svc) { return "step $n ($label): no service name" }
            if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) { return "step $n ($label): service $svc not found" }
            try {
                switch ($act) {
                    'stop'     { Stop-Service  -Name $svc -Force -ErrorAction Stop }
                    'start'    { Start-Service -Name $svc -ErrorAction Stop }
                    'disable'  { Stop-Service  -Name $svc -Force -ErrorAction SilentlyContinue
                                 Set-Service   -Name $svc -StartupType Disabled -ErrorAction Stop }
                    'manual'   { Set-Service   -Name $svc -StartupType Manual -ErrorAction Stop }
                    'auto'     { Set-Service   -Name $svc -StartupType Automatic -ErrorAction Stop }
                    default    { return "step $n ($label): unknown service action '$act'" }
                }
            } catch { return "step $n ($label): $act failed - $($_.Exception.Message)" }
            return $null
        }
        default { return "step $n ($label): unknown step type '$type'" }
    }
}

function Invoke-PostInstall($app) {
    $steps = @($app.postInstall | Where-Object { $_ })
    if (-not $steps.Count) { return @() }
    $problems = @()
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $err = $null
        try { $err = Invoke-PostStep $steps[$i] $app.id ($i + 1) $steps.Count }
        catch { $err = "step $($i + 1): $($_.Exception.Message)" }
        if ($err) {
            $problems += $err
            # a failed activation step must not silently cascade into the next one
            if ($steps[$i].stopOnError -ne $false) { $problems += 'remaining steps skipped'; break }
        }
    }
    return $problems
}

# The unpacked package is the largest transient on the client's disk - a 14 GB Revit
# package doubles its footprint while it exists - but it cannot be deleted the moment the
# installer exits, because a post-install step may still need to copy a file OUT of it.
# So it lives until the app is completely finished, and every exit path goes through here.
function Remove-Unpacked {
    if ($script:UnpackedDir -and (Test-Path -LiteralPath $script:UnpackedDir)) {
        try { Remove-Item -LiteralPath $script:UnpackedDir -Recurse -Force } catch {}
    }
    $script:UnpackedDir = $null
}

function Install-One($app) {
    Write-Status $app.id 'Verifying file' ''
    $hash = (Get-FileHash -LiteralPath $app.file -Algorithm SHA256).Hash.ToUpper()
    if ($hash -ne $app.sha256.ToUpper()) {
        Write-Status $app.id 'Failed' 'SHA-256 mismatch - file rejected, not executed'
        return
    }
    # Most vendors' silent installers are a FOLDER, not a file: an Adobe Admin Console
    # package is Build\setup.exe plus its payloads, the Office Deployment Tool needs its
    # configuration.xml sitting beside setup.exe, an Autodesk deployment is an image.
    # Shipping one of those as a single .exe leaves every sibling file back on the server
    # and the install fails for a reason nobody can see. So a package may be a .zip, and
    # `entry` names the installer inside it.
    #
    # A self-extracting exe was tried first and rejected: WinRAR's SFX returns its OWN exit
    # code, 0, whatever the installer inside did - which would report every failed install
    # as a success and silence the dirty verdict completely. Unpacking here keeps the real
    # installer's exit code, which is the one thing this tool cannot afford to get wrong.
    #
    # The zip is SHA-256 verified ABOVE, before a single byte is unpacked, so the pin covers
    # everything inside it exactly as tightly as it covered a bare installer.
    # Keyed on `entry` - the catalog's stated intent - and not on the filename alone. A zip
    # that reached Start-Process because its URL happened to end in .exe would be handed to
    # the shell's default archive handler, which opens a WINDOW and waits: an invisible GUI
    # in an elevated session, hanging the batch with nothing to show for it. Measured, not
    # imagined - it is what the harness did when this branch was mutated out.
    $runFile = $app.file
    $workDir = $null
    $unpacked = $null
    if ($app.entry -or [IO.Path]::GetExtension($app.file).ToLower() -eq '.zip') {
        if (-not $app.entry) {
            Write-Status $app.id 'Failed' 'package is a .zip but the catalog does not say which file inside it to run (entry)'
            return
        }
        $unpacked = Join-Path (Split-Path -Parent $app.file) "$($app.id)-unpacked"
        try {
            if (Test-Path -LiteralPath $unpacked) { Remove-Item -LiteralPath $unpacked -Recurse -Force }
            Write-Status $app.id 'Installing' 'unpacking package'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            # ExtractToDirectory, not Expand-Archive: 5.1's cmdlet is unusably slow at the
            # multi-GB sizes these packages run to.
            try {
                [IO.Compression.ZipFile]::ExtractToDirectory($app.file, $unpacked)
            } catch {
                # .NET's zip support is Deflate and Stored ONLY. 7-Zip and WinRAR happily
                # default to LZMA, BZip2 or Zstd, and such a package fails here with
                # "compressed using an unsupported compression method" - after the whole file
                # has already been downloaded. Windows ships bsdtar (libarchive) with those
                # codecs linked in, so it can read what .NET cannot. Present since Windows 10
                # 1803, which is below this tool's floor anyway.
                $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
                if (-not (Test-Path -LiteralPath $tar)) { throw }
                Write-Activity $app.id 'install' 'Unpacking' 'unsupported zip codec - retrying with tar'
                if (-not (Test-Path -LiteralPath $unpacked)) {
                    New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
                }
                $tp = Start-Process -FilePath $tar -ArgumentList @('-xf', "`"$($app.file)`"", '-C', "`"$unpacked`"") `
                                    -Wait -PassThru -WindowStyle Hidden
                if ($tp.ExitCode -ne 0) { throw "tar exited $($tp.ExitCode)" }
            }
        } catch {
            Write-Status $app.id 'Failed' "could not unpack the package - $($_.Exception.Message)"
            return
        }
        $runFile = Join-Path $unpacked ([string]$app.entry)
        if (-not (Test-Path -LiteralPath $runFile)) {
            Write-Status $app.id 'Failed' "the package does not contain '$($app.entry)'"
            try { Remove-Item -LiteralPath $unpacked -Recurse -Force } catch {}
            return
        }
        # the installer must run FROM its own folder, or every relative path it was given
        # (Office's '/configure configuration.xml' being the obvious one) resolves nowhere
        $workDir = Split-Path -Parent $runFile
        # post-install steps resolve their `from` against this, so it has to outlive the
        # installer itself - see Remove-Unpacked for when it actually goes
        $script:UnpackedDir = $unpacked
        Write-Activity $app.id 'install' 'Unpacked' "$([IO.Path]::GetFileName($app.file)) -> $($app.entry)"
    }

    Write-Status $app.id 'Installing' ''
    Write-Activity $app.id 'install' 'Started' "$([IO.Path]::GetFileName($runFile)) $($app.silentArgs)"

    $ext = [IO.Path]::GetExtension($runFile).ToLower()
    $maxTries = 3
    $v = $null
    $mins = 0

    # taken once, before the first attempt: a retry re-runs the same installer, and folders
    # created by attempt 1 are still this app's doing
    $before = Get-DirSnapshot
    $created = @()

    for ($try = 1; $try -le $maxTries; $try++) {
        $t0 = Get-Date
        # splatted rather than duplicating all three launch shapes: an unpacked package runs
        # from its own folder, a bare installer keeps the worker's default
        $extra = @{}
        if ($workDir) { $extra['WorkingDirectory'] = $workDir }
        if ($ext -eq '.msi') {
            $msiArgs = "/i `"$runFile`" /qn /norestart"
            if ($app.silentArgs) { $msiArgs += " $($app.silentArgs)" }
            $p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru @extra
        } elseif ([string]::IsNullOrWhiteSpace($app.silentArgs)) {
            $p = Start-Process -FilePath $runFile -Wait -PassThru @extra
        } else {
            $p = Start-Process -FilePath $runFile -ArgumentList $app.silentArgs -Wait -PassThru @extra
        }
        $mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
        $created = Get-CreatedDirs $before
        if (@($created).Count) {
            Write-Activity $app.id 'install' 'Created' (@($created) -join ' | ')
        }
        $v = Get-InstallVerdict $p.ExitCode
        Write-Activity $app.id 'install' $v.State "$($v.Text); exit $($p.ExitCode); $mins min; attempt $try of $maxTries"

        if ($v.Ok) { break }

        # 1618 is the only genuinely transient case: another installer holds the Windows
        # Installer mutex. Everything else is a decision or a break - retrying a cancel
        # would override a person who already said no.
        if ($v.Retry -and $try -lt $maxTries) {
            Write-Status $app.id 'Installing' "$($v.Text) - retrying in 30s (attempt $try of $maxTries)"
            Start-Sleep -Seconds 30
            continue
        }

        $detail = "$($v.Text) after $mins min"
        if ($v.Dirty) { $detail += ' - a partial install is on disk; the leftover scan will offer to remove it' }
        # the folders this attempt created travel with the verdict: on a dirty failure they are
        # exactly what the leftover scan should offer, and they are FACTS, not name matches
        Write-Status $app.id 'Failed' $detail $v.Dirty $created
        # our own scratch copy, not installer debris - the leftover scan looks at where the
        # product installs, never in here, so nothing downstream wants these bytes
        Remove-Unpacked
        return
    }
    # NOT deleted here. This used to be where the unpacked copy went, which quietly made it
    # impossible for a post-install step to take a file out of the package - the folder was
    # already gone by the time the steps ran. It is disposed of at the exits below instead.
    $ok = $true
    foreach ($vp in @($app.verifyPaths)) {
        if ($vp -and -not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($vp)))) { $ok = $false }
    }
    if (-not $ok) {
        # The installer claimed success but the product is not on disk. Usually a wrapper
        # that spawned the real engine and returned early, or a silent switch that made it
        # exit 0 without doing anything. Dirty by definition - something ran.
        Write-Activity $app.id 'verify' 'Failed' "verifyPaths missing after exit $($p.ExitCode)"
        Write-Status $app.id 'Failed' 'installed nothing - verify paths are missing, so a partial install may be on disk' $true $created
        Remove-Unpacked
        return
    }
    Write-Activity $app.id 'verify' 'Done' "verified in $mins min"
    $note = ''; if ($p.ExitCode -eq 3010) { $note = 'reboot required' }

    # Only now, with the install verified, run the app's own finishing steps. A failure here
    # is NOT an install failure - the product is on disk - so it reports amber with the exact
    # step that broke, rather than red or, worse, silence.
    $problems = Invoke-PostInstall $app
    $stepCount = @($app.postInstall | Where-Object { $_ }).Count
    if ($problems.Count) {
        $d = "installed, but $($problems.Count) post-install issue(s): " + (($problems | Select-Object -First 3) -join '; ')
        if ($note) { $d = "$note; $d" }
        Write-Status $app.id 'Skipped' $d
        Remove-Unpacked
        return
    }
    if ($stepCount) { $note = $(if ($note) { "$note; $stepCount post-install step(s) completed" } else { "$stepCount post-install step(s) completed" }) }
    Write-Status $app.id 'Installed' $note $false $created
    Remove-Unpacked
}
function Uninstall-One($app) {
    Write-Status $app.id 'Uninstalling' ''
    # Stop anything running from the app's own folder first. A running exe locks its
    # directory, and every later delete would fail with "in use" for no visible reason.
    if ($app.location) {
        $loc = [Environment]::ExpandEnvironmentVariables($app.location).TrimEnd('\')
        if ($loc -and $loc.Length -gt 12) {
            foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
                try {
                    if ($proc.Path -and $proc.Path.StartsWith($loc, 'OrdinalIgnoreCase')) {
                        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                    }
                } catch {}
            }
        }
    }
    # Microsoft Store packages are removed through the platform, not an installer exe.
    # -AllUsers plus the provisioned copy stops it reappearing for new profiles.
    if ($app.command -eq 'appx') {
        try {
            Remove-AppxPackage -Package $app.args -AllUsers -ErrorAction Stop
        } catch {
            try { Remove-AppxPackage -Package $app.args -ErrorAction Stop }
            catch { Write-Status $app.id 'Failed' $_.Exception.Message; return }
        }
        try {
            $fam = ($app.args -split '_')[0]
            Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                Where-Object { $_.DisplayName -eq $fam } |
                ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
        } catch {}
        if (@(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.PackageFullName -eq $app.args }).Count) {
            Write-Status $app.id 'Failed' 'package still present after removal'
        } else {
            Write-Status $app.id 'Uninstalled' ''
        }
        return
    }
    $exe = [Environment]::ExpandEnvironmentVariables($app.command)
    if (($exe -match '[\\/]') -and -not (Test-Path -LiteralPath $exe)) {
        Write-Status $app.id 'Failed' 'vendor uninstaller not found'
        return
    }
    if ([string]::IsNullOrWhiteSpace($app.args)) {
        $p = Start-Process -FilePath $exe -Wait -PassThru
    } else {
        $p = Start-Process -FilePath $exe -ArgumentList $app.args -Wait -PassThru
    }
    $badCode = ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010)
    # verify removal. For registry-discovered apps the detect target is the uninstall key
    # itself - the install folder often survives as leftovers even on a clean uninstall,
    # so the key disappearing is the reliable signal.
    $gone = $true
    if ($app.detect) {
        if ($app.detect -match '^HK(LM|CU|CR|EY)') {
            if (Test-Path -LiteralPath (ConvertTo-PSRegPath $app.detect)) { $gone = $false }
        } elseif (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($app.detect))) {
            $gone = $false
        }
    }
    # An uninstaller that removed the product and STILL returned non-zero is common: plenty
    # delete their own folder while running, so cmd cannot read its next line and returns a
    # failure for work that is already done. The detect target is the definition of "installed",
    # so when it is gone the product IS gone - reporting red there sends a technician chasing a
    # removal that already worked. The exit code still decides on its own when there is no
    # detect target to check, because then it is the only evidence there is.
    $proven = ([bool]$app.detect -and $gone)
    if ($badCode -and -not $proven) {
        Write-Status $app.id 'Failed' "Uninstaller exit code $($p.ExitCode)"
    } elseif (-not $gone) {
        Write-Status $app.id 'Failed' 'application still detected after uninstall'
    } else {
        Write-Status $app.id 'Uninstalled' $(if ($badCode) {
            "removed, though the uninstaller returned exit code $($p.ExitCode)" } else { '' })
    }
}
function Wipe-One($app) {
    # Remove every approved leftover. Each target was scanned, shown with its size and
    # explicitly ticked by the technician - nothing here is guessed at run time.
    $removed = 0; $failed = 0; $pending = 0; $hostLines = @()
    foreach ($t in @($app.targets)) {
        try {
            switch ($t.type) {
                'reg' {
                    $rk = ConvertTo-PSRegPath $t.path
                    if (Test-Path -LiteralPath $rk) { Remove-Item -LiteralPath $rk -Recurse -Force -ErrorAction Stop }
                    $removed++
                }
                'regvalue' {
                    # one VALUE out of a shared key - never the key itself. Run holds every
                    # other product's autostart entry too, and removing it would stop them all.
                    $rk = ConvertTo-PSRegPath $t.path
                    if (-not $t.name) { throw 'regvalue target has no value name' }
                    if (Test-Path -LiteralPath $rk) {
                        Remove-ItemProperty -LiteralPath $rk -Name ([string]$t.name) -Force -ErrorAction Stop
                    }
                    $removed++
                }
                'service' {
                    $svc = Get-Service -Name $t.path -ErrorAction SilentlyContinue
                    if ($svc) {
                        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $t.path -Force -ErrorAction SilentlyContinue }
                        # sc.exe delete works on 5.1 where Remove-Service does not exist
                        & "$env:SystemRoot\System32\sc.exe" delete $t.path | Out-Null
                    }
                    $removed++
                }
                'task' {
                    $leaf = Split-Path $t.path -Leaf
                    $path = Split-Path $t.path -Parent
                    if (-not $path.EndsWith('\')) { $path += '\' }
                    Unregister-ScheduledTask -TaskName $leaf -TaskPath $path -Confirm:$false -ErrorAction Stop
                    $removed++
                }
                'hosts' { $hostLines += $t.path }
                default {
                    $fp = [Environment]::ExpandEnvironmentVariables($t.path)
                    switch (Remove-Stubborn $fp) {
                        'removed' { $removed++ }
                        'reboot'  { $pending++ }
                        default   { $failed++ }
                    }
                }
            }
        } catch { $failed++ }
    }

    # hosts is rewritten once, dropping only the exact approved lines. Never regenerated
    # from scratch - unrelated entries on the client's machine must survive untouched.
    if ($hostLines.Count) {
        try {
            $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
            $keep = @(Get-Content -LiteralPath $hostsFile -ErrorAction Stop |
                      Where-Object { $hostLines -notcontains $_.Trim() })
            Set-Content -LiteralPath $hostsFile -Value $keep -Encoding ASCII -Force -ErrorAction Stop
            $removed += $hostLines.Count
        } catch { $failed += $hostLines.Count }
    }

    $detail = "$removed trace(s) removed"
    if ($pending -gt 0) { $detail += ", $pending scheduled for next restart" }
    if ($failed -gt 0)  { $detail += ", $failed could not be removed" }
    Write-Status $app.id 'Cleaned' $detail
}
# ---------- tweaks ----------
# Every tweak is a registry/policy/service change applied here, in the one elevated
# context, so the whole batch still costs a single UAC prompt.
$script:UserSid = ''

function Resolve-Reg([string]$Path) {
    # HKCU inside an elevated process is the ELEVATING account's hive - not necessarily
    # the technician's. The GUI passes its own SID, so per-user tweaks are written into
    # HKEY_USERS\<sid> and actually land on the profile the tech is looking at.
    if ($script:UserSid -and $Path -match '^HKCU[:\\]') {
        return "Registry::HKEY_USERS\$script:UserSid\" + ($Path -replace '^HKCU:?\\', '')
    }
    return ConvertTo-PSRegPath $Path
}
function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    $p = Resolve-Reg $Path
    if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $p -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
}
function Remove-RegKey([string]$Path) {
    $p = Resolve-Reg $Path
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue; return $true }
    return $false
}
function Set-SvcStart([string]$Name, [string]$Mode) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    try { Set-Service -Name $Name -StartupType $Mode -ErrorAction Stop; return $true } catch { return $false }
}
function Disable-Task([string]$Path, [string]$Name) {
    try { Disable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}
function Remove-AppxByName([string]$Pattern) {
    $n = 0
    try {
        foreach ($p in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $Pattern })) {
            try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; $n++ } catch {}
        }
    } catch {}
    try {
        foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $Pattern })) {
            try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction SilentlyContinue | Out-Null; $n++ } catch {}
        }
    } catch {}
    return $n
}

# Set to Manual, not Disabled: a disabled service that something genuinely needs fails
# hard, where Manual still lets a trigger start it. BITS is deliberately absent - this
# tool downloads through it. So are the network/identity services a machine cannot boot
# usefully without.
$script:ManualServices = @(
    'DiagTrack', 'dmwappushservice', 'diagnosticshub.standardcollector.service', 'WerSvc',
    'Fax', 'RemoteRegistry', 'RetailDemo', 'MapsBroker', 'WMPNetworkSvc', 'PcaSvc',
    'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc',
    'SCardSvr', 'ScDeviceEnum', 'SEMgrSvc', 'PhoneSvc', 'TapiSrv', 'WalletService',
    'WpcMonSvc', 'SharedAccess', 'lfsvc', 'TrkWks', 'AJRouter', 'SensorService',
    'SensrSvc', 'SensorDataService', 'WbioSrvc', 'iphlpsvc', 'p2pimsvc', 'p2psvc',
    'PNRPsvc', 'PNRPAutoReg', 'SSDPSRV', 'upnphost', 'wisvc', 'PerfHost'
)

# The preference table is substituted in by Start-Worker from the single definition in the
# GUI, so both sides always agree and the queue still carries nothing but an id and a state.
#__PREFTABLE__

# CreateProfile is what Windows itself calls the first time someone signs in: it builds
# C:\Users\<name> from the default profile with the right ACLs and a fresh NTUSER.DAT.
# Making the folder by hand instead produces a directory the user cannot actually use.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class UserProfile {
    [DllImport("userenv.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern int CreateProfile(string pszUserSid, string pszUserName,
                                    StringBuilder pathBuf, uint cchPath);
    public static int Create(string sid, string name, out string path) {
        var sb = new StringBuilder(512);
        int hr = CreateProfile(sid, name, sb, (uint)sb.Capacity);
        path = sb.ToString();
        return hr;
    }
}
"@ -ErrorAction SilentlyContinue

# The Administrators group is localised - "Administrateurs", "Administratoren". Only the
# well-known SID S-1-5-32-544 is stable, so never hard-code the English name.
function Get-AdminGroupName {
    try {
        return ((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value -replace '^.*\\', '')
    } catch { return 'Administrators' }
}

function Get-UserSid([string]$Name) {
    try { return (New-Object Security.Principal.NTAccount($Name)).Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { return '' }
}

function New-LocalAdmin($app) {
    $name = [string]$app.username
    $full = [string]$app.fullname
    Write-Status $app.id 'Applying' 'creating the account'

    $pw = [string]$app.password
    $created = $false
    try {
        if ($pw) {
            $sec = ConvertTo-SecureString $pw -AsPlainText -Force
            New-LocalUser -Name $name -Password $sec -ErrorAction Stop | Out-Null
        } else {
            New-LocalUser -Name $name -NoPassword -ErrorAction Stop | Out-Null
        }
        $created = $true
    } catch {
        # PS 5.1 without the LocalAccounts module, or a policy that blocks the cmdlet
        if ($pw) { & "$env:SystemRoot\System32\net.exe" user $name $pw /add 2>&1 | Out-Null }
        else { & "$env:SystemRoot\System32\net.exe" user $name /add 2>&1 | Out-Null }
        $created = ($LASTEXITCODE -eq 0)
    }
    if (-not $created) { Write-Status $app.id 'Failed' 'could not create the account'; return }

    try { Set-LocalUser -Name $name -PasswordNeverExpires $true -ErrorAction Stop } catch {}
    if ($full) {
        try { Set-LocalUser -Name $name -FullName $full -ErrorAction Stop }
        catch { & "$env:SystemRoot\System32\net.exe" user $name /fullname:"$full" 2>&1 | Out-Null }
    }

    # the Add Account dialog can create a standard user too, so only promote when asked
    $wantAdmin = $true
    if ($null -ne $app.admin) { $wantAdmin = [bool]$app.admin }
    $grp = Get-AdminGroupName
    if ($wantAdmin) {
        $isAdmin = $false
        try { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $name -ErrorAction Stop; $isAdmin = $true }
        catch {
            & "$env:SystemRoot\System32\net.exe" localgroup $grp $name /add 2>&1 | Out-Null
            $isAdmin = ($LASTEXITCODE -eq 0)
        }
        if (-not $isAdmin) {
            Write-Status $app.id 'Failed' "account created but could not be added to $grp - it is still a standard user"
            return
        }
    }

    # build the profile now so data can be copied in without a first sign-in
    $sid = Get-UserSid $name
    $profileNote = 'profile folder not created - sign in once before copying data'
    if ($sid) {
        $path = ''
        $hr = 0
        try { $hr = [UserProfile]::Create($sid, $name, [ref]$path) } catch { $hr = -1 }
        # 0x800700B7 is "already exists", which is a success for our purposes
        if ($hr -eq 0 -or $hr -eq -2147024713) { $profileNote = "profile created at $path" }
    }
    $role = $(if ($wantAdmin) { "a member of $grp" } else { 'a standard user' })
    Write-Status $app.id 'Applied' "$name created as $role; $profileNote"
}

# Guards are re-checked HERE, not just in the GUI. The queue file sits in a folder any
# process running as this user can write to, so the elevated side must never take a
# destructive instruction on trust. Cheap to verify, and it is the difference between a
# UI validation and an actual safety property.
function Test-AccountActionSafe([string]$Name, [string]$What) {
    if (-not $Name) { return 'no account name given' }
    $u = $null
    try { $u = Get-LocalUser -Name $Name -ErrorAction Stop } catch { return "no local account called $Name" }
    $sid = ('' + $u.SID.Value)
    # Built-ins cannot be deleted or demoted - Windows forbids both. DISABLING one is normal
    # hardening: Administrator and Guest ship disabled, so refusing that is wrong, and it left
    # a machine with the built-in Administrator switched on and no way to switch it back off.
    # Whatever this tool can enable, it must be able to disable.
    if ($What -in 'deleted', 'demoted') {
        if ($sid -match '-(500|501|503|504)$') { return "$Name is a built-in Windows account and cannot be $What" }
    }
    try {
        if ($Name -eq [Environment]::UserName) { return "$Name is the signed-in account and cannot be $What" }
    } catch {}
    if ($What -in 'deleted', 'disabled', 'demoted') {
        # would this leave the machine with no way to elevate?
        $admins = @()
        try {
            foreach ($m in @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)) {
                $n = (('' + $m.Name) -replace '^.*\\', '')
                $lu = $null
                try { $lu = Get-LocalUser -Name $n -ErrorAction Stop } catch { continue }   # skip groups
                if ($lu.Enabled) { $admins += $n }
            }
        } catch { return $null }   # cannot determine - the GUI already checked, do not block
        if ($admins -contains $Name -and $admins.Count -le 1) {
            return "$Name is the only enabled Administrator and cannot be $What"
        }
    }
    return $null
}

function Set-AccountAdmin($app) {
    $name = [string]$app.username
    $makeAdmin = [bool]$app.admin
    Write-Status $app.id 'Applying' ''
    if (-not $makeAdmin) {
        $why = Test-AccountActionSafe $name 'demoted'
        if ($why) { Write-Status $app.id 'Failed' "refused: $why"; return }
    }
    $grp = Get-AdminGroupName
    try {
        if ($makeAdmin) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $name -ErrorAction Stop }
        else { Remove-LocalGroupMember -SID 'S-1-5-32-544' -Member $name -ErrorAction Stop }
    } catch {
        $verb = $(if ($makeAdmin) { '/add' } else { '/delete' })
        & "$env:SystemRoot\System32\net.exe" localgroup $grp $name $verb 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Status $app.id 'Failed' "could not change $grp membership"; return }
    }
    Write-Status $app.id 'Applied' $(if ($makeAdmin) { "$name added to $grp" } else { "$name removed from $grp - now a standard user" })
}

function Set-AccountPassword($app) {
    $name = [string]$app.username
    $pw = [string]$app.password
    Write-Status $app.id 'Applying' ''
    try {
        if ($pw) {
            $sec = ConvertTo-SecureString $pw -AsPlainText -Force
            Set-LocalUser -Name $name -Password $sec -ErrorAction Stop
        } else {
            Set-LocalUser -Name $name -Password ([securestring]::new()) -ErrorAction Stop
        }
    } catch {
        & "$env:SystemRoot\System32\net.exe" user $name $pw 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Status $app.id 'Failed' "could not set the password: $($_.Exception.Message)"; return }
    }
    try { Set-LocalUser -Name $name -PasswordNeverExpires $true -ErrorAction Stop } catch {}
    Write-Status $app.id 'Applied' $(if ($pw) { "password set for $name" } else { "password cleared for $name - it can now sign in with no password" })
}

function Set-AccountEnabled($app) {
    $name = [string]$app.username
    $enable = [bool]$app.enable
    Write-Status $app.id 'Applying' ''
    if (-not $enable) {
        $why = Test-AccountActionSafe $name 'disabled'
        if ($why) { Write-Status $app.id 'Failed' "refused: $why"; return }
    }
    try {
        if ($enable) { Enable-LocalUser -Name $name -ErrorAction Stop } else { Disable-LocalUser -Name $name -ErrorAction Stop }
    } catch {
        $flag = $(if ($enable) { 'yes' } else { 'no' })
        & "$env:SystemRoot\System32\net.exe" user $name /active:$flag 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Status $app.id 'Failed' 'could not change the account state'; return }
    }
    Write-Status $app.id 'Applied' $(if ($enable) { "$name enabled" } else { "$name disabled - it cannot sign in, but its profile and files are untouched" })
}

function Remove-Account($app) {
    $name = [string]$app.username
    Write-Status $app.id 'Applying' ''
    $why = Test-AccountActionSafe $name 'deleted'
    if ($why) { Write-Status $app.id 'Failed' "refused: $why"; return }
    # deliberately account-only: the profile folder is left on disk so nothing the
    # migration missed is lost with it
    $path = ''
    try {
        $sid = ('' + (Get-LocalUser -Name $name -ErrorAction Stop).SID.Value)
        $pl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        if (Test-Path -LiteralPath $pl) {
            $path = ('' + (Get-ItemProperty -LiteralPath $pl -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath)
        }
    } catch {}
    try { Remove-LocalUser -Name $name -ErrorAction Stop }
    catch {
        & "$env:SystemRoot\System32\net.exe" user $name /delete 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Status $app.id 'Failed' 'could not delete the account'; return }
    }
    $detail = "$name deleted"
    if ($path) { $detail += "; profile folder KEPT at $path - remove it manually once the replacement is confirmed good" }
    Write-Status $app.id 'Applied' $detail
}

function Copy-ProfileData($app) {
    $src = ([string]$app.src).TrimEnd('\')
    $dstUser = [string]$app.dstUser
    $dstPath = ([string]$app.dstPath).TrimEnd('\')

    if (-not (Test-Path -LiteralPath $src)) { Write-Status $app.id 'Failed' "source profile not found: $src"; return }

    # destination may be an account that has never signed in - build its profile first
    if (-not $dstPath -or -not (Test-Path -LiteralPath $dstPath)) {
        Write-Status $app.id 'Applying' 'creating the destination profile'
        $sid = Get-UserSid $dstUser
        if (-not $sid) { Write-Status $app.id 'Failed' "cannot resolve the account $dstUser"; return }
        $path = ''
        $hr = 0
        try { $hr = [UserProfile]::Create($sid, $dstUser, [ref]$path) } catch { $hr = -1 }
        if (($hr -eq 0 -or $hr -eq -2147024713) -and $path) { $dstPath = $path.TrimEnd('\') }
        else {
            # last resort: read it back from ProfileList
            $pl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
            if (Test-Path -LiteralPath $pl) {
                $dstPath = ('' + (Get-ItemProperty -LiteralPath $pl -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath).TrimEnd('\')
            }
        }
        if (-not $dstPath -or -not (Test-Path -LiteralPath $dstPath)) {
            Write-Status $app.id 'Failed' 'could not create the destination profile - sign into the account once, then retry'
            return
        }
    }

    $copied = 0; $failed = 0; $bytes = [long]0
    $problems = @()
    foreach ($rel in @($app.items)) {
        $s = (Join-Path $src $rel).TrimEnd('\')
        $d = (Join-Path $dstPath $rel).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $s)) { continue }
        Write-Status $app.id 'Applying' "copying $rel"

        # /COPY:DAT deliberately omits ACLs so everything INHERITS the destination
        # profile's permissions - copy the source ACLs and the new user often cannot
        # open their own files. /XJ is not optional: a profile is full of legacy
        # junctions ("My Documents" -> "Documents") and robocopy will loop forever.
        & "$env:SystemRoot\System32\robocopy.exe" $s $d /E /COPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP 2>&1 | Out-Null
        $rc = $LASTEXITCODE
        # Robocopy returns a BITFIELD, not a severity: 1 copied, 2 extra, 4 mismatched,
        # 8 some files failed, 16 fatal. Only 16 means the copy itself broke. Treating
        # anything >=8 as failure would report a whole migration as failed because one
        # file was open - and on a live profile some file is always open.
        if ($rc -band 16) { $failed++; $problems += "$rel (fatal robocopy error $rc)"; continue }
        if ($rc -band 8) { $problems += "$rel (some files were locked and skipped)" }

        # verify rather than trust the exit code: compare what actually landed
        $sn = 0; $sb2 = [long]0; $dn = 0; $db = [long]0
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($s, '*', 'AllDirectories')) { $sn++; $sb2 += (New-Object IO.FileInfo $f).Length }
        } catch {}
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($d, '*', 'AllDirectories')) { $dn++; $db += (New-Object IO.FileInfo $f).Length }
        } catch {}
        if ($dn -lt $sn) { $problems += "$rel ($($sn - $dn) file(s) short - likely locked or in use)" }
        $copied++
        $bytes += $db
    }

    # Everything above was written by the elevated worker. If the destination profile does
    # not actually grant its own user access, the copy "succeeds" and the client signs in
    # to folders they cannot open - a failure that would otherwise surface hours later.
    try {
        $dsid = Get-UserSid $dstUser
        $acl = Get-Acl -LiteralPath $dstPath -ErrorAction Stop
        $hasUser = $false
        foreach ($ace in $acl.Access) {
            $id = ''
            try { $id = ('' + $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value) } catch { $id = '' }
            if ($id -and $dsid -and $id -eq $dsid) { $hasUser = $true; break }
        }
        if (-not $hasUser) {
            $problems += "$dstUser has no permission entry on its own profile folder - sign in as that account and confirm the files open"
        }
    } catch {}

    $detail = "$copied item(s) copied, $(Format-SizeW $bytes) into $dstPath; source left untouched"
    if ($failed) { $detail += "; $failed failed outright" }
    if ($problems.Count) { $detail += ". Check: " + (($problems | Select-Object -First 4) -join ', ') }
    if ($problems.Count -gt 4) { $detail += " (+$($problems.Count - 4) more)" }
    # Anything skipped is worth the technician's attention but is not a failed migration -
    # a file open in Word is the normal case, not a broken run. Say which, precisely.
    if ($failed) { Write-Status $app.id 'Failed' $detail }
    elseif ($problems.Count) { Write-Status $app.id 'Skipped' $detail }
    else { Write-Status $app.id 'Applied' $detail }
}

# the GUI's Format-Size lives in the other process; the worker needs its own
function Format-SizeW([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

# ---------- toolbox repairs ----------
# Each returns a detail string, or throws. They are deliberately verbose about what they
# actually did: "Windows Update - Reset" that silently does nothing is worse than useless
# on a client machine, because you move on believing it is fixed.
function Invoke-Fix($app) {
    $id = [string]$app.fix
    Write-Status $app.id 'Applying' ''
    switch ($id) {

        'autologon' {
            $u = [string]$app.alUser
            $pw = [string]$app.alPassword
            if (-not $u) { Write-Status $app.id 'Failed' 'no account name given'; return }
            if (-not (Get-LocalUser -Name $u -ErrorAction SilentlyContinue)) {
                Write-Status $app.id 'Failed' "no local account called $u"; return
            }
            $k = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            Set-Reg $k 'AutoAdminLogon' '1' 'String'
            Set-Reg $k 'DefaultUserName' $u 'String'
            Set-Reg $k 'DefaultDomainName' $env:COMPUTERNAME 'String'
            if ($pw) { Set-Reg $k 'DefaultPassword' $pw 'String' } else { Remove-RegVal $k 'DefaultPassword' }
            # a stale count makes Windows stop auto-logging-on after N reboots
            Remove-RegVal $k 'AutoLogonCount'
            Write-Status $app.id 'Applied' "$u will sign in automatically at boot. The password is stored in the registry in clear text - treat this machine as physically trusted."
            return
        }

        'netreset' {
            $out = @()
            foreach ($c in @(@('winsock reset', 'winsock'), @('int ip reset', 'TCP/IP'), @('int ipv6 reset', 'IPv6'))) {
                & "$env:SystemRoot\System32\netsh.exe" $c[0].Split(' ') 2>&1 | Out-Null
                $out += $c[1]
            }
            & "$env:SystemRoot\System32\ipconfig.exe" /release 2>&1 | Out-Null
            & "$env:SystemRoot\System32\ipconfig.exe" /renew   2>&1 | Out-Null
            & "$env:SystemRoot\System32\ipconfig.exe" /flushdns 2>&1 | Out-Null
            Write-Status $app.id 'Skipped' "reset $($out -join ', '), released/renewed DHCP and flushed DNS - RESTART REQUIRED before the stack changes take effect"
            return
        }

        'ntp' {
            [void](Set-SvcStart 'w32time' 'Automatic')
            try { Start-Service -Name 'w32time' -ErrorAction Stop } catch {}
            & "$env:SystemRoot\System32\w32tm.exe" /config /manualpeerlist:"time.windows.com,0x9" /syncfromflags:manual /reliable:YES /update 2>&1 | Out-Null
            $rc = $LASTEXITCODE
            $sync = (& "$env:SystemRoot\System32\w32tm.exe" /resync 2>&1) -join ' '
            $now = (Get-Date).ToString('HH:mm:ss')
            if ($rc -ne 0) { Write-Status $app.id 'Skipped' "time source set but w32tm returned $rc; clock now $now. $sync"; return }
            Write-Status $app.id 'Applied' "time source set to time.windows.com and resynced - clock now $now"
            return
        }

        'sfc' {
            # Both tools are slow and chatty; capture the verdict rather than the progress.
            $sfc = & "$env:SystemRoot\System32\sfc.exe" /scannow 2>&1
            $sfcTxt = ($sfc | Out-String) -replace "`0", ''
            $sfcFound = ($sfcTxt -match '(?i)did find|found corrupt')
            $sfcFixed = ($sfcTxt -match '(?i)successfully repaired')
            $dism = & "$env:SystemRoot\System32\Dism.exe" /Online /Cleanup-Image /RestoreHealth 2>&1
            $dismTxt = ($dism | Out-String)
            $dismOk = ($dismTxt -match '(?i)completed successfully')
            $d = 'sfc: ' + $(if ($sfcFound -and $sfcFixed) { 'found and repaired corruption' }
                             elseif ($sfcFound) { 'found corruption it could NOT repair - check CBS.log' }
                             else { 'no integrity violations' })
            $d += '; DISM: ' + $(if ($dismOk) { 'image restored successfully' } else { 'did not report success - see DISM.log' })
            if ($sfcFound -and -not $sfcFixed) { Write-Status $app.id 'Failed' $d } else { Write-Status $app.id 'Applied' $d }
            return
        }

        'wureset' {
            $svcs = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
            foreach ($s in $svcs) { try { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue } catch {} }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $moved = @()
            foreach ($pair in @(@("$env:SystemRoot\SoftwareDistribution", "SoftwareDistribution.old-$stamp"),
                                @("$env:SystemRoot\System32\catroot2", "catroot2.old-$stamp"))) {
                if (Test-Path -LiteralPath $pair[0]) {
                    try { Rename-Item -LiteralPath $pair[0] -NewName $pair[1] -Force -ErrorAction Stop; $moved += $pair[1] }
                    catch { }
                }
            }
            foreach ($s in $svcs) { try { Start-Service -Name $s -ErrorAction SilentlyContinue } catch {} }
            if (-not $moved.Count) {
                Write-Status $app.id 'Skipped' 'services restarted, but the update caches were locked and could not be renamed - retry after a reboot'
                return
            }
            Write-Status $app.id 'Applied' "update caches renamed ($($moved -join ', ')) and services restarted. Windows rebuilds them on the next update check; the .old folders can be deleted once it works."
            return
        }

        'winget' {
            $pkg = 'Microsoft.DesktopAppInstaller'
            $before = ''
            try { $before = (Get-AppxPackage -Name $pkg -ErrorAction SilentlyContinue | Select-Object -First 1).Version } catch {}
            $ok = $false
            try {
                Get-AppxPackage -AllUsers -Name $pkg -ErrorAction Stop | ForEach-Object {
                    Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction Stop
                }
                $ok = $true
            } catch {}
            $ver = ''
            try { $ver = (Get-AppxPackage -Name $pkg -ErrorAction SilentlyContinue | Select-Object -First 1).Version } catch {}
            $w = Get-Command winget.exe -ErrorAction SilentlyContinue
            if ($w) { Write-Status $app.id 'Applied' "App Installer re-registered (version $ver, was $before); winget resolves at $($w.Source)"; return }
            if ($ok) { Write-Status $app.id 'Skipped' "App Installer re-registered (version $ver) but winget.exe is still not on PATH - sign out and back in, or install App Installer from the Store"; return }
            Write-Status $app.id 'Failed' 'could not re-register App Installer - install it from the Microsoft Store (search "App Installer")'
            return
        }

        'openssh' {
            $cap = $null
            try { $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop | Select-Object -First 1 } catch {}
            if (-not $cap) { Write-Status $app.id 'Failed' 'OpenSSH Server capability not available on this build of Windows'; return }
            if ("$($cap.State)" -ne 'Installed') {
                try { Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null }
                catch { Write-Status $app.id 'Failed' "could not install OpenSSH Server: $($_.Exception.Message)"; return }
            }
            [void](Set-SvcStart 'sshd' 'Automatic')
            try { Start-Service -Name 'sshd' -ErrorAction Stop } catch {
                Write-Status $app.id 'Failed' "sshd installed but would not start: $($_.Exception.Message)"; return
            }
            $fw = 'OpenSSH Server (sshd)'
            try {
                if (-not (Get-NetFirewallRule -DisplayName $fw -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -DisplayName $fw -Direction Inbound -Action Allow -Protocol TCP `
                                        -LocalPort 22 -Profile Any -Enabled True -ErrorAction Stop | Out-Null
                }
            } catch {}
            $st = ''
            try { $st = "$((Get-Service sshd -ErrorAction SilentlyContinue).Status)" } catch {}
            Write-Status $app.id 'Applied' "sshd is $st and set to start automatically; inbound TCP 22 allowed. This machine now accepts remote shell logins - every account with a weak password is a way in."
            return
        }

        default { Write-Status $app.id 'Failed' "unknown fix id '$id'" }
    }
}

# ---------- firewall ----------
# The GUI sends an app name and its install folder, never a list of paths: the elevated
# side enumerates the executables and re-applies the protected-root rules itself. A queue
# file any user process can write to must not be able to name what gets blocked.
$script:FwProtected = @(
    $env:SystemRoot, (Join-Path $env:SystemRoot 'System32'), (Join-Path $env:SystemRoot 'SysWOW64'),
    $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:SystemDrive,
    (Join-Path $env:ProgramFiles 'Common Files'), (Join-Path ${env:ProgramFiles(x86)} 'Common Files'),
    $env:UserProfile, $env:LocalAppData, $env:AppData
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() }

function Test-FwRoot([string]$Root) {
    if (-not $Root) { return $false }
    $r = $Root.TrimEnd('\').ToLower()
    if ($r.Length -lt 4) { return $false }
    if ($script:FwProtected -contains $r) { return $false }
    $win = $env:SystemRoot.TrimEnd('\').ToLower()
    if ($r -eq $win -or $r.StartsWith($win + '\')) { return $false }
    return $true
}

# Stable across runs and machines, unlike String.GetHashCode which is only stable within
# a single process - these names have to still match the same exe next week.
function Get-PathId([string]$Path) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToLower()))
        return ([BitConverter]::ToString($b) -replace '-', '').Substring(0, 12)
    } finally { $sha.Dispose() }
}

function Get-FwFilterMap {
    $m = @{}
    try {
        foreach ($af in @(Get-NetFirewallApplicationFilter -ErrorAction Stop)) {
            $p = ('' + $af.AppPath); if (-not $p) { $p = ('' + $af.Program) }
            if ($p -and $p -ne 'Any') { $m[[string]$af.InstanceID] = $p }
        }
    } catch {}
    return $m
}

function Block-AppNetwork($app) {
    $root = ([string]$app.root).TrimEnd('\')
    $name = [string]$app.app
    $group = [string]$app.group
    Write-Status $app.id 'Applying' ''
    if (-not (Test-FwRoot $root)) { Write-Status $app.id 'Failed' "refused: $root is a system or shared root"; return }
    if (-not (Test-Path -LiteralPath $root)) { Write-Status $app.id 'Failed' "folder no longer exists: $root"; return }

    $exes = @()
    try { $exes = @([IO.Directory]::EnumerateFiles($root, '*.exe', 'AllDirectories')) } catch {}
    if (-not $exes.Count) { Write-Status $app.id 'Skipped' 'no executables found in that folder'; return }

    # skip anything already covered, so re-running does not pile up duplicates
    $existing = @{}
    $fmap = Get-FwFilterMap
    try {
        foreach ($r in @(Get-NetFirewallRule -Direction Outbound -Action Block -ErrorAction Stop)) {
            $p = $fmap[[string]$r.InstanceID]
            if ($p) { $existing[$p.ToLower()] = $true }
        }
    } catch {}

    $stamp = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    $pub = [string]$app.publisher
    $added = 0; $skipped = 0; $failed = 0
    foreach ($exe in $exes) {
        if ($existing.ContainsKey($exe.ToLower())) { $skipped++; continue }
        try {
            # -Name is the rule's identity and must be unique. Deriving it from a hash of
            # the exe path makes it deterministic, so Windows itself rejects a duplicate
            # even if the path check above ever misses one - idempotency enforced by the
            # system rather than only by our own bookkeeping.
            $rid = 'PC2Go-Block-' + (Get-PathId $exe)
            # Everything a technician needs is in the Description, where wf.msc shows it and
            # an export preserves it - including how to undo this without the tool.
            $desc = "Outbound block created by PC2Go App Installer ($([string]$app.build)) on $stamp." +
                    "`r`nApplication: $name" + $(if ($pub) { " ($pub)" }) +
                    "`r`nExecutable: $exe" +
                    "`r`nRemove from the Firewall tab, or run:  Remove-NetFirewallRule -Group `"$group`""
            New-NetFirewallRule -Name $rid `
                                -DisplayName "PC2Go | $name | $([IO.Path]::GetFileName($exe))" `
                                -Description $desc `
                                -Group $group -Direction Outbound -Action Block -Program $exe `
                                -Profile Any -Enabled True -ErrorAction Stop | Out-Null
            $added++
        } catch {
            # a name clash means the rule already exists - that is a skip, not a failure
            if ("$($_.Exception.Message)" -match 'already exists|duplicate') { $skipped++ } else { $failed++ }
        }
    }
    # ONE wording for both outcomes. The batch summary parses these counts, and having a
    # separate sentence for the fully-blocked case is exactly how the totals silently came
    # out empty - the phrase the parser looked for only existed in one of the two branches.
    $detail = "$added rule(s) added, $skipped already blocked"
    if ($failed) { $detail += ", $failed failed" }
    if ($added -eq 0 -and $failed -eq 0 -and $skipped -gt 0) {
        # nothing new is its own outcome: amber, so a repeat run never looks like fresh work
        Write-Status $app.id 'Skipped' "$detail - nothing to do, this app was already fully blocked"
        return
    }
    $detail += '. Running copies keep their current connections until restarted.'
    if ($failed -and -not $added) { Write-Status $app.id 'Failed' $detail } else { Write-Status $app.id 'Applied' $detail }
}

function Unblock-AppNetwork($app) {
    $root = ([string]$app.root).TrimEnd('\')
    Write-Status $app.id 'Applying' ''
    if (-not (Test-FwRoot $root)) { Write-Status $app.id 'Failed' "refused: $root is a system or shared root"; return }
    $prefix = $root.ToLower() + '\'
    $fmap = Get-FwFilterMap
    $removed = 0; $failed = 0; $foreign = 0
    try {
        foreach ($r in @(Get-NetFirewallRule -Direction Outbound -Action Block -ErrorAction Stop)) {
            $p = $fmap[[string]$r.InstanceID]
            if (-not $p) { continue }
            if (-not $p.ToLower().StartsWith($prefix)) { continue }
            if (('' + $r.Group) -ne [string]$app.group) { $foreign++ }
            try { Remove-NetFirewallRule -Name ('' + $r.Name) -ErrorAction Stop; $removed++ } catch { $failed++ }
        }
    } catch { Write-Status $app.id 'Failed' "could not read firewall rules: $($_.Exception.Message)"; return }
    if (-not $removed -and -not $failed) { Write-Status $app.id 'Skipped' 'no block rules pointed at that folder'; return }
    $detail = "$removed rule(s) removed"
    if ($foreign) { $detail += " ($foreign of them created by something other than this tool)" }
    if ($failed) { $detail += ", $failed could not be removed" }
    $detail += '. Internet access is restored immediately.'
    if ($failed -and -not $removed) { Write-Status $app.id 'Failed' $detail } else { Write-Status $app.id 'Applied' $detail }
}

# Removal by explicit rule NAME, for rules under shared roots that Test-FwRoot refuses and
# that therefore cannot be addressed by folder. The queue file is writable by any process
# running as this user, so a name arriving here is a REQUEST, not an instruction: each one is
# looked up and must independently prove it is an outbound Block rule before being touched.
# That way a mangled or malicious queue can never delete an Allow rule or a Windows system rule.
function Remove-NamedFwRules($app) {
    Write-Status $app.id 'Applying' ''
    $want = @($app.rules | Where-Object { $_ })
    if (-not $want.Count) { Write-Status $app.id 'Skipped' 'no rule names supplied'; return }
    # Second constraint beyond direction/action: the rule's program must live under the folder
    # the GUI said it was clearing. Without it a garbled queue entry could name ANY outbound
    # block rule on the machine - including an administrator's deliberate egress policy.
    $folder = ([string]$app.folder).TrimEnd('\')
    $prefix = $(if ($folder) { $folder.ToLower() + '\' } else { '' })
    $fmap = Get-FwFilterMap
    $removed = 0; $failed = 0; $refused = 0; $missing = 0; $foreign = 0; $outside = 0
    foreach ($n in $want) {
        $r = $null
        try { $r = Get-NetFirewallRule -Name ('' + $n) -ErrorAction Stop } catch { $missing++; continue }
        if (("$($r.Direction)" -ne 'Outbound') -or ("$($r.Action)" -ne 'Block')) { $refused++; continue }
        if ($prefix) {
            $p = $fmap[[string]$r.InstanceID]
            if (-not $p -or -not $p.ToLower().StartsWith($prefix)) { $outside++; continue }
        }
        if (('' + $r.Group) -ne [string]$app.group) { $foreign++ }
        try { Remove-NetFirewallRule -Name ('' + $r.Name) -ErrorAction Stop; $removed++ } catch { $failed++ }
    }
    $detail = "$removed rule(s) removed"
    if ($foreign)  { $detail += " ($foreign of them created by something other than this tool)" }
    if ($missing)  { $detail += ", $missing already gone" }
    if ($refused)  { $detail += ", $refused refused - not an outbound block rule" }
    if ($outside)  { $detail += ", $outside refused - outside $folder" }
    if ($failed)   { $detail += ", $failed failed" }
    # Everything refused is a security-relevant event, not a quiet no-op: report it as failed
    # so it is red in the log rather than amber.
    if ($removed -eq 0 -and ($refused -or $outside)) { Write-Status $app.id 'Failed' "$detail - nothing was removed"; return }
    if ($removed -eq 0 -and $failed -eq 0) { Write-Status $app.id 'Skipped' "$detail - nothing to do"; return }
    if ($failed -and -not $removed) { Write-Status $app.id 'Failed' $detail } else { Write-Status $app.id 'Applied' $detail }
}

function Apply-Pref($app) {
    $id = [string]$app.pref
    $want = [string]$app.state
    $d = @($script:PrefDefs | Where-Object { $_.id -eq $id })[0]
    if (-not $d) { Write-Status $app.id 'Failed' "unknown preference id '$id'"; return }
    Write-Status $app.id 'Applying' ''
    $ops = @(if ($want -eq 'on') { $d.on } else { $d.off })
    $n = 0
    foreach ($op in $ops) {
        # v = $null deletes the value, which restores the Windows default rather than
        # writing a guess at what that default is
        if ($null -eq $op.v) { Remove-RegVal $op.p $op.n }
        else {
            $type = 'DWord'; if ($op.t) { $type = [string]$op.t }
            Set-Reg $op.p $op.n $op.v $type
        }
        $n++
    }
    Write-Status $app.id 'Applied' "turned $want"
}

function Apply-Tweak($app) {
    $id = [string]$app.tweak
    Write-Status $app.id 'Applying' ''
    $detail = ''
    switch ($id) {

        # ---------------- Essential ----------------
        'activityhistory' {
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
            $detail = 'activity feed, publish and upload disabled'
        }
        'bitlocker' {
            # Automatic device encryption is blocked. Volumes that are ALREADY encrypted
            # are reported, never silently decrypted - that is hours of disk I/O on a
            # client machine and not something to trigger from a checkbox.
            Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 1
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\FVE' 'PreventDeviceEncryption' 1
            $enc = @()
            try { $enc = @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.ProtectionStatus -eq 'On' }) } catch {}
            $detail = 'automatic device encryption blocked'
            if ($enc.Count) { $detail += "; $($enc.Count) volume(s) already encrypted - left untouched, decrypt manually if required" }
        }
        'consumerfeatures' {
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 1
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
            $detail = 'suggested apps and consumer content disabled'
        }
        'deliveryopt' {
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
            Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 0
            [void](Set-SvcStart 'DoSvc' 'Manual')
            $detail = 'peer-to-peer update sharing off (HTTP only)'
        }
        'diskcleanup' {
            & "$env:SystemRoot\System32\cleanmgr.exe" /d C: /VERYLOWDISK 2>&1 | Out-Null
            & "$env:SystemRoot\System32\Dism.exe" /Online /Cleanup-Image /StartComponentCleanup /Quiet 2>&1 | Out-Null
            $detail = 'cleanmgr and component store cleanup completed'
        }
        'endtask' {
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 1
            $detail = 'End Task added to the taskbar right-click menu'
        }
        'folderdiscovery' {
            [void](Remove-RegKey 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell')
            Set-Reg 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' 'FolderType' 'NotSpecified' 'String'
            $detail = 'all folders forced to General Items layout'
        }
        'hibernation' {
            & "$env:SystemRoot\System32\powercfg.exe" /hibernate off 2>&1 | Out-Null
            Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 0
            Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabledDefault' 0
            $detail = 'hibernation off, hiberfil.sys reclaimed'
        }
        'location' {
            Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' 'SensorPermissionState' 0
            Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration' 'Status' 0
            Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'
            [void](Set-SvcStart 'lfsvc' 'Manual')
            $detail = 'location sensor and consent denied machine-wide'
        }
        'storesearch' {
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
            Set-Reg 'HKCU\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1
            $detail = 'web and store suggestions removed from search'
        }
        'devicecompanion' {
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1
            Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0
            $detail = 'device metadata and companion-app fetch blocked'
        }
        'restorepoint' {
            try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop } catch {}
            # Windows silently refuses a second restore point within 24h; 0 lifts that
            Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
            Checkpoint-Computer -Description 'PC2Go App Installer - before tweaks' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
            $detail = 'restore point created'
        }
        'servicesmanual' {
            $n = 0; $miss = 0
            foreach ($svc in $script:ManualServices) {
                if (Set-SvcStart $svc 'Manual') { $n++ } else { $miss++ }
            }
            $detail = "$n service(s) set to Manual, $miss not present on this machine"
        }
        'startlayout' {
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_ShowClassicMode' 1
            $detail = 'classic Start layout enabled (sign out to apply)'
        }
        'telemetry' {
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
            Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
            Set-Reg 'HKCU\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
            [void](Set-SvcStart 'DiagTrack' 'Disabled')
            [void](Set-SvcStart 'dmwappushservice' 'Disabled')
            $t = 0
            $t += [int](Disable-Task '\Microsoft\Windows\Application Experience\' 'Microsoft Compatibility Appraisal')
            $t += [int](Disable-Task '\Microsoft\Windows\Application Experience\' 'ProgramDataUpdater')
            $t += [int](Disable-Task '\Microsoft\Windows\Customer Experience Improvement Program\' 'Consolidator')
            $t += [int](Disable-Task '\Microsoft\Windows\Customer Experience Improvement Program\' 'UsbCeip')
            $t += [int](Disable-Task '\Microsoft\Windows\DiskDiagnostic\' 'Microsoft-Windows-DiskDiagnosticDataCollector')
            $detail = "telemetry policy set, DiagTrack disabled, $t scheduled task(s) disabled"
        }
        'tempfiles' {
            $freed = 0; $n = 0
            foreach ($dir in @($env:TEMP, (Join-Path $env:SystemRoot 'Temp'))) {
                if (-not (Test-Path -LiteralPath $dir)) { continue }
                foreach ($e in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
                    try {
                        $sz = 0
                        if ($e.PSIsContainer) { $sz = 0 } else { $sz = $e.Length }
                        Remove-Item -LiteralPath $e.FullName -Recurse -Force -ErrorAction Stop
                        $freed += $sz; $n++
                    } catch {}
                }
            }
            $detail = "$n temp item(s) removed"
        }
        'widgets' {
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
            $n = Remove-AppxByName 'MicrosoftWindows.Client.WebExperience'
            $detail = "widgets hidden and disabled by policy; $n package(s) removed"
        }
        'wpbt' {
            Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1
            $detail = 'OEM firmware-injected binaries blocked (reboot to apply)'
        }

        # ---------------- Advanced (CAUTION) ----------------
        'adobeblock' {
            # Appended between markers so the block is identifiable and reversible, and
            # the client's own hosts entries are never touched.
            $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
            $domains = @(
                'lm.licenses.adobe.com', 'na1r.services.adobe.com', 'hlrcv.stage.adobe.com',
                'practivate.adobe.com', 'activate.adobe.com', 'ereg.adobe.com',
                'wip3.adobe.com', 'activate.wip3.adobe.com', 'genuine.adobe.com',
                'prod.adobegenuine.com', 'ic.adobe.io', 'adobe-dns.adobe.com',
                'k.sni.global.fastly.net', 'cc-api-data.adobe.io'
            )
            $existing = @()
            if (Test-Path -LiteralPath $hostsFile) { $existing = @(Get-Content -LiteralPath $hostsFile -ErrorAction SilentlyContinue) }
            $add = @($domains | Where-Object { $d = $_; -not ($existing | Where-Object { $_ -match "\s$([regex]::Escape($d))\s*$" }) })
            if ($add.Count) {
                $block = @('', '# PC2Go Adobe block list - begin') +
                         @($add | ForEach-Object { "0.0.0.0 $_" }) +
                         @('# PC2Go Adobe block list - end')
                Add-Content -LiteralPath $hostsFile -Value $block -Encoding ASCII -ErrorAction Stop
            }
            $detail = "$($add.Count) domain(s) added to the hosts block list"
        }
        'backgroundapps' {
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
            $detail = 'UWP background execution disabled'
        }
        'bravedebloat' {
            foreach ($kv in @(@('BraveRewardsDisabled', 1), @('BraveWalletDisabled', 1), @('BraveVPNDisabled', 1),
                              @('BraveAIChatEnabled', 0), @('TorDisabled', 1), @('BraveSpeedreaderEnabled', 0),
                              @('PasswordManagerEnabled', 0), @('MetricsReportingEnabled', 0))) {
                Set-Reg 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' $kv[0] $kv[1]
            }
            $detail = 'Rewards, Wallet, VPN, Tor and AI chat disabled by policy'
        }
        'utctime' {
            Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal' 1
            $detail = 'hardware clock now interpreted as UTC'
        }
        'reservedstorage' {
            & "$env:SystemRoot\System32\Dism.exe" /Online /Set-ReservedStorageState /State:Disabled 2>&1 | Out-Null
            $detail = 'reserved storage disabled'
        }
        'explorerhome' {
            $r = 0
            $r += [int](Remove-RegKey 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_36354489\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}')
            $r += [int](Remove-RegKey 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_36354489\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}')
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1
            $detail = "$r namespace entr(ies) removed; Explorer opens on This PC"
        }
        'fullscreenopt' {
            Set-Reg 'HKCU\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
            Set-Reg 'HKCU\System\GameConfigStore' 'GameDVR_FSEBehavior' 2
            Set-Reg 'HKCU\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2
            Set-Reg 'HKCU\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 1
            Set-Reg 'HKCU\System\GameConfigStore' 'GameDVR_EFSEFeatureFlags' 0
            $detail = 'fullscreen optimizations disabled'
        }
        'ipv6disable' {
            Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 255
            $n = 0
            try {
                foreach ($b in @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction Stop | Where-Object { $_.Enabled })) {
                    try { Disable-NetAdapterBinding -Name $b.Name -ComponentID ms_tcpip6 -ErrorAction Stop; $n++ } catch {}
                }
            } catch {}
            $detail = "IPv6 disabled in registry and unbound from $n adapter(s) - reboot to apply"
        }
        'ipv4prefer' {
            Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 32
            $detail = 'IPv4 preferred over IPv6 (IPv6 left enabled) - reboot to apply'
        }
        'edgedebloat' {
            foreach ($kv in @(@('PersonalizationReportingEnabled', 0), @('ShowRecommendationsEnabled', 0),
                              @('HideFirstRunExperience', 1), @('UserFeedbackAllowed', 0),
                              @('ConfigureDoNotTrack', 1), @('AlternateErrorPagesEnabled', 0),
                              @('EdgeCollectionsEnabled', 0), @('EdgeShoppingAssistantEnabled', 0),
                              @('MicrosoftEdgeInsiderPromotionEnabled', 0), @('ShowMicrosoftRewards', 0),
                              @('WebWidgetAllowed', 0), @('DiagnosticData', 0),
                              @('EdgeAssetDeliveryServiceEnabled', 0), @('CryptoWalletEnabled', 0),
                              @('WalletDonationEnabled', 0), @('SpotlightExperiencesAndRecommendationsEnabled', 0))) {
                Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Edge' $kv[0] $kv[1]
            }
            $detail = 'Edge telemetry, shopping, rewards and widgets disabled by policy'
        }
        'edgeremove' {
            # Edge resists removal and Windows Update reinstalls it; the uninstaller is
            # run where present and the reinstall blocked, but this can revert.
            $done = 0
            foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
                if (-not $root) { continue }
                $appDir = Join-Path $root 'Microsoft\Edge\Application'
                if (-not (Test-Path -LiteralPath $appDir)) { continue }
                foreach ($v in @(Get-ChildItem -LiteralPath $appDir -Directory -ErrorAction SilentlyContinue)) {
                    $setup = Join-Path $v.FullName 'Installer\setup.exe'
                    if (Test-Path -LiteralPath $setup) {
                        try {
                            Start-Process -FilePath $setup -ArgumentList '--uninstall --system-level --verbose-logging --force-uninstall' -Wait -ErrorAction Stop
                            $done++
                        } catch {}
                    }
                }
            }
            Set-Reg 'HKLM\SOFTWARE\Microsoft\EdgeUpdate' 'DoNotUpdateToEdgeWithChromium' 1
            [void](Remove-AppxByName 'Microsoft.MicrosoftEdge*')
            $detail = "$done Edge installation(s) uninstalled; chromium reinstall blocked"
            if ($done -eq 0) { $detail = 'no removable Edge installer found - Edge may be OS-integrated on this build' }
        }
        'onedriveremove' {
            Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            $done = 0
            foreach ($setup in @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe")) {
                if (Test-Path -LiteralPath $setup) {
                    try { Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -ErrorAction Stop; $done++ } catch {}
                }
            }
            # Explorer sidebar entries survive the uninstaller
            foreach ($clsid in @('HKLM\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
                                 'HKLM\SOFTWARE\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}')) {
                try { Set-Reg $clsid 'System.IsPinnedToNameSpaceTree' 0 } catch {}
            }
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
            $detail = "$done OneDrive uninstaller(s) run; sync disabled by policy and sidebar entry hidden"
        }
        'razerdisable' {
            # Razer Synapse arrives as a device 'companion app' through Windows Update
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1
            Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' 'DontSearchWindowsUpdate' 1
            $k = 0
            foreach ($svc in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Razer*' })) {
                if (Set-SvcStart $svc.Name 'Disabled') { $k++ }
            }
            $detail = "auto-install of device companion apps blocked; $k Razer service(s) disabled"
        }
        'rdpwarnings' {
            Set-Reg 'HKCU\Software\Microsoft\Terminal Server Client' 'AuthenticationLevelOverride' 0
            $detail = 'unsigned .rdp publisher warnings suppressed'
        }
        'rightclickmenu' {
            # empty InprocServer32 default value = Windows 11 falls back to the full menu
            $p = Resolve-Reg 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
            if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $p -Name '(Default)' -Value '' -PropertyType String -Force -ErrorAction Stop | Out-Null
            $detail = 'classic right-click menu enabled (restart Explorer to apply)'
        }
        'storagesense' {
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 0
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\StorageSense' 'AllowStorageSenseGlobal' 0
            $detail = 'Storage Sense turned off'
        }
        'traynotify' {
            Set-Reg 'HKCU\Software\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' 0
            $detail = 'notification centre, calendar flyout and toasts disabled'
        }
        'teredo' {
            & "$env:SystemRoot\System32\netsh.exe" interface teredo set state disabled 2>&1 | Out-Null
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\TCPIP\v6Transition' 'Teredo_State' 'Disabled' 'String'
            $detail = 'Teredo tunnelling disabled'
        }
        'visualeffects' {
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
            Set-Reg 'HKCU\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
            Set-Reg 'HKCU\Control Panel\Desktop' 'DragFullWindows' '0' 'String'
            Set-Reg 'HKCU\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
            Set-Reg 'HKCU\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 0
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
            Set-Reg 'HKCU\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
            $detail = 'visual effects set to best performance (sign out to fully apply)'
        }
        'windowsai' {
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
            Set-Reg 'HKCU\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
            Set-Reg 'HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0
            $n = 0
            foreach ($pat in @('Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider', 'MicrosoftWindows.Client.CoPilot')) {
                $n += Remove-AppxByName $pat
            }
            try { Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -NoRestart -ErrorAction Stop | Out-Null } catch {}
            $detail = "Recall and Copilot disabled by policy; $n package(s) removed"
        }

        default { Write-Status $app.id 'Failed' "unknown tweak id '$id'"; return }
    }
    Write-Status $app.id 'Applied' $detail
}

# ---------- undo ----------
# Undo restores the DOCUMENTED WINDOWS DEFAULT, it does not replay a captured snapshot -
# keeping a state file would leave exactly the permanent footprint this tool promises not
# to. For policy values that means deleting the value so Windows reverts on its own, which
# is exact. Actions that deleted files or removed apps cannot be put back and say so.
function Remove-RegVal([string]$Path, [string]$Name) {
    $p = Resolve-Reg $Path
    if (Test-Path -LiteralPath $p) { Remove-ItemProperty -LiteralPath $p -Name $Name -Force -ErrorAction SilentlyContinue }
}

# Windows 10/11 stock startup type for every service the Manual tweak touches. Most are
# already Manual out of the box, so undo only really moves the handful that are not.
$script:ServiceDefaults = @{
    'DiagTrack' = 'Automatic'; 'dmwappushservice' = 'Manual'
    'diagnosticshub.standardcollector.service' = 'Manual'; 'WerSvc' = 'Manual'
    'Fax' = 'Manual'; 'RemoteRegistry' = 'Disabled'; 'RetailDemo' = 'Manual'
    'MapsBroker' = 'Automatic'; 'WMPNetworkSvc' = 'Manual'; 'PcaSvc' = 'Automatic'
    'XblAuthManager' = 'Manual'; 'XblGameSave' = 'Manual'; 'XboxNetApiSvc' = 'Manual'
    'XboxGipSvc' = 'Manual'; 'SCardSvr' = 'Manual'; 'ScDeviceEnum' = 'Manual'
    'SEMgrSvc' = 'Manual'; 'PhoneSvc' = 'Manual'; 'TapiSrv' = 'Manual'
    'WalletService' = 'Manual'; 'WpcMonSvc' = 'Manual'; 'SharedAccess' = 'Manual'
    'lfsvc' = 'Manual'; 'TrkWks' = 'Automatic'; 'AJRouter' = 'Manual'
    'SensorService' = 'Manual'; 'SensrSvc' = 'Manual'; 'SensorDataService' = 'Manual'
    'WbioSrvc' = 'Manual'; 'iphlpsvc' = 'Automatic'; 'p2pimsvc' = 'Manual'
    'p2psvc' = 'Manual'; 'PNRPsvc' = 'Manual'; 'PNRPAutoReg' = 'Manual'
    'SSDPSRV' = 'Manual'; 'upnphost' = 'Manual'; 'wisvc' = 'Manual'; 'PerfHost' = 'Manual'
}

function Undo-Tweak($app) {
    $id = [string]$app.tweak
    Write-Status $app.id 'Undoing' ''
    $detail = ''
    switch ($id) {

        'activityhistory' {
            foreach ($v in 'EnableActivityFeed', 'PublishUserActivities', 'UploadUserActivities') {
                Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' $v
            }
            $detail = 'activity history policy removed - Windows default restored'
        }
        'bitlocker' {
            Remove-RegVal 'HKLM\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption'
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\FVE' 'PreventDeviceEncryption'
            $detail = 'automatic device encryption allowed again'
        }
        'consumerfeatures' {
            foreach ($v in 'DisableWindowsConsumerFeatures', 'DisableConsumerAccountStateContent', 'DisableSoftLanding') {
                Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' $v
            }
            $detail = 'consumer features policy removed'
        }
        'deliveryopt' {
            Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 1
            Remove-RegVal 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode'
            [void](Set-SvcStart 'DoSvc' 'Automatic')
            $detail = 'delivery optimization back to LAN peering (default)'
        }
        'diskcleanup'  { Write-Status $app.id 'Skipped' 'one-time cleanup - nothing to undo'; return }
        'tempfiles'    { Write-Status $app.id 'Skipped' 'deleted temp files cannot be restored'; return }
        'restorepoint' { Write-Status $app.id 'Skipped' 'restore points are left in place deliberately'; return }
        'endtask' {
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 0
            $detail = 'End Task removed from the taskbar menu'
        }
        'folderdiscovery' {
            [void](Remove-RegKey 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell')
            $detail = 'automatic folder type discovery restored'
        }
        'hibernation' {
            & "$env:SystemRoot\System32\powercfg.exe" /hibernate on 2>&1 | Out-Null
            Remove-RegVal 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
            Remove-RegVal 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabledDefault'
            $detail = 'hibernation re-enabled'
        }
        'location' {
            Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' 'SensorPermissionState' 1
            Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration' 'Status' 1
            Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Allow' 'String'
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Allow' 'String'
            [void](Set-SvcStart 'lfsvc' 'Manual')
            $detail = 'location services allowed again'
        }
        'storesearch' {
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions'
            Remove-RegVal 'HKCU\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions'
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch'
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 1
            $detail = 'web and store search suggestions restored'
        }
        'devicecompanion' {
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork'
            Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 1
            $detail = 'device metadata and companion apps allowed again'
        }
        'servicesmanual' {
            $n = 0
            foreach ($svc in $script:ManualServices) {
                $def = $script:ServiceDefaults[$svc]
                if (-not $def) { continue }
                if (Set-SvcStart $svc $def) { $n++ }
            }
            $detail = "$n service(s) restored to their Windows default startup type"
        }
        'startlayout' {
            Remove-RegVal 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_ShowClassicMode'
            $detail = 'default Start layout restored'
        }
        'telemetry' {
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry'
            Remove-RegVal 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry'
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications'
            [void](Set-SvcStart 'DiagTrack' 'Automatic')
            [void](Set-SvcStart 'dmwappushservice' 'Manual')
            foreach ($t in @(@('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraisal'),
                             @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
                             @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
                             @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
                             @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'))) {
                try { Enable-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction Stop | Out-Null } catch {}
            }
            $detail = 'telemetry policy removed, DiagTrack and CEIP tasks re-enabled'
        }
        'widgets' {
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 1
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests'
            $detail = 'widgets button restored - the Web Experience Pack is NOT reinstalled (Store can restore it)'
        }
        'wpbt' {
            Remove-RegVal 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution'
            $detail = 'WPBT execution allowed again (reboot to apply)'
        }
        'adobeblock' {
            # only the lines between our own markers are removed; the client's entries stay
            $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
            $removed = 0
            if (Test-Path -LiteralPath $hostsFile) {
                $keep = New-Object System.Collections.ArrayList
                $inBlock = $false
                foreach ($line in @(Get-Content -LiteralPath $hostsFile -ErrorAction Stop)) {
                    if ($line -match 'PC2Go Adobe block list - begin') { $inBlock = $true; $removed++; continue }
                    if ($line -match 'PC2Go Adobe block list - end')   { $inBlock = $false; $removed++; continue }
                    if ($inBlock) { $removed++; continue }
                    [void]$keep.Add($line)
                }
                Set-Content -LiteralPath $hostsFile -Value $keep -Encoding ASCII -Force -ErrorAction Stop
            }
            $detail = "$removed hosts line(s) removed - only the PC2Go block, client entries untouched"
        }
        'backgroundapps' {
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 0
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground'
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 1
            $detail = 'background apps allowed again'
        }
        'bravedebloat' {
            [void](Remove-RegKey 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave')
            $detail = 'Brave policy overrides removed'
        }
        'utctime' {
            Remove-RegVal 'HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal'
            $detail = 'hardware clock back to local time'
        }
        'reservedstorage' {
            & "$env:SystemRoot\System32\Dism.exe" /Online /Set-ReservedStorageState /State:Enabled 2>&1 | Out-Null
            $detail = 'reserved storage re-enabled'
        }
        'explorerhome' {
            foreach ($clsid in '{f874310e-b6b7-47dc-bc84-b9e6b38f5903}', '{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}') {
                $p = Resolve-Reg "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_36354489\$clsid"
                if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force -ErrorAction SilentlyContinue | Out-Null }
            }
            Remove-RegVal 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo'
            $detail = 'Home and Gallery restored in File Explorer'
        }
        'fullscreenopt' {
            foreach ($v in 'GameDVR_DXGIHonorFSEWindowsCompatible', 'GameDVR_FSEBehavior', 'GameDVR_FSEBehaviorMode',
                           'GameDVR_HonorUserFSEBehaviorMode', 'GameDVR_EFSEFeatureFlags') {
                Remove-RegVal 'HKCU\System\GameConfigStore' $v
            }
            $detail = 'fullscreen optimizations restored'
        }
        'ipv6disable' {
            Remove-RegVal 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents'
            $n = 0
            try {
                foreach ($b in @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction Stop | Where-Object { -not $_.Enabled })) {
                    try { Enable-NetAdapterBinding -Name $b.Name -ComponentID ms_tcpip6 -ErrorAction Stop; $n++ } catch {}
                }
            } catch {}
            $detail = "IPv6 re-enabled and rebound to $n adapter(s) - reboot to apply"
        }
        'ipv4prefer' {
            Remove-RegVal 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents'
            $detail = 'default IPv6/IPv4 preference restored - reboot to apply'
        }
        'edgedebloat' {
            [void](Remove-RegKey 'HKLM\SOFTWARE\Policies\Microsoft\Edge')
            $detail = 'Edge policy overrides removed'
        }
        'edgeremove' {
            Remove-RegVal 'HKLM\SOFTWARE\Microsoft\EdgeUpdate' 'DoNotUpdateToEdgeWithChromium'
            $detail = 'reinstall block lifted - Edge is NOT reinstalled, get it from microsoft.com/edge or Windows Update'
        }
        'onedriveremove' {
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC'
            foreach ($clsid in @('HKLM\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
                                 'HKLM\SOFTWARE\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}')) {
                try { Set-Reg $clsid 'System.IsPinnedToNameSpaceTree' 1 } catch {}
            }
            $detail = 'sync policy lifted - OneDrive is NOT reinstalled'
        }
        'razerdisable' {
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork'
            Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 1
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' 'DontSearchWindowsUpdate'
            $k = 0
            foreach ($svc in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Razer*' })) {
                if (Set-SvcStart $svc.Name 'Automatic') { $k++ }
            }
            $detail = "driver companion apps allowed again; $k Razer service(s) re-enabled"
        }
        'rdpwarnings' {
            Remove-RegVal 'HKCU\Software\Microsoft\Terminal Server Client' 'AuthenticationLevelOverride'
            $detail = 'unsigned .rdp warnings restored'
        }
        'rightclickmenu' {
            [void](Remove-RegKey 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}')
            $detail = 'Windows 11 compact right-click menu restored (restart Explorer to apply)'
        }
        'storagesense' {
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 1
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\StorageSense' 'AllowStorageSenseGlobal'
            $detail = 'Storage Sense re-enabled'
        }
        'traynotify' {
            Remove-RegVal 'HKCU\Software\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter'
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 1
            Remove-RegVal 'HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'
            $detail = 'notification centre and toasts restored'
        }
        'teredo' {
            & "$env:SystemRoot\System32\netsh.exe" interface teredo set state default 2>&1 | Out-Null
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\TCPIP\v6Transition' 'Teredo_State'
            $detail = 'Teredo back to its default state'
        }
        'visualeffects' {
            # 0 = let Windows decide, which is the stock setting
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 0
            Set-Reg 'HKCU\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x9E, 0x1E, 0x07, 0x80, 0x12, 0x00, 0x00, 0x00)) 'Binary'
            Set-Reg 'HKCU\Control Panel\Desktop' 'DragFullWindows' '1' 'String'
            Set-Reg 'HKCU\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '1' 'String'
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 1
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 1
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 1
            Set-Reg 'HKCU\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 1
            $detail = 'visual effects back to the Windows default (sign out to fully apply)'
        }
        'windowsai' {
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis'
            Remove-RegVal 'HKCU\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis'
            Remove-RegVal 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'
            Remove-RegVal 'HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'
            Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 1
            $detail = 'AI policy removed - removed Copilot packages are NOT reinstalled'
        }

        default { Write-Status $app.id 'Failed' "unknown tweak id '$id'"; return }
    }
    Write-Status $app.id 'Reverted' $detail
}

$offset = 0
$finished = $false
while (-not $finished) {
    $lines = @(Get-Content -LiteralPath $QueueFile -ErrorAction SilentlyContinue)
    if ($lines.Count -le $offset) {
        if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { break }
        Start-Sleep -Milliseconds 700
        continue
    }
    for ($i = $offset; $i -lt $lines.Count; $i++) {
        $app = $null
        try { $app = $lines[$i] | ConvertFrom-Json } catch { continue }
        if ($app.end) { $finished = $true; break }
        if ($CancelFile -and (Test-Path -LiteralPath $CancelFile) -and $app.action -ne 'wipe') {
            Write-Status $app.id 'Cancelled' ''
            continue
        }
        try {
            switch ($app.action) {
                'uninstall' { Uninstall-One $app }
                'wipe'      { Wipe-One $app }
                'tweak'     {
                    # per-user tweaks must land in the technician's hive, not the
                    # elevating admin's - the GUI ships its SID with every entry
                    if ($app.userSid) { $script:UserSid = [string]$app.userSid }
                    Apply-Tweak $app
                }
                'untweak'   {
                    if ($app.userSid) { $script:UserSid = [string]$app.userSid }
                    Undo-Tweak $app
                }
                'pref'      {
                    if ($app.userSid) { $script:UserSid = [string]$app.userSid }
                    Apply-Pref $app
                }
                'fix'           { Invoke-Fix $app }
                'fwblock'       { Block-AppNetwork $app }
                'fwunblock'     { Unblock-AppNetwork $app }
                'fwunblockrules' { Remove-NamedFwRules $app }
                'newuser'       { New-LocalAdmin $app }
                'migrate'       { Copy-ProfileData $app }
                'setadmin'      { Set-AccountAdmin $app }
                'setpassword'   { Set-AccountPassword $app }
                'toggleacct'    { Set-AccountEnabled $app }
                'deleteaccount' { Remove-Account $app }
                default     { Install-One $app }
            }
        } catch { Write-Status $app.id 'Failed' $_.Exception.Message }
    }
    $offset = $lines.Count
}
Write-Status '_batch' 'Complete' ''
'@

# ---------- state machine ----------

$script:Phase = 'Idle'       # Idle | Download | Install | Done
$script:Pending = @()
$script:DlIndex = 0
$script:CurJob = $null
$script:StatusOffset = 0
$script:Busy = $false
$script:HadFailures = $false
$script:SpeedPrev = $null
$script:SpeedTxt = ''
$script:WorkerStarted = $false
$script:EndQueued = $false
$script:Paused = $false
$script:Deferred = @()
$script:DeepClean = $false
$script:AwaitingScan = $false
$script:ForceMode = $false
$script:ConfirmAction = $null
$script:PrefSyncing = $false
$script:SuspendDash = $false
$script:BatchTab = 'Install'   # which tab started the running batch, so only it shows progress
$script:UserSelecting = $false
$script:UsersLoaded = $false
$script:UserRow = $null
$script:UserSubTab = 'Accounts'
$script:ToolsLoaded = $false
$script:FwUserPicked = $false   # once the tech picks a filter, stop auto-defaulting it
$script:FwDirty = $true
$script:LastJobState = ''   # de-dupes the BITS retry log across 400ms ticks

function Start-Worker {
    # launch the single elevated worker the moment the first file is ready;
    # it then consumes the streaming queue while the GUI keeps downloading
    if ($script:WorkerStarted) { return $true }
    # single source of truth: the preference table defined in the GUI is injected into the
    # worker's own code, so the elevated side never takes registry paths off the queue
    Set-Content -Path $script:WorkerPath -Value ($workerScript.Replace('#__PREFTABLE__', $script:PrefTableSource)) -Encoding UTF8
    Remove-Item -LiteralPath $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
    $script:StatusOffset = 0
    try {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:WorkerPath`" -QueueFile `"$script:QueuePath`" -StatusFile `"$script:StatusPath`" -CancelFile `"$script:CancelPath`""
        Start-Process -FilePath $psExe -Verb RunAs -WindowStyle Hidden -ArgumentList $psArgs | Out-Null
        $script:WorkerStarted = $true
        # no prompt at all when the GUI itself already holds the elevated token - saying
        # "one UAC prompt" there would be describing something that did not happen
        Add-Log $(if ($script:Elevated) {
            'Elevated installer started (no prompt - this session is already elevated) - installs now run while remaining downloads continue.'
        } else {
            'Elevated installer started (one UAC prompt) - installs now run while remaining downloads continue.'
        })
        return $true
    } catch {
        Add-Log 'Elevation was declined - batch cancelled.'
        return $false
    }
}

function Enqueue-Install([object]$Item) {
    # hand a finished download to the elevated worker immediately
    if (-not (Start-Worker)) {
        Abort-Batch 'elevation declined'
        return
    }
    # Fetch any post-install payloads now, while the GUI still owns the download path. They
    # are small (a .bat, a licence file), so a plain request is enough - but they are handed
    # to the worker as LOCAL paths with their SHA-256, so the elevated side verifies them
    # exactly like the installer. Anything that runs elevated gets the same integrity gate.
    $steps = @()
    foreach ($st in @($Item.PostInstall)) {
        if (-not $st) { continue }
        $step = @{ type = [string]$st.type; name = [string]$st.name; args = [string]$st.args
                   sha256 = ('' + $st.sha256).ToUpper(); dest = [string]$st.dest; from = [string]$st.from
                   path = [string]$st.path; value = [string]$st.value; valueType = [string]$st.valueType
                   action = [string]$st.action; timeoutSec = [int]$st.timeoutSec }
        if ($st.url) {
            $fn = [IO.Path]::GetFileName(([Uri][string]$st.url).LocalPath)
            if (-not $fn) { $fn = "post-$([Guid]::NewGuid().ToString('N').Substring(0,8))" }
            $local = Join-Path $script:CacheDir $fn
            if (-not (Test-Path -LiteralPath $local)) {
                try {
                    Add-Log "$($Item.Name): fetching post-install file $fn"
                    Invoke-WebRequest -Uri ([string]$st.url) -OutFile $local -UseBasicParsing -TimeoutSec 60
                } catch {
                    Add-Log "$($Item.Name): could not download post-install file $fn - $($_.Exception.Message)"
                    Set-Status $Item "Failed: post-install file $fn unavailable" 'fail'
                    Set-Ring $Item 'fail'
                    $script:HadFailures = $true
                    return
                }
            }
            $step['file'] = $local
        }
        $steps += $step
    }
    if ($steps.Count) { Add-Log "$($Item.Name): $($steps.Count) post-install step(s) queued." }

    # Snapshot whether the product is ALREADY on disk, now, before anything runs. If this
    # install later fails dirty, this is the difference between "everything the scan finds
    # is debris" and "some of what the scan finds is the working copy that was here first".
    # Checked from the GUI rather than the worker: verifyPaths are readable unelevated, and
    # the answer has to be recorded against the row the technician is looking at.
    $Item.PreExisting = $false
    foreach ($vp in @($Item.VerifyPaths)) {
        if ($vp -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($vp)))) {
            $Item.PreExisting = $true
            break
        }
    }

    $entry = @{
        id = $Item.Id; action = 'install'; file = (Join-Path $script:CacheDir $Item.FileName)
        sha256 = $Item.Sha256; silentArgs = $Item.SilentArgs; verifyPaths = @($Item.VerifyPaths)
        entry = $Item.Entry; postInstall = $steps
    } | ConvertTo-Json -Compress -Depth 6
    Add-Content -Path $script:QueuePath -Value $entry -Encoding UTF8
    Set-Status $Item 'Queued for install' 'ready'
    $Item.Progress = 100
    Set-Ring $Item 'download'
}

function Abort-Batch([string]$Reason) {
    if ($script:CurJob) { Remove-BitsTransfer -BitsJob $script:CurJob -ErrorAction SilentlyContinue; $script:CurJob = $null }
    foreach ($p in $script:Pending) {
        if ($p.Status -notlike 'Installed*' -and $p.Status -notlike 'Failed*') { Set-Status $p "Failed: $Reason" 'fail'; Set-Ring $p 'fail' }
    }
    $script:HadFailures = $true
    Finish-Batch
}

function Read-WorkerStatus {
    if (-not (Test-Path $script:StatusPath)) { return }
    $lines = @(Get-Content $script:StatusPath -ErrorAction SilentlyContinue)
    for ($i = $script:StatusOffset; $i -lt $lines.Count; $i++) {
        $s = $null
        try { $s = $lines[$i] | ConvertFrom-Json } catch { continue }
        if ($s.id -eq '_batch') { $script:StatusOffset = $lines.Count; Finish-Batch; return }
        $item = $script:Pending | Where-Object { $_.Id -eq $s.id } | Select-Object -First 1
        if ($item) {
            # the worker's verdict that this failure left files behind - it is what puts the
            # row into the leftover scan once the rest of the batch has reported
            if ($s.dirty) { $item.Dirty = $true }
            if ($s.created) {
                $item.CreatedPaths = @($s.created)
                Add-Log "$($item.Name) installed into: $(@($s.created) -join ', ')"
            }
            $txt = $s.state; if ($s.detail) { $txt += ": $($s.detail)" }
            $kind = 'active'; $ring = 'busy'
            if ($s.state -in 'Installed', 'Uninstalled', 'Cleaned', 'Applied', 'Reverted') { $kind = 'ok'; $ring = 'ok' }
            elseif ($s.state -eq 'Failed') { $kind = 'fail'; $ring = 'fail' }
            elseif ($s.state -in 'Cancelled', 'Skipped') { $kind = 'warn'; $ring = 'warn' }
            # Wiping the debris of a failed install does not make the install a success.
            # Without this the row would go green on 'Cleaned' and the batch would count it
            # as done - the one outcome a technician must never be told.
            if ($s.state -eq 'Cleaned' -and $item.Dirty) {
                $txt = "Failed: partial install removed - $($s.detail)"
                $kind = 'fail'; $ring = 'fail'
            }
            Set-Status $item $txt $kind
            Set-Ring $item $ring
            if ($s.state -in 'Verifying file', 'Installing', 'Uninstalling', 'Applying', 'Undoing') {
                $TxtNow.Text = "$($s.state): $($item.Name)"
                $DotNow.Fill = '#FF4C8DFF'
            }
            # Log EVERY status the worker reports, not only the terminal ones. The elevated
            # side runs invisibly, so its intermediate steps ("Verifying file", "copying
            # Documents") are the only trace of what actually happened in there. Each status
            # is read once from the queue, so this cannot spam.
            Add-Log "$($item.Name) -> $txt"
        }
    }
    $script:StatusOffset = $lines.Count

    # deep clean: once every item has reported, scan for leftovers and show the kill list.
    # An uninstall batch always scans. An install batch scans only when something actually
    # failed dirty - a clean run must not make the technician sit through a leftover sweep.
    if ($script:AwaitingScan) {
        $busy = @($script:Pending | Where-Object {
            $_.Status -notmatch '^(Installed|Uninstalled|Cleaned|Applied|Reverted|Failed|Cancelled|Skipped)' })
        if ($busy.Count -eq 0) {
            $script:AwaitingScan = $false
            # A cancel or an abort already released the worker, and the wipe needs it alive.
            # Offering a kill list nothing could act on would be worse than not offering one.
            if ($script:EndQueued) { return }
            if ($script:BatchTab -eq 'Install' -and -not @($script:Pending | Where-Object { $_.Dirty }).Count) {
                Complete-Worker
            } else {
                Start-LeftoverScan
            }
        }
    }
}

function Start-LeftoverScan {
    $TxtNow.Text = 'Scanning for leftover files, folders and registry keys...'
    $DotNow.Fill = '#FF4C8DFF'
    Update-UI
    $ListWipe.ItemsSource = $null       # detach: the scan pumps the dispatcher as it runs
    $script:WipeFindings.Clear()
    # what got removed, plus what failed to install and left a mess behind
    $targets = @($script:Pending | Where-Object { $_.Status -like 'Uninstalled*' -or $_.Dirty })
    $dirtyScan = @($targets | Where-Object { $_.Dirty }).Count -gt 0
    $i = 0
    foreach ($p in $targets) {
        $i++
        $wasStatus = $p.Status; $wasFg = $p.StatusFg
        $script:ScanLabel = "Scanning $($p.Name)  ($i of $($targets.Count))"
        Set-Status $p 'Scanning for leftovers' 'active'
        Set-Ring $p 'busy'
        Update-UI
        foreach ($f in @(Scan-Leftovers $p (-not $p.PreExisting))) { $script:WipeFindings.Add($f) }
        if ($p.Dirty) {
            # a failed install stays failed and stays red: it is only its debris being scanned
            $p.Status = $wasStatus; $p.StatusFg = $wasFg
            Set-Ring $p 'fail'
        } else {
            Set-Status $p 'Uninstalled' 'ok'
            Set-Ring $p 'ok'
        }
    }
    $ListWipe.ItemsSource = $script:WipeView
    if ($script:WipeFindings.Count -eq 0) {
        Add-Log 'Leftover scan: nothing found - the machine is already clean.'
        # force mode never queued work for the elevated worker, so nothing will report
        # the batch complete on its own
        if ($script:ForceMode) { Finish-Batch } else { Complete-Worker }
        return
    }
    $bytes = ($script:WipeFindings | Measure-Object -Property SizeBytes -Sum).Sum
    $pre = @($script:WipeFindings | Where-Object { $_.Del }).Count
    # nothing pre-checked has two very different causes, and the technician has to be told
    # which one: no curated targets to offer, or curated targets that may not be rubbish
    $held = $dirtyScan -and -not @($targets | Where-Object { -not $_.PreExisting }).Count
    $tail = $(if ($pre) { "$pre are known app data and already checked; the rest matched by name only - review before wiping." }
              elseif ($held) { 'Nothing is pre-checked: these products were already installed before this batch, so some of what is listed may belong to the copy that was working. Tick only what should go.' }
              else { 'Nothing is pre-checked - every item here matched by name only. Tick what should go.' })
    $TxtWipeSub.Text = $(if ($dirtyScan) { "$($script:WipeFindings.Count) item(s) were left on disk by the failed install(s), totalling $(Format-Size $bytes). $tail" }
                         else { "$($script:WipeFindings.Count) leftover item(s) survived the uninstaller, totalling $(Format-Size $bytes). $tail" })
    Add-Log "Leftover scan: $($script:WipeFindings.Count) item(s) found ($(Format-Size $bytes))."
    $TxtNow.Text = "Leftovers found - awaiting review"
    $DotNow.Fill = '#FFFBBF24'
    $WipeOverlay.Opacity = 0
    $WipeOverlay.Visibility = 'Visible'
    $a = New-Object Windows.Media.Animation.DoubleAnimation 0, 1, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(220)))
    $WipeOverlay.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
}

function Complete-Worker {
    # release the elevated worker: no more items are coming. Held back until the leftover
    # review is over, for uninstalls and failed installs alike - once the worker reads the
    # end marker it exits, and anything appended after it is never seen.
    if ($script:WorkerStarted -and -not $script:EndQueued) {
        Add-Content -Path $script:QueuePath -Value '{"end":true}' -Encoding UTF8
        $script:EndQueued = $true
    }
}

function Finish-Batch {
    $script:Phase = 'Done'
    $script:Paused = $false
    foreach ($p in $script:Pending) {
        $p.ProgressVis = 'Collapsed'
        $p.SpinnerVis = 'Collapsed'
        if ($p.BadgeVis -eq 'Collapsed') { $p.RingTrackVis = 'Collapsed' }
    }
    $done = @($script:Pending | Where-Object { $_.Status -match '^(Installed|Uninstalled|Cleaned|Applied|Reverted)' }).Count
    $fail = @($script:Pending | Where-Object { $_.Status -like 'Failed*' }).Count
    $cans = @($script:Pending | Where-Object { $_.Status -match '^(Cancelled|Skipped)' }).Count
    $script:AwaitingScan = $false
    $script:DeepClean = $false
    $script:ForceMode = $false
    if ($fail -gt 0 -or $cans -gt 0) { $script:HadFailures = $true }
    $BarOverall.Value = 100
    $TxtOverall.Text = ''
    $summary = "$done completed, $fail failed"
    if ($cans -gt 0) { $summary += ", $cans cancelled" }
    # Firewall batches answer the question the batch file answered: how many rules were
    # actually NEW. Running it twice should visibly change nothing rather than looking
    # like it did the work again.
    if ($script:BatchTab -eq 'Fw') {
        $fwAdd = 0; $fwSkip = 0; $fwDel = 0; $fwNone = 0
        foreach ($p in $script:Pending) {
            $s = '' + $p.Status
            if ($s -match '(\d+) rule\(s\) added')     { $fwAdd  += [int]$Matches[1] }
            if ($s -match '(\d+) already blocked')     { $fwSkip += [int]$Matches[1] }
            if ($s -match '(\d+) rule\(s\) removed')   { $fwDel  += [int]$Matches[1] }
            if ($s -match 'no block rules pointed|no executables found') { $fwNone++ }
        }
        $bits = @()
        if ($fwAdd -or $fwSkip) {
            $bits += $(if ($fwAdd) { "$fwAdd new rule(s) added" } else { 'no new rules added - everything was already blocked' })
            if ($fwSkip) { $bits += "$fwSkip executable(s) already blocked, skipped" }
        }
        if ($fwDel) { $bits += "$fwDel rule(s) removed" }
        if ($fwNone) { $bits += "$fwNone program(s) had nothing to do" }
        if ($bits.Count) { $summary = ($bits -join ', ') }
    }
    $TxtStatus.Text = "Finished: $summary"
    $TxtNow.Text = "Finished - $summary"
    if ($fail -gt 0) { $DotNow.Fill = '#FFF87171' }
    elseif ($cans -gt 0) { $DotNow.Fill = '#FFFBBF24' }
    else { $DotNow.Fill = '#FF34D399' }
    Add-Log "Batch complete: $summary."
    Remove-Item -LiteralPath $script:CancelPath -ErrorAction SilentlyContinue
    if ($fail -eq 0 -and $cans -eq 0 -and -not $KeepCache) {
        # Remove the big installer files immediately; the rest goes on window close. .zip is in
        # the list because a package IS the installer here - leaving it out meant a 14 GB Office
        # or Revit download survived a clean batch while this very log line claimed otherwise,
        # and survived indefinitely if the batch had failed.
        Get-ChildItem $script:CacheDir -Include *.exe, *.msi, *.zip, *.part -Recurse -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Add-Log 'Downloaded installers removed.'
    } else {
        Add-Log 'Cache kept so a retry does not re-download completed files.'
    }
    $BtnInstall.IsEnabled = $true
    $BtnUninstall.IsEnabled = $true
    $BtnTweakApply.IsEnabled = $true
    $BtnTweakUndo.IsEnabled = $true
    $BtnRefresh.IsEnabled = $true
    $BtnMigrate.IsEnabled = $true
    $BtnNewAccount.IsEnabled = $true
    $BtnFwBlock.IsEnabled = $true
    $BtnFwUnblock.IsEnabled = $true
    $BtnRunFix.IsEnabled = $true
    if ($script:BatchTab -eq 'Fw') { Load-Firewall }
    # an account may have just been created, or a profile filled - re-read on next visit
    if ($script:BatchTab -eq 'Users') {
        $TxtNewUser.Clear(); $TxtNewFull.Clear()
        Load-Users
    }
    $BtnPause.Visibility = 'Collapsed'
    $BtnCancel.Visibility = 'Collapsed'
    $TxtInstallBtn.Text = 'Install Selected'
    # machine state changed: both inventories re-scan next time their sub-tab is opened
    $script:UnDirty = $true
    $script:StoreDirty = $true
    # re-read the toggles so they show what the machine is NOW, not what was requested
    if ($script:PrefItems.Count) { Sync-Prefs }
    if (@($script:Deferred).Count -gt 0) {
        # apps added after downloads had finished: run them now as a follow-up batch
        $next = @($script:Deferred)
        $script:Deferred = @()
        Add-Log "Starting queued follow-up batch: $($next.Count) app(s)."
        Start-Batch $next
        return
    }
    # Anything left for a human to do belongs on screen at the end, where it is read,
    # not in the catalog where it is not. Only for apps that actually installed: telling
    # somebody how to activate a product that failed would be worse than saying nothing.
    $notes = @()
    foreach ($p in $script:Pending) {
        if ($p.Status -match '^(Installed|Skipped)' -and $p.Instructions) {
            $notes += "$($p.Name)`n$($p.Instructions)"
            Add-Log "$($p.Name) - instructions: $(($p.Instructions -replace '\s+', ' '))"
        }
    }
    if ($notes.Count) {
        Show-Overlay 'Batch complete - action needed' ($summary + "`n`n" + ($notes -join "`n`n"))
    } else {
        Show-Overlay 'Batch complete' $summary
    }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        Drain-IconResults   # apply any icons the background pump has finished
        if ($script:WorkerStarted -and $script:Phase -in 'Download', 'Install') { Read-WorkerStatus }
        if ($script:Phase -eq 'Download') {
            if ($script:Paused) { return }
            if ($null -eq $script:CurJob) {
                if ($script:DlIndex -ge $script:Pending.Count) {
                    # All downloads handled - but the end marker is NOT sent yet. It used to
                    # go out here, which meant the worker had already exited by the time the
                    # last install reported, and a failed install's debris had nothing
                    # elevated left to delete it. Read-WorkerStatus now releases the worker
                    # once every app has reported, after the leftover review if there is one.
                    if ($script:WorkerStarted) {
                        if (-not $script:EndQueued) {
                            $script:AwaitingScan = $true
                            $script:Phase = 'Install'
                            $TxtStatus.Text = 'Installing remaining apps...'
                        }
                    } else {
                        Finish-Batch   # nothing downloaded successfully, no worker ever started
                    }
                    return
                }
                $item = $script:Pending[$script:DlIndex]
                $dest = Join-Path $script:CacheDir $item.FileName
                # already fully present (size matches) -> hash gets verified by the worker anyway
                if ((Test-Path $dest) -and ((Get-Item $dest).Length -eq $item.SizeBytes)) {
                    Enqueue-Install $item
                    $script:DlIndex++
                    return
                }
                Set-Status $item 'Starting download' 'active'
                $script:SpeedPrev = $null
                $script:SpeedTxt = ''
                try {
                    $existing = Get-BitsTransfer -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -eq "PC2GoDeploy:$($item.Id)" } | Select-Object -First 1
                    if ($existing) {
                        try { Set-BitsTransfer -BitsJob $existing -RetryInterval 60 -ErrorAction SilentlyContinue } catch {}
                        Resume-BitsTransfer -BitsJob $existing -Asynchronous -ErrorAction SilentlyContinue | Out-Null
                        $script:CurJob = $existing
                        Add-Log "Resuming previous download of $($item.Name)."
                    } else {
                        # RetryInterval is not cosmetic. Left at the machine default, a dropped
                        # connection puts the job into TransientError and BITS then backs off for
                        # MINUTES before trying again - measured at over 200 seconds still stuck
                        # in Connecting, on a server that answers a range request in 0.04s. On a
                        # link that blips, that is the difference between a pause and what looks
                        # to a technician like a dead download. 60 is the floor BITS accepts.
                        $script:CurJob = Start-BitsTransfer -Source $item.Url -Destination $dest `
                            -DisplayName "PC2GoDeploy:$($item.Id)" -Asynchronous -Priority Foreground `
                            -RetryInterval 60
                        Add-Log "Downloading $($item.Name) ($($item.Size))..."
                    }
                } catch {
                    # BITS unavailable (service disabled etc.) - fall back to direct resumable HTTP
                    Add-Log "BITS unavailable, using direct download: $($_.Exception.Message)"
                    try {
                        Invoke-ResumableDownload -Item $item -Dest $dest
                        $item.ProgressVis = 'Collapsed'
                        Enqueue-Install $item
                    } catch {
                        Set-Status $item "Failed: $($_.Exception.Message)" 'fail'
                        Set-Ring $item 'fail'
                        $item.ProgressVis = 'Collapsed'
                        Add-Log "Download failed for $($item.Name): $($_.Exception.Message)"
                        $script:HadFailures = $true
                    }
                    $script:DlIndex++
                }
            } else {
                $job = $script:CurJob
                $item = $script:Pending[$script:DlIndex]
                switch -Wildcard ("" + $job.JobState) {
                    'Transferred' {
                        Complete-BitsTransfer -BitsJob $job
                        $item.ProgressVis = 'Collapsed'
                        $script:CurJob = $null
                        $script:DlIndex++
                        Add-Log "$($item.Name) downloaded."
                        Enqueue-Install $item
                    }
                    'Error' {
                        $err = ('' + $job.ErrorDescription).Trim()
                        if (-not $err) { $err = ('' + $job.ErrorContextDescription).Trim() }
                        if (-not $err) { $err = "URL not reachable ($($item.Url))" }

                        # A BITS job outlives a signed URL: it survives reboots and BITS
                        # keeps retrying for up to 90 days, so a download paused over a
                        # weekend wakes to a 403 the URL can never recover from. Refresh
                        # the link and start a new job rather than failing the app.
                        # BITS cannot swap the URL on an existing job, so the partial
                        # bytes are lost - still far better than failing outright.
                        if (($err -match '403' -or $err -match 'Forbidden') -and -not $script:UrlRefreshed[$item.Id]) {
                            $script:UrlRefreshed[$item.Id] = $true
                            $fresh = Get-FreshCatalogUrl $item
                            if ($fresh) {
                                $item.Url = $fresh
                                Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
                                $script:CurJob = $null
                                Add-Log "$($item.Name): download link had expired - refreshed, restarting download."
                                Set-Status $item 'Link expired - restarting' 'warn'
                                return   # next tick re-enters and starts a job on the new URL
                            }
                        }

                        Set-Status $item "Failed: $err" 'fail'
                        Set-Ring $item 'fail'
                        $item.ProgressVis = 'Collapsed'
                        Add-Log "Download failed for $($item.Name): $err"
                        Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
                        $script:CurJob = $null
                        $script:DlIndex++
                        $script:HadFailures = $true
                    }
                    'TransientError' {
                        # BITS retries by itself, so this state persists across many ticks.
                        # Log the transition ONCE, with the reason - a download that silently
                        # sat "retrying" for ten minutes was the single most opaque thing in
                        # this tool. Recovery is logged too, by the default branch below.
                        $err = ('' + $job.ErrorDescription).Trim()
                        if (-not $err) { $err = ('' + $job.ErrorContextDescription).Trim() }
                        if (-not $err) { $err = 'no detail from BITS' }
                        Set-Status $item "Retrying (network): $err" 'warn'
                        if ($script:LastJobState -ne 'TransientError') {
                            Add-Log "Network problem downloading $($item.Name): $err - BITS is retrying automatically."
                            $script:LastJobState = 'TransientError'
                        }
                    }
                    default {
                        if ($script:LastJobState -eq 'TransientError') {
                            Add-Log "Network recovered - $($item.Name) is downloading again."
                            $script:LastJobState = ''
                        }
                        $pct = 0
                        if ($job.BytesTotal -gt 0 -and $job.BytesTotal -lt [uint64]::MaxValue) {
                            $pct = [math]::Floor($job.BytesTransferred * 100 / $job.BytesTotal)
                        }
                        # rolling download-speed indicator, refreshed about once a second
                        $now = Get-Date
                        if ($null -eq $script:SpeedPrev) {
                            $script:SpeedPrev = @{ bytes = [long]$job.BytesTransferred; time = $now }
                        } else {
                            $dt = ($now - $script:SpeedPrev.time).TotalSeconds
                            if ($dt -ge 1) {
                                $delta = [long]$job.BytesTransferred - $script:SpeedPrev.bytes
                                if ($delta -gt 0) { $script:SpeedTxt = (Format-Size ([long]($delta / $dt))) + '/s' }
                                $script:SpeedPrev = @{ bytes = [long]$job.BytesTransferred; time = $now }
                            }
                        }
                        $txt = "Downloading $pct%"
                        if ($script:SpeedTxt) { $txt += "  $script:SpeedTxt" }
                        Set-Status $item $txt 'active'
                        $item.ProgressVis = 'Visible'
                        $item.Progress = $pct
                        Update-Overall $pct
                        $nowTxt = "Downloading $($item.Name) - $pct%"
                        if ($script:SpeedTxt) { $nowTxt += "  at $script:SpeedTxt" }
                        $TxtNow.Text = "$nowTxt   (app $($script:DlIndex + 1) of $($script:Pending.Count))"
                        $DotNow.Fill = '#FF4C8DFF'
                    }
                }
            }
        }
    } finally { $script:Busy = $false }
})

# ---------- handlers ----------

function Start-Batch([object[]]$Sel) {
    # A .zip package is on the disk twice at its peak: the download, plus everything it
    # unpacks into. Installer payloads are already compressed, so the unpacked tree is about
    # the same size again - budget 2.2x for those and the old 1.2x for a bare installer.
    # Getting this wrong does not warn, it dies part-way through unpacking a 14 GB package.
    $needed = 0
    foreach ($s in $Sel) { $needed += [long]($s.SizeBytes * $(if ($s.Entry) { 2.2 } else { 1.2 })) }
    $free = (Get-PSDrive -Name ($script:CacheDir.Substring(0, 1))).Free
    if ($free -lt $needed) {
        Show-Overlay 'Not enough disk space' "This batch needs $(Format-Size $needed) including room to unpack, but only $(Format-Size $free) is free."
        return
    }
    foreach ($s in $Sel) {
        Set-Status $s 'Queued' 'neutral'
        $s.ProgressVis = 'Collapsed'
        Set-Ring $s 'queued'
        # catalog rows are long-lived objects reused batch after batch - a verdict from
        # last time must not send this batch into a leftover scan
        $s.Dirty = $false
        $s.CreatedPaths = @()
    }
    $script:Pending = @($Sel)
    $script:BatchTab = 'Install'
    $script:DlIndex = 0
    $script:CurJob = $null
    $script:HadFailures = $false
    $script:WorkerStarted = $false
    $script:EndQueued = $false
    $script:Paused = $false
    $script:AwaitingScan = $false
    Remove-Item -LiteralPath $script:QueuePath, $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
    $script:Phase = 'Download'
    $TxtInstallBtn.Text = 'Add to Queue'
    $BtnUninstall.IsEnabled = $false
    $BtnRefresh.IsEnabled = $false
    $BtnPause.Content = 'Pause'
    $BtnPause.Visibility = 'Visible'
    $BtnCancel.Visibility = 'Visible'
    $TxtNow.Text = 'Starting downloads...'
    $DotNow.Fill = '#FF4C8DFF'
    $TxtStatus.Text = 'Downloading...'
    Add-Log "Batch started: $($Sel.Count) application(s), $(Format-Size $needed) total."
}

$BtnInstall.Add_Click({
    $sel = @($script:Items | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) {
        Show-Overlay 'Nothing selected' 'Select at least one application to install.'
        return
    }
    if ($script:Phase -eq 'Download') {
        # live add: extend the running batch, no extra UAC prompt needed
        $new = @($sel | Where-Object { $script:Pending -notcontains $_ })
        if ($new.Count -eq 0) {
            Show-Overlay 'Already queued' 'All selected applications are already in the current batch.'
            return
        }
        foreach ($s in $new) {
            Set-Status $s 'Queued' 'neutral'
            $s.ProgressVis = 'Collapsed'
            Set-Ring $s 'queued'
            $s.Dirty = $false
        }
        $script:Pending = @($script:Pending) + $new
        Add-Log "Added $($new.Count) app(s) to the running batch."
        return
    }
    if ($script:Phase -eq 'Install') {
        # downloads already finished and the worker was told 'no more items':
        # queue as a follow-up batch that auto-starts when this one completes
        $new = @($sel | Where-Object { $script:Pending -notcontains $_ -and $script:Deferred -notcontains $_ })
        if ($new.Count -eq 0) {
            Show-Overlay 'Already queued' 'All selected applications are already queued.'
            return
        }
        foreach ($s in $new) { Set-Status $s 'Queued (next batch)' 'neutral'; Set-Ring $s 'queued' }
        $script:Deferred = @($script:Deferred) + $new
        Add-Log "Queued $($new.Count) app(s) - they start automatically when the current batch finishes (one more UAC prompt)."
        return
    }
    Start-Batch $sel
})

$BtnRefresh.Add_Click({
    # reloading the catalog rebuilds the very item objects the running batch is reporting
    # into, so this one genuinely has to wait
    if ($script:Phase -in 'Download', 'Install') {
        Show-Overlay 'Still busy' ('The catalog cannot be reloaded while a batch is running - the running apps are rows in this list.' +
                                   "`n`nIt refreshes automatically when the batch finishes.")
        return
    }
    Load-Catalog
})
$BtnOverlayOk.Add_Click({
    $Overlay.Visibility = 'Collapsed'
    $act = $script:ConfirmAction
    $script:ConfirmAction = $null
    if ($act) { & $act }
})
$BtnOverlayCancel.Add_Click({ $Overlay.Visibility = 'Collapsed'; $script:ConfirmAction = $null })

$BtnWipeSkip.Add_Click({
    $WipeOverlay.Visibility = 'Collapsed'
    Add-Log 'Leftover cleanup skipped by technician - nothing was deleted.'
    $script:WipeFindings.Clear()
    if ($script:ForceMode) { Finish-Batch } else { Complete-Worker }
})

$BtnWipeGo.Add_Click({
    $WipeOverlay.Visibility = 'Collapsed'
    $chosen = @($script:WipeFindings | Where-Object { $_.Del })
    if ($chosen.Count -eq 0) {
        Add-Log 'No leftover items were checked - nothing deleted.'
        $script:WipeFindings.Clear()
        if ($script:ForceMode) { Finish-Batch } else { Complete-Worker }
        return
    }
    # group by owning app so each row reports its own cleanup result
    foreach ($grp in ($chosen | Group-Object OwnerId)) {
        $item = $script:Pending | Where-Object { $_.Id -eq $grp.Name } | Select-Object -First 1
        if ($item) { Set-Status $item 'Cleaning leftovers' 'active'; Set-Ring $item 'busy' }
        $entry = @{
            id = $grp.Name; action = 'wipe'
            targets = @($grp.Group | ForEach-Object { @{ type = $_.Type; path = $_.Path; name = $_.Name } })
        } | ConvertTo-Json -Compress -Depth 4
        Add-Content -Path $script:QueuePath -Value $entry -Encoding UTF8
    }
    $bytes = ($chosen | Measure-Object -Property SizeBytes -Sum).Sum
    Add-Log "Wiping $($chosen.Count) leftover item(s), $(Format-Size $bytes) - registry keys and folders included."
    $TxtNow.Text = 'Wiping leftovers...'
    $DotNow.Fill = '#FF4C8DFF'
    $script:WipeFindings.Clear()
    Complete-Worker
})
$BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$BtnWinClose.Add_Click({ $window.Close() })
$TitleBar.Add_MouseLeftButtonDown({
    param($src, $e)
    # only drag from the bar itself - dragging from the search box would steal its focus
    # the moment you click into it, which makes the field feel dead
    if ($e.OriginalSource -isnot [Windows.Controls.DockPanel]) { return }
    try { $window.DragMove() } catch {}
})
$BtnTabInstall.Add_Click({ Select-Tab 'Install' })
$BtnTabUn.Add_Click({ Select-Tab 'Un' })
$BtnTabTweak.Add_Click({ Select-Tab 'Tweak' })
$BtnTabUsers.Add_Click({ Select-Tab 'Users' })
$BtnTabFw.Add_Click({ Select-Tab 'Fw' })
$BtnTabMigrate.Add_Click({ Select-Tab 'Migrate' })
$BtnTabTools.Add_Click({ Select-Tab 'Tools' })

$BtnAlCancel.Add_Click({ $AutoLogonOverlay.Visibility = 'Collapsed' })
$TxtAlUser.Add_TextChanged({ $HintAlUser.Visibility = $(if ($TxtAlUser.Text) { 'Collapsed' } else { 'Visible' }) })
$TxtAlPw.Add_TextChanged({ $HintAlPw.Visibility = $(if ($TxtAlPw.Text) { 'Collapsed' } else { 'Visible' }) })
$BtnAlOk.Add_Click({
    $u = ('' + $TxtAlUser.Text).Trim()
    if (-not $u) { Show-Overlay 'No account' 'Type the account that should sign in automatically.'; return }
    $pw = ('' + $TxtAlPw.Text)
    $AutoLogonOverlay.Visibility = 'Collapsed'
    $row = @($script:FixItems | Where-Object { $_.UnArgs -eq 'autologon' })
    Start-FixBatch $row @{ alUser = $u; alPassword = $pw }
})

$BtnRunFix.Add_Click({
    if (Test-BatchBusy) { return }
    $sel = @($script:FixItems | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) { Show-Overlay 'Nothing selected' 'Tick the repairs you want to run.'; return }

    # AutoLogon needs credentials, so it cannot ride along in a multi-select batch
    if (@($sel | Where-Object { $_.UnArgs -eq 'autologon' }).Count) {
        if ($sel.Count -gt 1) {
            Show-Overlay 'Run AutoLogon on its own' 'AutoLogon needs an account and password, so run it by itself - untick the others.'
            return
        }
        $TxtAlUser.Clear(); $TxtAlPw.Clear()
        try { $TxtAlUser.Text = [Environment]::UserName } catch {}
        $AutoLogonOverlay.Opacity = 0
        $AutoLogonOverlay.Visibility = 'Visible'
        $an = New-Object Windows.Media.Animation.DoubleAnimation 0, 1, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(180)))
        $AutoLogonOverlay.BeginAnimation([Windows.UIElement]::OpacityProperty, $an)
        return
    }

    $long = @($sel | Where-Object { $_.UnArgs -in 'sfc', 'wureset' })
    $reboot = @($sel | Where-Object { $_.UnArgs -in 'netreset' })
    $ssh = @($sel | Where-Object { $_.UnArgs -eq 'openssh' })
    $msg = "$($sel.Count) repair(s) will run, one after another, under a single UAC prompt:`n`n" +
           (($sel | ForEach-Object { "  - $($_.Name)" }) -join "`n")
    if ($long.Count)   { $msg += "`n`nSystem Corruption Scan and Windows Update Reset are slow - allow up to 30 minutes each. The window will look busy, not stuck." }
    if ($reboot.Count) { $msg += "`n`nNetwork Reset does not take effect until the machine restarts." }
    if ($ssh.Count)    { $msg += "`n`nOpenSSH Server opens port 22 and gives remote shell access to this PC. Only enable it on a machine you control, and make sure the accounts on it have real passwords." }
    Show-Confirm 'Run these repairs?' $msg ({ Start-FixBatch $sel $null }.GetNewClosure())
})

# --- account dialogs ---
$BtnAcctClose.Add_Click({ Hide-AcctDialog })
$BtnNewUserCancel.Add_Click({ $NewUserOverlay.Visibility = 'Collapsed' })
$BtnNewAccount.Add_Click({
    if (Test-BatchBusy) { return }
    $TxtNewUser.Clear(); $TxtNewFull.Clear(); $TxtNewPw.Clear()
    $ChkNewAdmin.IsChecked = $true
    $NewUserOverlay.Opacity = 0
    $NewUserOverlay.Visibility = 'Visible'
    $anim = New-Object Windows.Media.Animation.DoubleAnimation 0, 1, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(180)))
    $NewUserOverlay.BeginAnimation([Windows.UIElement]::OpacityProperty, $anim)
    [void]$TxtNewUser.Focus()
})

# The log is evidence. A technician needs to hand it to a colleague or attach it to a ticket,
# and the cache folder deletes itself on exit - so it has to leave the tool deliberately.
function Get-LogText {
    try {
        $r = New-Object Windows.Documents.TextRange($TxtLog.Document.ContentStart, $TxtLog.Document.ContentEnd)
        return $r.Text
    } catch { return '' }
}
$BtnCopyLog.Add_Click({
    $t = Get-LogText
    if (-not $t.Trim()) { Show-Overlay 'Nothing to copy' 'The log is empty.'; return }
    try {
        [Windows.Clipboard]::SetText($t)
        Add-Log "Log copied to the clipboard ($(($t -split "`n").Count) lines)."
    } catch { Show-Overlay 'Could not copy' $_.Exception.Message }
})
$BtnSaveLog.Add_Click({
    $t = Get-LogText
    if (-not $t.Trim()) { Show-Overlay 'Nothing to save' 'The log is empty.'; return }
    try {
        $dir = [Environment]::GetFolderPath('Desktop')
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { $dir = $env:USERPROFILE }
        $file = Join-Path $dir ("PC2Go-log-{0}-{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $header = Get-SessionHeader
        Set-Content -LiteralPath $file -Value (($header + $t) -join "`r`n") -Encoding UTF8 -ErrorAction Stop
        Add-Log "Log saved to $file"
        Show-Overlay 'Log saved' $file
    } catch { Show-Overlay 'Could not save the log' $_.Exception.Message }
})

$BtnFwRescan.Add_Click({ if (-not (Test-BatchBusy)) { Load-Firewall } })
$BtnFwDetailClose.Add_Click({ $FwDetailOverlay.Visibility = 'Collapsed' })
# The detail button lives inside the row template, so its Click bubbles to the list. Handling
# it here avoids wiring a handler per row and keeps it off the checkbox.
$fwDetailHandler = [Windows.RoutedEventHandler]{
    param($s, $e)
    $src = $e.OriginalSource
    if ($src -isnot [Windows.Controls.Button]) { return }
    $row = $null
    try { $row = $src.DataContext } catch {}
    if ($row) { Show-FwDetail $row; $e.Handled = $true }
}
$ListFw.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, $fwDetailHandler)
$ListFwOpen.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, $fwDetailHandler)

$BtnFwBlock.Add_Click({
    if (Test-BatchBusy) { return }
    $sel = @($script:FwItems | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) { Show-Overlay 'Nothing selected' 'Tick the programs you want to cut off from the internet.'; return }
    # An Unmatched row is a SHARED vendor tree (Common Files\Adobe and the like), not an
    # application. Blocking it would write rules across components other products depend on -
    # and the worker's Test-FwRoot would not stop it, because it refuses "Common Files" itself
    # but not a vendor folder inside it. These rows exist to be CLEARED, never to be blocked.
    $shared = @($sel | Where-Object { $_.RegKey -eq 'unmatched' })
    $sel = @($sel | Where-Object { $_.RegKey -ne 'unmatched' })
    if ($sel.Count -eq 0) {
        Show-Overlay 'Nothing blockable selected' (
            "Only Unmatched entr(y/ies) are ticked. Those are shared vendor folders that belong to no single " +
            "program - blocking them would cut off components other applications rely on.`n`n" +
            'Use Unblock Selected to clear their leftover rules instead.')
        return
    }
    # Blocking is outbound only. Windows already drops unsolicited inbound traffic, so
    # inbound rules would double the rule count for no practical gain.
    $running = @()
    foreach ($s in $sel) {
        $root = ([string]$s.UnArgs).TrimEnd('\')
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            try {
                if ($p.Path -and $p.Path.StartsWith($root + '\', 'OrdinalIgnoreCase')) { $running += $p.ProcessName; break }
            } catch {}
        }
    }
    $msg = "Every .exe inside these $($sel.Count) program folder(s) gets an outbound block rule:`n`n" +
           (($sel | Select-Object -First 8 | ForEach-Object { "  - $($_.Name)" }) -join "`n")
    if ($sel.Count -gt 8) { $msg += "`n  - ...and $($sel.Count - 8) more" }
    $msg += "`n`nThe programs still run - they just cannot reach the network. Rules are tagged " +
            "`"$($script:FwGroup)`" so Unblock and Remove ALL can find every one of them later."
    if ($shared.Count) {
        $msg += "`n`n$($shared.Count) Unmatched entr(y/ies) were skipped - shared vendor folders are never blocked."
    }
    # nothing is blocked twice: each executable is checked against the live rule table
    $already = @($sel | Where-Object { $_.IsSilent })
    if ($already.Count) {
        $have = 0
        foreach ($s in $already) { $have += [int]([string]$s.DetectPath) }
        $msg += "`n`n$($already.Count) of these already have rules ($have in total). Every executable is checked " +
                'against the live firewall table first, so those are reported as already blocked and skipped - ' +
                'running this twice adds nothing.'
    }
    if ($running.Count) {
        $msg += "`n`nNote: $(($running | Select-Object -Unique) -join ', ') " +
                'is running now. A block only applies to NEW connections, so close and reopen it for the change to bite.'
    }
    Show-Confirm 'Block internet access?' $msg ({
        Start-FwBatch 'fwblock' $sel
    }.GetNewClosure())
})

$BtnFwUnblock.Add_Click({
    if (Test-BatchBusy) { return }
    $sel = @($script:FwItems | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) { Show-Overlay 'Nothing selected' 'Tick the programs whose block rules you want removed.'; return }
    $withRules = @($sel | Where-Object { $_.IsSilent })
    if ($withRules.Count -eq 0) {
        Show-Overlay 'Nothing to unblock' 'None of the selected programs currently has an outbound block rule.'
        return
    }
    $total = 0
    foreach ($s in $withRules) { $total += [int]([string]$s.DetectPath) }
    $foreign = Get-ForeignRuleCount $withRules
    $msg = "$total rule(s) across $($withRules.Count) entr(y/ies) will be deleted, restoring internet access.`n`n"
    $msg += $(if ($foreign) {
                  "$foreign of them were created by something other than this tool - most likely an earlier script. " +
                  'They are removed too, which is how those leftovers finally get cleared.'
              } else { 'All of them were created by this tool.' })
    Show-Confirm 'Remove these block rules?' $msg ({ Start-FwBatch 'fwunblock' $withRules }.GetNewClosure())
})

$BtnFwRemoveAll.Add_Click({
    if (Test-BatchBusy) { return }
    $blocked = @($script:FwItems | Where-Object { $_.IsSilent })
    $total = 0
    foreach ($s in $blocked) { $total += [int]([string]$s.DetectPath) }
    if ($total -eq 0) { Show-Overlay 'Nothing to remove' 'No outbound block rules were found for any installed program.'; return }
    $foreign = Get-ForeignRuleCount $blocked
    $unmatched = @($blocked | Where-Object { $_.RegKey -eq 'unmatched' }).Count
    $msg = "$total outbound block rule(s) across $($blocked.Count) entr(y/ies) will be deleted.`n`n" +
           "Everything currently cut off regains internet access.`n"
    if ($unmatched) { $msg += "That includes $unmatched Unmatched entr(y/ies) - rules belonging to no installed program.`n" }
    $msg += "`n" + $(if ($foreign) {
                  "$foreign rule(s) were created by something other than this tool and will also go."
              } else { 'All of them were created by this tool.' })
    Show-Confirm 'Remove every block rule?' $msg ({ Start-FwBatch 'fwunblock' $blocked }.GetNewClosure())
})

$TxtNewUser.Add_TextChanged({ $HintNewUser.Visibility = $(if ($TxtNewUser.Text) { 'Collapsed' } else { 'Visible' }) })
$TxtNewFull.Add_TextChanged({ $HintNewFull.Visibility = $(if ($TxtNewFull.Text) { 'Collapsed' } else { 'Visible' }) })


$BtnNewUserOk.Add_Click({
    if (Test-BatchBusy) { return }
    $name = ('' + $TxtNewUser.Text).Trim()
    if (-not $name) {
        Show-Overlay 'No name' 'Type the account name to create.'
        return
    }
    # Windows rejects these outright, and a name that only differs by case still collides
    if ($name -match '[\\/"\[\]:;|=,+*?<>@]' -or $name.Length -gt 20) {
        Show-Overlay 'Invalid account name' ("Windows account names cannot contain  \ / `" [ ] : ; | = , + * ? < > @  " +
                                             'and must be 20 characters or fewer.')
        return
    }
    if (@($script:DstUsers | Where-Object { $_.Name -eq $name }).Count) {
        Show-Overlay 'Account exists' "There is already a local account called `"$name`". Pick it in the Copy TO column instead."
        return
    }
    # Blank display name means "same as the sign-in name" rather than no display name at
    # all, which is what a technician typing one name actually expects.
    $full = ('' + $TxtNewFull.Text).Trim()
    if (-not $full) { $full = $name }
    $pw = ('' + $TxtNewPw.Text)
    $asAdmin = [bool]$ChkNewAdmin.IsChecked
    $NewUserOverlay.Visibility = 'Collapsed'
    Show-Confirm 'Create this account?' (
        "Sign-in name:   $name`n" +
        "Display name:   $full$(if ($full -eq $name) { '   (same as the sign-in name)' })`n" +
        "Profile folder: C:\Users\$name`n" +
        "Password:       $(if ($pw) { $pw } else { 'none' })`n`n" +
        "It will be:`n" +
        "  - $(if ($asAdmin) { 'a member of Administrators, NOT a standard user' } else { 'a STANDARD user' })`n" +
        "  - set never to expire`n" +
        "  - given its profile folder straight away, so you can copy data in without signing into it first`n`n" +
        $(if ($pw) { 'The password is shown here so you can read it back to the client.' }
          else { 'With no password, anyone at the keyboard can sign in. Type one in the Password box, or use Set Password afterwards.' })
    ) ({ Start-UserBatch 'newuser' @{ username = $name; fullname = $full; password = $pw; admin = $asAdmin } }.GetNewClosure())
})

$TxtNewPw.Add_TextChanged({ $HintNewPw.Visibility = $(if ($TxtNewPw.Text) { 'Collapsed' } else { 'Visible' }) })

$BtnActAdmin.Add_Click({
    $a = Get-AccountTarget 'promote'
    if (-not $a) { return }
    if ($a.RegKey -eq 'admin') { Show-Overlay 'Already an Administrator' "`"$($a.Name)`" is already in the Administrators group."; return }
    Show-Confirm 'Promote to Administrator?' (
        "`"$($a.Name)`" becomes a full Administrator: it can install software, change any setting and read every user's files.`n`n" +
        'Only do this for a technician or owner account.'
    ) ({ Start-UserBatch 'setadmin' @{ username = [string]$a.UnArgs; admin = $true } }.GetNewClosure())
})

$BtnActStandard.Add_Click({
    $a = Get-AccountTarget 'demote'
    if (-not $a) { return }
    if ($a.RegKey -ne 'admin') { Show-Overlay 'Already standard' "`"$($a.Name)`" is not an Administrator."; return }
    # Losing the last admin means nobody can ever elevate on this machine again, and no
    # amount of clicking gets it back. Refuse before the worker is even started.
    $admins = @($script:AccountItems | Where-Object { $_.RegKey -eq 'admin' -and $_.IsSilent })
    if ($admins.Count -le 1) {
        Show-Overlay 'Refused - last Administrator' (
            "`"$($a.Name)`" is the only enabled Administrator on this machine.`n`n" +
            'Demoting it would leave nobody able to elevate, install software or undo the change. Create another admin first.')
        return
    }
    Show-Confirm 'Demote to Standard user?' (
        "`"$($a.Name)`" loses Administrator rights and can no longer elevate.`n`n" +
        "$($admins.Count - 1) other Administrator(s) remain."
    ) ({ Start-UserBatch 'setadmin' @{ username = [string]$a.UnArgs; admin = $false } }.GetNewClosure())
})

$BtnActPw.Add_Click({
    $a = Get-AccountTarget 'set a password for'
    if (-not $a) { return }
    $pw = ('' + $TxtNewPw.Text)
    $what = $(if ($pw) { "the password typed in the Password box above" } else { 'NO password at all' })
    Show-Confirm 'Set this password?' (
        "`"$($a.Name)`" will be given $what.`n`n" +
        $(if ($pw) { "Password: $pw`n`nIt is shown so you can read it back to the client." }
          else { 'A password-free account means anyone at the keyboard can sign in. Type one in the Password box first if that is not what you want.' })
    ) ({ Start-UserBatch 'setpassword' @{ username = [string]$a.UnArgs; password = $pw } }.GetNewClosure())
})

$BtnActToggle.Add_Click({
    $a = Get-AccountTarget 'enable or disable'
    if (-not $a) { return }
    $enable = -not $a.IsSilent      # IsSilent carries "currently enabled"
    if (-not $enable) {
        $me = ''
        try { $me = [Environment]::UserName } catch {}
        if ($a.Name -eq $me) {
            Show-Overlay 'Refused - that is you' "`"$($a.Name)`" is the account running this tool. Disabling it would lock you out of the session."
            return
        }
        $admins = @($script:AccountItems | Where-Object { $_.RegKey -eq 'admin' -and $_.IsSilent })
        if ($a.RegKey -eq 'admin' -and $admins.Count -le 1) {
            Show-Overlay 'Refused - last Administrator' "`"$($a.Name)`" is the only enabled Administrator. Disabling it would leave nobody able to elevate."
            return
        }
    }
    $verb = $(if ($enable) { 'Enable' } else { 'Disable' })
    # Turning the built-in Administrator on is a genuine hardening decision, not routine -
    # it is a well-known SID that ships disabled precisely because attackers target it.
    $isBuiltin = ($a.DetectPath -match '-(500|501|503|504)$' -or $a.Name -in 'Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount')
    if ($enable -and $isBuiltin) {
        Show-Confirm 'Enable a built-in Windows account?' (
            "`"$($a.Name)`" is a built-in account that Windows ships DISABLED on purpose - it is a " +
            "well-known target, and on many machines it has no password.`n`n" +
            "Enable it only for recovery, and set a password immediately afterwards.`n`n" +
            'You can switch it back off from here at any time.'
        ) ({ Start-UserBatch 'toggleacct' @{ username = [string]$a.UnArgs; enable = $true } }.GetNewClosure())
        return
    }
    Show-Confirm "$verb this account?" (
        $(if ($enable) { "`"$($a.Name)`" will be able to sign in again. Its profile and files are unchanged." }
          else { "`"$($a.Name)`" will no longer be able to sign in.`n`nNothing is deleted - the profile and all its files stay on disk, and you can enable it again from here. This is the safe alternative to deleting an account." })
    ) ({ Start-UserBatch 'toggleacct' @{ username = [string]$a.UnArgs; enable = $enable } }.GetNewClosure())
})

$BtnActDelete.Add_Click({
    $a = Get-AccountTarget 'delete'
    if (-not $a) { return }
    $me = ''
    try { $me = [Environment]::UserName } catch {}
    if ($a.Name -eq $me) {
        Show-Overlay 'Refused - that is you' "`"$($a.Name)`" is the account running this tool. It cannot delete itself."
        return
    }
    if ($a.DetectPath -match '-(500|501|503|504)$' -or $a.Name -in 'Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount') {
        Show-Overlay 'Refused - built-in account' "`"$($a.Name)`" is a built-in Windows account. Removing it is not supported and breaks servicing."
        return
    }
    $admins = @($script:AccountItems | Where-Object { $_.RegKey -eq 'admin' -and $_.IsSilent })
    if ($a.RegKey -eq 'admin' -and $admins.Count -le 1) {
        Show-Overlay 'Refused - last Administrator' "`"$($a.Name)`" is the only enabled Administrator on this machine. Deleting it would leave nobody able to elevate."
        return
    }
    # The profile is KEPT. Deleting an account and its data in one irreversible click is
    # how a migration that missed something becomes a disaster; the folder can be removed
    # from Explorer later, once the new profile is confirmed good.
    Show-Confirm 'Delete this account?' (
        "The account `"$($a.Name)`" will be removed from Windows.`n`n" +
        "Its profile folder is NOT deleted - $($a.Publisher)`n" +
        "The files stay on disk, so anything the migration missed is still recoverable. Remove the folder yourself once the new profile is confirmed working.`n`n" +
        'Consider Disable instead: it blocks sign-in and is completely reversible.'
    ) ({ Start-UserBatch 'deleteaccount' @{ username = [string]$a.UnArgs } }.GetNewClosure())
})

$BtnActLocal.Add_Click({
    # Windows exposes no API to convert a Microsoft sign-in to a local one in place - the
    # LocalAccounts module has no such cmdlet, and the linkage in HKLM\...\IdentityStore is
    # undocumented; editing it risks corrupting the very profile this tab exists to repair.
    # So this does not "convert" anything. It performs the outcome that IS automatable:
    # stand up a real local admin, move the data into it, and switch the old account off.
    $a = Get-AccountTarget 'replace with a local account'
    if (-not $a) { return }
    if ($a.Publisher -notlike '*Microsoft account*') {
        Show-Confirm 'That is already a local account' (
            "`"$($a.Name)`" is not signed in with a Microsoft account, so there is nothing to replace.`n`n" +
            'Continue anyway only if you want to build a fresh local admin beside it and move the data across.'
        ) ({ Invoke-ReplaceWithLocal $a }.GetNewClosure())
        return
    }
    Invoke-ReplaceWithLocal $a
})

function Invoke-ReplaceWithLocal([object]$Acct) {
    $name = ('' + $TxtNewUser.Text).Trim()
    if (-not $name) {
        Show-Overlay 'Name the new account first' (
            "Type the new local account's sign-in name in the box above, then press this again.`n`n" +
            "It becomes the replacement for `"$($Acct.Name)`" - a real Administrator with no Microsoft account attached.")
        return
    }
    if ($name -match '[\\/"\[\]:;|=,+*?<>@]' -or $name.Length -gt 20) {
        Show-Overlay 'Invalid account name' 'Windows account names cannot contain  \ / " [ ] : ; | = , + * ? < > @  and must be 20 characters or fewer.'
        return
    }
    if (@($script:AccountItems | Where-Object { $_.Name -eq $name }).Count) {
        Show-Overlay 'Account exists' "There is already an account called `"$name`". Pick a different name."
        return
    }

    $prof = @(Get-UserProfiles | Where-Object { $_.Sid -eq $Acct.DetectPath -or $_.Name -eq $Acct.Name })[0]
    if (-not $prof) {
        Show-Overlay 'No profile to copy' "`"$($Acct.Name)`" has no profile folder on this machine yet, so there is nothing to move. Create the account normally instead."
        return
    }
    # only the safe defaults, and only those that actually exist
    $items = @()
    foreach ($d in $script:MigrateDefs) {
        if (-not $d.safe) { continue }
        if (Test-Path -LiteralPath (Join-Path $prof.Path $d.id)) { $items += [string]$d.id }
    }

    $me = ''
    try { $me = [Environment]::UserName } catch {}
    $isSelf = ($Acct.Name -eq $me)
    $full = ('' + $TxtNewFull.Text).Trim(); if (-not $full) { $full = $name }
    $pw = ('' + $TxtNewPw.Text)

    $steps = @(
        @{ action = 'newuser'; label = "Create local admin `"$name`""
           data = @{ username = $name; fullname = $full; password = $pw } }
        @{ action = 'migrate'; label = "Copy $($items.Count) folder(s) from `"$($Acct.Name)`""
           data = @{ src = [string]$prof.Path; dstUser = $name; dstPath = ''; items = $items } }
    )
    # Disabling the account you are signed into would be refused by the worker anyway, and
    # rightly so - it would end the session mid-copy. Leave it running and say what to do.
    if (-not $isSelf) {
        $steps += @{ action = 'toggleacct'; label = "Disable `"$($Acct.Name)`""
                     data = @{ username = [string]$Acct.Name; enable = $false } }
    }

    $msg = "Windows cannot convert a Microsoft sign-in to a local one from a script - there is no API for it, " +
           "and the only supported route is the Settings wizard, which asks for the account password.`n`n" +
           "What this does instead, all under one UAC prompt:`n`n" +
           "  1. Create `"$name`" as a local Administrator$(if ($pw) { ' with the password above' } else { ', no password' })`n" +
           "  2. Copy $($items.Count) data folder(s) from `"$($Acct.Name)`" into it - nothing is moved or deleted`n"
    if ($isSelf) {
        $msg += "  3. (skipped) `"$($Acct.Name)`" is the account you are signed into, so it is left enabled`n`n" +
                "Sign into `"$name`" afterwards and disable the old account from this tab."
    } else {
        $msg += "  3. Disable `"$($Acct.Name)`" so it can no longer sign in - reversible, and its files stay on disk`n`n" +
                'The Microsoft account itself is untouched; it is only switched off on this PC.'
    }
    $msg += "`n`nPrefer a true in-place conversion, keeping the same profile and SID? Cancel and use " +
            'Settings > Accounts > Your info > Sign in with a local account instead.'

    Show-Confirm 'Replace with a local admin?' $msg ({ Start-UserChain $steps }.GetNewClosure())
}

$BtnMigrate.Add_Click({
    if (Test-BatchBusy) { return }
    $src = Get-SelectedUser $script:SrcUsers
    $dst = Get-SelectedUser $script:DstUsers
    if (-not $src) { Show-Overlay 'No source' 'Pick the profile to copy FROM in the left column.'; return }
    if (-not $dst) { Show-Overlay 'No destination' 'Pick the account to copy TO in the middle column.'; return }
    if ($src.DetectPath -eq $dst.DetectPath -or $src.Name -eq $dst.Name) {
        Show-Overlay 'Same account' 'The source and destination are the same profile. Pick two different accounts.'
        return
    }
    $sel = @($script:MigrateItems | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) { Show-Overlay 'Nothing selected' 'Tick at least one folder to copy.'; return }

    # Measure before promising anything: a profile copy is the one operation here that can
    # fill the disk, and finding that out half way through is how you brick a machine.
    $TxtNow.Text = 'Measuring...'
    $DotNow.Fill = '#FF4C8DFF'
    $RowNow.Visibility = 'Visible'
    Update-UI
    $total = [long]0
    foreach ($m in $sel) {
        $p = Join-Path ([string]$src.UnArgs) ([string]$m.UnArgs)
        $sz = Get-FolderSize $p
        $m.Size = Format-Size $sz
        $total += $sz
    }
    $RowNow.Visibility = 'Collapsed'
    $free = 0
    try { $free = (Get-PSDrive -Name ($env:SystemDrive.Substring(0, 1))).Free } catch {}
    if ($free -gt 0 -and $free -lt ($total * 1.1)) {
        Show-Overlay 'Not enough disk space' ("This copy needs $(Format-Size $total) plus headroom, but only $(Format-Size $free) is free.`n`n" +
                                              'Nothing is moved or deleted by this tool, so both copies have to fit.')
        return
    }
    $risky = @($sel | Where-Object { -not $_.IsSilent })
    $msg = "Copy $($sel.Count) item(s), $(Format-Size $total), from`n  $($src.UnArgs)`nto the profile of `"$($dst.Name)`".`n`n" +
           "The source profile is left completely untouched - this copies, it never moves.`n"
    if ($risky.Count) {
        $msg += "`n$($risky.Count) of these come from AppData. If the old profile is corrupt, the fault often lives there and can travel with them."
    }
    Show-Confirm 'Copy profile data?' $msg ({
        Start-UserBatch 'migrate' @{ src = [string]$src.UnArgs; dstUser = [string]$dst.DetectPath
                                     dstPath = [string]$dst.UnArgs
                                     items = @($sel | ForEach-Object { [string]$_.UnArgs }) }
    }.GetNewClosure())
})
$BtnSubDesktop.Add_Click({ Select-UnTab 'Desktop' })
$BtnSubStore.Add_Click({ Select-UnTab 'Store' })
$BtnRescan.Add_Click({
    # A rescan is read-only, so it is allowed while apps are downloading or installing -
    # that is exactly when a technician wants to confirm something landed. It is refused
    # only during an UNINSTALL or TWEAK batch, where this very list holds the rows the
    # worker is still reporting into and rebuilding it underneath them would throw.
    if ($script:Phase -in 'Download', 'Install' -and $script:BatchTab -ne 'Install') {
        Show-Overlay 'Cannot rescan yet' ("A removal batch is still running and this list holds the rows it is reporting into.`n`n" +
                                          'Rescan once it finishes - the list refreshes itself automatically anyway.')
        return
    }
    if ($script:UnSubTab -eq 'Store') { $script:StoreDirty = $true } else { $script:UnDirty = $true }
    Select-UnTab $script:UnSubTab
})
$BtnTabLog.Add_Click({ Select-Tab 'Log' })

$BtnPause.Add_Click({
    if ($script:Phase -ne 'Download' -or $null -eq $script:CurJob) { return }
    if (-not $script:Paused) {
        Suspend-BitsTransfer -BitsJob $script:CurJob -ErrorAction SilentlyContinue
        $script:Paused = $true
        $BtnPause.Content = 'Resume'
        $TxtNow.Text = 'Paused - download suspended (any running install continues)'
        $DotNow.Fill = '#FFFBBF24'
        Add-Log 'Download paused.'
    } else {
        Resume-BitsTransfer -BitsJob $script:CurJob -Asynchronous -ErrorAction SilentlyContinue | Out-Null
        $script:Paused = $false
        $BtnPause.Content = 'Pause'
        $DotNow.Fill = '#FF4C8DFF'
        Add-Log 'Download resumed.'
    }
})

$BtnCancel.Add_Click({
    if ($script:Phase -notin 'Download', 'Install') { return }
    New-Item -ItemType File -Path $script:CancelPath -Force | Out-Null
    if ($script:CurJob) { Remove-BitsTransfer -BitsJob $script:CurJob -ErrorAction SilentlyContinue; $script:CurJob = $null }
    $script:Paused = $false
    $BtnPause.Visibility = 'Collapsed'
    $script:DlIndex = $script:Pending.Count
    foreach ($p2 in $script:Pending) {
        if ($p2.Status -notmatch '^(Installed|Uninstalled|Failed|Installing|Uninstalling|Verifying)') {
            Set-Status $p2 'Cancelled' 'warn'
            Set-Ring $p2 'warn'
            $p2.ProgressVis = 'Collapsed'
        }
    }
    foreach ($d in $script:Deferred) { Set-Status $d '' 'neutral'; Set-Ring $d 'none' }
    $script:Deferred = @()
    Add-Log 'Cancel requested - a running install finishes safely; everything else stops.'
    if ($script:WorkerStarted) {
        if (-not $script:EndQueued) {
            Add-Content -Path $script:QueuePath -Value '{"end":true}' -Encoding UTF8
            $script:EndQueued = $true
        }
        $script:Phase = 'Install'
        $TxtNow.Text = 'Cancelling - waiting for the current install to finish...'
        $DotNow.Fill = '#FFFBBF24'
    } else {
        Finish-Batch
    }
})

$BtnForce.Add_Click({
    if (Test-BatchBusy) { return }
    $sel = @(@($script:UnItems) + @($script:UnStore) | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) {
        Show-Overlay 'Nothing selected' 'Select at least one application to force remove.'
        return
    }
    Show-Confirm 'Force remove without uninstalling?' (
        "The vendor uninstaller will NOT be run for $($sel.Count) selected item(s). " +
        "Everything found on disk and in the registry is wiped directly.`n`n" +
        "Use this when the uninstaller is missing or broken and a normal removal has already failed. " +
        "You still review the full list before anything is deleted.") ({ Start-Uninstall $sel $true }.GetNewClosure())
})

# Presets, Clear and Detect only tick boxes or read the machine - never blocked by a
# running batch. Queueing up the next job while a download finishes is the whole point.
$BtnPreStandard.Add_Click({ if (-not (Test-TweakListBusy)) { Select-TweakPreset 'Standard' } })
$BtnPreMinimal.Add_Click({  if (-not (Test-TweakListBusy)) { Select-TweakPreset 'Minimal' } })
$BtnPreAdvanced.Add_Click({ if (-not (Test-TweakListBusy)) { Select-TweakPreset 'Advanced' } })
$BtnPreClear.Add_Click({
    if (Test-TweakListBusy) { return }
    $script:SuspendDash = $true
    try {
        foreach ($t in $script:TweakItems) { $t.IsSelected = $false; Set-Status $t '' 'neutral'; Set-Ring $t 'none' }
    } finally { $script:SuspendDash = $false }
    # preferences are toggles, so "clear" means drop pending edits and show the machine's
    # real state again - unticking them all would read as "turn all 25 off"
    Sync-Prefs
    $TxtTweakHint.Text = ''
    Update-Dash
})
$BtnDetect.Add_Click({ if (-not (Test-TweakListBusy)) { Invoke-TweakDetect } })

$BtnTweakUndo.Add_Click({
    if (Test-BatchBusy) { return }
    $sel = @($script:TweakItems | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) {
        Show-Overlay 'Nothing selected' 'Select at least one tweak to undo. Tip: "Detect Applied" ticks everything currently applied on this machine.'
        return
    }
    # Undo restores the documented Windows default. Some tweaks delete or run something
    # and simply cannot be put back - say which, up front, instead of silently no-opping.
    $oneWay = @($sel | Where-Object { $_.UnArgs -in 'diskcleanup', 'tempfiles', 'restorepoint', 'edgeremove', 'onedriveremove', 'widgets', 'windowsai' })
    $msg = "$($sel.Count) tweak(s) will be reset to their Windows default."
    if ($oneWay.Count) {
        $names = ($oneWay | ForEach-Object { "  - $($_.Name)" }) -join "`n"
        $msg += "`n`n$($oneWay.Count) of them cannot be fully undone - the policy is reverted but deleted files and removed apps are NOT restored:`n$names"
    }
    Show-Confirm 'Undo selected tweaks?' $msg ({ Start-TweakUndo $sel }.GetNewClosure())
})

$BtnTweakApply.Add_Click({
    if (Test-BatchBusy) { return }
    # a batch is the ticked tweaks plus any preference whose toggle no longer matches the
    # machine - preferences you did not touch are never rewritten
    $sel = @($script:TweakItems | Where-Object { $_.IsSelected }) + @(Get-PendingPrefs)
    if ($sel.Count -eq 0) {
        Show-Overlay 'Nothing to do' 'Tick a tweak to apply, or change a preference toggle. Preferences already matching this machine are left alone.'
        return
    }
    $risky = @($sel | Where-Object { -not $_.IsSilent })
    $hasRestore = @($sel | Where-Object { $_.UnArgs -eq 'restorepoint' }).Count -gt 0
    if ($risky.Count -eq 0) {
        Start-Tweaks $sel
        return
    }
    # Advanced tweaks remove software or change network/OS behaviour - name them
    # explicitly rather than hiding the damage behind a count.
    $names = ($risky | Select-Object -First 8 | ForEach-Object { "  - $($_.Name)" }) -join "`n"
    if ($risky.Count -gt 8) { $names += "`n  - ...and $($risky.Count - 8) more" }
    $warn = "$($risky.Count) of the $($sel.Count) selected tweak(s) are in the CAUTION group:`n`n$names`n`n"
    $warn += $(if ($hasRestore) { 'A restore point is selected and will be created first.' }
               else { 'No restore point is selected. Tick "Restore Point - Create" first if you want an undo.' })
    Show-Confirm 'Apply advanced tweaks?' $warn ({ Start-Tweaks $sel }.GetNewClosure())
})

$BtnUninstall.Add_Click({
    if (Test-BatchBusy) { return }
    # selections survive sub-tab switches, so a batch can mix desktop programs and Store apps
    $sel = @(@($script:UnItems) + @($script:UnStore) | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) {
        Show-Overlay 'Nothing selected' 'Select at least one application to uninstall.'
        return
    }
    Start-Uninstall $sel $false
})

function Start-Uninstall([object[]]$sel, [bool]$Force) {
    foreach ($s in $sel) { Set-Status $s 'Queued' 'neutral'; Set-Ring $s 'none' }
    $script:Pending = $sel
    $script:BatchTab = 'Un'
    $script:HadFailures = $false
    $script:WorkerStarted = $false
    $script:EndQueued = $false
    $script:Paused = $false
    Remove-Item -LiteralPath $script:QueuePath, $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
    if (-not (Start-Worker)) {
        Abort-Batch 'elevation declined'
        return
    }
    # Deep clean is not optional: removing every trace is the reason this tool exists
    # over Control Panel. The opt-out lives in the preview, where the tech can see the
    # actual findings instead of deciding blind before the scan has even run.
    $script:DeepClean = $true
    $script:ForceMode = $Force
    if ($Force) {
        # Wise-style forced removal: the uninstaller is skipped entirely, which is the
        # only route left when it is missing or already broken. Straight to the scan.
        foreach ($s in $sel) { Set-Status $s 'Uninstalled' 'ok'; Set-Ring $s 'ok' }
        Add-Log "Force remove: skipping vendor uninstallers for $($sel.Count) item(s)."
        $script:Phase = 'Install'
        $BtnUninstall.IsEnabled = $false
        $BtnRefresh.IsEnabled = $false
        $BtnCancel.Visibility = 'Visible'
        $TxtStatus.Text = 'Force removing...'
        Start-LeftoverScan
        return
    }
    foreach ($s in $sel) {
        $entry = @{ id = $s.Id; action = 'uninstall'; command = $s.UnCommand; args = $s.UnArgs
                    detect = $s.DetectPath; location = @($s.CleanPaths)[0] } | ConvertTo-Json -Compress
        Add-Content -Path $script:QueuePath -Value $entry -Encoding UTF8
    }
    if ($script:DeepClean) {
        # hold the end marker: scan for leftovers and let the tech review before wiping
        $script:AwaitingScan = $true
        $script:EndQueued = $false
    } else {
        Add-Content -Path $script:QueuePath -Value '{"end":true}' -Encoding UTF8
        $script:EndQueued = $true
    }
    $script:Phase = 'Install'
    $BtnUninstall.IsEnabled = $false
    $BtnRefresh.IsEnabled = $false
    $BtnCancel.Visibility = 'Visible'
    $TxtStatus.Text = 'Uninstalling...'
    $TxtNow.Text = 'Uninstalling...'
    $DotNow.Fill = '#FF4C8DFF'
    Add-Log "Uninstall batch started: $($sel.Count) application(s) via vendor uninstallers."
}

# Debounced: refreshing three grouped CollectionViews on every keystroke re-filters
# hundreds of rows per character. 220ms of quiet first makes typing feel instant.
$script:SearchTimer = New-Object Windows.Threading.DispatcherTimer
$script:SearchTimer.Interval = [TimeSpan]::FromMilliseconds(220)
$script:SearchTimer.Add_Tick({
    $script:SearchTimer.Stop()
    # no silent catch here: a filter that throws leaves the old list on screen, which
    # looks exactly like a frozen UI and hides the real fault
    try {
        $script:View.Refresh()
        $script:UnView.Refresh()
        $script:StoreView.Refresh()
        $script:TweakView.Refresh()
        $script:PrefView.Refresh()
        $script:FwView.View.Refresh()
        $script:FwOpenSrc.View.Refresh()
        $script:FixView.Refresh()
    } catch {
        Add-Log "Search failed: $($_.Exception.Message)"
    }
    Update-SearchCount
})
$TxtSearch.Add_TextChanged({
    $script:SearchText = $TxtSearch.Text
    $empty = [string]::IsNullOrEmpty($TxtSearch.Text)
    $HintSearch.Visibility = $(if ($empty) { 'Visible' } else { 'Collapsed' })
    $BtnSearchClear.Visibility = $(if ($empty) { 'Collapsed' } else { 'Visible' })
    $script:SearchTimer.Stop()
    $script:SearchTimer.Start()
})
$BtnSearchClear.Add_Click({ $TxtSearch.Clear(); [void]$TxtSearch.Focus() })
$TxtSearch.Add_KeyDown({
    param($src, $e)
    if ($e.Key -eq 'Escape') { $TxtSearch.Clear(); $e.Handled = $true }
})

# Entrance animation: fade + gentle scale-up. Purely cosmetic, so it is wrapped -
# a failure here must never stop the window from opening.
$window.Add_Loaded({
    try {
        $dur = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(380))
        $ease = New-Object Windows.Media.Animation.CubicEase
        $ease.EasingMode = 'EaseOut'
        $fade = New-Object Windows.Media.Animation.DoubleAnimation 0, 1, $dur
        $window.BeginAnimation([Windows.Window]::OpacityProperty, $fade)
        # take the transform off the root element rather than via FindName: a Freezable
        # inside a property element does not reliably register in the XAML namescope
        $rs = $window.Content.RenderTransform
        if ($rs -and -not $rs.IsFrozen) {
            foreach ($prop in @([Windows.Media.ScaleTransform]::ScaleXProperty, [Windows.Media.ScaleTransform]::ScaleYProperty)) {
                $s = New-Object Windows.Media.Animation.DoubleAnimation 0.97, 1, $dur
                $s.EasingFunction = $ease
                $rs.BeginAnimation($prop, $s)
            }
        }
    } catch {
        $window.Opacity = 1
    }
})

$window.Add_Closed({
    # No-trace cleanup: remove everything on clean success or an untouched session.
    # Keep the cache only when there are partial downloads or failures worth resuming.
    # same list as the batch-end sweep: a leftover package is a reason to keep the cache too
    $partials = @(Get-ChildItem $script:CacheDir -Include *.exe, *.msi, *.zip, *.part -Recurse -ErrorAction SilentlyContinue)
    $ourJobs = @(Get-BitsTransfer -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'PC2GoDeploy:*' })
    # A job only earns the right to keep the cache if it actually holds bytes worth
    # resuming. One that never connected - 0 bytes against an unreachable host - is
    # garbage, and BITS retries it for 90 days: left counted as "active" it would block
    # the no-trace cleanup on this machine forever, on every future run.
    $deadJobs = @($ourJobs | Where-Object { $_.BytesTransferred -eq 0 -and "$($_.JobState)" -in 'Error', 'TransientError' })
    $activeJobs = @($ourJobs | Where-Object { $deadJobs -notcontains $_ })
    foreach ($j in $deadJobs) { Remove-BitsTransfer -BitsJob $j -ErrorAction SilentlyContinue }
    $cleanSuccess = ($script:Phase -eq 'Done' -and -not $script:HadFailures)
    $untouched = ($script:Phase -eq 'Idle' -and $partials.Count -eq 0 -and $activeJobs.Count -eq 0)
    if (-not $KeepCache -and ($cleanSuccess -or $untouched)) {
        foreach ($j in $activeJobs) { Remove-BitsTransfer -BitsJob $j -ErrorAction SilentlyContinue }
        # delete via a detached cmd so the folder can be removed even while this script file is in it
        $cmd = "ping -n 3 127.0.0.1 >nul & rd /s /q `"$script:CacheDir`""
        Start-Process cmd.exe -ArgumentList "/c $cmd" -WindowStyle Hidden
    }
})

# ---------- go ----------
# The window comes up first; the catalog is fetched after the first paint, so a slow or
# unreachable server can no longer hold the GUI hostage before it even appears.
# Every log starts by saying which machine, which build and which rights produced it.
# Without that a saved log is unattributable, and "it worked on mine" is unanswerable.
function Get-SessionHeader {
    $elev = 'no'
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ((New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $elev = 'yes' }
    } catch {}
    $os = ''
    try { $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $os = 'unknown' }
    return @(
        "PC2Go App Installer - $BuildTag",
        "Machine   : $env:COMPUTERNAME",
        "User      : $env:USERNAME   (elevated: $elev)",
        "OS        : $os   build $([Environment]::OSVersion.Version)",
        "PowerShell: $($PSVersionTable.PSVersion)",
        "Server    : $BaseUrl",
        "Started   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        ('-' * 60)
    )
}
foreach ($line in (Get-SessionHeader)) { Add-Log $line }

Load-Tweaks      # built-in list, no network - available before the catalog arrives
Load-Prefs       # toggles, pre-set from this machine's current state
$script:CatalogLoaded = $false
$window.Add_ContentRendered({
    if ($script:CatalogLoaded) { return }
    $script:CatalogLoaded = $true
    Load-Catalog
})
$timer.Start()
[void]$window.ShowDialog()
$timer.Stop()
# stop the icon pump so its runspace never outlives the window
$script:IconState.Stop = $true
try { $script:IconPS.Stop() } catch {}
try { $script:IconPS.Dispose() } catch {}
