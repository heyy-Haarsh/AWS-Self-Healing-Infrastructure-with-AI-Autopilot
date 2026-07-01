"""
lambda_function.py — Self-Healing Infrastructure Orchestrator
==============================================================
Member 2: Harshad (Orchestrator)

Pipeline:
  CloudWatch Canary fails
    → EventBridge Rule (Kumud's eventbridge.tf) catches ALARM state change
    → Sends a clean 5-key JSON payload to THIS Lambda
    → Lambda:
        (a) Runs SSM command to restart Nginx  [Member 3 — Vanshika fills in]
        (b) Asks Bedrock AI for log analysis   [Member 4 — Piyush fills in]
        (c) Archives report to S3 + SNS alert  [Member 5 fills in]

Payload shape guaranteed by Kumud's input_transformer:
  {
    "alarmName":  str,   # e.g. "Synthetics-Alarm-nginx-health-checker-1"
    "newState":   str,   # always "ALARM" (EventBridge rule filters for this)
    "instanceId": str,   # e.g. "i-0abc123def456"
    "region":     str,   # e.g. "ap-south-1"
    "source":     str    # "kumud-eventbridge-rule"
  }
"""

import json
import os
import time
import boto3
from botocore.config import Config

# ──────────────────────────────────────────────────────────────────────────────
# MODULE-LEVEL CLIENT INITIALISATION
# Placed OUTSIDE the handler so AWS Lambda reuses these across warm invocations,
# saving re-authentication overhead (~50-200 ms per call).
# region_name is pinned explicitly to guard against shared-account env variables
# pointing to the wrong region.
# ──────────────────────────────────────────────────────────────────────────────
REGION = os.environ.get("AWS_REGION", "ap-south-1")

# Bedrock can take up to 30s for long prompts — increase read timeout accordingly.
_bedrock_config = Config(read_timeout=60, connect_timeout=10)

ssm_client     = boto3.client("ssm",             region_name=REGION)
bedrock_client = boto3.client("bedrock-runtime", region_name=REGION, config=_bedrock_config)
s3_client      = boto3.client("s3",              region_name=REGION)
sns_client     = boto3.client("sns",             region_name=REGION)


# ──────────────────────────────────────────────────────────────────────────────
# CONSTANTS  (update these after teammates share their resource names)
# ──────────────────────────────────────────────────────────────────────────────
SSM_DOCUMENT_NAME  = "AWS-RunShellScript"          # Member 3 may swap for a custom doc
BEDROCK_MODEL_ID   = "anthropic.claude-3-haiku-20240307-v1:0"  # Member 4 must confirm access
S3_BUCKET_NAME     = os.environ.get("INCIDENT_BUCKET", "PLACEHOLDER_BUCKET")   # Member 5 fills in
SNS_TOPIC_ARN      = os.environ.get("SNS_TOPIC_ARN",   "PLACEHOLDER_SNS_ARN")  # Member 5 fills in


