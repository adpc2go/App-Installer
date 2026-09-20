# Copy a build under a new name so real-time protection scans it (and asks the cloud) exactly as a
# download would, then watch Defender's operational log for a verdict on that path. -Motw marks the
# copy as an internet download first (Zone.Identifier 3), the strictest path Defender has.
# Run before every publish: the exe is unsigned, and Defender's cloud ML condemned one build's hash
# (client 18, Trojan:Win32/Bearfoos.B!ml) while the same source with one string changed passed.
param([string]$Name, [string]$Exe = 'c:\Users\Legion-T7\Projects\App-Installer\client\dist\PC2Go.Deploy.exe', [int]$WaitSec = 75, [switch]$Motw,
      [string]$Dir = (Join-Path $env:TEMP 'pc2go-av'))
New-Item -ItemType Directory -Force $Dir | Out-Null
$dst = Join-Path $Dir "$Name.exe"
$hash = (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash.Substring(0, 12)
$t0 = Get-Date
Copy-Item -LiteralPath $Exe -Destination $dst -Force
if ($Motw) { Set-Content -Path $dst -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`nReferrerUrl=https://apps.pc2go.ca/go-exe`r`nHostUrl=https://apps.pc2go.ca/PC2Go.Deploy.exe" }
while (((Get-Date) - $t0).TotalSeconds -lt $WaitSec) {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116, 1117; StartTime = $t0.AddSeconds(-2) } -ErrorAction SilentlyContinue | Where-Object { $_.Message -like "*$dst*" })
    if ($ev.Count) {
        $m = ($ev | Sort-Object TimeCreated | Select-Object -First 1).Message -split "`n" | Where-Object { $_ -match 'Name:' } | Select-Object -First 1
        "DETECTED  $Name  ($hash)  after $([int]((Get-Date) - $t0).TotalSeconds)s :$($m.Trim())"
        return
    }
    Start-Sleep -Seconds 3
}
$od = & "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -Scan -ScanType 3 -File $dst -DisableRemediation 2>&1 | Out-String
$odv = $(if ($LASTEXITCODE -eq 2) { 'on-demand scan: THREAT' } elseif ($LASTEXITCODE -eq 0) { 'on-demand scan: clean' } else { "on-demand scan exit $LASTEXITCODE" })
"CLEAN     $Name  ($hash)  after $WaitSec s of real-time watch; $odv; file present: $(Test-Path -LiteralPath $dst)"
