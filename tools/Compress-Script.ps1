<#
.SYNOPSIS
    Strip a PowerShell script down to what has to ship. A library - dot-source it.

.DESCRIPTION
    This exists because of a measurement, not a preference.

    On a client running McAfee alongside Defender, loading AppDeploy.ps1 cost EIGHT SECONDS of
    script scanning - every run, not just the first. The same file on a Defender-only machine
    cost 18 ms. Antivirus scans script CONTENT, so the cost tracks the byte count, and 27% of
    that file is comments and indentation that no machine needs in order to run it.

    The comments are worth keeping in the repository - most of them explain a decision that
    cost somebody an afternoon to learn - so they come out on the way to the bucket, at publish
    time, and never from the source.

    Two properties this deliberately preserves:

      * LINE NUMBERS. Comment text is blanked in place rather than deleted, and blank lines are
        kept. A stack trace from a client machine still points at the right line of the source
        you have open. Collapsing the file would save a few more KB and make every future error
        report useless.
      * TOKENS. Only comment and whitespace bytes go. Test-Push.ps1 asserts the stripped
        script's token stream is identical to the original's, which is a stronger guarantee
        than "it still parses" - it means the two cannot behave differently.

    What it must never touch is the inside of a here-string. AppDeploy.ps1 carries its window
    layout as XAML and its entire elevated worker as a ~128 KB here-string; indentation there is
    content. Lines covered by a multi-line string token are left exactly as they are.
#>

<#
    Return the shippable form of a script: same code, same line numbers, fewer bytes.
#>
function ConvertTo-ShippableScript {
    param([Parameter(Mandatory = $true)][string]$Source)

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count) {
        throw "Refusing to strip a script that does not parse: $($errors[0].Message)"
    }

    # 1. Blank the comments where they stand. Overwriting with spaces rather than deleting is
    #    what keeps every later line at the number it had in the source.
    $chars = $Source.ToCharArray()
    foreach ($t in $tokens) {
        if ($t.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment) { continue }
        # #requires LOOKS like a comment and tokenises as one, but the engine acts on it -
        # blanking it would quietly drop the "Windows PowerShell 5.1" requirement from the file
        # that actually ships, and the script would then start under an edition where BITS and
        # WPF do not behave. It is a comment to the tokeniser and a directive to everything else.
        if ($t.Extent.Text -match '^\s*#requires\b') { continue }
        for ($i = $t.Extent.StartOffset; $i -lt $t.Extent.EndOffset -and $i -lt $chars.Length; $i++) {
            if ($chars[$i] -ne "`n" -and $chars[$i] -ne "`r") { $chars[$i] = ' ' }
        }
    }

    # 2. Work out which lines sit inside a multi-line string. Indentation there is CONTENT - the
    #    XAML layouts and the whole elevated worker live in here-strings, and trimming them
    #    would change what the tool draws and what it runs.
    #    Matched on the NAME containing "String" rather than against specific TokenKind values.
    #    A here-string is HereStringLiteral / HereStringExpandable, NOT StringLiteral - naming
    #    the two obvious kinds silently protected nothing, and this quietly re-indented the XAML
    #    and all 130 KB of the elevated worker. It parsed fine afterwards, which is exactly why
    #    the token-stream comparison exists.
    $protected = @{}
    foreach ($t in $tokens) {
        if ("$($t.Kind)" -notmatch 'String') { continue }
        if ($t.Extent.StartLineNumber -eq $t.Extent.EndLineNumber) { continue }
        for ($l = $t.Extent.StartLineNumber; $l -le $t.Extent.EndLineNumber; $l++) { $protected[$l] = $true }
    }

    # 3. Trim everything else. A line that held only a comment becomes empty and stays empty.
    #
    #    Split so the line TERMINATORS come back as captured pieces and can be written out
    #    untouched. Splitting on "`r?`n" and rejoining with a chosen newline rewrites every line
    #    ending in the file - which changes the bytes inside every here-string, and so changes
    #    what the worker actually runs. The token comparison caught exactly that.
    $parts = [regex]::Split((-join $chars), "(`r`n|`n|`r)")
    $sb = New-Object Text.StringBuilder
    $line = 1
    foreach ($part in $parts) {
        if ($part -eq "`r`n" -or $part -eq "`n" -or $part -eq "`r") {
            [void]$sb.Append($part)      # terminator, exactly as it was
            $line++
            continue
        }
        if ($protected.ContainsKey($line)) { [void]$sb.Append($part) }
        else { [void]$sb.Append($part.Trim()) }
    }
    return $sb.ToString()
}

<#
    Prove the stripped script is the same program.

    Comparing text would only say they differ, which is the point. Comparing the token stream -
    every token's kind and text, in order, ignoring comments - says they cannot behave
    differently. If this ever returns false, the stripped file must not ship.
#>
function Test-ScriptTokensMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Original,
        [Parameter(Mandatory = $true)][string]$Stripped
    )
    # Runs of blank lines are collapsed to one before comparing. A <# ... #> block comment is a
    # SINGLE token that swallows its own newlines; blanking it leaves that many empty lines
    # behind, each of which then tokenises as a NewLine. So the streams legitimately differ in
    # how many line breaks sit between two statements - and PowerShell does not care how many.
    # What still has to match exactly is that a break IS there, and every other token.
    function Get-CodeTokens([string]$s) {
        $t = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($s, [ref]$t, [ref]$e)
        if ($e -and $e.Count) { throw "does not parse: $($e[0].Message)" }
        $out = New-Object Collections.ArrayList
        $lastWasNewLine = $false
        foreach ($tok in $t) {
            if ($tok.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment) { continue }
            $isNewLine = ($tok.Kind -eq [System.Management.Automation.Language.TokenKind]::NewLine)
            if ($isNewLine -and $lastWasNewLine) { continue }
            [void]$out.Add($(if ($isNewLine) { 'NewLine' } else { '{0}|{1}' -f $tok.Kind, $tok.Text }))
            $lastWasNewLine = $isNewLine
        }
        return $out.ToArray()
    }
    $a = Get-CodeTokens $Original
    $b = Get-CodeTokens $Stripped
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
    return $true
}
