# 🔍 Codebase Review — AWS Self-Healing Infrastructure Pipeline

> **Scope:** Full architectural review mapped against the system specification and data contract.
> **Verdict legend:** ✅ Correct · ⚠️ Warning / minor issue · ❌ Bug / contract violation · 💡 Recommendation

---

## 1. Pipeline Architecture Alignment

```
CloudWatch Canary Failure
  ──► EventBridge Rule (eventbridge.tf)      ✅
  ──► Lambda Orchestrator (lambda_function.py) ✅
  ──► Path A: SSM Remediation               ✅ (primary, fatal on failure)
  ──► Path B: Bedrock Root-Cause Analysis   ✅ (secondary, graceful degradation)
  ──► Path C: S3 Archive + SNS Alert        ✅ (secondary, graceful degradation)
```

The high-level pipeline flow is **correctly implemented** and matches the specification exactly.

---

## 2. `lambda-orchestrator/lambda_function.py` — Detailed Review

### 2.1 Module-Level Client Initialisation

```python
# Lines 38-46
REGION = os.environ.get("AWS_REGION", "ap-south-1")
ssm_client     = boto3.client("ssm",             region_name=REGION)
bedrock_client = boto3.client("bedrock-runtime", region_name=REGION, config=_bedrock_config)
s3_client      = boto3.client("s3",              region_name=REGION)
sns_client     = boto3.client("sns",             region_name=REGION)
```

| Check | Result |
|---|---|
| Clients initialised at module level (warm-start optimisation) | ✅ |
| `region_name` explicitly pinned on all 4 clients | ✅ |
| `bedrock_config` sets `read_timeout=60` to handle LLM latency | ✅ |
| `connect_timeout=10` set appropriately | ✅ |

### 2.2 Event Payload Parsing vs. Data Contract

Spec guarantees these 5 keys:
```json
{ "alarmName", "newState", "instanceId", "region", "source" }
```

| Key | Lambda reads it as | Match? |
|---|---|---|
| `alarmName` | `event.get("alarmName", "Unknown-Alarm")` | ✅ |
| `newState` | `event.get("newState", "UNKNOWN")` | ✅ |
| `instanceId` | `event.get("instanceId")` | ✅ |
| `region` | `event.get("region", REGION)` | ✅ |
| `source` | `event.get("source", "Unknown")` | ✅ |

> ✅ **All payload keys match the EventBridge input_transformer output exactly.**

### 2.3 Alarm State Gate (Double Defence)

```python
if alarm_state != "ALARM":
    return {"statusCode": 200, "body": json.dumps("No action required.")}
```
✅ Correct second-line defence. EventBridge already filters for `ALARM`, but this guards against direct Lambda test invocations.

### 2.4 Critical Field Guard

```python
if not target_instance_id:
    raise ValueError("Payload missing critical field: instanceId...")
```
✅ Hard fail is correct — without `instanceId` no SSM command can be sent.

### 2.5 Path A — SSM Remediation

```python
ssm_response = ssm_client.send_command(
    InstanceIds=[target_instance_id],
    DocumentName=SSM_DOCUMENT_NAME,      # "AWS-RunShellScript"
    Parameters={"commands": ["sudo systemctl restart nginx"]},
    ClientToken=context.aws_request_id,  # Idempotency token
    TimeoutSeconds=60,
    Comment=f"Self-healing: triggered by alarm {alarm_name}",
)
```

| Check | Result |
|---|---|
| `InstanceIds` correctly wrapped in a list | ✅ |
| `DocumentName = "AWS-RunShellScript"` is the correct built-in SSM document | ✅ |
| `Parameters.commands` key matches `AWS-RunShellScript` schema | ✅ |
| `ClientToken = context.aws_request_id` for idempotency | ✅ Matches spec requirement |
| `TimeoutSeconds=60` set | ✅ |
| SSM failure raises `RuntimeError` and aborts pipeline | ✅ Correct — primary path must not degrade silently |

#### ⚠️ `_wait_for_ssm_command` Helper — Poll Gap Risk

