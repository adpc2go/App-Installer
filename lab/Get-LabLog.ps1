# Read the guest's launch transcript from the host.
param([string]$VMName='AppLab',[string]$CredPath="$env:LOCALAPPDATA\$VMName\guest.cred.xml")
$s = New-PSSession -VMName $VMName -Credential (Import-Clixml $CredPath)
Invoke-Command $s { Get-Content 'C:\Lab\run.log' -Raw -ErrorAction SilentlyContinue }
Remove-PSSession $s
