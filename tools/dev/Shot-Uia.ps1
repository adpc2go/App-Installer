# Launch the compiled client against a loopback catalog, drive it through UI Automation (no
# synthetic mouse, no foreground needed), screenshot the window with PrintWindow, close it.
# Lived in the session scratchpad until Temp cleanup took it; kept here since.
#   -Actions  'invoke:Block Internet Access','help:Show the executables this covers','toggle:2','wait:3','dump'
# Note: rows inside a grouped ItemsControl are not exposed to UI Automation, so 'toggle' only
# reaches flat lists; use a Select All button (invoke) to show a ticked state on grouped lists.
param([string]$Exe = 'c:\Users\Legion-T7\Projects\App-Installer\client\dist\PC2Go.Deploy.exe',
      [string]$Catalog = 'c:\Users\Legion-T7\Projects\App-Installer\server\apps.json',
      [string]$Out = (Join-Path $env:TEMP 'client-shot.png'),
      [int]$Port = 18779, [double]$SettleSec = 4, [string[]]$Actions = @(), [string]$Extra = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -Namespace Shot -Name U32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
public struct RECT { public int L, T, R, B; }
'@
[void][Shot.U32]::SetProcessDPIAware()
$json = [IO.File]::ReadAllBytes($Catalog)
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
$serve = {
    param($l, $j)
    while ($l.IsListening) {
        try { $c = $l.GetContext() } catch { break }
        if ($c.Request.RawUrl -eq '/apps.json') { $c.Response.ContentType = 'application/json'; $c.Response.OutputStream.Write($j, 0, $j.Length) } else { $c.Response.StatusCode = 404 }
        $c.Response.Close()
    }
}
$ps = [PowerShell]::Create(); [void]$ps.AddScript($serve).AddArgument($listener).AddArgument($json); $h = $ps.BeginInvoke()
$p = Start-Process -FilePath $Exe -ArgumentList "-BaseUrl http://127.0.0.1:$Port -NoSelfElevate -KeepCache $Extra" -PassThru
try {
    Start-Sleep -Seconds $SettleSec
    $p.Refresh()
    $hwnd = $p.MainWindowHandle
    $root = [Windows.Automation.AutomationElement]::FromHandle($hwnd)
    $A = [Windows.Automation.AutomationElement]
    $T = [Windows.Automation.TreeScope]::Descendants
    foreach ($act in $Actions) {
        $kind, $arg = $act -split ':', 2
        switch ($kind) {
            'wait' { Start-Sleep -Seconds ([double]$arg) }
            'dump' {
                # what UI Automation sees right now: element counts by control type, first checkbox names
                $root = [Windows.Automation.AutomationElement]::FromHandle($hwnd)
                $els = $root.FindAll($T, [Windows.Automation.Condition]::TrueCondition)
                "dump: $($els.Count) elements"
                $els | ForEach-Object { $_.Current.ControlType.ProgrammaticName } | Group-Object | Sort-Object Count -Descending | ForEach-Object { "   $($_.Count) x $($_.Name)" }
                $els | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::CheckBox } | Select-Object -First 5 | ForEach-Object { "   checkbox: '$($_.Current.Name)'" }
            }
            'invoke' {
                $el = $root.FindFirst($T, (New-Object Windows.Automation.PropertyCondition ($A::NameProperty), $arg))
                if (-not $el) { throw "no element named '$arg'" }
                $el.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
                "invoked '$arg'"
            }
            'help' {
                # the first button whose tooltip is this (a Firewall row's detail button)
                $el = $root.FindFirst($T, (New-Object Windows.Automation.PropertyCondition ($A::HelpTextProperty), $arg))
                if (-not $el) { throw "no element with help text '$arg'" }
                $el.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
                "invoked help '$arg'"
            }
            'toggle' {
                # the Nth checkbox (1-based) among every checkbox in the window
                $all = $root.FindAll($T, (New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::ControlTypeProperty), ([Windows.Automation.ControlType]::CheckBox)))
                $i = [int]$arg
                if ($all.Count -lt $i) { "WARN only $($all.Count) checkboxes - not toggled"; continue }
                $all.Item($i - 1).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
                "toggled checkbox $i"
            }
        }
        Start-Sleep -Milliseconds 600
    }
    Start-Sleep -Milliseconds 800
    $r = New-Object Shot.U32+RECT
    [void][Shot.U32]::GetWindowRect($hwnd, [ref]$r)
    $w = $r.R - $r.L; $hgt = $r.B - $r.T
    $bmp = New-Object Drawing.Bitmap $w, $hgt
    $g = [Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void][Shot.U32]::PrintWindow($hwnd, $hdc, 2)
    $g.ReleaseHdc($hdc)
    $bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    "saved $Out  ($w x $hgt)"
} finally {
    if (-not $p.HasExited) { try { $p.Kill() } catch { } }
    $listener.Stop(); $ps.Stop(); $ps.Dispose()
}
