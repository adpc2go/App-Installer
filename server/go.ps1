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
# Stamped by tools\Publish-Release.ps1 at publish time and printed in the banner. That line used
# to end with Get-Date, which is just "now": it read as a login time and told the technician
# nothing about whether the tool in front of him was the current one. These two say what went
# out and when it went out, in UTC, because the people running this are not in one timezone.
$Release  = 'unpublished'                      # <-- rewritten on publish
$Released = 'unpublished'                      # <-- rewritten on publish
# The launch line is pasted into whatever window happened to be open - often 80x25, sometimes a
# tall thin one - and the banner is designed at 64 columns with wider status lines under it. So
# the window is put into a known shape once, here, before anything is drawn. Every call is
# guarded: a redirected host, a remote session and the ISE each refuse one or more of them, and
# none of it is worth failing a launch over.
function Set-ConsoleShape {
    try { $Host.UI.RawUI.WindowTitle = 'PC2Go App Installer' } catch { }
    # Three steps, in this order, through the .NET console API rather than $Host.UI.RawUI.
    #
    # The rule the console enforces is that the window may never be wider or taller than the
    # buffer, not even for the instant between two assignments - so the window is shrunk to
    # something that fits the CURRENT buffer first, the buffer then takes its real shape, and
    # only then does the window grow into it. Measured: doing it in any other order either
    # throws "Window cannot be taller than the screen buffer" or silently collapses the buffer.
    #
    # The 3000-row buffer is a request, not a promise. Under Windows Terminal - which is the
    # default on Windows 11 - the console is a ConPTY, where the buffer IS the window and
    # scrollback belongs to the terminal rather than to us; there BufferHeight simply reads back
    # as the window height and Terminal keeps its own, longer, scrollback. Under classic conhost
    # it takes, and a long run stays readable afterwards. Neither case is worth failing over.
    try {
        $wantW = [Math]::Min(100, [Console]::LargestWindowWidth)
        $wantH = [Math]::Min(34,  [Console]::LargestWindowHeight)
        $w0 = [Math]::Min($wantW, [Console]::BufferWidth)
        $h0 = [Math]::Min([Console]::WindowHeight, [Console]::BufferHeight)
        [Console]::SetWindowSize($w0, $h0)
        [Console]::SetBufferSize($wantW, [Math]::Max(3000, $h0))
        [Console]::SetWindowSize($wantW, $wantH)
    } catch { }
}
Set-ConsoleShape

$dir = Join-Path $env:LOCALAPPDATA 'PC2GoDeploy'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$ps1 = Join-Path $dir 'AppDeploy.ps1'
# The compiled client. 'exe' once it is live at the edge (BOOT_CLIENT in wrangler.toml); until
# then the script is launched and these lines are idle. Both values are rewritten by the Worker.
$Client = 'script'
$ExeHash = 'PINNED_EXE_SHA256_GOES_HERE'
$exe = Join-Path $dir 'PC2Go.Deploy.exe'

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
# The exe is taken only with a real pin. An unpinned script runs with a warning; an unpinned
# exe is not run at all - the script is launched instead, verified as it always was.
$useExe = ($Client -eq 'exe' -and $ExeHash -match '^[0-9A-Fa-f]{64}$')
$tool = $ps1; $want = $PinnedHash; $key = 'AppDeploy.ps1'; $toolPinned = $pinned
if ($useExe) { $tool = $exe; $want = $ExeHash; $key = 'PC2Go.Deploy.exe'; $toolPinned = $true }

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

<#
    Hold the splash until the tool's own window is up, then a moment longer.

    Launching is not finishing. The bootstrap used to put the splash away and immediately exit,
    but the tool still has to start PowerShell, parse 700 KB of script, build its window and
    fetch the catalog - several seconds during which the technician has a splash vanish and then
    nothing at all on screen, which is the one moment it is most needed.

    MainWindowHandle is the signal, and it is exact: the tool is launched -WindowStyle Hidden, so
    its console never counts, and the handle stays 0 until the WPF window is actually shown.
    Measured against a stand-in that slept three seconds before showing its window - the handle
    flipped at 3716ms, not before.

    Bounded, and best-effort throughout. If the tool never opens a window this waits TimeoutSec
    and gives up rather than holding a splash over a machine that is going nowhere; a splash is
    a courtesy and must never become the reason the bootstrap does not end.