```python
# Line 229-250
def _wait_for_ssm_command(command_id, instance_id, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            result = ssm_client.get_command_invocation(...)
            status = result["Status"]
            if status in ("Success", "Failed", "Cancelled", "TimedOut"):
                return status
        except ssm_client.exceptions.InvocationDoesNotExist:
            pass
        time.sleep(5)
    return "PollTimeout"
```

✅ **Logic is correct.** `InvocationDoesNotExist` is properly caught during the SSM propagation window.

⚠️ **Lambda execution timeout risk:** The Lambda timeout must exceed the poller's `90s` window plus time for Paths B and C. Ensure the Lambda function's configured timeout is **≥ 120 seconds** in the Terraform/Console config (not currently enforced in code).

⚠️ **`PollTimeout` is returned but not raised.** If the command is still running when the poller exits, `ssmStatus` in the incident summary will read `"PollTimeout"` — the SNS alert will reflect an incomplete status. This is an acceptable trade-off but should be documented.

### 2.6 Path B — Bedrock Analysis

```python
bedrock_response = bedrock_client.invoke_model(
    modelId="anthropic.claude-3-haiku-20240307-v1:0",
    contentType="application/json",
    accept="application/json",
    body=json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 512,
        "messages": [{"role": "user", "content": prompt_text}],
    }),
)
response_body = json.loads(bedrock_response["body"].read())
ai_analysis   = response_body["content"][0]["text"]
```

| Check | Result |
|---|---|
| `modelId` matches spec (`anthropic.claude-3-haiku-20240307-v1:0`) | ✅ |
| `anthropic_version` set to `bedrock-2023-05-31` (required by Anthropic on Bedrock) | ✅ |
| `body.read()` correctly called (Bedrock returns a `StreamingBody`) | ✅ |
| Response parsed via `content[0]["text"]` (Claude Messages API format) | ✅ |
| `max_tokens=512` suitable for a 3-bullet response | ✅ |
| Bedrock failure caught in its own `except` block — does not abort SSM path | ✅ |
| Prompt asks for exactly 3 bullet points as specified | ✅ |

### 2.7 Path C — S3 Archive

```python
report_key = f"incidents/{alarm_name}/{context.aws_request_id}.json"
s3_client.put_object(
    Bucket=S3_BUCKET_NAME,
    Key=report_key,
    Body=json.dumps(incident_summary, indent=2),
    ContentType="application/json",
)
```

| Check | Result |
|---|---|
| S3 key uses `aws_request_id` as unique file name | ✅ No collision risk |
| `ContentType="application/json"` set | ✅ |
| Failure caught, non-fatal | ✅ |
| `S3_BUCKET_NAME` read from env var with placeholder fallback | ✅ |

> ⚠️ `alarm_name` sourced from the event payload is used raw in the S3 key path. If `alarmName` ever contains characters invalid for S3 key paths (e.g., `/`), the `put_object` call will silently create nested prefixes. **Recommendation:** sanitise with `alarm_name.replace("/", "_")`.

### 2.8 Path C — SNS Notification

```python
sns_client.publish(
    TopicArn=SNS_TOPIC_ARN,
    Subject=f"[HEALED] {alarm_name}",
    Message=sns_message,
)
```

| Check | Result |
|---|---|
| `TopicArn` read from env var | ✅ |
| `Subject` contains alarm name for quick triage | ✅ |
| Failure caught, non-fatal | ✅ |

> ⚠️ **SNS `Subject` length limit is 100 characters.** If `alarm_name` is long, `publish()` will raise a `InvalidParameterException`. Guard with: `Subject=f"[HEALED] {alarm_name}"[:100]`

### 2.9 Final Response

```python
return {
    "statusCode": 200,
    "body": json.dumps({
        "message": f"Orchestrator pipeline completed for {target_instance_id}.",
        "summary": incident_summary,
    }),
}
```
✅ Correct structure. `incident_summary` accumulates results from all three paths progressively, so partial successes are faithfully recorded.

---

## 3. `eventbridge.tf` — Detailed Review

### 3.1 Event Pattern Filter

```hcl
event_pattern = jsonencode({
  "source"      : ["aws.cloudwatch"],
  "detail-type" : ["CloudWatch Alarm State Change"],
  "detail" : {
    "alarmName" : [var.cloudwatch_alarm_name],
    "state"     : { "value" : ["ALARM"] }
  }
})
```

