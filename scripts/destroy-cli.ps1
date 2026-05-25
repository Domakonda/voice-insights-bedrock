#requires -Version 5
<#
.SYNOPSIS
Tears down resources created by deploy-cli.ps1. Reads state from .deploy-state.json.

.NOTES
Tracks failures explicitly and only removes the state file on a fully clean run.
If anything fails, the state file is preserved so the script can be re-run.
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

$script:failures = New-Object System.Collections.Generic.List[string]

function Invoke-AwsDelete {
    <#
      Runs `aws ...`, prints exit + first stderr line on failure. Returns $true on success,
      $false on failure. Treats "resource not found" / 404 as success (idempotent teardown).
    #>
    param(
        [Parameter(Mandatory)][string[]]$AwsArgs,
        [string]$Label
    )
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & aws @AwsArgs 2>$errFile
        $code   = $LASTEXITCODE
        $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
        if ($code -eq 0) {
            Write-Host "    ok" -ForegroundColor DarkGreen
            return $true
        }
        # AWS CLI exits 254 for client errors. Treat "does not exist" as already-gone.
        $alreadyGone = $stderr -match '(NoSuchEntity|NoSuchBucket|NotFoundException|ResourceNotFoundException|Queue does not exist|cannot be found|does not exist)'
        if ($alreadyGone) {
            Write-Host "    already gone" -ForegroundColor DarkGray
            return $true
        }
        $msg = if ($stderr) { ($stderr -split "`n")[0].Trim() } else { "(no stderr)" }
        Write-Host "    FAILED (exit $code): $msg" -ForegroundColor Red
        $script:failures.Add("$Label : $msg")
        return $false
    } finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- API Gateway
Write-Host "==> Deleting API Gateway $($o.apiId)" -ForegroundColor Cyan
[void] (Invoke-AwsDelete -AwsArgs @('apigatewayv2','delete-api','--api-id',$o.apiId) -Label "api/$($o.apiId)")

# ---------------------------------------------------------------- Lambdas (+ ESMs)
foreach ($fn in @($o.submissionFn, $o.normalizationFn, $o.retrievalFn)) {
    Write-Host "==> Deleting Lambda $fn" -ForegroundColor Cyan
    $esms = & aws lambda list-event-source-mappings --function-name $fn --query 'EventSourceMappings[].UUID' --output text 2>$null
    foreach ($u in ($esms -split '\s+' | Where-Object { $_ -and $_ -ne 'None' })) {
        Write-Host "  ESM $u" -ForegroundColor DarkGray
        [void] (Invoke-AwsDelete -AwsArgs @('lambda','delete-event-source-mapping','--uuid',$u) -Label "esm/$u")
    }
    [void] (Invoke-AwsDelete -AwsArgs @('lambda','delete-function','--function-name',$fn) -Label "lambda/$fn")
}

# ---------------------------------------------------------------- Log groups
foreach ($suffix in @('submission','normalization','retrieval')) {
    $name = "/aws/lambda/$($state.projectName)-$($state.environment)-$suffix"
    Write-Host "==> Deleting log group $name" -ForegroundColor Cyan
    [void] (Invoke-AwsDelete -AwsArgs @('logs','delete-log-group','--log-group-name',$name) -Label "logs/$name")
}

# ---------------------------------------------------------------- SQS queues
foreach ($q in @($o.submissionQ, $o.normalizationQ, $o.submissionDlq, $o.normalizationDlq)) {
    if (-not $q) { continue }
    Write-Host "==> Deleting SQS $q" -ForegroundColor Cyan
    [void] (Invoke-AwsDelete -AwsArgs @('sqs','delete-queue','--queue-url',$q) -Label "sqs/$q")
}

# ---------------------------------------------------------------- DynamoDB
Write-Host "==> Deleting DynamoDB $($o.transcriptsTbl)" -ForegroundColor Cyan
[void] (Invoke-AwsDelete -AwsArgs @('dynamodb','delete-table','--table-name',$o.transcriptsTbl) -Label "ddb/$($o.transcriptsTbl)")

# ---------------------------------------------------------------- S3 buckets (versioned)
foreach ($b in @($o.inputBucket, $o.outputBucket)) {
    Write-Host "==> Emptying + deleting bucket $b" -ForegroundColor Cyan

    # Step 1: drop current (non-versioned) objects
    [void] (Invoke-AwsDelete -AwsArgs @('s3','rm',"s3://$b",'--recursive','--quiet') -Label "s3-rm/$b")

    # Step 2: drop every version + delete marker. list-object-versions is paginated;
    # capture the entire JSON document in one shot before parsing.
    $raw = (& aws s3api list-object-versions --bucket $b --max-items 1000 --output json 2>$null) | Out-String
    if ($raw -and $raw.Trim()) {
        try {
            $j = $raw | ConvertFrom-Json
            $items = @()
            if ($j.Versions)       { $items += @($j.Versions) }
            if ($j.DeleteMarkers)  { $items += @($j.DeleteMarkers) }
            if ($items.Count -gt 0) {
                Write-Host "    purging $($items.Count) versions/markers" -ForegroundColor DarkGray
                foreach ($v in $items) {
                    if ($v.Key -and $v.VersionId) {
                        & aws s3api delete-object --bucket $b --key $v.Key --version-id $v.VersionId 2>$null | Out-Null
                    }
                }
            }
            # If a NextToken was set, the user has > 1000 versions — surface it.
            if ($j.NextToken) {
                Write-Host "    WARN: more than 1000 versions in $b — re-run to fully empty" -ForegroundColor Yellow
                $script:failures.Add("s3-versions/$b : > 1000 versions, partial purge only")
            }
        } catch {
            Write-Host "    FAILED to parse version list: $_" -ForegroundColor Red
            $script:failures.Add("s3-versions/$b : parse error")
        }
    }

    # Step 3: delete the empty bucket
    [void] (Invoke-AwsDelete -AwsArgs @('s3api','delete-bucket','--bucket',$b) -Label "bucket/$b")
}

# ---------------------------------------------------------------- IAM roles
foreach ($role in @($o.submissionRole, $o.normalizationRole, $o.retrievalRole)) {
    Write-Host "==> Deleting IAM role $role" -ForegroundColor Cyan
    [void] (Invoke-AwsDelete -AwsArgs @('iam','delete-role-policy','--role-name',$role,'--policy-name','inline') -Label "iam-inline/$role")
    [void] (Invoke-AwsDelete -AwsArgs @('iam','detach-role-policy','--role-name',$role,'--policy-arn','arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole') -Label "iam-detach/$role")
    [void] (Invoke-AwsDelete -AwsArgs @('iam','delete-role','--role-name',$role) -Label "iam-role/$role")
}

# ---------------------------------------------------------------- Summary
Write-Host ''
if ($script:failures.Count -eq 0) {
    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    Write-Host 'DESTROY COMPLETE — state file removed.' -ForegroundColor Green
} else {
    Write-Host "DESTROY FINISHED WITH $($script:failures.Count) FAILURE(S):" -ForegroundColor Yellow
    foreach ($f in $script:failures) { Write-Host "  - $f" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host "State file preserved at $stateFile. Re-run after addressing the failures." -ForegroundColor Yellow
    exit 1
}
