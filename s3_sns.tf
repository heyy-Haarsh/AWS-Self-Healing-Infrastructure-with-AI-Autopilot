# ------------------------------------------------------------
# RESOURCE: S3 Bucket (Incident Audit Vault)
# ------------------------------------------------------------
resource "aws_s3_bucket" "incident_vault" {
  bucket = "${var.project_prefix}-nginx-incident-vault-${random_string.suffix.result}"
}

resource "aws_s3_bucket_versioning" "incident_vault_versioning" {
  bucket = aws_s3_bucket.incident_vault.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "incident_vault_pab" {
  bucket = aws_s3_bucket.incident_vault.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------
# RESOURCE: SNS Topic (Email Alerts)
# ------------------------------------------------------------
resource "aws_sns_topic" "incident_alerts" {
  name = "${var.project_prefix}-nginx-incident-alerts"
}

# ------------------------------------------------------------
# RESOURCE: SNS Email Subscription
# ------------------------------------------------------------
# IMPORTANT: AWS will send a confirmation email to this address upon creation.
# You MUST manually click "Confirm subscription" in that email before
# any incident alerts will be delivered.
resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.incident_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# (Optional) Random string for globally unique S3 bucket name
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}