| Check | Result |
|---|---|
| `source` targets `aws.cloudwatch` | ✅ |
| `detail-type` matches CloudWatch alarm event type exactly | ✅ |
| Filters on exact `alarmName` from variable (matches `"Synthetics-Alarm-nginx-health-checker-1"`) | ✅ |
| Filters only `state.value = "ALARM"` — ignores `OK` / `INSUFFICIENT_DATA` | ✅ |

### 3.2 Input Transformer

```hcl
input_transformer {
  input_paths = {
    alarmName = "$.detail.alarmName"
    newState  = "$.detail.state.value"
  }
  input_template = jsonencode({
    alarmName  = "<alarmName>"
    newState   = "<newState>"
    instanceId = aws_instance.kumud_ec2.id   # hardcoded at deploy time
    region     = var.aws_region
    source     = "kumud-eventbridge-rule"
  })
}
```

| Check | Result |
|---|---|
| `alarmName` extracted from `$.detail.alarmName` | ✅ |
| `newState` extracted from `$.detail.state.value` | ✅ |
| `instanceId` injected from Terraform state (`aws_instance.kumud_ec2.id`) | ✅ |
| `region` injected from `var.aws_region` (`"ap-south-1"`) | ✅ |
| `source` hardcoded as `"kumud-eventbridge-rule"` | ✅ |
| All 5 keys in the output match the data contract exactly | ✅ |

> ✅ **The input_transformer is the most critical coupling point in this system. It is implemented correctly.**

### 3.3 Lambda Permission

```hcl
resource "aws_lambda_permission" "allow_eventbridge_invoke" {
  statement_id  = "AllowKumudEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.nginx_alarm_rule.arn
}
```

✅ Permission is correctly scoped to this specific rule's ARN via `source_arn`, preventing lateral invocation from other EventBridge rules.

> ⚠️ `function_name` is being set to the full `lambda_function_arn`. The `aws_lambda_permission` resource's `function_name` argument accepts both an ARN and a name. Using the full ARN is valid but make sure it does **not** include a version suffix (`:1`, `:$LATEST`) — those require a `qualifier` argument or the permission will be scoped to just that version. Ensure the ARN in `variables.tf` is an **unqualified** function ARN.

---

## 4. `main.tf` — EC2 Instance Review

| Check | Result |
|---|---|
| AMI sourced dynamically via `data.aws_ami.ubuntu` (no stale AMI ID) | ✅ |
| Filters on `ubuntu-jammy-22.04-amd64` + `hvm` virtualisation | ✅ |
| Canonical's owner ID `099720109477` used | ✅ |
| `user_data_replace_on_change = true` ensures re-provisioning on script change | ✅ |
| SSH (22) and HTTP (80) ingress rules defined | ✅ |
| Egress unrestricted (EC2 needs outbound for SSM agent, package manager) | ✅ |

> ❌ **Critical missing piece — SSM IAM Role:** The EC2 instance has **no IAM Instance Profile** attached. For SSM `send_command` (Path A) to work, the EC2 must have the `AmazonSSMManagedInstanceCore` policy attached via an IAM instance profile. Without this, the instance will not register with SSM and the `send_command` call will fail with `InvalidInstanceId`.

Add the following to `main.tf`:
```hcl
resource "aws_iam_role" "ec2_ssm_role" {
  name = "${var.project_prefix}-ec2-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm_profile" {
  name = "${var.project_prefix}-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm_role.name
}
```
And attach it to the instance:
```hcl
resource "aws_instance" "kumud_ec2" {
  # ... existing config ...
  iam_instance_profile = aws_iam_instance_profile.ec2_ssm_profile.name
}
```

---

## 5. `user_data.sh` — Bootstrap Script Review

| Check | Result |
|---|---|
| `set -e` — exits on any error, preventing partial installs | ✅ |
| Redirects all output to `/var/log/user_data.log` for post-boot debugging | ✅ |
| Installs and starts Nginx | ✅ |
| Creates `kill_nginx.sh` at `/home/ubuntu/kill_nginx.sh` | ✅ |
| `chmod +x` on the kill script | ✅ |
| `systemctl enable nginx` — survives instance reboots | ✅ |
| Fetches public IP via IMDSv1 (`http://169.254.169.254/...`) | ⚠️ |

