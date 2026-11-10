# =====================================================================
# Set a NEW password (the old one cannot be recovered - only a one-way hash is
# stored). Rotates the session secret too, so open sessions are invalidated.
#   pwsh ./deploy/reset_password.ps1
# =====================================================================
param([int]$SessionMinutes = 0)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
function Check($m){ if ($LASTEXITCODE -ne 0) { throw $m } }

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$state = Get-Content (Join-Path $root ".deploy-state.json") -Raw | ConvertFrom-Json
$FUNC = $state.functionName; $REGION = $state.region; $PROFILE_N = $state.profile

# preserve existing env, regenerate only the gate values
$cfg = aws lambda get-function-configuration --function-name $FUNC --region $REGION --profile $PROFILE_N --output json | ConvertFrom-Json
$vars = [ordered]@{}
$cfg.Environment.Variables.PSObject.Properties | ForEach-Object { $vars[$_.Name] = $_.Value }
if ($SessionMinutes -gt 0) { $vars["SESSION_MIN"] = "$SessionMinutes" }

function RandStr($set,$n){ -join (1..$n | ForEach-Object { [char]($set | Get-Random) }) }
$alnum = (48..57)+(65..90)+(97..122); $hexs = (48..57)+(97..102)
$pwd = RandStr $alnum 20; $salt = RandStr $hexs 32; $secret = RandStr $alnum 48
$sha = [Security.Cryptography.SHA256]::Create()
$hash = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($salt + $pwd))) | ForEach-Object { $_.ToString("x2") }) -join ""
$vars["GATE_SALT"] = $salt; $vars["GATE_HASH"] = $hash; $vars["GATE_SECRET"] = $secret

$ep = Join-Path $root "_env.json"
($( @{ Variables=$vars } | ConvertTo-Json -Depth 10 )) | Set-Content $ep -Encoding ascii
aws lambda update-function-configuration --function-name $FUNC --environment ("file://"+$ep) --region $REGION --profile $PROFILE_N --query "LastUpdateStatus" --output text
Check "update-function-configuration failed"
aws lambda wait function-updated --function-name $FUNC --region $REGION --profile $PROFILE_N; Check "wait failed"
Remove-Item $ep -Force -ErrorAction SilentlyContinue

Write-Host "==================================================================="
Write-Host ("  NEW PASSWORD : {0}" -f $pwd)
Write-Host "==================================================================="
Write-Host "  Save it now (not shown again). Old sessions are now invalid."