# ──────────────────────────────────────────────────────────────────────────────
def lambda_handler(event, context):
    """
    Central orchestrator — invoked by EventBridge when CloudWatch ALARM fires.
    Uses context.aws_request_id as an idempotency token for SSM to prevent
    duplicate remediation if EventBridge delivers the same event twice.
    """

    # ── 1. PARSE PAYLOAD ─────────────────────────────────────────────────────
    # Keys match EXACTLY what Kumud's input_transformer emits (eventbridge.tf L100-106)
    alarm_name         = event.get("alarmName", "Unknown-Alarm")
    alarm_state        = event.get("newState",  "UNKNOWN")
    target_instance_id = event.get("instanceId")
    region             = event.get("region",    REGION)
    source             = event.get("source",    "Unknown")

    print(f"🚨 Event received from: {source}")
    print(f"🔔 Alarm [{alarm_name}] → state: [{alarm_state}]")

    # ── 2. ALARM STATE GATE (second-line defence) ────────────────────────────
    # EventBridge pattern already filters for ALARM, but validate in code too
    # in case someone tests the Lambda directly with a synthetic payload.
    if alarm_state != "ALARM":
        print(f"ℹ️  State is [{alarm_state}] — no remediation needed. Exiting cleanly.")
        return {"statusCode": 200, "body": json.dumps("No action required.")}

    # ── 3. CRITICAL FIELD GUARD ──────────────────────────────────────────────
    if not target_instance_id:
        # Hard failure — without an instance ID we cannot do anything meaningful.
        raise ValueError("Payload missing critical field: instanceId. Check Kumud's input_transformer.")

    print(f"🖥️  Target EC2 to heal: {target_instance_id}")

    # Track what each path produced so we can build a unified incident summary.
    remediation_result = None
    ai_analysis        = None
    incident_summary   = {
        "alarmName":  alarm_name,
        "instanceId": target_instance_id,
        "region":     region,
    }

    # ══════════════════════════════════════════════════════════════════════════
    # PATH A — AUTOMATED REMEDIATION via SSM  [PRIMARY — must succeed]
    # Member 3 (Vanshika): replace the placeholder command list below with your
    # SSM document name / parameters, or drop in your custom SSM Document ARN.
    # ══════════════════════════════════════════════════════════════════════════
    print("🛠️  Dispatching SSM repair command…")
    try:
        ssm_response = ssm_client.send_command(
            InstanceIds=[target_instance_id],
            DocumentName=SSM_DOCUMENT_NAME,
            Parameters={
                # ── Member 3: swap out or extend this command list ──────────
                "commands": ["sudo systemctl restart nginx"]
            },
            # Idempotency token — prevents duplicate execution if EventBridge
            # retries. Lambda request ID is unique per invocation attempt.
            ClientToken=context.aws_request_id,
            TimeoutSeconds=60,
            Comment=f"Self-healing: triggered by alarm {alarm_name}",
        )

        command_id = ssm_response["Command"]["CommandId"]
        print(f"✅ SSM command dispatched. CommandId: {command_id}")

        # Poll until the command completes (or 90s elapses).
        # Member 3: if you switch to an async pattern, remove this block.
        remediation_result = _wait_for_ssm_command(command_id, target_instance_id)
        print(f"🔧 SSM result: {remediation_result}")
        incident_summary["ssmCommandId"] = command_id
        incident_summary["ssmStatus"]    = remediation_result

    except Exception as ssm_error:
        # SSM failure is CRITICAL — surface it loudly and abort pipeline.
        print(f"❌ SSM remediation FAILED: {ssm_error}")
        raise RuntimeError(f"Primary remediation failed: {ssm_error}") from ssm_error

    # ══════════════════════════════════════════════════════════════════════════
    # PATH B — GENAI LOG ANALYSIS via Bedrock  [SECONDARY — graceful degradation]
    # Member 4 (Piyush): replace the prompt body and model_id below with your
    # fine-tuned prompt. Ensure Claude 3 Haiku model access is enabled in
    # ap-south-1 Bedrock console before deploying.
    # ══════════════════════════════════════════════════════════════════════════
    print("🤖 Prompting Amazon Bedrock for root-cause analysis…")
    try:
        # ── Member 4: customise this prompt ─────────────────────────────────
        prompt_text = (
            f"An AWS CloudWatch alarm named '{alarm_name}' fired in region '{region}'. "
            f"The affected EC2 instance is '{target_instance_id}'. "
            f"SSM remediation status: '{remediation_result}'. "
            "In exactly 3 concise bullet points, explain: "
            "1) the most likely root cause, "
            "2) what the automated fix did, "
            "3) one preventive measure for next time."
        )

        bedrock_response = bedrock_client.invoke_model(
            modelId=BEDROCK_MODEL_ID,
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
        print(f"🤖 Bedrock analysis:\n{ai_analysis}")
        incident_summary["aiAnalysis"] = ai_analysis

    except Exception as bedrock_error:
        # Non-critical — log and continue; remediation already completed above.
        ai_analysis = f"[Bedrock unavailable: {bedrock_error}]"
        incident_summary["aiAnalysis"] = ai_analysis
        print(f"⚠️  Bedrock analysis skipped (non-fatal): {bedrock_error}")

    # ══════════════════════════════════════════════════════════════════════════
    # PATH C — STORAGE & NOTIFICATION  [SECONDARY — graceful degradation]
    # Member 5: drop your S3 upload + SNS publish code into these blocks.
    # Set S3_BUCKET_NAME and SNS_TOPIC_ARN as Lambda environment variables.
    # ══════════════════════════════════════════════════════════════════════════
    print("📦 Archiving incident report to S3…")
    try:
        report_key = f"incidents/{alarm_name}/{context.aws_request_id}.json"
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=report_key,
            Body=json.dumps(incident_summary, indent=2),
            ContentType="application/json",
        )
        print(f"✅ Report archived: s3://{S3_BUCKET_NAME}/{report_key}")
        incident_summary["s3ReportKey"] = report_key

    except Exception as s3_error:
        print(f"⚠️  S3 archive skipped (non-fatal): {s3_error}")

    print("📨 Sending SNS notification…")
    try:
        sns_message = (
            f"🚨 Self-Healing Alert\n"
            f"Alarm : {alarm_name}\n"
            f"Instance: {target_instance_id}\n"
            f"SSM fix : {remediation_result}\n\n"
            f"AI Analysis:\n{ai_analysis}"
        )
        sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"[HEALED] {alarm_name}",
            Message=sns_message,
        )
        print("✅ SNS notification dispatched.")

    except Exception as sns_error:
        print(f"⚠️  SNS notification skipped (non-fatal): {sns_error}")

    # ── 4. SUCCESS RESPONSE ──────────────────────────────────────────────────
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": f"Orchestrator pipeline completed for {target_instance_id}.",
            "summary": incident_summary,
        }),
    }


# ──────────────────────────────────────────────────────────────────────────────
# HELPER — Poll SSM command until terminal state or timeout
# ──────────────────────────────────────────────────────────────────────────────
def _wait_for_ssm_command(command_id: str, instance_id: str, timeout: int = 90) -> str:
    """
    Polls get_command_invocation every 5 seconds until the SSM command reaches
    a terminal state (Success / Failed / Cancelled) or the timeout elapses.

    Returns the final status string.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            result = ssm_client.get_command_invocation(
                CommandId=command_id,
                InstanceId=instance_id,
            )
            status = result["Status"]
            if status in ("Success", "Failed", "Cancelled", "TimedOut"):
                return status
        except ssm_client.exceptions.InvocationDoesNotExist:
            pass  # Command not yet registered on instance — keep polling
        time.sleep(5)

    return "PollTimeout"  # Lambda is about to return; SSM may still be running