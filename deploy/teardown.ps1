# =====================================================================
# Remove everything this tool created (reads .deploy-state.json).
# CloudFront must be disabled before it can be deleted, so this takes several
# minutes. Safe to re-run; each step ignores "already gone".
#   pwsh ./deploy/teardown.ps1
# =====================================================================
$ErrorActionPreference = "Continue"
$PSNativeCommandUseErrorActionPreference = $false

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$state = Get-Content (Join-Path $root ".deploy-state.json") -Raw | ConvertFrom-Json
$FUNC = $state.functionName; $REGION = $state.region; $PROFILE_N = $state.profile
$ROLE = $state.roleName; $DIST = $state.distributionId; $OAC = $state.oacId

Write-Host "[1] disable + delete CloudFront distribution $DIST ..."
$tmp = Join-Path $root "_distcfg.json"
aws cloudfront get-distribution-config --id $DIST --profile $PROFILE_N --output json | Out-File $tmp -Encoding ascii
if ($LASTEXITCODE -eq 0) {
  $o = Get-Content $tmp -Raw | ConvertFrom-Json
  $etag = $o.ETag
  if ($o.DistributionConfig.Enabled) {
    $o.DistributionConfig.Enabled = $false
    ($o.DistributionConfig | ConvertTo-Json -Depth 30) | Set-Content $tmp -Encoding ascii
    aws cloudfront update-distribution --id $DIST --distribution-config ("file://"+$tmp) --if-match $etag --profile $PROFILE_N --query "Distribution.Status" --output text
    Write-Host "    disabling; waiting for deployed ..."
    aws cloudfront wait distribution-deployed --id $DIST --profile $PROFILE_N
    $etag = aws cloudfront get-distribution-config --id $DIST --profile $PROFILE_N --query "ETag" --output text
  }
  aws cloudfront delete-distribution --id $DIST --if-match $etag --profile $PROFILE_N
}
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

Write-Host "[2] delete Origin Access Control $OAC ..."
$oacEtag = aws cloudfront get-origin-access-control --id $OAC --profile $PROFILE_N --query "ETag" --output text 2>$null
if ($LASTEXITCODE -eq 0 -and $oacEtag) { aws cloudfront delete-origin-access-control --id $OAC --if-match $oacEtag --profile $PROFILE_N }

Write-Host "[3] delete Lambda Function URL + function ..."
aws lambda delete-function-url-config --function-name $FUNC --region $REGION --profile $PROFILE_N 2>$null
aws lambda delete-function --function-name $FUNC --region $REGION --profile $PROFILE_N 2>$null

Write-Host "[4] delete IAM role ..."
aws iam delete-role-policy --role-name $ROLE --policy-name embed-and-logs --profile $PROFILE_N 2>$null
aws iam delete-role --role-name $ROLE --profile $PROFILE_N 2>$null

Write-Host "DONE. Verify in the console if needed."
