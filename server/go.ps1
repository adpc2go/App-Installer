# PC2Go bootstrap - served at https://apps.pc2go.ca/go
#
# Universal launch line (works pasted into cmd, Windows PowerShell 5.1, or PowerShell 7):
#   powershell -NoP -EP Bypass -C "irm https://apps.pc2go.ca/go | iex"
# PowerShell-only shorthand:
#   irm https://apps.pc2go.ca/go | iex
#
# This bootstrap runs fine under 5.1 or 7, then always launches the tool with
# Windows PowerShell 5.1 (in-box on Win10/11), where WPF + BITS behave natively.

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288 } catch {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 }

$winPS = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $winPS)) {
    Write-Host 'Windows PowerShell 5.1 not found - this tool requires Windows 10 or 11.' -ForegroundColor Yellow
    return
}

$BaseUrl = 'https://apps.pc2go.ca'             # <-- your server
$dir = Join-Path $env:LOCALAPPDATA 'PC2GoDeploy'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$ps1 = Join-Path $dir 'AppDeploy.ps1'

# Integrity pin. Deliberately a placeholder in the repository: the real hash is injected at
# the edge by the Worker from APPDEPLOY_SHA256 (cloudflare/worker.js, serveBootstrap). It is
# kept out of the R2 copy of this file on purpose - an attacker able to rewrite AppDeploy.ps1
# in the bucket must not also be able to rewrite the hash that guards it.
#
# Publish-Release.ps1 pins into cloudflare/wrangler.toml, never into this line. Do not paste
# a real hash here: it goes stale on the very next release, and then running this file
# directly fails its own integrity check for no reason anyone can see.
$PinnedHash = 'PINNED_SHA256_GOES_HERE'
$pinned = ($PinnedHash -ne 'PINNED_SHA256_GOES_HERE')

# Run straight from the repository and nothing injected a pin, so the download below is
# unverified. That is a real reduction in safety and it should never pass for a normal run.
if (-not $pinned) {
    Write-Host 'UNPINNED: the integrity of AppDeploy.ps1 will not be verified.' -ForegroundColor Yellow
    Write-Host 'This copy was not served through the Worker, which is what injects the pin.' -ForegroundColor Yellow
    Write-Host 'For a verified run:  irm https://apps.pc2go.ca/go | iex' -ForegroundColor Yellow
}

# Re-download only when the copy already here is not the release we want.
#
# The tool is ~480 KB and was fetched again on every single run, even when the identical bytes
# were already on disk. That is a download, a disk write, and - the part that actually hurts on
# a client machine - another full AMSI scan of half a megabyte of script before PowerShell will
# run a line of it. The pinned hash already answers "is the local copy the right one?", so ask
# that first. When the answer is no, or there is no local copy, nothing changes: fetch, verify.
#
# This cannot weaken the pin. A cached file is used ONLY when its hash equals the pin, which is
# exactly the test a freshly downloaded one has to pass.
# ---------- the splash ----------
#
# Everything below this point is invisible from the outside: a hash of 545 KB, possibly a 545 KB
# download, and then PowerShell loading and antivirus scanning that file before one line of it
# runs. On a healthy machine that is under half a second. The note further down records EIGHT
# SECONDS on a client running a second antivirus alongside Defender, and a technician standing
# there cannot tell dead air from a hang - so they paste the line again and pay for all of it
# twice.
#
# It appears only if the run is still going after 1.2 seconds. On a healthy machine that never
# happens and nothing is shown at all; on the slow one it is the difference between "working"
# and "broken". It runs on its own thread because this one is about to block on a download.
#
# The colours are the palette both windows share, so what appears first looks like what it becomes.
$script:Splash = $null

