# ============================================================
# outputs.tf  —  PHASE 1
# ------------------------------------------------------------
# Values printed to terminal after "terraform apply" finishes.
# These are the key details you need right after deployment.
# ============================================================

output "ec2_instance_id" {
  description = "EC2 Instance ID — share this with your teammates"
  value       = aws_instance.kumud_ec2.id
  # e.g. i-0a1b2c3d4e5f67890
}

output "ec2_public_ip" {
  description = "Public IP of your EC2 instance"
  value       = aws_instance.kumud_ec2.public_ip
}

output "website_url" {
  description = "Open this in your browser to verify Nginx is running"
  value       = "http://${aws_instance.kumud_ec2.public_ip}"
}

output "ssh_command" {
  description = "SSH command to log into EC2 and run kill_nginx.sh"
  value       = "ssh -i ~/.ssh/kumud-key ubuntu@${aws_instance.kumud_ec2.public_ip}"
}

output "kill_script_location" {
  description = "Path of kill_nginx.sh on the EC2 instance"
  value       = "/home/ubuntu/kill_nginx.sh"
}

output "crash_simulation_command" {
  description = "Run this AFTER SSHing in to simulate the Nginx crash"
  value       = "sudo bash /home/ubuntu/kill_nginx.sh"
}

output "phase1_checklist" {
  description = "Verification steps after deployment"
  value       = <<-EOT

    ============================================================
     PHASE 1 DEPLOYED — VERIFY BEFORE MOVING TO PHASE 2
    ============================================================

     Step 1: Wait 2-3 minutes for user_data.sh to finish

     Step 2: Open in browser →  http://${aws_instance.kumud_ec2.public_ip}
             Expected: Custom Nginx homepage ✅

     Step 3: SSH in →  ssh -i ~/.ssh/kumud-key ubuntu@${aws_instance.kumud_ec2.public_ip}

     Step 4: Confirm kill_nginx.sh exists on the instance:
             ls -la /home/ubuntu/kill_nginx.sh  ✅

     Step 5: Confirm Nginx is running:
             sudo systemctl status nginx  ✅

     Step 6: Test the crash simulation:
             sudo bash /home/ubuntu/kill_nginx.sh
             → Website should now fail to load ✅

     Step 7: Restart Nginx (undo crash before Phase 2):
             sudo systemctl start nginx

     ✅ All steps passing → ready for Phase 2
    ============================================================
  EOT
}

# ----------------------------------
# PHASE 2 — EventBridge Outputs
# ----------------------------------

output "eventbridge_rule_name" {
  description = "Name of the EventBridge Rule watching the alarm"
  value       = aws_cloudwatch_event_rule.nginx_alarm_rule.name
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge Rule (share with teammate if needed)"
  value       = aws_cloudwatch_event_rule.nginx_alarm_rule.arn
}

output "phase2_checklist" {
  description = "Verification steps for Phase 2"
  value       = <<-EOT

    ============================================================
     PHASE 2 DEPLOYED — EVENTBRIDGE RULE ACTIVE
    ============================================================

     ⚠️  IMPORTANT: lambda_function_arn is currently a PLACEHOLDER.
         Update variables.tf with the real ARN once your teammate
         shares it, then re-run: terraform apply

     Verify the rule exists:
       AWS Console → EventBridge → Rules → kumud-alarm-state-change

     Test the full chain (once real Lambda ARN is set):
       1. SSH in → sudo bash /home/ubuntu/kill_nginx.sh
       2. Wait 1-2 min → Canary fails → Alarm goes to ALARM state
       3. Check EventBridge Rule → Monitoring tab → Invocations should increase
       4. Check teammate's Lambda → CloudWatch Logs → should show execution

     ✅ Your scope (EC2 → kill script → EventBridge) is now complete.
    ============================================================
  EOT
}
