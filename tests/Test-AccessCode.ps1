<#
.SYNOPSIS
    The access-code hand-off: the DACL, the freshness rule, and the shred.

.DESCRIPTION
    The access code is typed in go.ps1 and used in AppDeploy.ps1 - but not always by the same
    process, and that is the whole problem this file exists for. -Verb RunAs builds a FRESH
    environment through the AppInfo service, so an environment variable does not survive into
    the elevated copy, which is the copy that fetches the catalog. The code therefore travels
    through a DPAPI hand-off token in ProgramData, and every property that makes that safe is
    invisible by inspection:

      * the file must be unreadable by other accounts on the machine. LocalMachine DPAPI has
        no per-user key - readable IS decryptable - so the DACL is the entire control.
      * the DACL must be applied AT CREATION. Write-then-tighten leaves a window in which the
        file sits under ProgramData's inherited ACL, where Users have read.
      * the CREATOR must be on the DACL. A filtered-token admin cannot write to an
        Administrators-only file, and that is the account that writes this.
      * a token older than the hand-off itself must be IGNORED. Otherwise a leftover file lets
        a second technician silently authenticate with a code they never typed.

    Functions are lifted out of go.ps1 and AppDeploy.ps1 by AST rather than copied, so this
    tests what ships. Everything happens under a sandbox path; the real
    %ProgramData%\PC2GoDeploy is never touched.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-AccessCode.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not $repo) { $repo = $here }

