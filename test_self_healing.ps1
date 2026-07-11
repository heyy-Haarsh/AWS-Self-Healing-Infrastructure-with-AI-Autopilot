# ============================================================
# test_self_healing.ps1
# Full automated end-to-end self-healing pipeline test.
# Crashes Nginx, invokes Lambda, verifies heal, checks all services.
# Run with: powershell -ExecutionPolicy Bypass -File test_self_healing.ps1
# ============================================================

$INSTANCE_ID    = "i-043af021b75cc0d1f"
$LAMBDA_NAME    = "kumud-self-healing-orchestrator"
$S3_BUCKET      = "kumud-nginx-incident-vault-y48yyp"
$REGION         = "ap-south-1"
$PAYLOAD_FILE   = "test_payload.json"
$LOG_FILE       = "self_healing_test_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Log {
    param([string]$msg, [string]$level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$level] $msg"
    Write-Host $line
    Add-Content -Path $LOG_FILE -Value $line
}
function Sep { $l="="*65; Write-Host $l; Add-Content $LOG_FILE $l }

function Send-SSMCommand([string]$cmd) {
    return (aws ssm send-command --instance-ids $INSTANCE_ID --document-name "AWS-RunShellScript" --parameters "commands=$cmd" --region $REGION --query "Command.CommandId" --output text 2>&1).Trim()
}

function Wait-SSMResult([string]$commandId, [int]$maxWait=90) {
    $elapsed=0
    while ($elapsed -lt $maxWait) {
        Start-Sleep -Seconds 4; $elapsed+=4
        $r = aws ssm get-command-invocation --command-id $commandId --instance-id $INSTANCE_ID --region $REGION --output json 2>&1
        if ($r -match '"Status"') {
            $j = $r | ConvertFrom-Json
            if ($j.Status -in @("Success","Failed","Cancelled","TimedOut")) { return $j }
        }
    }
    return $null
}

# ─── START ───────────────────────────────────────────────────
Sep; Log "SELF-HEALING PIPELINE — AUTOMATED TEST STARTED"; Sep

# STEP 1: Pre-crash Nginx check
Log "STEP 1: Checking Nginx status BEFORE crash..."
$r = Wait-SSMResult (Send-SSMCommand "systemctl is-active nginx")
$beforeStatus = $r.StandardOutputContent.Trim()
Log "  Nginx before crash: '$beforeStatus'"
if ($beforeStatus -ne "active") {
    Log "  Nginx already down — restarting first..." "WARN"
    Wait-SSMResult (Send-SSMCommand "sudo systemctl start nginx") | Out-Null
    Start-Sleep -Seconds 3
}

# STEP 2: Crash Nginx
Sep; Log "STEP 2: Simulating crash — stopping Nginx..."
$r2 = Wait-SSMResult (Send-SSMCommand "sudo systemctl stop nginx")
Log "  SSM stop status: $($r2.Status)"
$r3 = Wait-SSMResult (Send-SSMCommand "systemctl is-active nginx")
$crashedStatus = $r3.StandardOutputContent.Trim()
Log "  Nginx after crash: '$crashedStatus'"
if ($crashedStatus -ne "active") { Log "  CONFIRMED: Nginx is DOWN" } else { Log "  WARNING: Nginx still up!" "WARN" }

# STEP 3: Invoke Lambda (simulate alarm)
Sep; Log "STEP 3: Invoking Lambda to simulate CloudWatch ALARM..."
$lambdaOut = "lambda_invoke_result.json"
aws lambda invoke --function-name $LAMBDA_NAME --payload "file://$PAYLOAD_FILE" --cli-binary-format raw-in-base64-out --log-type Tail --region $REGION --output json $lambdaOut 2>&1 | Out-Null
$lambdaJson = Get-Content $lambdaOut -Raw | ConvertFrom-Json
Log "  Lambda StatusCode: $($lambdaJson.StatusCode)"
if ($lambdaJson.FunctionError) { Log "  FunctionError: $($lambdaJson.FunctionError)" "ERROR" } else { Log "  Lambda ran without unhandled exceptions." }
# Decode logs
if ($lambdaJson.LogResult) {
    $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($lambdaJson.LogResult))
    Sep; Log "LAMBDA LOGS:"
    $decoded -split "`n" | ForEach-Object {
        $cl = $_ -replace "[^\x20-\x7E]","?"
        if ($cl.Trim() -ne "") { Log "  $cl" }
    }
}