function Show-Splash {
    if ($script:Splash) { return }
    try {
        $rs = [RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $ps = [PowerShell]::Create()
        $ps.Runspace = $rs
        # A shared, synchronised handle back to the window's dispatcher. Without it there is no
        # safe way to stop this: $ps.Stop() and $rs.Close() both BLOCK against a running
        # Dispatcher.Run(), which hung the bootstrap outright - the splash stayed up and the tool
        # never launched. Shutting the dispatcher down from outside lets Run() return on its own.
        $sync = [hashtable]::Synchronized(@{})
        $rs.SessionStateProxy.SetVariable('Sync', $sync)
        [void]$ps.AddScript({
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" SizeToContent="WidthAndHeight"
        WindowStartupLocation="CenterScreen">
  <Border Background="#FF17171B" BorderBrush="#FF3C3C45" BorderThickness="1" CornerRadius="12"
          Width="360" Padding="24,22,24,20">
    <StackPanel>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
        <Border Width="30" Height="30" CornerRadius="8" VerticalAlignment="Center">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
              <GradientStop Color="#FF4C8DFF" Offset="0"/>
              <GradientStop Color="#FF2563EB" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
          <Path Data="M 15,8 L 15,20 M 10,15 L 15,20 L 20,15 M 9,24 L 21,24" Stroke="White"
                StrokeThickness="2.2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                StrokeLineJoin="Round" Stretch="None"/>
        </Border>
        <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="PC2Go App Installer" FontSize="14" FontWeight="SemiBold" Foreground="#FFE9E9EE"/>
          <TextBlock Text="apps.pc2go.ca" FontSize="11" Foreground="#FF6E6E7A"/>
        </StackPanel>
      </StackPanel>
      <TextBlock Text="Getting this machine's copy ready..." FontSize="12.3" Foreground="#FF9A9AA6"
                 Margin="0,0,0,11"/>
      <Border Height="3" CornerRadius="2" Background="#FF26262E" ClipToBounds="True">
        <Border x:Name="Bar" Height="3" Width="90" CornerRadius="2" Background="#FF4C8DFF"
                HorizontalAlignment="Left">
          <Border.RenderTransform><TranslateTransform x:Name="Slide"/></Border.RenderTransform>
        </Border>
      </Border>
    </StackPanel>
  </Border>
</Window>
"@
            $w = [Windows.Markup.XamlReader]::Parse($xaml)
            $Sync.Dispatcher = $w.Dispatcher
            $slide = $w.FindName('Slide')
            $a = New-Object Windows.Media.Animation.DoubleAnimation 0, 222, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(1100)))
            $a.AutoReverse = $true
            $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $slide.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $a)
            $w.Show()
            [Windows.Threading.Dispatcher]::Run()
        })
        $handle = $ps.BeginInvoke()
        $script:Splash = @{ PS = $ps; RS = $rs; Handle = $handle; Sync = $sync }
    } catch {
        # A splash is a courtesy. It must never be the reason the tool does not start.
        $script:Splash = $null
    }
}

function Hide-Splash {
    $sp = $script:Splash
    if (-not $sp) { return }
    # Cleared FIRST, so nothing can wait on this twice.
    $script:Splash = $null
    # InvokeShutdown, never Stop(). Dispatcher.Run() then returns, the pipeline ends by itself,
    # and the disposals below have nothing left to block on. Every one of these is best-effort:
    # a splash that will not close is not a reason to fail a launch.
    try { if ($sp.Sync.Dispatcher) { $sp.Sync.Dispatcher.InvokeShutdown() } } catch { }
    try { $sp.PS.Dispose() } catch { }
    try { $sp.RS.Dispose() } catch { }
}

# Armed here, and fired by whatever is still running at 1.2 seconds.
$script:SplashTimer = New-Object Timers.Timer
$script:SplashTimer.Interval = 1200
$script:SplashTimer.AutoReset = $false
Register-ObjectEvent -InputObject $script:SplashTimer -EventName Elapsed -Action { Show-Splash } | Out-Null
$script:SplashTimer.Start()

