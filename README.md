🚀 Self-Healing Cloud Infrastructure Project
📌 Overview
This project demonstrates an AI-driven self-healing cloud infrastructure pipeline using AWS services, Terraform, Python (boto3), and Amazon Bedrock.
Each team member is responsible for a specific module, stitched together by the central Lambda function.

👥 Team Roles & Responsibilities
Member 1: Infrastructure & Simulation – Kumud
Role: Target Environment & Alarms
Tasks:

Provision 1 EC2 instance (Ubuntu/Linux) with Nginx web server using Terraform.

Write a 2-line bash script on the instance to kill Nginx (simulate crash).

Configure CloudWatch Alarm to detect Nginx downtime.

Hook the alarm to an EventBridge Rule for triggering remediation.

Member 2: The Orchestrator – Harshad
Role: Central Lambda Logic
Tasks:

Create the AWS Lambda Function in Python.

Write the boto3-based core structure to catch EventBridge triggers.

Assemble scripts/configurations from all members into the main Lambda loop.

Member 3: The System Fixer – Vanshika
Role: Automation & Remediation
Tasks:

Attach correct IAM role to EC2 for SSM communication.

Create an SSM shell script command:

bash
sudo systemctl restart nginx
Provide Member 2 with the Python boto3 snippet to trigger this SSM command.

Member 4: The AI Engineer – Piyush
Role: GenAI Log Analyzer
Tasks:

Ensure Amazon Bedrock model access (Claude 3 Haiku).

Write a Python boto3 snippet to send raw error logs to Bedrock.

Fine-tune prompt for 3 crisp bullet-point explanations in plain English.

Member 5: The Messenger
Role: S3 Storage & Discord Alerts
Tasks:

Create an Amazon S3 bucket for audit logs.

Set up an SNS Topic with Discord/Slack Webhook integration.

Write Python code for Lambda to:

Upload AI report to S3.

Send status link via SNS → Discord channel.

⚙️ Tech Stack
AWS Services: EC2, CloudWatch, EventBridge, Lambda, SSM, Bedrock, S3, SNS

Languages: Python (boto3), Bash

IaC Tool: Terraform

📂 Project Flow
EC2 + Nginx → Crash simulated via bash script.

CloudWatch Alarm → Detects downtime.

EventBridge Rule → Triggers Lambda.

Lambda Function → Orchestrates remediation + AI analysis.

SSM Command → Restarts Nginx service.

Bedrock AI → Generates human-readable incident report.

S3 + SNS