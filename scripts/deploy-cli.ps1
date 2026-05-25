#requires -Version 5
<#
.SYNOPSIS
Deploys the voice-insights-bedrock pipeline to AWS using imperative AWS CLI calls.
Mirrors the resources defined in terraform/. Used as a workaround when Norton's
loopback TLS filter blocks Terraform's plugin gRPC mTLS handshake.

.NOTES
Lambda bundles must exist at terraform/dist/{submission,normalization,retrieval}.zip
(run `yarn build` first).
#>
[CmdletBinding()]
param(
    [string]$Region        = 'us-east-1',
    [string]$ProjectName   = 'voice-insights',
    [string]$Environment   = 'dev',
    [string]$OwnerTag      = 'owner',
    # Required: pass with -BdaProjectArn / -BdaProfileArn or set $env:BDA_PROJECT_ARN / $env:BDA_PROFILE_ARN.
    # Example profile ARN: arn:aws:bedrock:us-east-1:<account-id>:data-automation-profile/us.data-automation-v1
    [string]$BdaProjectArn = $env:BDA_PROJECT_ARN,
    [string]$BdaProfileArn = $env:BDA_PROFILE_ARN
)

if (-not $BdaProjectArn -or -not $BdaProfileArn) {
    throw "BdaProjectArn and BdaProfileArn are required. Pass via parameters or set BDA_PROJECT_ARN / BDA_PROFILE_ARN env vars."
}

$ErrorActionPreference = 'Stop'
# Set AWS_CA_BUNDLE in your shell if your machine inspects TLS (e.g. corporate proxy).
$env:AWS_PAGER          = ''

$repoRoot   = Split-Path -Parent $PSScriptRoot
$distDir    = Join-Path $repoRoot 'terraform\dist'
$stateFile  = Join-Path $repoRoot '.deploy-state.json'

$script:awsJsonTempFiles = New-Object System.Collections.Generic.List[string]

function Write-Stage($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Sub($msg)   { Write-Host "    $msg" -ForegroundColor DarkGray }

function New-AwsJson {
    # Write JSON to a UTF-8 (no BOM) temp file and return file:// URI.
    # Avoids PowerShell 5.1 stripping double quotes when splatting inline JSON to native exe.
    param([Parameter(Mandatory)][string]$Json)
    $f = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($f, $Json, [System.Text.UTF8Encoding]::new($false))
    $script:awsJsonTempFiles.Add($f) | Out-Null
    return "file://$f"
}

function Invoke-Aws {
    param([Parameter(Mandatory)][string[]]$AwsArgs, [switch]$Raw)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & aws @AwsArgs 2>$errFile
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            $err = (Get-Content -Raw -ErrorAction SilentlyContinue $errFile)
            throw "aws $($AwsArgs -join ' ') failed (exit $code):`n$err"
        }
        if ($Raw) { return $output }
        return ($output | Out-String).Trim()
    } finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $prev
    }
}

try {

# Load or initialise deploy state (preserves suffix across re-runs)
if (Test-Path $stateFile) {
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json
    Write-Stage "Resuming deploy with suffix '$($state.suffix)'"
} else {
    $suffix = -join ((1..8) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })
    $state = [pscustomobject]@{
        suffix      = $suffix
        region      = $Region
        projectName = $ProjectName
        environment = $Environment
        createdAt   = (Get-Date).ToString('o')
    }
    $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8
    Write-Stage "New deploy with suffix '$suffix'"
}

$nameBase    = "$ProjectName-$Environment"
$inputBucket = "$nameBase-input-$($state.suffix)"
$outBucket   = "$nameBase-output-$($state.suffix)"
$ddbTable    = "$nameBase-transcripts"
$subQueue    = "$nameBase-submission"
$subDlq      = "$nameBase-submission-dlq"
$normQueue   = "$nameBase-normalization"
$normDlq     = "$nameBase-normalization-dlq"
$apiName     = "$nameBase-api"

Write-Stage 'Identifying account'
$accountId = Invoke-Aws -AwsArgs @('sts','get-caller-identity','--query','Account','--output','text')
Write-Sub "Account: $accountId  Region: $Region"

# ---------------------------------------------------------------- S3 buckets
$sseConfigUri = New-AwsJson -Json (ConvertTo-Json -Compress -Depth 10 @{
    Rules = @(@{ ApplyServerSideEncryptionByDefault = @{ SSEAlgorithm = 'AES256' } })
})

