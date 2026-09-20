<#
.SYNOPSIS
    The one Data Backup path that needs TWO machines: back a profile folder up from one lab VM
    to a share on the other, with a sign-in, through the real worker code - and find that PC
    the way the Find a PC dialog does.

.DESCRIPTION
    Runs on the Hyper-V host. Copies AppDeploy.ps1 into the SOURCE VM over PowerShell Direct,
    slices the worker out of it there (the same extraction Test-DataBackup uses), and runs:

      1. GUI side, inside the source VM: Find-NetworkHosts must discover the target VM by
         its address; Get-HostShares must list the share; Connect-Share with the sign-in must
         succeed and Disconnect-Share must not throw.
      2. Worker side, inside the source VM: a hand-written 'migrate' queue entry with
         dstKind=folder pointing at \\TARGET\SHARE, netUser/netPassword set, run through the
         real worker script. The row must report Applied; the files and the pc2go-backup.json
         manifest must be readable on the share afterwards; a second run must be incremental;
         a wrong password must come back as a sentence, not a hang.

    Nothing runs elevated: PowerShell Direct hands a filtered token, and none of this needs
    more. The share must already exist on the target (create it once, as an admin there):
        New-Item -ItemType Directory -Force C:\Backup; New-SmbShare -Name Backup -Path C:\Backup -FullAccess lab

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-LabSmb.ps1 -SourceVM Home -TargetVM Pro -Share Backup
#>
[CmdletBinding()]
param(
    [string]$SourceVM = 'Home',
    [string]$TargetVM = 'Pro',
    [string]$Share = 'Backup',
    [string]$User = 'lab',
    [string]$Password = '8559',
    [string]$ScriptPath
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptPath) { $ScriptPath = Join-Path (Split-Path -Parent $here) 'server\AppDeploy.ps1' }

