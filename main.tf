# ============================================================
# main.tf  —  PHASE 1
# ------------------------------------------------------------
# Creates exactly 3 resources:
#
#   1. aws_key_pair          → registers your SSH key with AWS
#   2. aws_security_group    → firewall: allow SSH (22) + HTTP (80)
#   3. aws_instance          → Ubuntu EC2 with Nginx auto-installed
#
# user_data.sh runs on first boot and:
#   - Installs Nginx
#   - Creates a custom homepage
#   - Drops kill_nginx.sh at /home/ubuntu/kill_nginx.sh
#   - Starts Nginx
# ============================================================


# ------------------------------------------------------------
# DATA SOURCE: Find the latest Ubuntu 22.04 AMI automatically
# ------------------------------------------------------------
# An AMI is the "operating system snapshot" used to create EC2.
# Instead of hardcoding an AMI ID (which changes per region and
# goes stale), this looks up the latest Ubuntu 22.04 dynamically.
# This is READ ONLY — it does not create anything in AWS.
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
    # jammy  = Ubuntu 22.04 LTS codename
    # amd64  = standard 64-bit architecture
    # *      = wildcard for any date suffix
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"] # Required for t2/t3 instance types
  }

  # Only use images published by Canonical (official Ubuntu publisher)
  owners = ["099720109477"]
}


# ------------------------------------------------------------
# RESOURCE 1: SSH Key Pair
# ------------------------------------------------------------
# Needed so someone can SSH into the EC2 instance during the demo
# to run kill_nginx.sh and simulate the crash.
#
# How SSH keys work:
#   - You generate a key PAIR: private key + public key
#   - Public key → goes into AWS here (like a padlock)
#   - Private key → stays on your laptop (like the key to the padlock)
#   - When you SSH, AWS checks if your private key matches → access granted
#
# Generate your key pair (run once on your laptop):
#   ssh-keygen -t rsa -b 4096 -f ~/.ssh/kumud-key
# Get the public key to paste into variables.tf:
#   cat ~/.ssh/kumud-key.pub
resource "aws_key_pair" "kumud_key" {
  key_name   = "${var.project_prefix}-key-pair" # "kumud-key-pair"
  public_key = var.my_public_key

  tags = {
    Name    = "${var.project_prefix}-key-pair"
    Project = "self-healing-infra"
    Owner   = var.project_prefix
    Phase   = "1-ec2"
  }
}


# ------------------------------------------------------------
# RESOURCE 2: Security Group (Firewall)
# ------------------------------------------------------------
# AWS blocks ALL traffic to EC2 by default.
# A Security Group is a firewall where you explicitly ALLOW
# the traffic you need.
#
# We open:
#   Port 22  → SSH  (to run kill_nginx.sh during demo)
#   Port 80  → HTTP (for browser + CloudWatch Canary in Phase 2)
resource "aws_security_group" "kumud_sg" {
  name        = "${var.project_prefix}-sg" # "kumud-sg"
  description = "Allow SSH (22) and HTTP (80) for Kumud self-healing project"

  # INBOUND: Allow SSH
  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow from any IP (fine for college demo)
  }

  # INBOUND: Allow HTTP
  # This is what the CloudWatch Synthetics Canary (Phase 2) will check.
  ingress {
    description = "HTTP access for Nginx and Canary health checks"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # OUTBOUND: Allow everything
  # EC2 needs this to download packages, reach AWS APIs, etc.
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"           # -1 = all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_prefix}-sg"
    Project = "self-healing-infra"
    Owner   = var.project_prefix
    Phase   = "1-ec2"
  }
}


# ------------------------------------------------------------
# RESOURCE 3: EC2 Instance (Ubuntu Web Server)
# ------------------------------------------------------------
# The actual Ubuntu virtual machine running in AWS Mumbai.
#
# On first boot, AWS automatically runs user_data.sh which:
#   1. Installs Nginx
#   2. Creates a custom homepage at /var/www/html/index.html
#   3. Creates kill_nginx.sh at /home/ubuntu/kill_nginx.sh
#   4. Starts the Nginx service
#
# After ~2-3 minutes, http://<public_ip> will show your website.
resource "aws_instance" "kumud_ec2" {
  ami                    = data.aws_ami.ubuntu.id        # Latest Ubuntu 22.04
  instance_type          = var.instance_type             # t2.micro
  key_name               = aws_key_pair.kumud_key.key_name
  vpc_security_group_ids = [aws_security_group.kumud_sg.id]

  # Read user_data.sh from the same folder and pass it to EC2.
  # This script runs once automatically on the very first boot.
  user_data = file("${path.module}/user_data.sh")

  # If user_data.sh changes, recreate the instance to re-run it.
  user_data_replace_on_change = true

  tags = {
    Name    = "${var.project_prefix}-ec2" # "kumud-ec2" in AWS Console
    Project = "self-healing-infra"
    Owner   = var.project_prefix
    Phase   = "1-ec2"
    Role    = "nginx-web-server"
  }
}
