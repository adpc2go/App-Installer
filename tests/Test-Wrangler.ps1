<#
.SYNOPSIS
    The hidden wrangler run: it never waits, it never lies about the outcome, and it can always
    be stopped.

.DESCRIPTION
    Setting the access code used to open a visible cmd.exe over the Management Console and block
    the dispatcher until wrangler returned. Hiding that window is only safe because three things
    replaced what the window was for, and all three are invisible by inspection:

      * -Wait must be ABSENT. It is what froze the window, and a hidden frozen window is worse
        than a visible one because there is nothing left to look at.
      * the exit code must be REAL. When Start-Process redirects and is not given -Wait,
        PowerShell releases the process handle and ExitCode reads back as empty - no exception,
        just nothing - so a successful run is judged a failure and a failed one cannot be told
        apart from it. Touching .Handle at start time is the only thing that prevents this.
      * a sign-in prompt must be RECOGNISED. wrangler stops and waits for an expired Cloudflare
        login. Visible, a person saw it; hidden, it is a silent hang, so it is detected from
        wrangler's own output and repeated in the window.

    Plus the two give-up clocks, the tree-kill (npx is a launcher - killing it leaves node
    running), and the secret file, which must never exist in a readable state and must not
    survive the call.

    The behavioural half drives cmd.exe as a stand-in for wrangler, so the drain, the verdicts
    and the timeouts are exercised against a real process rather than a mock. The static half
    reads what ships, by AST, so a comment saying "never waits" cannot pass for the fact.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Wrangler.ps1
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

$r2File     = Join-Path $repo 'tools\R2-Upload.ps1'
$editorFile = Join-Path $repo 'tools\Catalog-Editor.ps1'
$pubFile    = Join-Path $repo 'tools\Publish-Release.ps1'

# ---------------------------------------------------------------- AST helpers
function Get-Ast([string]$Path) {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) { throw "$Path has $($errs.Count) parse error(s): $($errs[0].Message)" }
    return $ast
}
function Get-Fn($Ast, [string]$Name) {
    return ($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) |
        Select-Object -First 1)
}
function Get-Commands($Node) {
    if (-not $Node) { return @() }
    return @($Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
}
# Only real code reaches the AST - a comment mentioning "--yes" or "-Wait" cannot satisfy these.
function Get-Strings($Node) {
    if (-not $Node) { return @() }
    return @($Node.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
        ForEach-Object { $_.Value })
}
function Get-Members($Node) {
    if (-not $Node) { return @() }
    return @($Node.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.MemberExpressionAst] }, $true) |
        ForEach-Object { "$($_.Member)" })
}
function Get-HashKeys($Node) {
    $out = @()
    if (-not $Node) { return $out }
    foreach ($h in $Node.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
        foreach ($pair in $h.KeyValuePairs) { $out += "$($pair.Item1)" }
    }
    return $out
}

$sandboxSecrets = @()

