# ------------------------------------------------------------
# Zip up Harshad's Python code so Lambda can accept it
# ------------------------------------------------------------
data "archive_file" "orchestrator_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

# ------------------------------------------------------------
# IAM Role — this is what lets the Lambda call SSM/Bedrock/S3/SNS
# (This is DIFFERENT from ec2_ssm_role in iam.tf — that one is for
# the EC2 instance, this one is for the Lambda function itself)
# ------------------------------------------------------------
resource "aws_iam_role" "orchestrator_lambda_role" {
  name = "${var.project_prefix}-orchestrator-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Lets the Lambda write logs to CloudWatch (basic requirement for every Lambda)
resource "aws_iam_role_policy_attachment" "orchestrator_basic_logs" {
  role       = aws_iam_role.orchestrator_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lets the Lambda actually run SSM commands, call Bedrock, write to S3, publish to SNS
resource "aws_iam_role_policy_attachment" "orchestrator_ssm" {
  role       = aws_iam_role.orchestrator_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMFullAccess"
}

resource "aws_iam_role_policy_attachment" "orchestrator_bedrock" {
  role       = aws_iam_role.orchestrator_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
}

resource "aws_iam_role_policy_attachment" "orchestrator_s3" {
  role       = aws_iam_role.orchestrator_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "orchestrator_sns" {
  role       = aws_iam_role.orchestrator_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
}

# ------------------------------------------------------------
# THE ACTUAL LAMBDA FUNCTION — this replaces the cwsyn- placeholder
# ------------------------------------------------------------
resource "aws_lambda_function" "orchestrator" {
  function_name    = "${var.project_prefix}-self-healing-orchestrator"
  role              = aws_iam_role.orchestrator_lambda_role.arn
  handler           = "lambda_function.lambda_handler"
  runtime           = "python3.12"
  timeout           = 120
  filename          = data.archive_file.orchestrator_zip.output_path
  source_code_hash  = data.archive_file.orchestrator_zip.output_base64sha256

  environment {
    variables = {
      INCIDENT_BUCKET = "PLACEHOLDER_BUCKET"   # Member 5 will replace this later
      SNS_TOPIC_ARN    = "PLACEHOLDER_SNS_ARN"  # Member 5 will replace this later
      TARGET_INSTANCE_ID  = aws_instance.kumud_ec2.id
    }
  }
}