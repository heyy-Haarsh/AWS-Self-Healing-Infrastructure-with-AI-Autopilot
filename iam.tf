# ------------------------------------------------------------
# RESOURCE 1: IAM Role for EC2
# ------------------------------------------------------------
# This role is assumed by the EC2 instance.
#
# The assume_role_policy (Trust Policy) specifies WHO is allowed
# to assume this role.
#
# Here we allow only the EC2 service to use this role.

resource "aws_iam_role" "ec2_ssm_role" {

  name = "${var.project_prefix}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# ------------------------------------------------------------
# RESOURCE 2: Attach Systems Manager Policy
# ------------------------------------------------------------
# By default, the IAM Role has NO permissions.
#
# This attaches AWS's managed policy:
#
#   AmazonSSMManagedInstanceCore
#
# which allows the EC2 instance to:
#   • Register with AWS Systems Manager
#   • Receive Run Command requests
#   • Send command output back to AWS

resource "aws_iam_role_policy_attachment" "ssm_policy" {

  role = aws_iam_role.ec2_ssm_role.name

  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ------------------------------------------------------------
# RESOURCE 3: IAM Instance Profile
# ------------------------------------------------------------
# EC2 instances cannot directly use an IAM Role.
#
# AWS requires an Instance Profile, which acts as a container
# for the IAM Role and is attached to the EC2 instance.
#
# This Instance Profile will later be referenced inside
# aws_instance.kumud_ec2 using:
#
# iam_instance_profile = aws_iam_instance_profile.ec2_ssm_profile.name

resource "aws_iam_instance_profile" "ec2_ssm_profile" {

  name = "${var.project_prefix}-ec2-ssm-profile"

  role = aws_iam_role.ec2_ssm_role.name
}