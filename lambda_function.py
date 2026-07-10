import json
import os
import time
import boto3
from datetime import datetime
from botocore.config import Config
from botocore.exceptions import ClientError

# ──────────────────────────────────────────────────────────────────────────────
# MODULE-LEVEL CLIENT INITIALISATION
# ──────────────────────────────────────────────────────────────────────────────
REGION = os.environ.get("AWS_REGION", "ap-south-1")

# Bedrock can take up to 30s for long prompts, adding retries for throttling.
_bedrock_config = Config(
    read_timeout=60, 
    connect_timeout=10, 
    retries={'max_attempts': 3, 'mode': 'standard'}
)

ssm_client     = boto3.client("ssm",             region_name=REGION)
bedrock_client = boto3.client("bedrock-runtime", region_name=REGION, config=_bedrock_config)
s3_client      = boto3.client("s3",              region_name=REGION)
sns_client     = boto3.client("sns",             region_name=REGION)

# ──────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ──────────────────────────────────────────────────────────────────────────────
SSM_DOCUMENT_NAME  = "AWS-RunShellScript"
BEDROCK_MODEL_ID   = "anthropic.claude-3-haiku-20240307-v1:0"
S3_BUCKET_NAME     = os.environ.get("INCIDENT_BUCKET", "PLACEHOLDER_BUCKET")
SNS_TOPIC_ARN      = os.environ.get("SNS_TOPIC_ARN",   "PLACEHOLDER_SNS_ARN")

# ──────────────────────────────────────────────────────────────────────────────
# PART A — GenAI Log Analyzer
# ──────────────────────────────────────────────────────────────────────────────
def analyze_incident(error_text: str) -> str:
    """Uses Claude 3 Haiku via Bedrock to analyze the incident and summarize."""
    prompt_text = (
        "You are an expert AWS Site Reliability Engineer.\n"
        "Based on the following incident details, provide EXACTLY 3 concise bullet points in plain English covering:\n"
        "1) The most likely root cause.\n"
        "2) What the automated fix did and the result.\n"
        "3) One preventive measure for the future.\n\n"
        f"Incident Details:\n{error_text}"
    )
    
    try:
        response = bedrock_client.invoke_model(
            modelId=BEDROCK_MODEL_ID,
            contentType="application/json",
            accept="application/json",
            body=json.dumps({
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 512,
                "messages": [{"role": "user", "content": prompt_text}]
            })
        )
        response_body = json.loads(response["body"].read())
        return response_body["content"][0]["text"].strip()
    except ClientError as e:
        print(f"⚠️  Bedrock analysis failed: {e}")
        return f"[Bedrock Analysis Failed: {str(e)}]"

# ──────────────────────────────────────────────────────────────────────────────
# PART B — S3 Audit Vault + Email Alerts
# ──────────────────────────────────────────────────────────────────────────────
def upload_report_to_s3(bucket: str, report: str, incident_id: str) -> str:
    """Uploads the AI-generated report as a timestamped .txt file to S3."""
    timestamp = datetime.utcnow().strftime("%Y-%m-%dT%H-%M-%SZ")
    object_key = f"incidents/{incident_id}/{timestamp}.txt"
    try:
        s3_client.put_object(
            Bucket=bucket,
            Key=object_key,
            Body=report,
            ContentType="text/plain"
        )
        return f"s3://{bucket}/{object_key}"
    except Exception as e:
        print(f"⚠️  S3 Upload failed: {e}")
        return f"Upload Failed: {str(e)}"

def send_email_alert(sns_topic_arn: str, subject: str, message: str, s3_link: str, remediation_status: str):
    """Sends a formatted email containing the summary, S3 link, and status."""
    timestamp = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    full_message = (
        f"Timestamp: {timestamp}\n"
        f"Remediation Status: {remediation_status}\n\n"
        f"AI Analysis:\n{message}\n\n"
        f"Detailed Report: {s3_link}"
    )
    try:
        sns_client.publish(
            TopicArn=sns_topic_arn,
            Subject=subject,
            Message=full_message
        )
        print("✅ SNS email alert dispatched.")
    except Exception as e:
        print(f"⚠️  SNS Publish failed: {e}")

