# =====================================================================
# One-shot deploy: a password-gated public page that embeds ONE Quick/QuickSight
# dashboard, as ONE registered user, via CloudFront + Lambda Function URL (IAM auth).
#
#   1. copy  config.example.json  ->  config.json   and fill in your values
#   2. pwsh ./deploy/deploy.ps1
#
# Prints the share URL + a generated password (password shown ONLY in your terminal).
# Works on Windows PowerShell and cross-platform PowerShell (pwsh) with AWS CLI v2.
# =====================================================================
param([string]$ConfigPath = "")
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
function Check($m){ if ($LASTEXITCODE -ne 0) { throw $m } }

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $ConfigPath) { $ConfigPath = Join-Path $root "config.json" }
if (-not (Test-Path $ConfigPath)) { throw "config.json not found. Copy config.example.json to config.json and fill it in." }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$PROFILE_N = $cfg.awsProfile; if (-not $PROFILE_N) { $PROFILE_N = "default" }
$REGION    = $cfg.region;     if (-not $REGION)    { $REGION = "us-east-1" }
$ACCOUNT   = "$($cfg.accountId)"
$DASH      = $cfg.dashboardId
$USER_ARN  = $cfg.userArn
$FUNC      = $cfg.functionName; if (-not $FUNC) { $FUNC = "quick-dashboard-share" }
$SESSION   = [int]$cfg.sessionMinutes; if ($SESSION -le 0) { $SESSION = 120 }
$PRICE     = $cfg.priceClass; if (-not $PRICE) { $PRICE = "PriceClass_100" }
$MINT_ROLE = "$($cfg.mintRoleArn)"
$MINT_EXT  = "$($cfg.mintExternalId)"
$ROLE      = "$FUNC-exec"
$OAC_NAME  = "$FUNC-oac"
$CACHE_DISABLED    = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"   # managed: CachingDisabled
$ORIGREQ_ALLVIEWER = "b689b0a8-53d0-40ab-baf2-68738e2966ac"   # managed: AllViewerExceptHostHeader
$lambdaDir = Join-Path $root "lambda"
$zipPath   = Join-Path $root "function.zip"
$statePath = Join-Path $root ".deploy-state.json"

# ---- guard: placeholders not left in ----
if ($ACCOUNT -eq "123456789012" -or $DASH -eq "your-dashboard-id" -or $USER_ARN -like "*your-registered-user*") {
  throw "config.json still has example placeholders. Fill accountId / dashboardId / userArn first."
}
# ---- guard: function already exists ----
aws lambda get-function --function-name $FUNC --region $REGION --profile $PROFILE_N 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { throw "Function '$FUNC' already exists. Run ./deploy/teardown.ps1 first, or change functionName in config.json." }

Write-Host "[1/9] download embedding SDK ..."
$sdk = Join-Path $lambdaDir "quicksight-embedding-js-sdk.min.js"
if (-not (Test-Path $sdk)) {
  $sdkUrl = "https://cdn.jsdelivr.net/npm/amazon-quicksight-embedding-sdk/dist/quicksight-embedding-js-sdk.min.js"
  Invoke-WebRequest -Uri $sdkUrl -OutFile $sdk -UseBasicParsing
  if (-not (Select-String -Path $sdk -Pattern "createEmbeddingContext" -Quiet)) { throw "SDK download looks wrong (no createEmbeddingContext)." }
}

Write-Host "[2/9] generate password + salt + hash ..."
function RandStr($set,$n){ -join (1..$n | ForEach-Object { [char]($set | Get-Random) }) }
$alnum = (48..57)+(65..90)+(97..122); $hexs = (48..57)+(97..102)
$pwd    = RandStr $alnum 20
$salt   = RandStr $hexs 32
$secret = RandStr $alnum 48
$sha    = [Security.Cryptography.SHA256]::Create()
$hash   = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($salt + $pwd))) | ForEach-Object { $_.ToString("x2") }) -join ""