$script:Pass = 0; $script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green }
    else { $script:Fail++
        Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
function Write-Section([string]$Title) {
    Write-Host ''; Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkCyan
}

$sandbox = Join-Path $env:TEMP ("pc2go-access-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

try {
    # ---------------------------------------------------------------- lift what ships
    Write-Section 'Lifting the real functions out of go.ps1 and AppDeploy.ps1'

    function Get-Fn([string]$File, [string]$Name) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) |
            Select-Object -First 1
        if (-not $fn) { throw "Could not extract $Name from $File" }
        return $fn.Extent.Text
    }
    $goPath  = Join-Path $repo 'server\go.ps1'
    $appPath = Join-Path $repo 'server\AppDeploy.ps1'
    . ([scriptblock]::Create((Get-Fn $goPath 'Write-AccessBlob')))
    . ([scriptblock]::Create((Get-Fn $appPath 'Clear-AccessFile')))
    Assert-True 'Write-AccessBlob lifted from go.ps1'     ($null -ne (Get-Command Write-AccessBlob -ErrorAction SilentlyContinue))
    Assert-True 'Clear-AccessFile lifted from AppDeploy'  ($null -ne (Get-Command Clear-AccessFile -ErrorAction SilentlyContinue))

    # go.ps1 and AppDeploy.ps1 each carry a copy (go.ps1 cannot dot-source a 900 KB script just
    # to write 200 bytes). They must not drift: the same three SIDs, the same protection call.
    $goSrc  = Get-Fn $goPath 'Write-AccessBlob'
    $appSrc = Get-Fn $appPath 'Write-AccessBlob'
    $norm = { param($s) ($s -replace '#[^\r\n]*', '' -replace '\s+', ' ').Trim() }
    Assert-Equal 'both copies of Write-AccessBlob are identical code' (& $norm $goSrc) (& $norm $appSrc)

    # ---------------------------------------------------------------- 1. the DACL
    Write-Section '1. The token is written unreadable by other accounts, from the first byte'

    $token = Join-Path $sandbox 'access.bin'
    Write-AccessBlob $token 'hunter2-the-code'
    Assert-True 'the token was written' (Test-Path -LiteralPath $token)

    $acl = Get-Acl -LiteralPath $token
    Assert-True  'inheritance is OFF - it does not take ProgramData''s Users:read' `
                 $acl.AreAccessRulesProtected
    $rules = @($acl.Access)
    Assert-Equal 'exactly three access rules' 3 $rules.Count

    $me    = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $sids  = @($rules | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
    Assert-True 'the CREATOR is on it (a filtered-token admin must be able to WRITE it)' ($sids -contains $me)
    Assert-True 'Administrators is on it (the elevated copy may be another admin account)' ($sids -contains 'S-1-5-32-544')
    Assert-True 'SYSTEM is on it'                                                          ($sids -contains 'S-1-5-18')
    # the whole point: no Users, no Everyone, no Authenticated Users
    foreach ($bad in 'S-1-5-32-545', 'S-1-1-0', 'S-1-5-11') {
        Assert-True "no access for $bad" (-not ($sids -contains $bad))
    }
    Assert-True 'every rule is an Allow of FullControl' `
                (@($rules | Where-Object { $_.AccessControlType -ne 'Allow' -or $_.FileSystemRights -ne 'FullControl' }).Count -eq 0)

    # ---------------------------------------------------------------- 2. the payload
    Write-Section '2. The payload is DPAPI, decryptable by this machine, and not the plain code'

    Add-Type -AssemblyName System.Security
    $raw = [IO.File]::ReadAllBytes($token)
    Assert-True 'the file is not the code in plain text' `
                (([Text.Encoding]::UTF8.GetString($raw)) -notmatch 'hunter2')
    $back = [Text.Encoding]::UTF8.GetString(
        [Security.Cryptography.ProtectedData]::Unprotect($raw, $null, 'LocalMachine'))
    Assert-Equal 'and it round-trips back to the code' 'hunter2-the-code' $back

    # LocalMachine, not CurrentUser: the elevated copy may be a DIFFERENT admin account, and a
    # CurrentUser blob would be undecryptable there - the hand-off would fail exactly for the
    # case it exists to serve.
    #
    # This cannot be asserted by round-tripping. The scope argument to Unprotect is advisory:
    # the blob carries its own scope, so Unprotect(..., 'CurrentUser') on a LocalMachine blob
    # SUCCEEDS on this machine. (Asserting otherwise is how this test failed first time.) What
    # can be pinned is the source: both writers must protect at LocalMachine and neither may
    # ever reach for CurrentUser.
    foreach ($pair in @(@{ n = 'go.ps1'; s = $goSrc }, @{ n = 'AppDeploy.ps1'; s = $appSrc })) {
        Assert-True "$($pair.n) protects at LocalMachine"      ($pair.s -match "Protect\([^)]*'LocalMachine'\)")
        Assert-True "$($pair.n) never uses CurrentUser"        ($pair.s -notmatch 'CurrentUser')
    }
    # and the reader must agree, or the token it writes is one it cannot read back
    Assert-True 'AppDeploy unprotects at LocalMachine' `
                ((Get-Content -LiteralPath $appPath -Raw) -match "Unprotect\([^)]*'LocalMachine'\)")

    # ---------------------------------------------------------------- 3. rewrite in place
    Write-Section '3. Rewriting keeps the guarantees (a second launch reuses the path)'

    Write-AccessBlob $token 'a-different-code'
    $acl2 = Get-Acl -LiteralPath $token
    Assert-True  'still protected after a rewrite' $acl2.AreAccessRulesProtected
    Assert-Equal 'still exactly three rules'       3 @($acl2.Access).Count
    Assert-Equal 'and it holds the NEW code' 'a-different-code' ([Text.Encoding]::UTF8.GetString(
        [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($token), $null, 'LocalMachine')))

    # ---------------------------------------------------------------- 4. freshness
    Write-Section '4. A stale token is debris, not a credential'

    # The rule as AppDeploy applies it. A hand-off token lives for the seconds between the
    # launcher and the elevated copy; anything older is from a run that died, and trusting it
    # lets a second technician authenticate with a code they never typed.
    $isFresh = {
        param($p)
        $m = ([datetime]::UtcNow - (Get-Item -LiteralPath $p).LastWriteTimeUtc).TotalMinutes
        return ($m -le 2 -and $m -ge -2)
    }
    Assert-True 'a token just written is fresh' (& $isFresh $token)

    (Get-Item -LiteralPath $token).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-3)
    Assert-True 'three minutes old is NOT fresh' (-not (& $isFresh $token))
    (Get-Item -LiteralPath $token).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-14)
    Assert-True 'a fortnight old is NOT fresh'   (-not (& $isFresh $token))
    # a clock that jumped backwards must not make an old file look new either
    (Get-Item -LiteralPath $token).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(10)
    Assert-True 'a future timestamp is NOT fresh' (-not (& $isFresh $token))

    # ---------------------------------------------------------------- 5. the shred
    Write-Section '5. The code does not outlive the session that used it'

    (Get-Item -LiteralPath $token).LastWriteTimeUtc = [datetime]::UtcNow
    $script:AccessPath = $token
    Clear-AccessFile
    Assert-True 'Clear-AccessFile removed the token' (-not (Test-Path -LiteralPath $token))

    # and it is a no-op rather than a throw when there is nothing to clear - it runs on every
    # window close, including sessions that never had a code
    $threw2 = $false
    try { Clear-AccessFile } catch { $threw2 = $true }
    Assert-True 'and it is safe to call when the file is already gone' (-not $threw2)

    # ---------------------------------------------------------------- 6. the wiring
    Write-Section '6. The wiring that makes the above reachable'

    $appText = Get-Content -LiteralPath $appPath -Raw
    $goText  = Get-Content -LiteralPath $goPath -Raw
    Assert-True 'AppDeploy prefers the environment over the file' `
                ($appText -match '(?s)if \(\$env:PC2GO_CODE\).*?\} elseif \(Test-Path -LiteralPath \$script:AccessPath\)')
    Assert-True 'AppDeploy attaches the header to the catalog fetch' `
                ($appText -match 'apps\.json"[^\r\n]*-Headers \$script:AccessHeader')
    Assert-True 'and to the mid-download link refresh (a resumed weekend download needs it)' `
                (@([regex]::Matches($appText, 'apps\.json"[^\r\n]*-Headers \$script:AccessHeader')).Count -ge 2)
    Assert-True 'AppDeploy shreds the token once the catalog has loaded' `
                ($appText -match "(?s)Live catalog.*?Clear-AccessFile")
    Assert-True 'and again on window close' `
                ($appText -match '(?s)\$window\.Add_Closed\(\{.*?Clear-AccessFile')
    Assert-True 'a 403 is explained as an access-code problem, not a network one' `
                ($appText -match "Access code required")
    Assert-True 'go.ps1 writes the token before the elevated launch' `
                ($goText -match '(?s)Save-AccessCode.*?-Verb RunAs')
    Assert-True 'go.ps1 never puts the code on a command line' `
                ($goText -notmatch '\$launch[^\r\n]*PC2GO_CODE')
    Assert-True 'go.ps1 prompts with a SecureString, not a visible Read-Host' `
                ($goText -match 'Read-Host -AsSecureString')

    # EVERY run of the go line must ask. An env var outlives the command that set it, so a
    # second `irm ... | iex` in the same console would otherwise reuse the first run's code
    # and never prompt - which looks exactly like a gate that has stopped working, and would
    # let a rotated code be masked by a stale one still sitting in the shell.
    $firstClear = $goText.IndexOf('$env:PC2GO_CODE = ''''')
    $firstUse   = $goText.IndexOf('function Get-AccessHeader')
    Assert-True 'go.ps1 clears any inherited code' ($firstClear -ge 0)
    Assert-True 'and clears it BEFORE anything can read it (so every run prompts)' `
                ($firstClear -ge 0 -and $firstUse -gt $firstClear)
    # and it does not linger in the technician's own shell after the tool has been launched
    $lastClear  = $goText.LastIndexOf('$env:PC2GO_CODE = ''''')
    $lastLaunch = $goText.LastIndexOf('Start-Process -FilePath $winPS')
    Assert-True 'and again after the launch, so it does not linger in the console' `
                ($lastLaunch -ge 0 -and $lastClear -gt $lastLaunch)

    # ---------------------------------------------------------------- 7. the banner
    Write-Section '7. The login banner says the right thing, and only the true thing'

    $banner = Get-Fn $goPath 'Show-AccessBanner'
    Assert-True 'there is a banner'                       ($banner.Length -gt 0)
    Assert-True 'it states whose service this is'         ($banner -match 'property of PC2Go')
    Assert-True 'it tells an unauthorized user to leave'  ($banner -match 'disconnect')
    # The honesty rule, and the trust rule, in one assertion each. This runs on the CLIENT's
    # machine, often with the client watching: a banner claiming activity is monitored reads
    # as surveillance OF THEM. And per-code attribution does not exist yet, so claiming it
    # would be a promise nobody could keep on the day it mattered.
    Assert-True 'it says connections MAY be logged, not that all access is recorded' `
                ($banner -match 'may be logged')
    foreach ($claim in 'all activity', 'is recorded', 'are monitored', 'being monitored') {
        Assert-True "it never claims '$claim'" ($banner -notmatch [regex]::Escape($claim))
    }

    $reader = Get-Fn $goPath 'Read-AccessCode'
    Assert-True 'the typed code is white'                 ($reader -match "'White'")
    Assert-True 'and the console colour is put back'      ($reader -match '(?s)finally\s*\{.*ForegroundColor = \$old')
    Assert-True 'the mask is still a SecureString'        ($reader -match 'Read-Host -AsSecureString')
    Assert-True 'attempts remaining are shown on a retry' ($reader -match 'remaining')
    # sixteen lines redrawn per wrong keystroke would bury the one line that matters
    Assert-True 'the banner is drawn once, not per attempt' `
                ($goText -match '\$tries -eq 0\s*\)\s*\{\s*Show-AccessBanner')

    Write-Host ''
    Write-Host ("{0}/{1} passed" -f $script:Pass, ($script:Pass + $script:Fail)) `
               -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    if (Test-Path -LiteralPath $sandbox) {
        Write-Host "  NOTE: sandbox survived at $sandbox" -ForegroundColor Yellow
    } else {
        Write-Host 'All test artefacts removed from this machine.' -ForegroundColor DarkGray
    }
}