$cred = New-Object PSCredential($User, (ConvertTo-SecureString $Password -AsPlainText -Force))
$src = New-PSSession -VMName $SourceVM -Credential $cred
$tgt = New-PSSession -VMName $TargetVM -Credential $cred
try {
    $tInfo = Invoke-Command -Session $tgt -ScriptBlock {
        [pscustomobject]@{ Name = $env:COMPUTERNAME
                           Ip   = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' } | Select-Object -First 1).IPAddress
                           Shares = @(Get-SmbShare | Where-Object { $_.Name -notlike '*$' } | ForEach-Object { $_.Name }) }
    }
    Write-Host "Target : $($tInfo.Name) ($($tInfo.Ip)) shares: $($tInfo.Shares -join ',')" -ForegroundColor DarkGray
    if ($tInfo.Shares -notcontains $Share) { throw "Share '$Share' does not exist on $($tInfo.Name) - create it there first (see the header)." }

    $remoteDir = "C:\Users\$User\pc2go-labsmb"
    Invoke-Command -Session $src -ScriptBlock { param($d) New-Item -ItemType Directory -Force -Path $d | Out-Null; Remove-Item "$d\*" -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $remoteDir
    Copy-Item -LiteralPath $ScriptPath -Destination "$remoteDir\AppDeploy.ps1" -ToSession $src -Force

    $result = Invoke-Command -Session $src -ArgumentList $remoteDir, $tInfo.Name, $tInfo.Ip, $Share, $User, $Password -ScriptBlock {
        param($dir, $tName, $tIp, $share, $user, $pw)
        $ErrorActionPreference = 'Stop'
        $out = New-Object Collections.Generic.List[string]
        $script:pass = 0; $script:fail = 0
        function Check([string]$what, $cond) { if ($cond) { $script:pass++; $out.Add("PASS  $what") } else { $script:fail++; $out.Add("FAIL  $what") } }

        $srcText = Get-Content -LiteralPath "$dir\AppDeploy.ps1" -Raw
        # ---- GUI half: the share-finding functions, extracted by AST
        $gAst = [System.Management.Automation.Language.Parser]::ParseFile("$dir\AppDeploy.ps1", [ref]$null, [ref]$null)
        function Get-GFn([string]$Name) {
            $all = @($gAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true))
            if (-not $all.Count) { throw "no $Name in the GUI half" }; return $all[0].Extent.Text
        }
        $pinv = @($gAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -like '*Native.Share*WNetAddConnection2*' }, $true))
        . ([scriptblock]::Create($pinv[0].Extent.Text))
        foreach ($n in 'Get-ShareRoot', 'Connect-Share', 'Disconnect-Share', 'Invoke-OffUi', 'Get-LocalIPv4', 'Get-LocalSubnets', 'Resolve-HostLabel', 'Get-HostShares', 'Find-NetworkHosts', 'Resolve-ShareUser') {
            . ([scriptblock]::Create((Get-GFn $n)))
        }
        $unc = "\\$tName\$share"
        $who = Resolve-ShareUser $user $tName
        $out.Add("sign-in resolves to: $who")

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $hosts = @(Find-NetworkHosts -TimeoutMs 800)
        $out.Add("Find-NetworkHosts: $($hosts.Count) host(s) in $([int]$sw.Elapsed.TotalSeconds)s -> " + (@($hosts | ForEach-Object { "$($_.Name)/$($_.Ip)" }) -join ', '))
        Check "the scan found the other VM ($tIp)" ([bool]@($hosts | Where-Object { $_.Ip -eq $tIp }).Count)
        Check "and put a name to it" ([bool]@($hosts | Where-Object { $_.Ip -eq $tIp -and $_.Name -and $_.Name -ne $_.Ip }).Count)

        # a session may already exist; drop it so the sign-in is real
        Disconnect-Share $unc
        $why = Connect-Share $unc $who $pw
        Check "Connect-Share with the sign-in succeeds ('$why')" (-not $why)
        $shares = Get-HostShares $tName
        $out.Add("Get-HostShares: " + $(if ($null -eq $shares) { '<could not ask>' } else { $shares -join ',' }))
        Check 'Get-HostShares answered' ($null -ne $shares)
        Check "and listed '$share'" (@($shares) -contains $share)
        Disconnect-Share $unc

        # ---- worker half
        $q = [char]39; $marker = [char]36 + 'workerScript = @' + $q
        $ws = $srcText.IndexOf($marker); $wf = $srcText.IndexOf("`n", $ws) + 1; $we = $srcText.IndexOf("`n" + $q + '@', $wf)
        $body = $srcText.Substring($wf, $we - $wf)
        # the substitutions Start-Worker makes, minimal: the tables are not needed for a copy
        $body = $body.Replace('#__NVAPISOURCE__', ('$NvApiSrc = ' + $q + $q)).Replace('#__SHAREDTABLES__', '').Replace('#__INSTALLERFAMILY__', '')
        $workerPath = "$dir\worker.ps1"
        [IO.File]::WriteAllText($workerPath, $body, (New-Object Text.UTF8Encoding $true))
        $cache = "$dir\cache"; New-Item -ItemType Directory -Force -Path $cache | Out-Null
        $queue = "$cache\queue.jsonl"; $status = "$cache\status.jsonl"; $cancel = "$cache\cancel.flag"; $skip = "$cache\skip.txt"

        # the source: a small real folder of THIS profile, with a file we know
        $rel = 'Links'
        $srcRoot = $env:USERPROFILE
        if (-not (Test-Path "$srcRoot\$rel")) { New-Item -ItemType Directory -Force -Path "$srcRoot\$rel" | Out-Null }
        $stamp = "pc2go-smb-$([Guid]::NewGuid().ToString('N').Substring(0,6)).txt"
        Set-Content -LiteralPath "$srcRoot\$rel\$stamp" -Value 'over the wire' -Encoding ASCII
        $dstPath = "$unc\PC2Go Backup - $env:COMPUTERNAME - $user"

        function Run-Worker([string]$id, [string]$password) {
            Remove-Item $queue, $status, $cancel -Force -ErrorAction SilentlyContinue
            $entry = @{ id = $id; action = 'migrate'; src = $srcRoot; srcKind = 'profile'; dstUser = ''; dstPath = $dstPath; dstKind = 'folder'
                        netUser = $who; netPassword = $password; items = @($rel) } | ConvertTo-Json -Compress -Depth 4
            Add-Content -Path $queue -Value $entry -Encoding UTF8
            Add-Content -Path $queue -Value '{"end":true}' -Encoding UTF8
            $p = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$workerPath`" -QueueFile `"$queue`" -StatusFile `"$status`" -CancelFile `"$cancel`" -SkipFile `"$skip`""
            if (-not $p.WaitForExit(180000)) { Stop-Process -Id $p.Id -Force; return $null }
            $last = $null
            foreach ($l in @(Get-Content $status -ErrorAction SilentlyContinue)) { try { $o = $l | ConvertFrom-Json; if ($o.id -eq $id) { $last = $o } } catch { } }
            return $last
        }
        $r1 = Run-Worker 'smb1' $pw
        $out.Add("run 1: $($r1.state) - $($r1.detail)")
        Check 'run 1 reported Applied' ($r1 -and $r1.state -eq 'Applied')
        Check 'and named the share as the destination' ($r1 -and $r1.detail -like "*$unc*")

        # look at the share from THIS VM, with the sign-in
        Disconnect-Share $unc; [void](Connect-Share $unc $who $pw)
        Check 'the file is on the share' (Test-Path -LiteralPath "$dstPath\$rel\$stamp")
        $mf = $null; try { $mf = Get-Content -LiteralPath "$dstPath\pc2go-backup.json" -Raw | ConvertFrom-Json } catch { }
        Check 'the manifest is on the share and parses' ($null -ne $mf)
        Check 'and names this machine as the source' ($mf -and $mf.sourceMachine -eq $env:COMPUTERNAME)
        Check 'and lists the folder as verified' ($mf -and @($mf.items | Where-Object { $_.rel -eq $rel -and $_.verified }).Count -eq 1)
        Disconnect-Share $unc
        # the worker must not leave its own session behind
        $left = @(& "$env:SystemRoot\System32\net.exe" use 2>$null | Select-String -SimpleMatch "\\$tName").Count
        Check 'no connection to the other PC is left mapped afterwards' ($left -eq 0)

        $r2 = Run-Worker 'smb2' $pw
        $out.Add("run 2: $($r2.state) - $($r2.detail)")
        Check 'a second run is Applied too (incremental, nothing deleted)' ($r2 -and $r2.state -eq 'Applied')

        $r3 = Run-Worker 'smb3' 'definitely-wrong'
        $out.Add("run 3 (bad password): $($r3.state) - $($r3.detail)")
        Check 'a wrong password is refused with a sentence' ($r3 -and $r3.state -eq 'Failed' -and $r3.detail -match 'not accepted|refused')

        Remove-Item -LiteralPath "$srcRoot\$rel\$stamp" -Force -ErrorAction SilentlyContinue
        $out.Add("$($script:pass)/$($script:pass + $script:fail) passed")
        return ,$out.ToArray()
    }
    $result | ForEach-Object {
        $c = if ($_ -like 'PASS*') { 'Green' } elseif ($_ -like 'FAIL*') { 'Red' } else { 'DarkGray' }
        Write-Host "  $_" -ForegroundColor $c
    }
    if (@($result | Where-Object { $_ -like 'FAIL*' }).Count) { exit 1 }
} finally {
    # what landed on the target, then leave both VMs as found
    try {
        Invoke-Command -Session $tgt -ScriptBlock { param($s) $p = (Get-SmbShare -Name $s).Path; Write-Host ("  on target: " + (@(Get-ChildItem -LiteralPath $p -Recurse -File | ForEach-Object { $_.FullName.Substring($p.Length) }) -join ', ')) -ForegroundColor DarkGray; Remove-Item "$p\*" -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $Share
        Invoke-Command -Session $src -ScriptBlock { param($d) Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $remoteDir
    } catch { Write-Host "cleanup: $($_.Exception.Message)" -ForegroundColor Yellow }
    Remove-PSSession $src, $tgt -ErrorAction SilentlyContinue
}
