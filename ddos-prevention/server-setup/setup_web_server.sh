#!/bin/bash
# =============================================================
#  Web Server Setup — Run on VM1 (Target) and VM2 (Backup)
#  FYP: Prevention of DDoS Attacks with Virtualization
#  Author: Oladeji Ibrahim Olaleye | U22CYS1103
# =============================================================
# Usage: sudo bash setup_web_server.sh [target|backup]
# Run on VM1 for target, VM2 for backup.

set -e
ROLE=${1:-target}
echo "[INFO] Setting up $ROLE web server on Debian..."

# ── 1. Update system ─────────────────────────────────────────
apt-get update -y && apt-get upgrade -y

# ── 2. Install dependencies ───────────────────────────────────
apt-get install -y nginx python3 python3-pip net-tools curl

# ── 3. Install Python packages for monitor agent ─────────────
pip3 install flask psutil --break-system-packages 2>/dev/null || pip3 install flask psutil

# ── 4. Configure nginx ────────────────────────────────────────
if [ "$ROLE" = "target" ]; then
    SERVER_NAME="Target Web Server (VM1)"
    PORT=80
else
    SERVER_NAME="Backup Web Server (VM2)"
    PORT=80
fi

# Create demo web page
mkdir -p /var/www/html
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>FYP Demo — ${SERVER_NAME}</title>
  <style>
    body { font-family: Arial, sans-serif; background:#1a1a2e; color:#eee; 
           display:flex; align-items:center; justify-content:center; 
           height:100vh; margin:0; flex-direction:column; }
    .box { background:#16213e; padding:40px; border-radius:12px; 
           border:2px solid #0f3460; text-align:center; max-width:500px; }
    h1  { color:#e94560; margin:0 0 10px; }
    p   { color:#a8b2d8; }
    .badge { background:#0f3460; padding:6px 16px; border-radius:20px; 
             display:inline-block; margin-top:15px; font-size:0.85em; }
  </style>
</head>
<body>
  <div class="box">
    <h1>${SERVER_NAME}</h1>
    <p>Prevention of DDoS Attacks with Virtualization</p>
    <p>Oladeji Ibrahim Olaleye | U22CYS1103</p>
    <div class="badge">Air Force Institute of Technology, Kaduna</div>
  </div>
</body>
</html>
EOF

# Health check endpoint via nginx
cat > /etc/nginx/sites-available/default << NGINXEOF
server {
    listen 80 default_server;
    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /health {
        return 200 '{"status":"ok","server":"${ROLE}"}';
        add_header Content-Type application/json;
    }
}
NGINXEOF

nginx -t && systemctl restart nginx && systemctl enable nginx
echo "[OK] nginx configured and started on port 80"

# ── 5. Set up Monitor Agent as systemd service ───────────────
cp /tmp/monitor_agent.py /opt/monitor_agent.py 2>/dev/null || true

cat > /etc/systemd/system/monitor-agent.service << EOF
[Unit]
Description=DDoS Monitor Agent
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/monitor_agent.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable monitor-agent
systemctl start monitor-agent 2>/dev/null || echo "[WARN] monitor-agent not started (agent file missing at /opt/)"

echo ""
echo "═══════════════════════════════════════════════"
echo "  $ROLE web server setup complete"
echo "  Nginx : http://$(hostname -I | awk '{print $1}')"
echo "  Agent : http://$(hostname -I | awk '{print $1}'):5002/metrics"
echo "═══════════════════════════════════════════════"