# STEP 4: Verify Nginx healed
Sep; Log "STEP 4: Verifying Nginx AFTER Lambda heal..."
Start-Sleep -Seconds 5
$r4 = Wait-SSMResult (Send-SSMCommand "systemctl is-active nginx")
$healedStatus = $r4.StandardOutputContent.Trim()
Log "  Nginx after Lambda: '$healedStatus'"
if ($healedStatus -eq "active") { Log "  [PASS] SELF-HEALING WORKED — Nginx is BACK UP!" } else { Log "  [FAIL] Nginx still DOWN after Lambda!" "ERROR" }

# STEP 5: Check S3
Sep; Log "STEP 5: Checking S3 for incident report..."
$s3List = aws s3 ls "s3://$S3_BUCKET/incidents/" --recursive --region $REGION 2>&1
if ($s3List -match "incidents/") {
    Log "  [PASS] S3 report found:"
    $s3List -split "`n" | Where-Object { $_.Trim() -ne "" } | ForEach-Object { Log "    $_" }
    $latestKey = ($s3List -split "`n" | Where-Object { $_ -match "\.txt" } | Select-Object -Last 1).Trim().Split(" ")[-1]
    if ($latestKey) {
        Log "  Report content from s3://$S3_BUCKET/$latestKey :"
        $content = aws s3 cp "s3://$S3_BUCKET/$latestKey" - --region $REGION 2>&1
        $content -split "`n" | ForEach-Object { Log "    $_" }
    }
} else { Log "  [FAIL] No S3 reports found!" "ERROR" }

# STEP 6: Check SNS subscription
Sep; Log "STEP 6: Checking SNS email subscription..."
$subArn = "arn:aws:sns:ap-south-1:750545041118:kumud-nginx-incident-alerts:ab3def0f-8455-4ee7-90d2-f0272612a123"
$pending = (aws sns get-subscription-attributes --subscription-arn $subArn --region $REGION --query "Attributes.PendingConfirmation" --output text 2>&1).Trim()
Log "  PendingConfirmation: $pending"
if ($pending -eq "true") {
    Log "  [WARN] Email NOT confirmed — go to piyushcollege12@gmail.com and click the AWS confirmation link!" "WARN"
} else { Log "  [PASS] Email subscription confirmed — alerts will be delivered." }

# STEP 7: Bedrock access test
Sep; Log "STEP 7: Testing Bedrock model invocation..."
$testBody = '{"anthropic_version":"bedrock-2023-05-31","max_tokens":20,"messages":[{"role":"user","content":"Say OK"}]}'
$bedrockOut = "bedrock_test.json"
aws bedrock-runtime invoke-model --model-id "anthropic.claude-3-haiku-20240307-v1:0" --body $testBody --content-type "application/json" --accept "application/json" --region $REGION $bedrockOut 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Log "  [PASS] Bedrock invocation SUCCEEDED."
    $bedrockReply = (Get-Content $bedrockOut -Raw | ConvertFrom-Json).content[0].text
    Log "  Bedrock replied: $bedrockReply"
} else {
    $errMsg = aws bedrock-runtime invoke-model --model-id "anthropic.claude-3-haiku-20240307-v1:0" --body $testBody --content-type "application/json" --accept "application/json" --region $REGION $bedrockOut 2>&1
    Log "  [FAIL] Bedrock failed: $errMsg" "ERROR"
    Log "  Fix: AWS Console -> Bedrock -> Model access -> Enable Claude 3 Haiku" "ERROR"
}

# FINAL SUMMARY
Sep; Log "FINAL SUMMARY"  ; Sep
Log "  Nginx crashed:      $(if ($crashedStatus -ne 'active') {'[PASS]'} else {'[FAIL]'})"
Log "  Lambda invoked:     $(if ($lambdaJson.StatusCode -eq 200) {'[PASS]'} else {'[FAIL]'})"
Log "  Nginx self-healed:  $(if ($healedStatus -eq 'active') {'[PASS]'} else {'[FAIL]'})"
Log "  S3 report written:  $(if ($s3List -match 'incidents/') {'[PASS]'} else {'[FAIL]'})"
Log "  SNS subscription:   $(if ($pending -ne 'true') {'[PASS]'} else {'[WARN] Email not yet confirmed'})"
Log "  Bedrock invoke:     $(if ($LASTEXITCODE -eq 0) {'[PASS]'} else {'[FAIL] Enable model access in Console'})"
Sep
Log "Log file: $LOG_FILE"
Log "TEST COMPLETE."
Sep