<#
    Everything from here to the end runs inside one try/finally, and the finally is the only
    thing that guarantees the splash comes down.

    Ctrl+C at the access-code prompt used to leave it on screen for ever. The splash owns a
    dedicated STA runspace thread running Dispatcher.Run(), which blocks until somebody calls
    InvokeShutdown() - and stopping the pipeline calls nothing. The window stayed, the runspace
    stayed open inside the technician's own session, and the only way out was closing the
    console. `trap` is no use here: Ctrl+C stops a pipeline, it does not raise a terminating
    error, so finally is the one construct that still runs.

    The body below is deliberately NOT re-indented. Shifting nearly three hundred lines by four
    spaces would bury this change in a diff that looked like a rewrite, and PowerShell does not
    care - the reader does.
#>
try {

$needFetch = $true
if ($pinned -and (Test-Path -LiteralPath $ps1)) {
    try {
        if ((Get-FileHash -LiteralPath $ps1 -Algorithm SHA256).Hash -eq $PinnedHash.ToUpper()) {
            $needFetch = $false
        }
    } catch { $needFetch = $true }
}

# ---- access code ----
# The paste-line is deliberately public - anyone can note it down. What it FETCHES is not:
# the edge refuses the tool and the catalog without the access code, so a noted line gains
# nothing on its own. The code is typed here (masked, never in the URL, never on a command
# line - process listings show those) and travels to AppDeploy through the process
# environment. Rotating the code is one `wrangler secret put`.
#
# EVERY run of the go line asks. An environment variable lives as long as the PowerShell
# session that set it, so without this line the FIRST `irm ... | iex` would prompt and a
# second one in the same console would silently reuse that code and never ask again - which
# is indistinguishable, from the outside, from a gate that has stopped working. Clearing it
# here also means a rotated code cannot be masked by a stale one still sitting in the shell.
#
# Deliberately not a "remember me": the prompt is the point. It costs one line of typing per
# launch, and it is the only moment anybody is asked to prove they are meant to be here.
$env:PC2GO_CODE = ''

# Runs $Try with the current code; on a 403 marked x-pc2go-auth it prompts (3 tries) and
# retries. Any other failure is not an auth problem and is rethrown untouched.
# The notice a technician meets before typing anything, in the shape network equipment uses:
# a boxed banner, an explicit statement of ownership, and an instruction to disconnect. That
# is the visual language of a controlled system, and this is one.
#
# The wording is careful on two counts, and both are deliberate.
#   * It never suggests the CLIENT is being watched. This runs on their machine, over their
#     remote session, often with them looking at the screen - "all activity is recorded" reads
#     as surveillance of the person reading it, which is the one sentence that costs trust.
#     It says whose service this is, not who is being monitored.
#   * "may be logged" is TRUE - the edge logs requests. "All access is logged and attributed"
#     would not be, because per-code attribution does not exist yet. A banner that claims a
#     capability nobody has is worth nothing on the day it matters.
function Show-AccessBanner {
    $node = 'apps.pc2go.ca'
    try { $node = ([Uri]$BaseUrl).Host } catch { }
    $rel = 'unpinned'
    if ($pinned) { $rel = $PinnedHash.Substring(0, 12).ToLower() }
    # Width follows the window when it is narrower than the banner, or a 70-column console
    # wraps every line and the box stops being a box. 64 is the design width.
    $w = 64
    try { $w = [Math]::Max(40, [Math]::Min(64, $Host.UI.RawUI.WindowSize.Width - 4)) } catch { }
    $bar = '  ' + ('=' * $w)
    # Reverse video for the name: black on green, padded to the FULL width of the frame so it
    # reads as a solid header bar rather than a highlighted phrase. Centred by padding rather
    # than by counting spaces into the literal, so it stays centred at any width.
    $title = 'P C 2 G o   S E R V I C E'
    $lead  = [Math]::Max(0, [int](($w - $title.Length) / 2))
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkGreen
    Write-Host '  ' -NoNewline
    Write-Host ((' ' * $lead) + $title).PadRight($w) -ForegroundColor Black -BackgroundColor Green
    $sub  = 'REMOTE APPLICATION DEPLOYMENT SYSTEM'
    $lead2 = [Math]::Max(0, [int](($w - $sub.Length) / 2))
    Write-Host ('  ' + (' ' * $lead2) + $sub) -ForegroundColor Green
    Write-Host $bar -ForegroundColor DarkGreen
    Write-Host ''
    Write-Host '   NOTICE TO USERS' -ForegroundColor Green
    Write-Host ''
    Write-Host '   This service is the property of PC2Go and is provided solely' -ForegroundColor Gray
    Write-Host '   for the use of authorized technicians.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '   If you are not an authorized user, disconnect IMMEDIATELY.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '   Connections to this service may be logged.' -ForegroundColor Gray
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkGreen
    Write-Host ('   node {0}   release {1}   {2}' -f $node, $rel, (Get-Date -Format 'yyyy-MM-dd HH:mm')) -ForegroundColor DarkGray
    Write-Host $bar -ForegroundColor DarkGreen
    Write-Host ''
}

# Masked, and typed in WHITE so the asterisks read as input rather than as more banner.
#
# Read-Host draws its own mask in whatever the console foreground currently is - there is no
# parameter for it - so the colour is set around the call and restored in a finally. That
# restore is not tidiness: this runs inside the technician's OWN shell, and a green console
# left behind after the tool launches is a mess we made in someone else's window. Both the
# raw console and the host UI are set, because which one Read-Host honours depends on the
# host, and neither is guaranteed to exist (a redirected or hosted runspace has no console).
function Read-AccessCode([int]$Remaining, [int]$Max) {
    $label = '   Access code'
    if ($Remaining -lt $Max) {
        $label += "  ($Remaining attempt$(if ($Remaining -ne 1) { 's' }) remaining)"
    }
    Write-Host "$label" -ForegroundColor Green -NoNewline
    Write-Host ': ' -NoNewline
    $oldC = $null; $oldH = $null
    try { $oldC = [Console]::ForegroundColor; [Console]::ForegroundColor = 'White' } catch { }
    try { $oldH = $Host.UI.RawUI.ForegroundColor; $Host.UI.RawUI.ForegroundColor = 'White' } catch { }
    try {
        $sec = Read-Host -AsSecureString
    } finally {
        if ($null -ne $oldC) { try { [Console]::ForegroundColor = $oldC } catch { } }
        if ($null -ne $oldH) { try { $Host.UI.RawUI.ForegroundColor = $oldH } catch { } }
    }
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Invoke-WithAccess([scriptblock]$Try) {
    $max = 3
    $tries = 0
    while ($true) {
        try { & $Try; return $true } catch {
            $need = $false
            try {
                $resp = $_.Exception.Response
                $need = ($resp -and [int]$resp.StatusCode -eq 403 -and
                         ('' + $resp.Headers['x-pc2go-auth']) -eq 'required')
            } catch { }
            if (-not $need) { throw }
            # The TIMER first, then the window. Hiding it alone was not enough: the timer is a
            # one-shot armed at startup, so if the 403 came back in under 1.2 seconds this
            # cleared a splash that did not exist yet and the timer then fired ON TOP of the
            # prompt - $script:Splash being $null by then, Show-Splash happily built a second
            # one, and nothing hid it again until the code was accepted.
            $script:SplashTimer.Stop()
            Hide-Splash    # the prompt must be visible, not behind the splash
            if ($tries -ge $max) {
                Write-Host ''
                Write-Host '   ACCESS DENIED - too many incorrect codes.' -ForegroundColor Red
                Write-Host '   Contact PC2Go for the current access code.' -ForegroundColor DarkGray
                Write-Host ''
                throw 'Access code not accepted - aborting.'
            }
            # The banner is drawn ONCE. Redrawing sixteen lines per wrong keystroke would bury
            # the one line that matters, which is why the retry is a single denial instead.
            if ($tries -eq 0) { Show-AccessBanner }
            else {
                Write-Host '   ACCESS DENIED' -ForegroundColor Red
                Write-Host ''
            }
            $env:PC2GO_CODE = Read-AccessCode ($max - $tries) $max
            $tries++
        }
    }
}
function Get-AccessHeader {
    $h = @{}
    if ($env:PC2GO_CODE) { $h['x-pc2go-code'] = $env:PC2GO_CODE }
    return $h
}

# Hand the code to a copy of the tool that will run ELEVATED.
#
# The environment does not survive -Verb RunAs: ShellExecuteEx goes through the AppInfo
# service, which builds a fresh block for the elevated process. So the code typed here would
# simply be absent in the copy that actually fetches the catalog - and only for an admin
# technician on a normal launch, which is the common case. A command-line argument is not the
# answer either: Win32_Process.CommandLine is readable by every process on the box.
#
# DPAPI at LocalMachine scope, in ProgramData, with an EXPLICIT DACL. Each part earns itself:
#   ProgramData    - %LOCALAPPDATA% is per-user, and the UAC prompt may be answered with a
#                    DIFFERENT admin account, whose LOCALAPPDATA is somewhere else entirely.
#   LocalMachine   - a CurrentUser blob written here would be undecryptable by that other
#                    admin. The trade is that LocalMachine has no per-user key, so ANY local
#                    process could unprotect it: the file ACL is what actually guards it.
#   Explicit DACL  - ProgramData subfolders inherit read access for Users, so an inherited
#                    ACL would leave the code readable by every standard account on the
#                    machine. Inheritance off; creator + Administrators + SYSTEM only.
#                    The creator is on the list because a filtered-token admin cannot write
#                    to an Administrators-only file - that ACL would break the writer.
# The elevated copy shreds the file the moment it has used it.
# The DACL is applied AT CREATION rather than after the write: WriteAllBytes would create the
# file under ProgramData's inherited ACL, where Users have read - and with LocalMachine DPAPI
# readable means decryptable, so that window is exactly what this design exists to close.
function Write-AccessBlob([string]$Path, [string]$Code) {
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $sec = New-Object Security.AccessControl.FileSecurity
    $sec.SetAccessRuleProtection($true, $false)
    foreach ($sid in @(([Security.Principal.WindowsIdentity]::GetCurrent()).User,
                       (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'),
                       (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'))) {
        $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $sid, 'FullControl', 'Allow')))
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Code)
    $blob = $null
    try { $blob = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'LocalMachine') }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # FileSystemRights lives in Security.AccessControl, NOT System.IO - the IO-namespaced
    # spelling parses fine and throws "Unable to find type" only when this actually runs
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Create,
                                   [Security.AccessControl.FileSystemRights]::WriteData,
                                   [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $sec)
    try { $fs.Write($blob, 0, $blob.Length) } finally { $fs.Dispose() }
}

function Save-AccessCode {
    if (-not $env:PC2GO_CODE) { return }
    $path = Join-Path $env:ProgramData 'PC2GoDeploy\access.bin'
    try { Write-AccessBlob $path $env:PC2GO_CODE; return } catch { }
    # A leftover token written by a DIFFERENT account refuses our write through its own DACL.
    # It is debris by definition - the tool deletes this file the moment it has used it - so
    # clearing it is the correct move, not a workaround.
    try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop; Write-AccessBlob $path $env:PC2GO_CODE; return } catch { }
    # Only now is it worth a person's attention - and this is the one failure whose symptom
    # (a 403 after typing the right code) cannot be diagnosed without naming the file.
    Write-Host 'Could not hand the access code to the elevated copy.' -ForegroundColor Yellow
    Write-Host "A hand-off file from another account is in the way: $path" -ForegroundColor Yellow
    Write-Host 'Delete it as an administrator, or start the tool from an elevated PowerShell.' -ForegroundColor Yellow
}

