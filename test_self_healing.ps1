# ============================================================
# test_self_healing.ps1  v3
# Full automated end-to-end self-healing pipeline test.
# Run: powershell -ExecutionPolicy Bypass -File test_self_healing.ps1
# ============================================================

# Use the folder the script itself lives in as the base — fixes file:// path issues
$BASE = $PSScriptRoot
if (-not $BASE) { $BASE = Split-Path -Parent $MyInvocation.MyCommand.Path }

$INSTANCE_ID  = "i-043af021b75cc0d1f"
$LAMBDA_NAME  = "kumud-self-healing-orchestrator"
$S3_BUCKET    = "kumud-nginx-incident-vault-y48yyp"
$REGION       = "ap-south-1"
$PAYLOAD_FILE = Join-Path $BASE "test_payload.json"
$LOG_FILE     = Join-Path $BASE "self_healing_test_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$LAMBDA_OUT   = Join-Path $BASE "lambda_invoke_result.json"
$BEDROCK_BODY = Join-Path $BASE "bedrock_body.json"
$BEDROCK_OUT  = Join-Path $BASE "bedrock_test.json"

function Log {
    param([string]$msg, [string]$level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$level] $msg"
    Write-Host $line
    Add-Content -Path $LOG_FILE -Value $line
}
function Sep { $l = "="*65; Write-Host $l; Add-Content $LOG_FILE $l }

function Send-SSMCommand([string]$cmd) {
    return (aws ssm send-command `
        --instance-ids $INSTANCE_ID `
        --document-name "AWS-RunShellScript" `
        --parameters "commands=$cmd" `
        --region $REGION `
        --query "Command.CommandId" `
        --output text 2>&1).Trim()
}

function Wait-SSMResult([string]$commandId, [int]$maxWait = 90) {
    $elapsed = 0
    while ($elapsed -lt $maxWait) {
        Start-Sleep -Seconds 4
        $elapsed += 4
        $raw = aws ssm get-command-invocation `
            --command-id $commandId `
            --instance-id $INSTANCE_ID `
            --region $REGION `
            --output json 2>&1
        if ($raw -match '"Status"') {
            $j = $raw | ConvertFrom-Json
            if ($j.Status -in @("Success","Failed","Cancelled","TimedOut")) { return $j }
        }
    }
    return $null
}

# ── START ─────────────────────────────────────────────────────
Sep
Log "SELF-HEALING PIPELINE - AUTOMATED TEST STARTED (v3)"
Log "Script base dir: $BASE"
Sep

# ── STEP 1: Pre-crash Nginx check ─────────────────────────────
Log "STEP 1: Checking Nginx status BEFORE crash..."
$r = Wait-SSMResult (Send-SSMCommand "systemctl is-active nginx")
$beforeStatus = $r.StandardOutputContent.Trim()
Log "  Nginx before crash: '$beforeStatus'"
if ($beforeStatus -ne "active") {
    Log "  Nginx already down - restarting it first..." "WARN"
    Wait-SSMResult (Send-SSMCommand "sudo systemctl start nginx") | Out-Null
    Start-Sleep -Seconds 4
    $r2 = Wait-SSMResult (Send-SSMCommand "systemctl is-active nginx")
    Log "  Nginx status after pre-restore: '$($r2.StandardOutputContent.Trim())'"
}

# ── STEP 2: Crash Nginx ───────────────────────────────────────
Sep
Log "STEP 2: Simulating crash - stopping Nginx..."
$stopResult = Wait-SSMResult (Send-SSMCommand "sudo systemctl stop nginx")
Log "  SSM stop status: $($stopResult.Status)"
$verifyStop = Wait-SSMResult (Send-SSMCommand "systemctl is-active nginx")
$crashedStatus = $verifyStop.StandardOutputContent.Trim()
Log "  Nginx after crash: '$crashedStatus'"
if ($crashedStatus -ne "active") {
    Log "  CONFIRMED: Nginx is DOWN (crash successful)"
} else {
    Log "  WARNING: Nginx still active after crash attempt!" "WARN"
}

# ── STEP 3: Invoke Lambda ─────────────────────────────────────
Sep
Log "STEP 3: Invoking Lambda to simulate CloudWatch ALARM event..."
Log "  Using payload file: $PAYLOAD_FILE"

# FIX v3: use absolute path for payload; capture stderr to $lambdaCliErr
$lambdaCliErr = aws lambda invoke `
    --function-name $LAMBDA_NAME `
    "--payload" "file://$PAYLOAD_FILE" `
    --cli-binary-format raw-in-base64-out `
    --log-type Tail `
    --region $REGION `
    --output json `
    "$LAMBDA_OUT" 2>&1

if (Test-Path $LAMBDA_OUT) {
    $lambdaJson = Get-Content $LAMBDA_OUT -Raw | ConvertFrom-Json
    $statusCode  = $lambdaJson.StatusCode
    Log "  Lambda StatusCode: $statusCode"
    if ($lambdaJson.FunctionError) {
        Log "  FunctionError: $($lambdaJson.FunctionError)" "ERROR"
    } else {
        Log "  Lambda ran without unhandled exceptions."
    }
    # Decode and print Lambda tail logs
    if ($lambdaJson.LogResult) {
        $decoded = [System.Text.Encoding]::UTF8.GetString(
            [System.Convert]::FromBase64String($lambdaJson.LogResult))
        Sep
        Log "LAMBDA EXECUTION LOGS:"
        $decoded -split "`n" | ForEach-Object {
            $cl = $_ -replace "[^\x20-\x7E]","?"
            if ($cl.Trim() -ne "") { Log "  $cl" }
        }
    }
} else {
    $statusCode = 0
    Log "  [FAIL] Output file not created. AWS CLI error:" "ERROR"
    Log "  $lambdaCliErr" "ERROR"
}

