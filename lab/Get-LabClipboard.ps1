#requires -Version 5.1
<#
  Guest clipboard -> host clipboard.  .\Get-LabClipboard.ps1
  Add -NoSet to print it instead of replacing your host clipboard.
#>
param(
    [string]$VMName   = 'Home',
    [string]$CredPath = "$env:LOCALAPPDATA\$VMName\guest.cred.xml",
    [switch]$NoSet
)
$ErrorActionPreference = 'Stop'
$cred = Import-Clixml $CredPath
$s = New-PSSession -VMName $VMName -Credential $cred

Invoke-Command $s -ArgumentList $cred.UserName -ScriptBlock {
    param($user)
    New-Item -ItemType Directory -Force -Path 'C:\Lab' | Out-Null
    Remove-Item 'C:\Lab\clip-out.txt' -Force -ErrorAction SilentlyContinue
    # Same window-station problem in reverse: only the interactive session can read the
    # clipboard the user sees, so it dumps it to a file this session can pick up.
    Set-Content 'C:\Lab\clip-get.ps1' -Encoding UTF8 -Value @'
Set-Content 'C:\Lab\clip-out.txt' -Value (Get-Clipboard -Raw) -Encoding UTF8 -NoNewline
'@
    Unregister-ScheduledTask -TaskName 'LabClipGet' -Confirm:$false -ErrorAction SilentlyContinue
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File C:\Lab\clip-get.ps1'
    $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName 'LabClipGet' -Action $a -Principal $p | Out-Null
    Start-ScheduledTask -TaskName 'LabClipGet'
}

$text = $null
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    $text = Invoke-Command $s { Get-Content 'C:\Lab\clip-out.txt' -Raw -ErrorAction SilentlyContinue }
    if ($null -ne $text) { break }
    Start-Sleep -Milliseconds 300
}
Remove-PSSession $s

if ($null -eq $text) { throw 'Guest did not produce clipboard content within 15s.' }
if ($NoSet) { $text } else { Set-Clipboard -Value $text; Write-Host ("pulled {0} chars from the lab clipboard" -f $text.Length) -ForegroundColor Green }