#>
function Wait-AppWindow($Proc, [int]$TimeoutSec = 45, [int]$LingerMs = 1200) {
    if (-not $Proc) { return }
    Show-Splash
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        try {
            $Proc.Refresh()
            if ($Proc.HasExited) { break }
            if ($Proc.MainWindowHandle -ne [IntPtr]::Zero) {
                # The window exists; give it long enough to paint before pulling the splash out
                # from under it, or the two swap places with a visible gap between them.
                Start-Sleep -Milliseconds $LingerMs
                break
            }
        } catch { break }
        Start-Sleep -Milliseconds 200
    }
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
if ($toolPinned -and (Test-Path -LiteralPath $tool)) {
    try {
        if ((Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash -eq $want.ToUpper()) {
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

    # Width follows the window when it is narrower than the banner, or a 70-column console
    # wraps every line and the box stops being a box. 64 is the design width.
    $w = 64
    try { $w = [Math]::Max(40, [Math]::Min(64, $Host.UI.RawUI.WindowSize.Width - 4)) } catch { }
    $bar = '  ' + ('=' * $w)
    # Reverse video for the name: black on green, padded to the FULL width of the frame so it
    # reads as a solid header bar rather than a highlighted phrase. Centred by padding rather
    # than by counting spaces into the literal, so it stays centred at any width.
    # Two logos. The solid one is built from U+2588 FULL BLOCK and drawn twice - once offset by
    # one row and one column in dark grey, then again on top in green with the spaces skipped, so
    # the grey shows through as a cast shadow. That needs three things the host may not give us:
    # a UTF-8 output code page, a readable cursor position, and a buffer tall enough to move
    # around in. When any of them is missing the flat ASCII logo below is drawn instead, which is
    # what shipped before and renders on anything. The code page is put back afterwards: glyphs
    # already on screen are stored decoded, so restoring it does not un-draw them, and the tool
    # launched after this gets the console it expected.
    # Assembled from per-letter columns rather than written as five long literals, because a
    # long literal that is one character out is invisible in the source and obvious on screen -
    # which is exactly what happened the first time this was written by hand. Every glyph is
    # five columns, joined by one, so every row is the same width by construction.
    $glyphs = @{
        P = @('#### ', '#  # ', '#### ', '#    ', '#    ')
        C = @(' ####', '#    ', '#    ', '#    ', ' ####')
        T = @('#### ', '   # ', '#### ', '#    ', '#### ')     # the 2
        G = @(' ####', '#    ', '# ###', '#   #', ' ####')
        O = @(' ### ', '#   #', '#   #', '#   #', ' ### ')
    }
    # built at run time so the file itself stays pure ASCII on disk - the same reason the flat
    # logo below exists at all
    $blk = [string][char]0x2588
    $solid = @(0..4 | ForEach-Object {
        $r = $_
        (@('P', 'C', 'T', 'G', 'O') | ForEach-Object { $glyphs[$_][$r] }) -join ' '
    })
    $solid = @($solid | ForEach-Object { $_.Replace('#', $blk) })
    $logo = @(
        ' ____   ____ ____   ____        ',
        '|  _ \ / ___|___ \ / ___| ___   ',
        '| |_) | |     __) | |  _ / _ \  ',
        '|  __/| |___ / __/| |_| | (_) | ',
        '|_|    \____|_____|\____|\___/  '
    )
    $lead  = [Math]::Max(0, [int](($w - $logo[0].Length) / 2))
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkGreen

    $drew = $false
    $prevEnc = $null
    try {
        $prevEnc = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
        if ([Console]::OutputEncoding.CodePage -eq 65001) {
            $raw = $Host.UI.RawUI
            $x0  = [Math]::Max(0, [int](($w - $solid[0].Length) / 2)) + 2
            # Room FIRST, and the position read AFTER it - not the other way round. Writing these
            # blank lines can SCROLL the buffer, and when it does, everything already on screen
            # moves up by however many rows scrolled. A position read beforehand then points at
            # the wrong row, which is exactly what happens when the launch line is pasted into a
            # console that already has output in it - i.e. every real launch. Reading afterwards
            # and counting back cannot be wrong, because the scroll has already happened.
            $gap = $solid.Count + 2
            for ($i = 0; $i -lt $gap; $i++) { Write-Host '' }
            $landed = $raw.CursorPosition
            $y0 = $landed.Y - $gap
            if ($y0 -lt 0) { throw 'not enough room above the cursor for the logo' }
            for ($i = 0; $i -lt $solid.Count; $i++) {
                $raw.CursorPosition = New-Object Management.Automation.Host.Coordinates(($x0 + 1), ($y0 + $i + 1))
                Write-Host $solid[$i] -ForegroundColor DarkGray -NoNewline
            }
            # the face, in runs of solid characters, so the shadow survives in the gaps
            for ($i = 0; $i -lt $solid.Count; $i++) {
                $row = $solid[$i]; $c = 0
                while ($c -lt $row.Length) {
                    if ($row[$c] -eq ' ') { $c++; continue }
                    $s0 = $c
                    while ($c -lt $row.Length -and $row[$c] -ne ' ') { $c++ }
                    $raw.CursorPosition = New-Object Management.Automation.Host.Coordinates(($x0 + $s0), ($y0 + $i))
                    Write-Host $row.Substring($s0, $c - $s0) -ForegroundColor Green -NoNewline
                }
            }
            # back to where the blank lines left us, so everything after this prints below
            $raw.CursorPosition = $landed
            $drew = $true
        }
    } catch { $drew = $false }
    finally { try { if ($prevEnc) { [Console]::OutputEncoding = $prevEnc } } catch { } }
    if (-not $drew) {
        # the flat logo that shipped before, and what any host that refused one of the three
        # things above still gets - a redirected console, a remote session, the ISE
        foreach ($ln in $logo) { Write-Host ('  ' + (' ' * $lead) + $ln) -ForegroundColor Green }
    }
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
    # version on the left, updated against the right-hand end of the frame, so the two read as
    # two facts rather than one run-on line. Padded by arithmetic like every other line here, so
    # it stays aligned at whatever width the window gives us.
    $vTxt = "version $Release"
    $uTxt = "updated $Released"
    $pad  = [Math]::Max(3, $w - $vTxt.Length - $uTxt.Length)
    Write-Host ('   ' + $vTxt + (' ' * $pad) + $uTxt) -ForegroundColor DarkGray
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
                $ex = $_.Exception
                if ($ex -is [Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }
                $resp = $ex.Response
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
            # Shown DIRECTLY, not by re-arming the timer, and this is the whole reason the
            # splash was never visible while the tool was actually downloading.
            #
            # PowerShell dispatches event-action callbacks between pipeline statements. A
            # blocking fetch never yields, so a timer armed before it does not fire
            # until it RETURNS. Measured: an 800ms one-shot against a 4052ms download fired at
            # +4051ms - the instant the request finished, by which point the splash has nothing
            # left to cover. The only moment it could ever appear was during Read-Host, which is
            # exactly why it used to land on top of the passcode prompt.
            #
            # The code has just been typed and the next thing is the fetch, so there is no
            # guessing left to do about whether work is coming - say so, and show it now.
            Write-Host '   Checking the code and getting this machine''s copy ready...' -ForegroundColor DarkGray
            Write-Host ''
            Show-Splash
        }
    }
}
function Get-AccessHeader {
    $h = @{}
    if ($env:PC2GO_CODE) { $h['x-pc2go-code'] = $env:PC2GO_CODE }
    return $h
}

# One fetch from the edge, to a file - or a HEAD, to prove the code, with no file.
# Not Invoke-WebRequest: in PowerShell 5.1 its progress bar is redrawn per chunk (MEASURED: the
# same 1 MB took 746 ms with it, 86 ms without) and it never asks for gzip (1,014 KB on the wire
# against 251 KB). A 403 still arrives as a WebException with its Response, so Invoke-WithAccess
# reads it as before, and the hash is taken after decompression, so the pin is untouched.
function Get-EdgeFile([string]$Uri, [string]$OutFile, [hashtable]$Headers, [int]$TimeoutSec = 300, [switch]$Head) {
    $req = [Net.HttpWebRequest]::Create($Uri)
    $req.Method = $(if ($Head) { 'HEAD' } else { 'GET' })
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $req.UserAgent = 'PC2GoDeploy/go'
    foreach ($k in @($Headers.Keys)) { $req.Headers[$k] = [string]$Headers[$k] }
    $resp = $null
    try { $resp = $req.GetResponse() } catch {
        # a .NET throw inside a function arrives wrapped; hand the caller the real WebException
        $ex = $_.Exception
        if ($ex.InnerException) { $ex = $ex.InnerException }
        throw $ex
    }
    try {
        if ($Head) { return }
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($OutFile)
        try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
    } finally { $resp.Close() }
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
        Get-EdgeFile -Uri "$BaseUrl/$key" -OutFile $tool -Headers (Get-AccessHeader)
    })
    if ($toolPinned) {
        $actual = (Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash
        if ($actual -ne $want.ToUpper()) {
            Remove-Item $tool -Force
            Hide-Splash
            throw "$key failed integrity check - aborting."
        }
    }
} else {
    # The tool is already cached, so nothing above would have asked for the code - but the
    # catalog fetch inside the tool still needs it, and the tool has no console to ask on.
    # A HEAD probe against the catalog settles it here, where a prompt is possible.
    [void](Invoke-WithAccess {
        Get-EdgeFile -Uri "$BaseUrl/apps.json" -Head -TimeoutSec 15 -Headers (Get-AccessHeader)
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

$launchExe = $winPS
$launch = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`" -BaseUrl `"$BaseUrl`"$extra"
if ($useExe) {
    # The pin is the trust root either way. A signature, when there is one, has to be intact:
    # a broken one on bytes that match the pin means the pin was moved to cover it.
    $sig = Get-AuthenticodeSignature -LiteralPath $exe
    if ($sig.Status -ne 'Valid' -and $sig.Status -ne 'NotSigned') {
        Remove-Item $exe -Force
        Hide-Splash
        throw "PC2Go.Deploy.exe carries a broken signature ($($sig.Status)) - aborting."
    }
    # the exe reads the tool's own switches; there is no interpreter in between
    $launchExe = $exe
    $launch = "-BaseUrl `"$BaseUrl`"$extra"
}

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
# claiming to be "getting ready" reads as two things happening at once. Only on the path that
# prompts: hidden on every launch, an already-elevated console watched it vanish for a second
# and come back for no dialog at all (reported from the field).
$script:SplashTimer.Stop()

if ($elevate) {
    Hide-Splash
    try {
        # the elevated copy gets a fresh environment, so the code has to travel out-of-band
        Save-AccessCode
        # -NoSelfElevate because the decision is already made; without it the elevated copy
        # would run the same check again for nothing.
        $child = Start-Process -FilePath $launchExe -Verb RunAs -WindowStyle Hidden -PassThru `
                               -ArgumentList "$launch -NoSelfElevate"
        # The tool has it (through the hand-off file); this console has no further use for it,
        # and a code left in the environment is one a later command could read.
        $env:PC2GO_CODE = ''
        # The splash was put away for the UAC prompt above - a modal dialog over a window still
        # claiming to be "getting ready" reads as two things happening at once. The prompt has
        # been answered by now, so it comes back for the wait that actually needs it.
        Wait-AppWindow $child
        return
    } catch {
        # Declined, or elevation unavailable. Fall through and let the tool ask in its own way.
    }
}

$child = Start-Process -FilePath $launchExe -WindowStyle Hidden -PassThru -ArgumentList $launch
# The launched tool inherited it a moment ago; leaving a copy behind in the technician's own
# shell serves nothing, and the next go line asks again by design.
$env:PC2GO_CODE = ''
Wait-AppWindow $child

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