try {
    # ================================================================ static: what ships
    Write-Section 'What ships: -Wait is gone, --yes is there, the handle is held'

    $r2Ast  = Get-Ast $r2File
    $edAst  = Get-Ast $editorFile
    $pubAst = Get-Ast $pubFile

    $startFn = Get-Fn $r2Ast 'Start-WranglerWatched'
    Assert-True 'R2-Upload.ps1 defines Start-WranglerWatched' ($null -ne $startFn)

    # The splat is the only place Start-Process gets its arguments, so its keys ARE the call.
    $spKeys = @(Get-HashKeys $startFn)
    Assert-True  'Start-WranglerWatched never passes -Wait'            (-not ($spKeys -contains 'Wait'))
    Assert-True  'it does pass PassThru'                               ($spKeys -contains 'PassThru')
    Assert-True  'it hides the window'                                 ($spKeys -contains 'WindowStyle')
    Assert-True  'it redirects stdout'                                 ($spKeys -contains 'RedirectStandardOutput')
    Assert-True  'it redirects stderr'                                 ($spKeys -contains 'RedirectStandardError')
    Assert-True  'no -Wait parameter anywhere in the function'         (@(Get-Strings $startFn) -notcontains 'Wait')

    # The whole reason ExitCode is answerable at all. Deleting this line breaks nothing that
    # parses and everything that reports.
    Assert-True  'the process handle is held open (ExitCode trap)'     (@(Get-Members $startFn) -contains 'Handle')

    $resolveFn = Get-Fn $r2Ast 'Resolve-Wrangler'
    Assert-True  'R2-Upload.ps1 owns Resolve-Wrangler'                 ($null -ne $resolveFn)
    Assert-True  'the npx path passes --yes'                           (@(Get-Strings $resolveFn) -contains '--yes')
    Assert-True  'it prefers a global wrangler first'                  (@(Get-Strings $resolveFn) -contains 'wrangler')

    # One answer about where wrangler is, not two that disagree.
    Assert-True  'Publish-Release.ps1 no longer defines its own copy'  ($null -eq (Get-Fn $pubAst 'Resolve-Wrangler'))
    Assert-True  'Publish-Release.ps1 dot-sources R2-Upload.ps1'       ((Get-Content $pubFile -Raw) -match 'R2-Upload\.ps1')

    $drainFn = Get-Fn $r2Ast 'Read-WatchedFile'
    # Without ReadWrite the child's own handle makes every poll throw, and progress silently
    # stops - which looks exactly like the hang this replaced.
    Assert-True  'the drain shares Read AND Write with the child'      (@(Get-Members $drainFn) -contains 'ReadWrite')
    Assert-True  'the drain seeks from a stored offset'                (@(Get-Members $drainFn) -contains 'Seek')

    $killFn = Get-Fn $r2Ast 'Stop-ProcessTree'
    Assert-True  'Stop-ProcessTree exists'                             ($null -ne $killFn)
    Assert-True  'it kills the TREE, not just the launcher'            (@(Get-Strings $killFn) -contains '/T')

    Write-Section 'The console: no console'

    $invokeFn = Get-Fn $edAst 'Invoke-Wrangler'
    Assert-True  'Invoke-Wrangler still exists for its callers'        ($null -ne $invokeFn)
    Assert-True  'it no longer starts a process itself'                (@(Get-Commands $invokeFn) -notcontains 'Start-Process')
    Assert-True  'it hands off to Start-WranglerWatched'               (@(Get-Commands $invokeFn) -contains 'Start-WranglerWatched')
    Assert-True  'no hardcoded cmd.exe left in it'                     (@(Get-Strings $invokeFn) -notcontains 'cmd.exe')

    $edText = Get-Content $editorFile -Raw
    Assert-True  'the hardcoded "npx wrangler" line is gone'           ($edText -notmatch '/c npx wrangler')
    Assert-True  'the timer polls the wrangler run first'              ($edText -match 'if \(\$script:WranglerWatch\) \{ Complete-WranglerCall; return \}')

    $completeFn = Get-Fn $edAst 'Complete-WranglerCall'
    Assert-True  'Complete-WranglerCall exists'                        ($null -ne $completeFn)
    Assert-True  'it polls the watch'                                  (@(Get-Commands $completeFn) -contains 'Update-WranglerWatched')
    Assert-True  'it surfaces a sign-in in the window'                 (@(Get-Commands $completeFn) -contains 'Show-Notice')
    # Every terminal verdict has to say something, or a stopped run looks like a working one.
    foreach ($v in @('ok', 'cancelled', 'stalled', 'timeout')) {
        Assert-True "it handles the '$v' verdict"                      (@(Get-Strings $completeFn) -contains $v)
    }

    $cancelText = ($edText -split 'BtnPushCancel\.Add_Click')[1]
    Assert-True  'Stop kills a wrangler run too'                       ($cancelText -match 'Stop-WranglerWatched')

    $stopUiFn = Get-Fn $edAst 'Stop-PushUi'
    # The push bar reports real percentages; inheriting an animating bar would make them a lie.
    Assert-True  'Stop-PushUi clears the indeterminate bar'            ($stopUiFn.Extent.Text -match 'IsIndeterminate')

    $publishFn = Get-Fn $edAst 'Start-Publish'
    Assert-True  'Start-Publish no longer fetches on the UI thread'    (@(Get-Commands $publishFn) -notcontains 'Invoke-WebRequest')
    Assert-True  'the pin fetch moved to a runspace'                   ($null -ne (Get-Fn $edAst 'Start-PinFetch'))
    Assert-True  'and is collected without waiting'                    ($null -ne (Get-Fn $edAst 'Complete-PinFetch'))
    $pinWork = ($edText -split '\$script:PinWork\s*=')[1]
    Assert-True  'the fetch itself still has a timeout'                ($pinWork -match 'TimeoutSec')

    # ================================================================ behavioural
    Write-Section 'Driving a real process: cmd.exe standing in for wrangler'

    . $r2File
    # Resolve-Wrangler would find the real wrangler; the point here is the watching, not wrangler.
    $script:WranglerCmd = @{ Exe = (Join-Path $env:SystemRoot 'System32\cmd.exe'); Pre = @('/c') }

    function Invoke-Drive($Watch, [int]$MaxSec = 40) {
        $t0 = Get-Date
        while ($Watch.Verdict -eq 'running' -and ((Get-Date) - $t0).TotalSeconds -lt $MaxSec) {
            [void](Update-WranglerWatched $Watch)
            Start-Sleep -Milliseconds 150
        }
        [void](Update-WranglerWatched $Watch)
        return $Watch
    }

    $ok = Invoke-Drive (Start-WranglerWatched -Arguments @('echo first line & echo second line') -WorkingDirectory $env:TEMP)
    Assert-Equal 'a clean run ends "ok"'                    'ok' $ok.Verdict
    # The regression that motivated the whole harness: without the held handle this is ''.
    Assert-True  'its exit code is a real integer, not empty' ($ok.ExitCode -is [int])
    Assert-Equal 'and the integer is 0'                     0 $ok.ExitCode
    Assert-True  'stdout was drained'                       ($ok.Text -match 'first line')
    Assert-True  'the last line is offered to the UI'       ((Get-WatchedLine $ok) -eq 'second line')
    Assert-True  'the stdout temp file is cleaned up'       (-not (Test-Path -LiteralPath $ok.OutPath))
    Assert-True  'the stderr temp file is cleaned up'       (-not (Test-Path -LiteralPath $ok.ErrPath))

    $bad = Invoke-Drive (Start-WranglerWatched -Arguments @('echo something broke 1>&2 & exit 3') -WorkingDirectory $env:TEMP)
    Assert-Equal 'a non-zero exit ends "failed"'            'failed' $bad.Verdict
    Assert-Equal 'the exit code is carried through'         3 $bad.ExitCode
    Assert-True  'stderr is drained as well as stdout'      ($bad.Text -match 'something broke')

    # An unknown outcome must never be reported as success - that is the one call that changes
    # what every technician in the field is authenticating against.
    $fake = @{ Verdict = 'running'; ExitCode = $null; Text = ''; OutOffset = [long]0; ErrOffset = [long]0
               OutPath = (Join-Path $env:TEMP 'pc2go-none.out'); ErrPath = (Join-Path $env:TEMP 'pc2go-none.err')
               InPath = ''; NeedsSignIn = $false; SignInUrl = ''; Started = (Get-Date); LastOutput = (Get-Date)
               TimeoutSec = 600; StallSec = 180; Proc = ([pscustomobject]@{ HasExited = $true; ExitCode = $null; Id = 0 }) }
    [void](Update-WranglerWatched $fake)
    Assert-Equal 'an unknowable exit code is NOT called success' 'failed' $fake.Verdict

    Write-Section 'The sign-in that used to need a window'

    $oauth = Invoke-Drive (Start-WranglerWatched -WorkingDirectory $env:TEMP -Arguments @(
        'echo Attempting to login via OAuth... & echo https://dash.cloudflare.com/oauth2/auth?client_id=abc^&scope=x & ping -n 2 127.0.0.1 >nul'))
    Assert-True  'a Cloudflare sign-in is recognised'       $oauth.NeedsSignIn
    Assert-True  'and its URL is captured to show'          ($oauth.SignInUrl -match '^https://dash\.cloudflare\.com/oauth2/auth')

    $localhost = Invoke-Drive (Start-WranglerWatched -WorkingDirectory $env:TEMP -Arguments @(
        'echo listening on http://localhost:8976/oauth/callback & ping -n 2 127.0.0.1 >nul'))
    Assert-True  'the localhost callback counts too'        $localhost.NeedsSignIn

    $quiet = Invoke-Drive (Start-WranglerWatched -Arguments @('echo Uploaded secret ACCESS_CODE') -WorkingDirectory $env:TEMP)
    Assert-True  'an ordinary success is NOT called a sign-in' (-not $quiet.NeedsSignIn)

    Write-Section 'Two clocks, and a Stop that reaches the whole tree'

    $stall = Invoke-Drive (Start-WranglerWatched -Arguments @('ping -n 30 127.0.0.1 >nul') `
                            -WorkingDirectory $env:TEMP -StallSec 2 -TimeoutSec 600) 25
    Assert-Equal 'silence for StallSec ends the run'        'stalled' $stall.Verdict
    Assert-True  'and the process really is dead'           ($stall.Proc.HasExited)

    $timeout = Invoke-Drive (Start-WranglerWatched -Arguments @('ping -n 30 127.0.0.1 >nul') `
                              -WorkingDirectory $env:TEMP -StallSec 600 -TimeoutSec 2) 25
    Assert-Equal 'the wall clock is a separate verdict'     'timeout' $timeout.Verdict
    Assert-True  'that process is dead too'                 ($timeout.Proc.HasExited)

    $cancel = Start-WranglerWatched -Arguments @('ping -n 30 127.0.0.1 >nul') -WorkingDirectory $env:TEMP
    Stop-WranglerWatched -Watch $cancel
    Assert-Equal 'Stop reports "cancelled", not "failed"'   'cancelled' $cancel.Verdict
    Assert-True  'Stop kills the process'                   ($cancel.Proc.HasExited)
    [void](Update-WranglerWatched $cancel)
    Assert-Equal 'a finished verdict is never overwritten'  'cancelled' $cancel.Verdict

    Write-Section 'The secret: never readable, never left behind'

    $secretPath = New-SecretTempFile -Text 'Sup3r-Secret-Code'
    $sandboxSecrets += $secretPath
    $acl = Get-Acl -LiteralPath $secretPath
    Assert-Equal 'the secret file has exactly one ACE'      1 @($acl.Access).Count
    Assert-Equal 'and it belongs to the creator'            ([Security.Principal.WindowsIdentity]::GetCurrent()).Name `
                                                            "$(@($acl.Access)[0].IdentityReference)"
    # AreAccessRulesProtected, plural. The singular spelling is not a property, so it evaluates
    # to $null and the assertion fails while the code is perfectly correct.
    Assert-True  'inheritance is off'                       ($acl.AreAccessRulesProtected)
    # A BOM would silently become the first character of the access code.
    Assert-Equal 'it is written without a BOM'              17 ([IO.File]::ReadAllBytes($secretPath).Length)
    Remove-SecretTempFile $secretPath
    Assert-True  'and it shreds'                            (-not (Test-Path -LiteralPath $secretPath))

    $withIn = Start-WranglerWatched -Arguments @('findstr /r .') -WorkingDirectory $env:TEMP -StdIn 'Sup3r-Secret-Code'
    $inPath = $withIn.InPath
    $sandboxSecrets += $inPath
    [void](Invoke-Drive $withIn)
    Assert-True  'stdin reaches the child'                  ($withIn.Text -match 'Sup3r-Secret-Code')
    Assert-True  'the secret file is gone afterwards'       (-not (Test-Path -LiteralPath $inPath))
    Assert-Equal 'and the watch forgets where it was'       '' $withIn.InPath

    $killedIn = Start-WranglerWatched -Arguments @('ping -n 30 127.0.0.1 >nul') -WorkingDirectory $env:TEMP -StdIn 'another-secret'
    $killedInPath = $killedIn.InPath
    $sandboxSecrets += $killedInPath
    Stop-WranglerWatched -Watch $killedIn
    # The path that used to be a `finally` - a cancelled run must clean up as thoroughly as a
    # finished one, or Stop becomes the way to leave a secret on disk.
    Assert-True  'a CANCELLED run shreds its secret too'    (-not (Test-Path -LiteralPath $killedInPath))

    Write-Section 'The drain: whole lines only'

    $probe = Join-Path $env:TEMP ("pc2go-drain-" + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    [IO.File]::WriteAllText($probe, "complete line`r`nhalf a li")
    $off = [long]0
    $got = Read-WatchedFile -Path $probe -Offset ([ref]$off)
    Assert-True  'a complete line is consumed'              ($got -match 'complete line')
    Assert-True  'a half-written line is left alone'        ($got -notmatch 'half a li')
    [IO.File]::AppendAllText($probe, "ne now finished`r`n")
    $more = Read-WatchedFile -Path $probe -Offset ([ref]$off)
    Assert-True  'and completed on the next pass'           ($more -match 'half a line now finished')
    Assert-True  'nothing is delivered twice'               ($more -notmatch 'complete line')
    # Without -Flush the last line of a process that did not end with a newline is lost for ever.
    [IO.File]::AppendAllText($probe, 'no newline at the end')
    $noEol = Read-WatchedFile -Path $probe -Offset ([ref]$off)
    Assert-Equal 'an unterminated tail waits by default'    '' $noEol
    $flushed = Read-WatchedFile -Path $probe -Offset ([ref]$off) -Flush
    Assert-True  'and is flushed once the process exits'    ($flushed -match 'no newline at the end')
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue

    $ansi = @{ Text = "$([char]27)[32mgreen text$([char]27)[0m`r`n" }
    Assert-Equal 'ANSI colour never reaches the window'     'green text' (Get-WatchedLine $ansi)
    Assert-Equal 'and no output is an empty line, not junk' '' (Get-WatchedLine @{ Text = "`r`n   `r`n" })
}
finally {
    foreach ($s in $sandboxSecrets) {
        if ($s) { try { Remove-Item -LiteralPath $s -Force -ErrorAction SilentlyContinue } catch { } }
    }
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
