#requires -Version 5.1
<#
  Host clipboard -> guest clipboard.  .\Send-LabClipboard.ps1
  Or send literal text:               .\Send-LabClipboard.ps1 -Text 'whatever'

  Works in Basic Session, where vmconnect shares no clipboard at all.
#>
param(
    [string]$VMName   = 'Home',
    [string]$Text,
    [string]$CredPath = "$env:LOCALAPPDATA\$VMName\guest.cred.xml"
)
$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('Text')) { $Text = Get-Clipboard -Raw }
if ($null -eq $Text) { throw 'Host clipboard is empty (or holds non-text).' }

$cred = Import-Clixml $CredPath
$s = New-PSSession -VMName $VMName -Credential $cred
Invoke-Command $s -ArgumentList $Text, $cred.UserName -ScriptBlock {
    param($t, $user)
    New-Item -ItemType Directory -Force -Path 'C:\Lab' | Out-Null
    Set-Content 'C:\Lab\clip.txt' -Value $t -Encoding UTF8 -NoNewline

    # The clipboard belongs to a window station, and PowerShell Direct lands in session 0 -
    # so a Set-Clipboard here would write a clipboard nothing on the desktop can see. The
    # task runs it in the signed-in session, which owns the clipboard the user actually uses.
    Set-Content 'C:\Lab\clip-set.ps1' -Encoding UTF8 -Value @'
Set-Clipboard -Value (Get-Content 'C:\Lab\clip.txt' -Raw)
'@
    Unregister-ScheduledTask -TaskName 'LabClipSet' -Confirm:$false -ErrorAction SilentlyContinue
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File C:\Lab\clip-set.ps1'
    $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName 'LabClipSet' -Action $a -Principal $p | Out-Null
    Start-ScheduledTask -TaskName 'LabClipSet'
}
Remove-PSSession $s
Write-Host ("sent {0} chars to the lab clipboard" -f $Text.Length) -ForegroundColor Green
