#!/bin/bash
# ============================================================
# user_data.sh
# ------------------------------------------------------------
# Runs automatically on first EC2 boot. Does 5 things:
#   1. Update Ubuntu package list
#   2. Install Nginx
#   3. Create a custom homepage
#   4. Drop kill_nginx.sh onto the instance
#   5. Start Nginx
# ============================================================

set -e
exec > /var/log/user_data.log 2>&1

echo "=================================================="
echo "  EC2 bootstrap started: $(date)"
echo "=================================================="

# ----------------------------------------------------------
# STEP 1: Update package list
# ----------------------------------------------------------
echo "[STEP 1/5] Updating package list..."
apt-get update -y
echo "[STEP 1/5] Done."

# ----------------------------------------------------------
# STEP 2: Install Nginx
# ----------------------------------------------------------
echo "[STEP 2/5] Installing Nginx..."
apt-get install -y nginx
echo "[STEP 2/5] Nginx installed."

# ----------------------------------------------------------
# STEP 3: Create a custom homepage
# ----------------------------------------------------------
echo "[STEP 3/5] Creating custom homepage..."
cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Kumud | Self-Healing Infrastructure Demo</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: 'Segoe UI', Arial, sans-serif;
      background: #0d1117;
      color: #c9d1d9;
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 100vh;
    }
    .card {
      background: #161b22;
      border: 1px solid #30363d;
      border-radius: 12px;
      padding: 48px 40px;
      max-width: 560px;
      text-align: center;
    }
    .badge {
      display: inline-block;
      background: #238636;
      color: #fff;
      font-size: 0.75em;
      padding: 4px 12px;
      border-radius: 20px;
      margin-bottom: 20px;
    }
    h1 { font-size: 1.8em; color: #f0f6fc; margin-bottom: 8px; }
    h2 { font-size: 1.1em; color: #8b949e; font-weight: 400; margin-bottom: 24px; }
    .status {
      background: #0d1117;
      border: 1px solid #238636;
      border-radius: 8px;
      padding: 16px;
      margin: 20px 0;
      font-size: 1.1em;
      color: #3fb950;
    }
    .info { font-size: 0.85em; color: #6e7681; line-height: 1.8; margin-top: 20px; }
    .info span { color: #58a6ff; }
  </style>
</head>
<body>
  <div class="card">
    <div class="badge">● NGINX RUNNING</div>
    <h1>🛡️ Self-Healing Infrastructure</h1>
    <h2>AI Autopilot — College Project Demo</h2>
    <div class="status">✅ Website Status: <strong>ONLINE</strong></div>
    <div class="info">
      <p>Owner: <span>Kumud</span> &nbsp;|&nbsp; Region: <span>ap-south-1</span></p>
      <p>Role: <span>Member 1 — Infrastructure & Simulation</span></p>
      <br>
      <p>Monitored by <span>CloudWatch Synthetics Canary</span></p>
      <p>Nginx down → Canary fails → Alarm → EventBridge → Lambda heals</p>
    </div>
  </div>
</body>
</html>
EOF
echo "[STEP 3/5] Homepage created."

# ----------------------------------------------------------
# STEP 4: Drop kill_nginx.sh onto the instance
# ----------------------------------------------------------
# This is the 2-line crash simulation script.
# It will live at /home/ubuntu/kill_nginx.sh on the server.
# During the demo, someone SSHs in and runs:
#   sudo bash /home/ubuntu/kill_nginx.sh
echo "[STEP 4/5] Creating kill_nginx.sh on the instance..."

cat > /home/ubuntu/kill_nginx.sh << 'EOF'
#!/bin/bash
systemctl stop nginx
echo "Nginx stopped. Website is now DOWN. CloudWatch Canary will detect this failure."
EOF

# Make the script executable so it can be run directly
chmod +x /home/ubuntu/kill_nginx.sh

echo "[STEP 4/5] kill_nginx.sh created at /home/ubuntu/kill_nginx.sh"

# ----------------------------------------------------------
# STEP 5: Start Nginx and enable auto-start on reboot
# ----------------------------------------------------------
echo "[STEP 5/5] Starting Nginx..."
systemctl start nginx
systemctl enable nginx
echo "[STEP 5/5] Nginx started and enabled."

# ----------------------------------------------------------
# Done
# ----------------------------------------------------------
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "=================================================="
echo "  Bootstrap complete: $(date)"
echo "  Website: http://$PUBLIC_IP"
echo "  Crash script: /home/ubuntu/kill_nginx.sh"
echo "=================================================="