# ---- env + trust + policy ----
$dashArn = "arn:aws:quicksight:{0}:{1}:dashboard/{2}" -f $REGION,$ACCOUNT,$DASH
$envVars = [ordered]@{
  QS_ACCOUNT=$ACCOUNT; QS_REGION=$REGION; QS_USER_ARN=$USER_ARN; QS_DASHBOARD_ID=$DASH;
  SESSION_MIN="$SESSION"; GATE_SALT=$salt; GATE_HASH=$hash; GATE_SECRET=$secret
}
if ($MINT_ROLE) { $envVars.MINT_ROLE_ARN = $MINT_ROLE; if ($MINT_EXT) { $envVars.MINT_EXTERNAL_ID = $MINT_EXT } }

$trust = @{ Version="2012-10-17"; Statement=@(@{ Effect="Allow"; Principal=@{ Service="lambda.amazonaws.com" }; Action="sts:AssumeRole" }) } | ConvertTo-Json -Depth 10
$stmts = @(
  @{ Sid="Embed"; Effect="Allow"; Action="quicksight:GenerateEmbedUrlForRegisteredUser"; Resource=@($USER_ARN,$dashArn) },
  @{ Sid="Logs"; Effect="Allow"; Action=@("logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"); Resource=("arn:aws:logs:{0}:{1}:*" -f $REGION,$ACCOUNT) }
)
if ($MINT_ROLE) { $stmts += @{ Sid="AssumeMint"; Effect="Allow"; Action="sts:AssumeRole"; Resource=$MINT_ROLE } }
$pol = @{ Version="2012-10-17"; Statement=$stmts } | ConvertTo-Json -Depth 10

$tp=Join-Path $root "_trust.json"; $pp=Join-Path $root "_policy.json"; $ep=Join-Path $root "_env.json"
Set-Content $tp $trust -Encoding ascii; Set-Content $pp $pol -Encoding ascii
($( @{ Variables=$envVars } | ConvertTo-Json -Depth 10 )) | Set-Content $ep -Encoding ascii

Write-Host "[3/9] create exec role ..."
$roleArn = aws iam create-role --role-name $ROLE --assume-role-policy-document ("file://"+$tp) --profile $PROFILE_N --query "Role.Arn" --output text
Check "create-role failed"
aws iam put-role-policy --role-name $ROLE --policy-name embed-and-logs --policy-document ("file://"+$pp) --profile $PROFILE_N | Out-Null
Check "put-role-policy failed"
Start-Sleep -Seconds 12

Write-Host "[4/9] package + create Lambda ..."
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $lambdaDir "*") -DestinationPath $zipPath -Force
$created=$false
for ($i=1; $i -le 5; $i++) {
  $err = aws lambda create-function --function-name $FUNC --runtime python3.12 --handler lambda_function.handler `
    --role $roleArn --timeout 30 --memory-size 256 --zip-file ("fileb://"+$zipPath) --environment ("file://"+$ep) `
    --region $REGION --profile $PROFILE_N 2>&1
  if ($LASTEXITCODE -eq 0) { $created=$true; break }
  Write-Host ("    retry ({0}/5) in 6s (role propagating)" -f $i); Start-Sleep -Seconds 6
}
if (-not $created) { Write-Host $err; throw "create-function failed" }
aws lambda wait function-active --function-name $FUNC --region $REGION --profile $PROFILE_N; Check "wait function-active failed"

Write-Host "[5/9] create Function URL (AuthType AWS_IAM) ..."
$fnUrl = aws lambda create-function-url-config --function-name $FUNC --auth-type AWS_IAM --region $REGION --profile $PROFILE_N --query "FunctionUrl" --output text
Check "create-function-url-config failed"
$originDomain = ($fnUrl -replace "^https://","") -replace "/$",""

Write-Host "[6/9] create Origin Access Control ..."
$oacCfg = "{""Name"":""$OAC_NAME"",""Description"":""OAC for $FUNC"",""SigningProtocol"":""sigv4"",""SigningBehavior"":""always"",""OriginAccessControlOriginType"":""lambda""}"
$oacPath = Join-Path $root "_oac.json"; Set-Content $oacPath $oacCfg -Encoding ascii
$oacId = aws cloudfront create-origin-access-control --origin-access-control-config ("file://"+$oacPath) --profile $PROFILE_N --query "OriginAccessControl.Id" --output text
Check "create-origin-access-control failed"

