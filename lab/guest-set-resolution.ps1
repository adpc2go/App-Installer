# Runs INSIDE the guest via Update-Baseline.ps1. Sets the console resolution and persists it,
# so every revert starts at this size instead of 1024x768.
#
# ChangeDisplaySettings only affects the display of the session that calls it, and
# PowerShell Direct lands in session 0 - so the work is handed to a scheduled task running
# in the signed-in session, the same way the GUI launch and the clipboard bridge are.
$ErrorActionPreference = 'Stop'
$W = 1280; $H = 1024   # same as Pro's Enhanced Session size

$helper = @"
`$src = @'
using System;
using System.Runtime.InteropServices;
public class Disp {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
    public int dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll")] public static extern int EnumDisplaySettings(string d,int m,ref DEVMODE dm);
  [DllImport("user32.dll")] public static extern int ChangeDisplaySettings(ref DEVMODE dm,int f);
  public static int Set(int w,int h){
    DEVMODE dm = new DEVMODE();
    dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (EnumDisplaySettings(null, -1, ref dm) == 0) return -99;
    dm.dmPelsWidth = w; dm.dmPelsHeight = h;
    dm.dmFields = 0x80000 | 0x100000;          // DM_PELSWIDTH | DM_PELSHEIGHT
    return ChangeDisplaySettings(ref dm, 0x01); // CDS_UPDATEREGISTRY - survives the reboot
  }
}
'@
Add-Type -TypeDefinition `$src
`$r = [Disp]::Set($W, $H)
Set-Content 'C:\Lab\res-result.txt' -Value ("rc=`$r " + [string](Get-CimInstance Win32_VideoController).VideoModeDescription) -Encoding UTF8
"@

New-Item -ItemType Directory -Force -Path 'C:\Lab' | Out-Null
Remove-Item 'C:\Lab\res-result.txt' -Force -ErrorAction SilentlyContinue
Set-Content 'C:\Lab\set-res.ps1' -Value $helper -Encoding UTF8

$user = "$env:COMPUTERNAME\$env:USERNAME"
Unregister-ScheduledTask -TaskName 'LabSetRes' -Confirm:$false -ErrorAction SilentlyContinue
$a = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Lab\set-res.ps1'
$p = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName 'LabSetRes' -Action $a -Principal $p | Out-Null
Start-ScheduledTask -TaskName 'LabSetRes'

$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    if (Test-Path 'C:\Lab\res-result.txt') { break }
    Start-Sleep -Milliseconds 400
}
# rc=0 is DISP_CHANGE_SUCCESSFUL; anything else and the size did not take.
if (Test-Path 'C:\Lab\res-result.txt') { Get-Content 'C:\Lab\res-result.txt' -Raw }
else { 'resolution task produced no result within 30s' }
