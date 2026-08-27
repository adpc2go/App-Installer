#requires -Version 5.1
<#
  Continuously mirror the host clipboard into the guest. For the Home VM, which cannot host
  RDP and so can never have Enhanced Session's native clipboard.

    labsync              # foreground, Ctrl+C to stop
    labsync -Background  # detached, keeps running; Stop-Job to end it

  One PowerShell Direct session and one scheduled task are set up once and reused, so a
  clipboard change costs a file write and a task trigger rather than a new connection.
#>
[CmdletBinding()]
param(
    [string]$VMName    = 'AppLab',
    [int]$PollMs       = 700,
    [string]$CredPath  = "$env:LOCALAPPDATA\$VMName\guest.cred.xml",
    [switch]$Background
)
$ErrorActionPreference = 'Stop'

if ($Background) {
    # NOT Start-Job: background jobs run MTA, and Get-Clipboard requires STA - it returns
    # nothing there, so the loop would poll forever and never see a change. A detached
    # -STA process is the only way this works.
    $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",
        '-VMName',$VMName,'-PollMs',$PollMs)
    Write-Host "clipboard sync running as PID $($p.Id) - 'Stop-Process -Id $($p.Id)' to end it" -ForegroundColor Green
    return
}

$cred = Import-Clixml $CredPath
$s = New-PSSession -VMName $VMName -Credential $cred

# Registered once. The clipboard belongs to a window station and PowerShell Direct lands in
# session 0, so the actual Set-Clipboard has to run in the signed-in session.
Invoke-Command $s -ArgumentList $cred.UserName -ScriptBlock {
    param($user)
    New-Item -ItemType Directory -Force -Path 'C:\Lab' | Out-Null
    Set-Content 'C:\Lab\clip-set.ps1' -Encoding UTF8 -Value @'
Set-Clipboard -Value (Get-Content 'C:\Lab\clip.txt' -Raw)
'@
    if (-not (Get-ScheduledTask -TaskName 'LabClipSet' -ErrorAction SilentlyContinue)) {
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File C:\Lab\clip-set.ps1'
        $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName 'LabClipSet' -Action $a -Principal $p | Out-Null
    }
}

Write-Host "mirroring host clipboard -> $VMName (Ctrl+C to stop)" -ForegroundColor Green
$last = $null
try {
    while ($true) {
        $now = Get-Clipboard -Raw -ErrorAction SilentlyContinue
        if ($null -ne $now -and $now -ne $last) {
            $last = $now
            try {
                Invoke-Command $s -ArgumentList $now -ScriptBlock {
                    param($t)
                    Set-Content 'C:\Lab\clip.txt' -Value $t -Encoding UTF8 -NoNewline
                    Start-ScheduledTask -TaskName 'LabClipSet'
                }
                Write-Host ("  -> {0} chars" -f $now.Length) -ForegroundColor DarkGray
            } catch {
                # A revert kills the session mid-loop; reconnect rather than dying.
                Write-Host '  reconnecting...' -ForegroundColor DarkGray
                Remove-PSSession $s -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                $s = New-PSSession -VMName $VMName -Credential $cred
                $last = $null
            }
        }
        Start-Sleep -Milliseconds $PollMs
    }
} finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
