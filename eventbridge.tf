# ============================================================
# eventbridge.tf  —  PHASE 2
# ------------------------------------------------------------
# This file creates the EventBridge Rule that connects your
# CloudWatch Alarm (created via Console) to your teammate's
# Lambda function.
#
# Flow:
#   CloudWatch Alarm → ALARM state
#         │
#         ▼
#   EventBridge Rule (this file) → catches the state change event
#         │
#         ▼
#   Lambda Function (teammate's code) → heals the infrastructure
#
# Your responsibility ENDS at the EventBridge Rule.
# ============================================================


# ------------------------------------------------------------
# RESOURCE 1: EventBridge Rule
# ------------------------------------------------------------
# EventBridge is AWS's event router. Think of it as a smart
# mail filter — it watches for specific events happening in
# your AWS account, and when a match is found, it forwards
# that event to wherever you tell it to (the "target").
#
# Here, we tell EventBridge: "Watch for CloudWatch Alarm state
# changes, but ONLY care about MY specific alarm, and ONLY when
# it transitions to ALARM (not OK, not INSUFFICIENT_DATA)."
resource "aws_cloudwatch_event_rule" "nginx_alarm_rule" {
  name        = "${var.project_prefix}-alarm-state-change" # "kumud-alarm-state-change"
  description = "Triggers when the Nginx health check alarm goes into ALARM state"

  # event_pattern is a JSON filter. EventBridge compares every
  # event happening in your AWS account against this pattern.
  # Only events matching ALL fields below will trigger this rule.
  event_pattern = jsonencode({
    # Only events coming from CloudWatch Alarms service
    "source" : ["aws.cloudwatch"],

    # Only "state change" events (not alarm creation/deletion etc.)
    "detail-type" : ["CloudWatch Alarm State Change"],

    "detail" : {
      # Only match OUR specific alarm by name.
      # This is the exact alarm name created by the Canary in Console.
      "alarmName" : [var.cloudwatch_alarm_name],

      # Only match when the NEW state is "ALARM"
      # (we don't care about OK or INSUFFICIENT_DATA transitions)
      "state" : {
        "value" : ["ALARM"]
      }
    }
  })

  # ENABLED means this rule is actively listening.
  # You could set this to "DISABLED" to pause it without deleting it.
  state = "ENABLED"

  tags = {
    Name    = "${var.project_prefix}-alarm-state-change"
    Project = "self-healing-infra"
    Owner   = var.project_prefix
    Phase   = "2-eventbridge"
  }
}


# ------------------------------------------------------------
# RESOURCE 2: EventBridge Target
# ------------------------------------------------------------
# A Rule alone only FILTERS events — it doesn't send them anywhere
# on its own. A "Target" tells EventBridge WHERE to deliver the
# matching event.
#
# Here we point it at your teammate's Lambda function ARN.
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule = aws_cloudwatch_event_rule.nginx_alarm_rule.name

  # The ARN of your teammate's Lambda function.
  # This is currently a PLACEHOLDER — update variables.tf once
  # your teammate shares the real ARN, then re-run terraform apply.
  arn = var.lambda_function_arn

  # input_transformer customizes WHAT data gets sent to the Lambda.
  # Without this, Lambda would receive the raw, messy AWS event.
  # With this, we send a clean, simple JSON payload instead.
  input_transformer {
    # input_paths: pull specific fields OUT of the raw event
    input_paths = {
      alarmName = "$.detail.alarmName"   # e.g. "Synthetics-Alarm-nginx-health-checker-1"
      newState  = "$.detail.state.value" # e.g. "ALARM"
    }

    # input_template: build the clean JSON payload sent to Lambda,
    # using the values extracted above (referenced as <alarmName> etc.)
    input_template = jsonencode({
      alarmName  = "<alarmName>"
      newState   = "<newState>"
      instanceId = aws_instance.kumud_ec2.id # so Lambda knows WHICH EC2 to heal
      region     = var.aws_region
      source     = "kumud-eventbridge-rule"
    })
  }
}


# ------------------------------------------------------------
# RESOURCE 3: Permission for EventBridge to invoke the Lambda
# ------------------------------------------------------------
# By default, Lambda functions REJECT calls from any AWS service
# unless explicitly told otherwise. This resource grants EventBridge
# specific permission to invoke your teammate's Lambda — and ONLY
# when triggered by THIS exact rule (not any other EventBridge rule
# in the shared account).
#
# Think of it as handing EventBridge a single-use door key that
# only opens this one Lambda's door.
resource "aws_lambda_permission" "allow_eventbridge_invoke" {
  statement_id  = "AllowKumudEventBridgeInvoke" # Unique ID for this permission
  action        = "lambda:InvokeFunction"        # What EventBridge is allowed to do
  function_name = var.lambda_function_arn        # Which Lambda function
  principal     = "events.amazonaws.com"        # WHO gets this permission (EventBridge service)

  # Restrict this permission to ONLY be usable by our specific rule.
  # This prevents other EventBridge rules (maybe created by teammates)
  # from accidentally being able to invoke this same Lambda.
  source_arn = aws_cloudwatch_event_rule.nginx_alarm_rule.arn
}
