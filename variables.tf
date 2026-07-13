# ============================================================
# variables.tf
# ------------------------------------------------------------
# All configurable settings in one place.
# Change a value here and it updates everywhere automatically.
# ============================================================

variable "aws_region" {
  description = "AWS region where all resources will be created"
  type        = string
  default     = "ap-south-1" # Mumbai
}

variable "project_prefix" {
  description = "Prefix added to every resource name to avoid conflicts in shared account"
  type        = string
  default     = "kumud"
  # All resources will be named: kumud-ec2, kumud-sg, kumud-key-pair, etc.
  # This prevents name collisions with your teammates' resources.
}

variable "instance_type" {
  description = "EC2 instance size"
  type        = string
  default     = "t3.micro" # 1 vCPU, 1GB RAM — free tier eligible
}

variable "my_public_key" {
  description = "Contents of your SSH public key (~/.ssh/kumud-key.pub)"
  type        = string
  default     ="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCXHnDh6sSgllpA8VH1huSs1zAYMzh5Mdf3rl2xSEEFfhLrF2yiY9yroRa0uPeGdFbP7/OrE40bBXLoGGzpabnn8lkT1PASwKfjAXZEkQvBtH0Xr5rM5bOPDpaHq9f1tyVcqVH9VgpLxgykvlM8eQ/wf/n8IqA1yrNXBoh2AmqCH+3YeTFzuH5v6i325lMViTblltisgvTIpkjF8IN01BaAbUoLHUcjQsmo4/pnjiNrfSouwmEWC8ERondmFKIXGkocJmjtrGLmoW005O5iReyePNn3spkuGdyvyz10cxqQISlwGkfviTuu21Qya2gleazcxelXzRUS33tVga5zkW3Jwd0lYThknf2IbbKMxYpuJEBSxtk7IAkxhEdxZQ4j6MF/Lb7k/3dXCdXuqp9FtKY9s2FM9WBDSHAFrM7u/Bp2qvYyx7ssWzQupzejZguVDLsskWf0dtkSjw7a14fKk15rfSiVhUN1zVtNB0hNfb1Ys1RYWWZHTsWDVteM1xHEfIFvOlJClQHmLv6+iqF9fezpXskLxHRlAlvVWN29MyqI3TnSjzqlc4TDa5HnN5ZzMz6poq9aloCU/lis1ptJ8PLQHX2RGmxPqdMT3AQrzSuVIrR6YO8PiqggpmYMkN5cI6Ndqk51hwcBR/zQLeaInTfF2q1NLpyWZBRDJ9dEv4vvTQ== kojab@Rocky"
  # HOW TO GENERATE:
  #   ssh-keygen -t rsa -b 4096 -f ~/.ssh/kumud-key
  # HOW TO GET THE VALUE TO PASTE:
  #   cat ~/.ssh/kumud-key.pub
}

# --------------------------
# PHASE 2 — EventBridge Variables
# --------------------------

# The exact name of the CloudWatch Alarm created by the Canary
# (via AWS Console). Find this at: CloudWatch → Alarms.
variable "cloudwatch_alarm_name" {
  description = "Exact name of the CloudWatch Alarm created by the Synthetics Canary"
  type        = string
  default     = "Synthetics-Alarm-nginx-health-checker-1"
}

variable "alert_email" {
  description = "Email address to receive incident alerts via SNS"
  type        = string
  default     = "[EMAIL_ADDRESS]" # Replace with actual email
}
