#requires -Version 5
<#
.SYNOPSIS
Tears down resources created by deploy-cli.ps1. Reads state from .deploy-state.json.
#>
[CmdletBinding()]
param([string]$Region = 'us-east-1')

$ErrorActionPreference = 'Continue'
# Set AWS_CA_BUNDLE in your shell if your machine inspects TLS (e.g. corporate proxy).
$env:AWS_PAGER          = ''

$repoRoot  = Split-Path -Parent $PSScriptRoot
$stateFile = Join-Path $repoRoot '.deploy-state.json'
if (-not (Test-Path $stateFile)) { throw "No deploy state at $stateFile" }
$state = Get-Content $stateFile -Raw | ConvertFrom-Json
$o = $state.outputs

function Try-Aws([string[]]$Args) {
    & aws @Args 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "    skip (already gone or error)" -ForegroundColor DarkGray }
}

Write-Host "==> Deleting API Gateway $($o.apiId)" -ForegroundColor Cyan
Try-Aws @('apigatewayv2','delete-api','--api-id',$o.apiId)

foreach ($fn in @($o.submissionFn, $o.normalizationFn, $o.retrievalFn)) {
    Write-Host "==> Deleting Lambda $fn" -ForegroundColor Cyan
    # Remove ESMs first
    $esms = & aws lambda list-event-source-mappings --function-name $fn --query 'EventSourceMappings[].UUID' --output text 2>$null
    foreach ($u in ($esms -split '\s+' | Where-Object { $_ })) {
        Try-Aws @('lambda','delete-event-source-mapping','--uuid',$u)
    }
    Try-Aws @('lambda','delete-function','--function-name',$fn)
}

foreach ($lg in @('submission','normalization','retrieval')) {
    $name = "/aws/lambda/$($state.projectName)-$($state.environment)-$lg"
    Write-Host "==> Deleting log group $name" -ForegroundColor Cyan
    Try-Aws @('logs','delete-log-group','--log-group-name',$name)
}

foreach ($q in @($o.submissionQ, $o.normalizationQ, $o.submissionDlq, $o.normalizationDlq)) {
    if ($q) {
        Write-Host "==> Deleting SQS $q" -ForegroundColor Cyan
        Try-Aws @('sqs','delete-queue','--queue-url',$q)
    }
}

Write-Host "==> Deleting DynamoDB $($o.transcriptsTbl)" -ForegroundColor Cyan
Try-Aws @('dynamodb','delete-table','--table-name',$o.transcriptsTbl)

foreach ($b in @($o.inputBucket, $o.outputBucket)) {
    Write-Host "==> Emptying + deleting bucket $b" -ForegroundColor Cyan
    Try-Aws @('s3','rm',"s3://$b",'--recursive')
    # Versioned bucket: delete object versions and delete markers
    & aws s3api list-object-versions --bucket $b --output json 2>$null | ForEach-Object {
        $j = $_ | ConvertFrom-Json
        foreach ($v in ($j.Versions + $j.DeleteMarkers)) {
            if ($v) {
                & aws s3api delete-object --bucket $b --key $v.Key --version-id $v.VersionId 2>$null | Out-Null
            }
        }
    }
    Try-Aws @('s3api','delete-bucket','--bucket',$b)
}

foreach ($role in @($o.submissionRole, $o.normalizationRole, $o.retrievalRole)) {
    Write-Host "==> Deleting IAM role $role" -ForegroundColor Cyan
    Try-Aws @('iam','delete-role-policy','--role-name',$role,'--policy-name','inline')
    Try-Aws @('iam','detach-role-policy','--role-name',$role,'--policy-arn','arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole')
    Try-Aws @('iam','delete-role','--role-name',$role)
}

Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'DESTROY COMPLETE' -ForegroundColor Green