Write-Host "[7/9] create CloudFront distribution ..."
$caller = [guid]::NewGuid().ToString()
$distCfg = @"
{
  "CallerReference": "$caller",
  "Comment": "$FUNC",
  "Enabled": true,
  "Origins": { "Quantity": 1, "Items": [ {
    "Id": "lambda-origin", "DomainName": "$originDomain", "OriginAccessControlId": "$oacId",
    "CustomHeaders": { "Quantity": 0 },
    "CustomOriginConfig": { "HTTPPort": 80, "HTTPSPort": 443, "OriginProtocolPolicy": "https-only",
      "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] }, "OriginReadTimeout": 30, "OriginKeepaliveTimeout": 5 }
  } ] },
  "DefaultCacheBehavior": {
    "TargetOriginId": "lambda-origin", "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": { "Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] } },
    "Compress": false, "CachePolicyId": "$CACHE_DISABLED", "OriginRequestPolicyId": "$ORIGREQ_ALLVIEWER"
  },
  "PriceClass": "$PRICE",
  "ViewerCertificate": { "CloudFrontDefaultCertificate": true },
  "Restrictions": { "GeoRestriction": { "RestrictionType": "none", "Quantity": 0 } },
  "HttpVersion": "http2"
}
"@
$distPath = Join-Path $root "_dist.json"; Set-Content $distPath $distCfg -Encoding ascii
$distJson = aws cloudfront create-distribution --distribution-config ("file://"+$distPath) --profile $PROFILE_N --output json
Check "create-distribution failed"
$dist = $distJson | ConvertFrom-Json
$distId = $dist.Distribution.Id; $distArn = $dist.Distribution.ARN; $cfDom = $dist.Distribution.DomainName

Write-Host "[8/9] allow CloudFront to invoke Lambda (both URL + Function) ..."
aws lambda add-permission --function-name $FUNC --statement-id cloudfront-oac --action lambda:InvokeFunctionUrl `
  --principal cloudfront.amazonaws.com --source-arn $distArn --function-url-auth-type AWS_IAM --region $REGION --profile $PROFILE_N | Out-Null
Check "add-permission InvokeFunctionUrl failed"
aws lambda add-permission --function-name $FUNC --statement-id cloudfront-oac-fn --action lambda:InvokeFunction `
  --principal cloudfront.amazonaws.com --source-arn $distArn --region $REGION --profile $PROFILE_N | Out-Null
Check "add-permission InvokeFunction failed"

# state file (for teardown / reset) - gitignored
(@{ functionName=$FUNC; roleName=$ROLE; distributionId=$distId; oacId=$oacId; region=$REGION; profile=$PROFILE_N; cloudfrontDomain=$cfDom } | ConvertTo-Json) | Set-Content $statePath -Encoding ascii

Write-Host "    waiting for CloudFront to deploy (3-10 min) ..."
aws cloudfront wait distribution-deployed --id $distId --profile $PROFILE_N; Check "wait distribution-deployed failed"

Write-Host "[9/9] pin EMBED_ORIGIN = https://$cfDom ..."
$envVars.EMBED_ORIGIN = "https://$cfDom"
($( @{ Variables=$envVars } | ConvertTo-Json -Depth 10 )) | Set-Content $ep -Encoding ascii
aws lambda update-function-configuration --function-name $FUNC --environment ("file://"+$ep) --region $REGION --profile $PROFILE_N --query "LastUpdateStatus" --output text
Check "update-function-configuration (EMBED_ORIGIN) failed"
aws lambda wait function-updated --function-name $FUNC --region $REGION --profile $PROFILE_N; Check "wait function-updated failed"

Remove-Item $tp,$pp,$ep,$oacPath,$distPath,$zipPath -Force -ErrorAction SilentlyContinue

Write-Host "==================================================================="
Write-Host ("  SHARE URL : https://{0}/" -f $cfDom)
Write-Host ("  PASSWORD  : {0}" -f $pwd)
Write-Host ("  SESSION   : {0} min" -f $SESSION)
Write-Host "==================================================================="
Write-Host "  Save the password now (not shown again). Send URL and password via"
Write-Host "  two different channels. Reset: ./deploy/reset_password.ps1  Remove: ./deploy/teardown.ps1"