if ($needFetch) {
    [void](Invoke-WithAccess {
        Invoke-WebRequest -Uri "$BaseUrl/AppDeploy.ps1" -OutFile $ps1 -UseBasicParsing -Headers (Get-AccessHeader)
    })
    if ($pinned) {
        $actual = (Get-FileHash -LiteralPath $ps1 -Algorithm SHA256).Hash
        if ($actual -ne $PinnedHash.ToUpper()) {
            Remove-Item $ps1 -Force
            Hide-Splash
            throw 'AppDeploy.ps1 failed integrity check - aborting.'
        }
    }
} else {
    # The tool is already cached, so nothing above would have asked for the code - but the
    # catalog fetch inside the tool still needs it, and the tool has no console to ask on.
    # A HEAD probe against the catalog settles it here, where a prompt is possible.
    [void](Invoke-WithAccess {
        Invoke-WebRequest -Uri "$BaseUrl/apps.json" -Method Head -UseBasicParsing -TimeoutSec 15 -Headers (Get-AccessHeader) | Out-Null
    })
}

# Set PC2GO_TIMING before running this to get a startup breakdown written to
# %LOCALAPPDATA%\PC2GoDeploy\timing.log. It comes from the environment because the whole tool is
# launched through `irm ... | iex`, where there is nowhere to put a switch:
#
#   $env:PC2GO_TIMING = 1
#   irm https://apps.pc2go.ca/go | iex
$extra = ''
if ($env:PC2GO_TIMING) { $extra = ' -Timing' }