# ── STEP 4: Verify Nginx healed ───────────────────────────────
Sep
Log "STEP 4: Verifying Nginx status AFTER Lambda heal..."
Start-Sleep -Seconds 10
$r4 = Wait-SSMResult (Send-SSMCommand "systemctl is-active nginx")
$healedStatus = $r4.StandardOutputContent.Trim()
Log "  Nginx after Lambda: '$healedStatus'"
if ($healedStatus -eq "active") {
    Log "  [PASS] SELF-HEALING WORKED - Nginx is BACK UP!"
} else {
    Log "  [FAIL] Nginx still DOWN after Lambda ran!" "ERROR"
}

# ── STEP 5: Check S3 for reports ─────────────────────────────
Sep
Log "STEP 5: Checking S3 for incident reports..."
$s3List = aws s3 ls "s3://$S3_BUCKET/incidents/" --recursive --region $REGION 2>&1
if ($s3List -match "incidents/") {
    Log "  [PASS] S3 reports found:"
    $s3List -split "`n" | Where-Object { $_.Trim() -ne "" } | ForEach-Object { Log "    $_" }
    $lastLine  = ($s3List -split "`n" | Where-Object { $_ -match "\.txt" } | Select-Object -Last 1).Trim()
    $latestKey = ($lastLine -split "\s+")[-1]
    if ($latestKey) {
        Log "  Fetching latest report (s3://$S3_BUCKET/$latestKey)..."
        $content = aws s3 cp "s3://$S3_BUCKET/$latestKey" - --region $REGION 2>&1
        Log "  --- S3 Report Content ---"
        $content -split "`n" | ForEach-Object { Log "    $_" }
        Log "  --- End of Report ---"
    }
} else {
    Log "  [FAIL] No S3 reports found in bucket!" "ERROR"
}

# ── STEP 6: SNS subscription status ──────────────────────────
Sep
Log "STEP 6: Checking SNS email subscription..."
$subArn  = "arn:aws:sns:ap-south-1:750545041118:kumud-nginx-incident-alerts:ab3def0f-8455-4ee7-90d2-f0272612a123"
$pending = (aws sns get-subscription-attributes `
    --subscription-arn $subArn `
    --region $REGION `
    --query "Attributes.PendingConfirmation" `
    --output text 2>&1).Trim()
Log "  PendingConfirmation: $pending"
if ($pending -eq "true") {
    Log "  [WARN] Email NOT confirmed - check piyushcollege12@gmail.com inbox!" "WARN"
    Log "         Click the AWS Notification - Subscription Confirmation link." "WARN"
} else {
    Log "  [PASS] Email subscription confirmed - alerts will be delivered."
}

# ── STEP 7: Bedrock live invocation test ──────────────────────
Sep
Log "STEP 7: Testing Bedrock Claude 3 Haiku invocation..."

# FIX v3: use fileb:// (binary file) instead of file:// — AWS CLI v2 treats
#         file:// as base64 for blob params, fileb:// sends raw bytes correctly.
[System.IO.File]::WriteAllText(
    $BEDROCK_BODY,
    '{"anthropic_version":"bedrock-2023-05-31","max_tokens":20,"messages":[{"role":"user","content":"Reply with the single word: OK"}]}'
)
Log "  Bedrock body written to: $BEDROCK_BODY"

$bedrockCliErr = aws bedrock-runtime invoke-model `
    --model-id "anthropic.claude-3-haiku-20240307-v1:0" `
    "--body" "fileb://$BEDROCK_BODY" `
    --content-type "application/json" `
    --accept "application/json" `
    --region $REGION `
    "$BEDROCK_OUT" 2>&1

if ($LASTEXITCODE -eq 0 -and (Test-Path $BEDROCK_OUT)) {
    $reply = (Get-Content $BEDROCK_OUT -Raw | ConvertFrom-Json).content[0].text
    Log "  [PASS] Bedrock invocation SUCCEEDED."
    Log "  Bedrock reply: '$reply'"
    $bedrockPass = $true
} else {
    Log "  [FAIL] Bedrock invocation FAILED." "ERROR"
    Log "  Error: $bedrockCliErr" "ERROR"
    Log "  ACTION: AWS Console -> Amazon Bedrock -> Model access -> Enable Claude 3 Haiku" "ERROR"
    $bedrockPass = $false
}

# ── FINAL SUMMARY ─────────────────────────────────────────────
Sep
Log "FINAL SUMMARY"
Sep
Log ("  Nginx crashed:      " + $(if ($crashedStatus -ne 'active') {'[PASS]'} else {'[FAIL]'}))
Log ("  Lambda invoked:     " + $(if ($statusCode -eq 200)         {'[PASS]'} else {'[FAIL]'}))
Log ("  Nginx self-healed:  " + $(if ($healedStatus -eq 'active')  {'[PASS]'} else {'[FAIL]'}))
Log ("  S3 report written:  " + $(if ($s3List -match 'incidents/')  {'[PASS]'} else {'[FAIL]'}))
Log ("  SNS email:          " + $(if ($pending -ne 'true')          {'[PASS]'} else {'[WARN] Confirm subscription email'}))
Log ("  Bedrock invoke:     " + $(if ($bedrockPass)                 {'[PASS]'} else {'[FAIL] Enable Claude 3 Haiku in AWS Console -> Bedrock -> Model access'}))
Sep
Log "Full log saved to: $LOG_FILE"
Log "TEST COMPLETE."
Sep