> ⚠️ **IMDSv2 Compatibility:** Some AWS-hardened AMIs enforce **IMDSv2 (token-required)** by default. The bare `curl http://169.254.169.254/latest/meta-data/public-ipv4` (IMDSv1) may fail silently. This only affects the log echo at the end and is **non-blocking**, but update if you see empty `PUBLIC_IP` in the logs:
```bash
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)
```

---

## 6. `variables.tf` — Variable Hygiene

| Variable | Status |
|---|---|
| `aws_region = "ap-south-1"` | ✅ Matches all other configs |
| `cloudwatch_alarm_name = "Synthetics-Alarm-nginx-health-checker-1"` | ✅ Matches spec exactly |
| `lambda_function_arn` — placeholder ARN | ⚠️ Must be updated before `terraform apply` |
| `my_public_key` — real RSA public key is present | ✅ |

> ⚠️ The public SSH key in `variables.tf` is **committed to the repository**. This is not a secret (public keys are safe to share), but verify the matching **private key** is never committed.

---

## 7. Missing Files Inventory

The following directories are **empty** and need content from other team members:

| Directory | Required Content | Owner |
|---|---|---|
| `bedrock-prompts/` | Prompt templates or fine-tuned prompts | Member 4 (Piyush) |
| `ssm-scripts/` | Custom SSM Document (optional — built-in `AWS-RunShellScript` is already used) | Member 3 (Vanshika) |
| `infrastructure/` | IAM role for Lambda execution (needs SSM, Bedrock, S3, SNS permissions) | Member 2/3 |
| `notifications/` | SNS topic TF config, Discord webhook setup | Member 5 |

---

## 8. Lambda IAM Execution Role (Critical Gap)

The Lambda function itself needs an **execution role** with permissions to call all four AWS services. This IAM role is **not defined anywhere** in the current codebase. It must grant:

```
ssm:SendCommand
ssm:GetCommandInvocation
bedrock:InvokeModel
s3:PutObject
sns:Publish
logs:CreateLogGroup
logs:CreateLogStream
logs:PutLogEvents
```

This is typically defined as a `aws_iam_role` + `aws_lambda_function` resource in Terraform, likely intended to go in the `infrastructure/` directory.

---

## 9. Summary of Findings

### ❌ Blockers (will cause runtime failure)
1. **EC2 has no IAM instance profile** — SSM `send_command` will fail with `InvalidInstanceId`. Add `AmazonSSMManagedInstanceCore` policy to the EC2 via an instance profile.
2. **Lambda execution IAM role is undefined** — Lambda cannot call SSM, Bedrock, S3, or SNS without it. Must be created before deployment.

### ⚠️ Warnings (non-blocking but should be fixed)
3. **Lambda timeout must be ≥ 120s** — the SSM poller runs up to 90s; ensure the Lambda function configured timeout accounts for all three paths.
4. **SNS Subject truncation** — cap `Subject` at 100 characters.
5. **S3 key with raw `alarm_name`** — sanitise slashes in the key path.
6. **IMDSv1 curl in `user_data.sh`** — use IMDSv2 token-based metadata fetch for robustness.
7. **`lambda_function_arn` is a placeholder** — must be updated in `variables.tf` before running `terraform apply` for Phase 2.
8. **`function_name` in `aws_lambda_permission`** — confirm the ARN does not include a version qualifier.

### ✅ Correctly Implemented
- Full 5-key data contract mapping (EventBridge → Lambda)
- Module-level boto3 client initialisation (warm-start optimised)
- `context.aws_request_id` as SSM `ClientToken` (idempotency)
- Independent `try/except` blocks per path (graceful degradation)
- Bedrock model ID, API version, and response parsing
- EventBridge event pattern filter (source + detail-type + alarm name + state)
- Input transformer producing the exact data contract payload
- Lambda permission scoped to specific EventBridge rule ARN
- AMI dynamic lookup via Canonical owner ID
- SSM command polling with `InvocationDoesNotExist` guard