$launch = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`" -BaseUrl `"$BaseUrl`"$extra"

# Decide elevation HERE rather than inside the tool.
#
# AppDeploy.ps1 can elevate itself, and still can - but to reach that decision it must first be
# loaded, and it is ~480 KB. On a machine running a second antivirus alongside Defender that
# load measured EIGHT SECONDS of script scanning, paid in full by a process whose only job is to
# decide "should I elevate?" and then exit. Deciding it here, in a file small enough to scan
# instantly, means the tool is loaded once instead of twice.
#
# Only the fast path lives here. Test-IsAdminMember in AppDeploy.ps1 remains the authority - it
# has an ADSI fallback for machines where Get-LocalGroupMember misbehaves, and duplicating that
# would be two copies of a subtle thing, free to drift apart. If anything here is uncertain (the
# check throws, the group cannot be read, UAC is declined) this falls through and launches
# exactly as before, letting the tool decide for itself. Slower, never wrong.
#
# The membership test asks the GROUP, not the token: on a filtered token the Administrators SID
# can be deny-only, or absent altogether, even for a real administrator.
$elevate = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $me = $id.User.Value
        foreach ($m in @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop)) {
            if ($m.SID.Value -eq $me) { $elevate = $true; break }
        }
    }
} catch { $elevate = $false }

