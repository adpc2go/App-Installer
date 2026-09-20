# The pin lines the live bootstrap serves: /go-exe (the exe trial line) and /go (the default).
# After Publish-Release the Worker deploy takes a few seconds to propagate - run twice if stale.
$b = Invoke-RestMethod -Uri 'https://apps.pc2go.ca/go-exe' -UseBasicParsing -TimeoutSec 30
$s = Invoke-RestMethod -Uri 'https://apps.pc2go.ca/go' -UseBasicParsing -TimeoutSec 30
foreach ($line in ($b -split "`n")) { if ($line -match '^\s*\$(ExeHash|Client|PinnedHash)\s*=') { 'go-exe: ' + $line.Trim() } }
foreach ($line in ($s -split "`n")) { if ($line -match '^\s*\$(ExeHash|Client|PinnedHash)\s*=') { 'go:     ' + $line.Trim() } }