# ──────────────────────────────────────────────────────────────────────────────
# HELPER — Poll SSM command
# ──────────────────────────────────────────────────────────────────────────────
def _wait_for_ssm_command(command_id: str, instance_id: str, timeout: int = 90) -> str:
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
            pass
        time.sleep(5)
    return "PollTimeout"

# ──────────────────────────────────────────────────────────────────────────────
# PART C — Final Integration (Lambda Handler)
# ──────────────────────────────────────────────────────────────────────────────
def lambda_handler(event, context):
    print(f"🚨 Raw Event: {json.dumps(event)}")
    
    # 1. PARSE PAYLOAD
    detail              = event.get("detail", {})
    alarm_name          = detail.get("alarmName", "Unknown-Alarm")
    alarm_state         = detail.get("state", {}).get("value", "UNKNOWN")
    alarm_reason        = detail.get("state", {}).get("reason", "No reason provided")
    target_instance_id  = os.environ.get("TARGET_INSTANCE_ID")
    region              = event.get("region", REGION)

    # 2. ALARM STATE GATE
    if alarm_state != "ALARM":
        print(f"ℹ️  State is [{alarm_state}] — no remediation needed. Exiting cleanly.")
        return {"statusCode": 200, "body": json.dumps("No action required.")}

    if not target_instance_id:
        raise ValueError("Payload missing critical field: TARGET_INSTANCE_ID.")

    print(f"🖥️  Target EC2 to heal: {target_instance_id}")

    try:
        # 3. AUTOMATED REMEDIATION (SSM)
        print("🛠️  Dispatching SSM repair command…")
        ssm_response = ssm_client.send_command(
            InstanceIds=[target_instance_id],
            DocumentName=SSM_DOCUMENT_NAME,
            Parameters={
                "commands":  [
                    "sudo systemctl restart nginx",
                    "sudo systemctl status nginx --no-pager"
                ]
            },
            TimeoutSeconds=60,
            Comment=f"Self-healing: triggered by alarm {alarm_name}",
        )
        command_id = ssm_response["Command"]["CommandId"]
        print(f"✅ SSM command dispatched. CommandId: {command_id}")
        
        remediation_result = _wait_for_ssm_command(command_id, target_instance_id)
        print(f"🔧 SSM result: {remediation_result}")
        
        # 4. CAPTURE INCIDENT DETAILS FOR AI
        incident_context = (
            f"Alarm Name: {alarm_name}\n"
            f"Alarm Reason: {alarm_reason}\n"
            f"Target Instance: {target_instance_id}\n"
            f"Region: {region}\n"
            f"SSM Command ID: {command_id}\n"
            f"SSM Execution Status: {remediation_result}\n"
        )
        
        print("🤖 Prompting Amazon Bedrock for root-cause analysis…")
        ai_analysis = analyze_incident(incident_context)
        print(f"🤖 Bedrock analysis:\n{ai_analysis}")
        
        # 5. UPLOAD TO S3
        print("📦 Archiving incident report to S3…")
        s3_link = upload_report_to_s3(
            bucket=S3_BUCKET_NAME, 
            report=ai_analysis, 
            incident_id=alarm_name
        )
        print(f"✅ Report archived: {s3_link}")
        
        # 6. SEND EMAIL ALERT
        print("📨 Sending SNS notification…")
        subject = f"🚨 Nginx Incident Auto-Resolved — {target_instance_id}"
        send_email_alert(
            sns_topic_arn=SNS_TOPIC_ARN,
            subject=subject,
            message=ai_analysis,
            s3_link=s3_link,
            remediation_status=remediation_result
        )

        return {
            "statusCode": 200,
            "body": json.dumps("Orchestrator pipeline completed successfully.")
        }
        
    except Exception as e:
        print(f"❌ Unhandled Exception in Pipeline: {e}")
        # Send a failure alert if possible
        try:
            sns_client.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=f"❌ FAILED Self-Healing — {target_instance_id}",
                Message=f"The self-healing pipeline encountered an error: {str(e)}"
            )
        except Exception:
            pass
        raise