foreach ($b in @($inputBucket, $outBucket)) {
    Write-Stage "S3 bucket: $b"
    $exists = $true
    try { Invoke-Aws -AwsArgs @('s3api','head-bucket','--bucket',$b) | Out-Null } catch { $exists = $false }
    if (-not $exists) {
        if ($Region -eq 'us-east-1') {
            Invoke-Aws -AwsArgs @('s3api','create-bucket','--bucket',$b,'--region',$Region) | Out-Null
        } else {
            Invoke-Aws -AwsArgs @('s3api','create-bucket','--bucket',$b,'--region',$Region,
                         '--create-bucket-configuration',"LocationConstraint=$Region") | Out-Null
        }
        Write-Sub 'created'
    } else { Write-Sub 'exists' }

    Invoke-Aws -AwsArgs @('s3api','put-public-access-block','--bucket',$b,
                 '--public-access-block-configuration',
                 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true') | Out-Null
    Invoke-Aws -AwsArgs @('s3api','put-bucket-versioning','--bucket',$b,
                 '--versioning-configuration','Status=Enabled') | Out-Null
    Invoke-Aws -AwsArgs @('s3api','put-bucket-encryption','--bucket',$b,
                 '--server-side-encryption-configuration',$sseConfigUri) | Out-Null
    Write-Sub 'configured (PAB, versioning, SSE)'
}

# ---------------------------------------------------------------- DynamoDB
Write-Stage "DynamoDB table: $ddbTable"
$ddbExists = $true
try { Invoke-Aws -AwsArgs @('dynamodb','describe-table','--table-name',$ddbTable) | Out-Null } catch { $ddbExists = $false }
if (-not $ddbExists) {
    Invoke-Aws -AwsArgs @('dynamodb','create-table','--table-name',$ddbTable,
                 '--attribute-definitions','AttributeName=jobId,AttributeType=S',
                 '--key-schema','AttributeName=jobId,KeyType=HASH',
                 '--billing-mode','PAY_PER_REQUEST',
                 '--sse-specification','Enabled=true') | Out-Null
    Write-Sub 'creating, waiting for ACTIVE...'
    Invoke-Aws -AwsArgs @('dynamodb','wait','table-exists','--table-name',$ddbTable) | Out-Null
    Invoke-Aws -AwsArgs @('dynamodb','update-continuous-backups','--table-name',$ddbTable,
                 '--point-in-time-recovery-specification','PointInTimeRecoveryEnabled=true') | Out-Null
    Write-Sub 'active, PITR enabled'
} else { Write-Sub 'exists' }

# ---------------------------------------------------------------- SQS queues
function Ensure-Queue {
    param([string]$Name, [int]$Visibility, [int]$Retention, [string]$DlqArn)
    Write-Stage "SQS queue: $Name"
    $attrs = @{
        VisibilityTimeout       = "$Visibility"
        MessageRetentionPeriod  = "$Retention"
    }
    if ($DlqArn) {
        $attrs.RedrivePolicy = (ConvertTo-Json -Compress @{ deadLetterTargetArn = $DlqArn; maxReceiveCount = 3 })
    }
    $attrsUri = New-AwsJson -Json (ConvertTo-Json -Compress $attrs)
    $url = $null
    try {
        $url = Invoke-Aws -AwsArgs @('sqs','get-queue-url','--queue-name',$Name,'--query','QueueUrl','--output','text')
        Invoke-Aws -AwsArgs @('sqs','set-queue-attributes','--queue-url',$url,'--attributes',$attrsUri) | Out-Null
        Write-Sub "exists: $url"
    } catch {
        $url = Invoke-Aws -AwsArgs @('sqs','create-queue','--queue-name',$Name,'--attributes',$attrsUri,
                            '--query','QueueUrl','--output','text')
        Write-Sub "created: $url"
    }
    $arn = Invoke-Aws -AwsArgs @('sqs','get-queue-attributes','--queue-url',$url,
                        '--attribute-names','QueueArn','--query','Attributes.QueueArn','--output','text')
    return [pscustomobject]@{ Url = $url; Arn = $arn }
}

$subDlqQ   = Ensure-Queue -Name $subDlq  -Visibility 60  -Retention 1209600
$normDlqQ  = Ensure-Queue -Name $normDlq -Visibility 60  -Retention 1209600
$subQ      = Ensure-Queue -Name $subQueue  -Visibility 360 -Retention 345600 -DlqArn $subDlqQ.Arn
$normQ     = Ensure-Queue -Name $normQueue -Visibility 360 -Retention 345600 -DlqArn $normDlqQ.Arn

Write-Stage 'SQS queue policies (allow S3 SendMessage)'
foreach ($pair in @(
    @{ Q = $subQ;  Bucket = $inputBucket },
    @{ Q = $normQ; Bucket = $outBucket   }
)) {
    $policy = ConvertTo-Json -Depth 10 -Compress @{
        Version   = '2012-10-17'
        Statement = @(@{
            Sid       = 'AllowS3Send'
            Effect    = 'Allow'
            Principal = @{ Service = 's3.amazonaws.com' }
            Action    = 'sqs:SendMessage'
            Resource  = $pair.Q.Arn
            Condition = @{
                ArnLike      = @{ 'aws:SourceArn'    = "arn:aws:s3:::$($pair.Bucket)" }
                StringEquals = @{ 'aws:SourceAccount' = $accountId }
            }
        })
    }
    $attrsUri = New-AwsJson -Json (ConvertTo-Json -Compress @{ Policy = $policy })
    Invoke-Aws -AwsArgs @('sqs','set-queue-attributes','--queue-url',$pair.Q.Url,'--attributes',$attrsUri) | Out-Null
    Write-Sub "policy applied: $($pair.Q.Arn)"
}

# ---------------------------------------------------------------- IAM roles
$assumeUri = New-AwsJson -Json (ConvertTo-Json -Depth 10 -Compress @{
    Version   = '2012-10-17'
    Statement = @(@{
        Effect    = 'Allow'
        Principal = @{ Service = 'lambda.amazonaws.com' }
        Action    = 'sts:AssumeRole'
    })
})

function Ensure-Role {
    param([string]$Name, [string]$InlinePolicyJson)
    Write-Stage "IAM role: $Name"
    $arn = $null
    try {
        $arn = Invoke-Aws -AwsArgs @('iam','get-role','--role-name',$Name,'--query','Role.Arn','--output','text')
        Write-Sub "exists: $arn"
    } catch {
        $arn = Invoke-Aws -AwsArgs @('iam','create-role','--role-name',$Name,
                            '--assume-role-policy-document',$assumeUri,
                            '--query','Role.Arn','--output','text')
        Write-Sub "created: $arn"
    }
    Invoke-Aws -AwsArgs @('iam','attach-role-policy','--role-name',$Name,
                 '--policy-arn','arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole') | Out-Null
    $inlineUri = New-AwsJson -Json $InlinePolicyJson
    Invoke-Aws -AwsArgs @('iam','put-role-policy','--role-name',$Name,
                 '--policy-name','inline','--policy-document',$inlineUri) | Out-Null
    return $arn
}

$ddbArn       = "arn:aws:dynamodb:${Region}:${accountId}:table/${ddbTable}"
$inputBktArn  = "arn:aws:s3:::$inputBucket"
$outBktArn    = "arn:aws:s3:::$outBucket"

# BDA cross-region inference profiles route to other AWS regions internally; the IAM
# auth check happens against the destination region's profile ARN. Allow all regions.
$bdaProfileArnPattern = ($BdaProfileArn -replace '^arn:aws:bedrock:[^:]+:', 'arn:aws:bedrock:*:')
$submissionInline = ConvertTo-Json -Depth 10 -Compress @{
    Version = '2012-10-17'
    Statement = @(
        @{ Sid='SqsRead';        Effect='Allow'; Action=@('sqs:ReceiveMessage','sqs:DeleteMessage','sqs:GetQueueAttributes'); Resource=$subQ.Arn },
        @{ Sid='S3ReadInput';    Effect='Allow'; Action='s3:GetObject';  Resource="$inputBktArn/*" },
        @{ Sid='S3WriteOutput';  Effect='Allow'; Action='s3:PutObject';  Resource="$outBktArn/*" },
        @{ Sid='InvokeBDA';      Effect='Allow'; Action='bedrock:InvokeDataAutomationAsync'; Resource=@($BdaProjectArn,$BdaProfileArn,$bdaProfileArnPattern) }
    )
}
$normalizationInline = ConvertTo-Json -Depth 10 -Compress @{
    Version = '2012-10-17'
    Statement = @(
        @{ Sid='SqsRead';      Effect='Allow'; Action=@('sqs:ReceiveMessage','sqs:DeleteMessage','sqs:GetQueueAttributes'); Resource=$normQ.Arn },
        @{ Sid='S3ReadOutput'; Effect='Allow'; Action='s3:GetObject';  Resource="$outBktArn/*" },
        @{ Sid='DdbWrite';     Effect='Allow'; Action='dynamodb:PutItem'; Resource=$ddbArn }
    )
}
$retrievalInline = ConvertTo-Json -Depth 10 -Compress @{
    Version = '2012-10-17'
    Statement = @(
        @{ Sid='DdbRead'; Effect='Allow'; Action='dynamodb:GetItem'; Resource=$ddbArn }
    )
}

$subRoleArn  = Ensure-Role -Name "$nameBase-submission"    -InlinePolicyJson $submissionInline
$normRoleArn = Ensure-Role -Name "$nameBase-normalization" -InlinePolicyJson $normalizationInline
$retRoleArn  = Ensure-Role -Name "$nameBase-retrieval"     -InlinePolicyJson $retrievalInline

Write-Stage 'Waiting 10s for IAM role propagation'
Start-Sleep -Seconds 10

# ---------------------------------------------------------------- CloudWatch log groups
foreach ($fn in @('submission','normalization','retrieval')) {
    $lg = "/aws/lambda/$nameBase-$fn"
    try { Invoke-Aws -AwsArgs @('logs','create-log-group','--log-group-name',$lg) | Out-Null } catch {}
    Invoke-Aws -AwsArgs @('logs','put-retention-policy','--log-group-name',$lg,'--retention-in-days','14') | Out-Null
    Write-Sub "log group: $lg"
}

# ---------------------------------------------------------------- Lambda functions
function Ensure-Lambda {
    param(
        [string]$Name, [string]$RoleArn, [string]$ZipPath,
        [int]$MemoryMB = 512, [int]$TimeoutSec = 60,
        [hashtable]$EnvVars
    )
    Write-Stage "Lambda: $Name"
    if (-not (Test-Path $ZipPath)) { throw "Missing Lambda zip: $ZipPath" }
    $envUri = New-AwsJson -Json (ConvertTo-Json -Compress @{ Variables = $EnvVars })
    $exists = $true
    try { Invoke-Aws -AwsArgs @('lambda','get-function','--function-name',$Name) | Out-Null } catch { $exists = $false }
    if (-not $exists) {
        # create-function with retry: IAM role may not have propagated yet
        $attempt = 0
        while ($true) {
            $attempt++
            try {
                Invoke-Aws -AwsArgs @('lambda','create-function','--function-name',$Name,'--runtime','nodejs20.x',
                     '--handler','index.handler','--role',$RoleArn,
                     '--zip-file',"fileb://$ZipPath",
                     '--memory-size',"$MemoryMB",'--timeout',"$TimeoutSec",
                     '--environment',$envUri) | Out-Null
                break
            } catch {
                if ($attempt -ge 6 -or "$_" -notmatch 'InvalidParameterValueException|cannot be assumed') { throw }
                Write-Sub "role not yet usable, retrying in 5s (attempt $attempt)"
                Start-Sleep -Seconds 5
            }
        }
        Write-Sub 'created'
    } else {
        Invoke-Aws -AwsArgs @('lambda','update-function-code','--function-name',$Name,
                     '--zip-file',"fileb://$ZipPath",'--publish') | Out-Null
        Invoke-Aws -AwsArgs @('lambda','wait','function-updated','--function-name',$Name) | Out-Null
        Invoke-Aws -AwsArgs @('lambda','update-function-configuration','--function-name',$Name,
                     '--memory-size',"$MemoryMB",'--timeout',"$TimeoutSec",
                     '--environment',$envUri,'--role',$RoleArn) | Out-Null
        Invoke-Aws -AwsArgs @('lambda','wait','function-updated','--function-name',$Name) | Out-Null
        Write-Sub 'updated'
    }
    return Invoke-Aws -AwsArgs @('lambda','get-function','--function-name',$Name,
                        '--query','Configuration.FunctionArn','--output','text')
}

$subFnArn = Ensure-Lambda -Name "$nameBase-submission" -RoleArn $subRoleArn `
    -ZipPath (Join-Path $distDir 'submission.zip') -EnvVars @{
        BDA_PROJECT_ARN = $BdaProjectArn
        BDA_PROFILE_ARN = $BdaProfileArn
        OUTPUT_BUCKET   = $outBucket
        OUTPUT_PREFIX   = 'transcripts'
        LOG_LEVEL       = 'INFO'
    }

$normFnArn = Ensure-Lambda -Name "$nameBase-normalization" -RoleArn $normRoleArn `
    -ZipPath (Join-Path $distDir 'normalization.zip') -EnvVars @{
        TRANSCRIPTS_TABLE = $ddbTable
        LOG_LEVEL         = 'INFO'
    }

$retFnArn = Ensure-Lambda -Name "$nameBase-retrieval" -RoleArn $retRoleArn `
    -ZipPath (Join-Path $distDir 'retrieval.zip') -TimeoutSec 15 -EnvVars @{
        TRANSCRIPTS_TABLE = $ddbTable
        LOG_LEVEL         = 'INFO'
    }

# ---------------------------------------------------------------- Event source mappings
function Ensure-Esm {
    param([string]$QueueArn, [string]$FnName)
    $existing = (Invoke-Aws -AwsArgs @('lambda','list-event-source-mappings','--function-name',$FnName,
                              '--event-source-arn',$QueueArn,
                              '--query','EventSourceMappings[0].UUID','--output','text'))
    if ($existing -and $existing -ne 'None') {
        Write-Sub "ESM exists: $existing"
        return
    }
    Invoke-Aws -AwsArgs @('lambda','create-event-source-mapping','--function-name',$FnName,
                 '--event-source-arn',$QueueArn,'--batch-size','10',
                 '--maximum-batching-window-in-seconds','5',
                 '--function-response-types','ReportBatchItemFailures') | Out-Null
    Write-Sub "ESM created for $FnName"
}
Write-Stage 'Event source mappings (SQS -> Lambda)'
Ensure-Esm -QueueArn $subQ.Arn  -FnName "$nameBase-submission"
Ensure-Esm -QueueArn $normQ.Arn -FnName "$nameBase-normalization"

# ---------------------------------------------------------------- S3 bucket notifications
Write-Stage 'S3 notifications (S3 -> SQS)'
$inputNotifUri = New-AwsJson -Json (ConvertTo-Json -Depth 10 -Compress @{
    QueueConfigurations = @(@{ QueueArn = $subQ.Arn; Events = @('s3:ObjectCreated:*') })
})
Invoke-Aws -AwsArgs @('s3api','put-bucket-notification-configuration','--bucket',$inputBucket,
             '--notification-configuration',$inputNotifUri) | Out-Null
Write-Sub "input notif -> $($subQ.Arn)"

$outNotifUri = New-AwsJson -Json (ConvertTo-Json -Depth 10 -Compress @{
    QueueConfigurations = @(@{
        QueueArn = $normQ.Arn
        Events   = @('s3:ObjectCreated:*')
        Filter   = @{ Key = @{ FilterRules = @(@{ Name='suffix'; Value='result.json' }) } }
    })
})
Invoke-Aws -AwsArgs @('s3api','put-bucket-notification-configuration','--bucket',$outBucket,
             '--notification-configuration',$outNotifUri) | Out-Null
Write-Sub "output notif -> $($normQ.Arn) (suffix=result.json)"

# ---------------------------------------------------------------- API Gateway (HTTP API)
Write-Stage "API Gateway HTTP API: $apiName"
$apiId = (Invoke-Aws -AwsArgs @('apigatewayv2','get-apis','--query',"Items[?Name=='$apiName'].ApiId | [0]",'--output','text'))
if (-not $apiId -or $apiId -eq 'None') {
    $apiId = Invoke-Aws -AwsArgs @('apigatewayv2','create-api','--name',$apiName,'--protocol-type','HTTP',
                          '--description','Voice Insights transcript retrieval API',
                          '--query','ApiId','--output','text')
    Write-Sub "created: $apiId"
} else {
    Write-Sub "exists: $apiId"
}

$integId  = (Invoke-Aws -AwsArgs @('apigatewayv2','get-integrations','--api-id',$apiId,
                          '--query',"Items[?IntegrationUri=='$retFnArn'].IntegrationId | [0]",'--output','text'))
if (-not $integId -or $integId -eq 'None') {
    $integId = Invoke-Aws -AwsArgs @('apigatewayv2','create-integration','--api-id',$apiId,
                            '--integration-type','AWS_PROXY','--integration-uri',$retFnArn,
                            '--integration-method','POST','--payload-format-version','2.0',
                            '--query','IntegrationId','--output','text')
    Write-Sub "integration created: $integId"
} else {
    Write-Sub "integration exists: $integId"
}

$routeKey = 'GET /transcripts/{jobId}'
$routeId  = (Invoke-Aws -AwsArgs @('apigatewayv2','get-routes','--api-id',$apiId,
                          '--query',"Items[?RouteKey=='$routeKey'].RouteId | [0]",'--output','text'))
if (-not $routeId -or $routeId -eq 'None') {
    Invoke-Aws -AwsArgs @('apigatewayv2','create-route','--api-id',$apiId,'--route-key',$routeKey,
                 '--target',"integrations/$integId") | Out-Null
    Write-Sub "route created: $routeKey"
} else {
    Write-Sub "route exists: $routeId"
}

$stageExists = $true
try { Invoke-Aws -AwsArgs @('apigatewayv2','get-stage','--api-id',$apiId,'--stage-name','$default') | Out-Null } catch { $stageExists = $false }
if (-not $stageExists) {
    Invoke-Aws -AwsArgs @('apigatewayv2','create-stage','--api-id',$apiId,'--stage-name','$default','--auto-deploy') | Out-Null
    Write-Sub 'stage $default created'
} else {
    Write-Sub 'stage $default exists'
}

$sourceArn = "arn:aws:execute-api:${Region}:${accountId}:${apiId}/*/*"
try {
    Invoke-Aws -AwsArgs @('lambda','add-permission','--function-name',"$nameBase-retrieval",
                 '--statement-id','AllowAPIGatewayInvoke','--action','lambda:InvokeFunction',
                 '--principal','apigateway.amazonaws.com','--source-arn',$sourceArn) | Out-Null
    Write-Sub 'lambda permission added'
} catch {
    if ("$_" -match 'ResourceConflictException') {
        Write-Sub 'lambda permission already present'
    } else { throw }
}

$apiEndpoint = Invoke-Aws -AwsArgs @('apigatewayv2','get-api','--api-id',$apiId,
                            '--query','ApiEndpoint','--output','text')

# ---------------------------------------------------------------- Persist outputs
$outputs = [pscustomobject]@{
    inputBucket       = $inputBucket
    outputBucket      = $outBucket
    transcriptsTbl    = $ddbTable
    apiEndpoint       = $apiEndpoint
    apiId             = $apiId
    submissionFn      = "$nameBase-submission"
    normalizationFn   = "$nameBase-normalization"
    retrievalFn       = "$nameBase-retrieval"
    submissionQ       = $subQ.Url
    normalizationQ    = $normQ.Url
    submissionDlq     = $subDlqQ.Url
    normalizationDlq  = $normDlqQ.Url
    submissionRole    = "$nameBase-submission"
    normalizationRole = "$nameBase-normalization"
    retrievalRole     = "$nameBase-retrieval"
}
$state | Add-Member -NotePropertyName outputs -NotePropertyValue $outputs -Force

$state | ConvertTo-Json -Depth 10 | Set-Content -Path $stateFile -Encoding utf8

Write-Host ''
Write-Host 'DEPLOY COMPLETE' -ForegroundColor Green
Write-Host "  Input bucket : $inputBucket"
Write-Host "  Output bucket: $outBucket"
Write-Host "  API endpoint : $apiEndpoint"
Write-Host "  DynamoDB     : $ddbTable"
Write-Host ''
Write-Host "Try: aws s3 cp my-clip.mp3 s3://$inputBucket/samples/my-clip.mp3"
Write-Host "Then: curl $apiEndpoint/transcripts/<jobId>"

} finally {
    foreach ($f in $script:awsJsonTempFiles) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}