# The splash goes before the UAC prompt, not after it: a modal dialog over a window still
# claiming to be "getting ready" reads as two things happening at once.
$script:SplashTimer.Stop()
Hide-Splash

if ($elevate) {
    try {
        # the elevated copy gets a fresh environment, so the code has to travel out-of-band
        Save-AccessCode
        # -NoSelfElevate because the decision is already made; without it the elevated copy
        # would run the same check again for nothing.
        Start-Process -FilePath $winPS -Verb RunAs -WindowStyle Hidden -ArgumentList "$launch -NoSelfElevate"
        # The tool has it (through the hand-off file); this console has no further use for it,
        # and a code left in the environment is one a later command could read.
        $env:PC2GO_CODE = ''
        return
    } catch {
        # Declined, or elevation unavailable. Fall through and let the tool ask in its own way.
    }
}

Start-Process -FilePath $winPS -WindowStyle Hidden -ArgumentList $launch
# The launched tool inherited it a moment ago; leaving a copy behind in the technician's own
# shell serves nothing, and the next go line asks again by design.
$env:PC2GO_CODE = ''

} finally {
    # Reached on EVERY exit: the normal launch above, a throw, and - the case this exists for -
    # Ctrl+C at the access-code prompt. Both calls are idempotent and both swallow their own
    # failures, because a splash that will not close must never become the reason a launch
    # fails or an error is replaced by a different one on the way out.
    try { $script:SplashTimer.Stop() } catch { }
    try { Hide-Splash } catch { }
    # The code never outlives the bootstrap. On the Ctrl+C path nothing below the prompt runs,
    # so without this a cancelled launch would leave the typed code sitting in the technician's
    # own shell for anything later in that session to read.
    $env:PC2GO_CODE = ''
}
