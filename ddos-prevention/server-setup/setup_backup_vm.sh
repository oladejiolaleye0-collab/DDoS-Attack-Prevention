#!/usr/bin/env bash
# =============================================================================
# VirtShield - VM2 Backup/Failover Node Setup
# Author : Oladeji Ibrahim Olaleye | U22CYS1103
# Purpose: Provision VM2 (192.168.100.20) as a hot-standby web server
#          that accepts DNAT failover traffic from the controller (VM4)
#          when VM1 is isolated during a DDoS experiment.
#
# Usage  : sudo bash setup_backup_vm.sh
# Host   : Ubuntu 22.04 LTS (VMware VMnet1 host-only)
# IP     : 192.168.100.20 / 24   GW: 192.168.100.1
# =============================================================================
set -euo pipefail

VM_IP="192.168.100.20"
CONTROLLER_IP="192.168.100.40"
NGINX_PORT=80
LOG="/var/log/virtshield-setup.log"

exec > >(tee -a "$LOG") 2>&1
echo "[$(date)] === VM2 Backup Node Setup Starting ==="

# 1. Static IP (netplan)
NETCFG="/etc/netplan/01-virtshield.yaml"
cat > "$NETCFG" <<EOF
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      addresses:
        - ${VM_IP}/24
      gateway4: 192.168.100.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF
chmod 600 "$NETCFG"
netplan apply
echo "[OK] Static IP set to ${VM_IP}"

# 2. System update & packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx python3 python3-pip curl ufw net-tools
echo "[OK] Packages installed"

# 3. Nginx - identical web content as VM1 (hot-standby)
WWW="/var/www/html"
mkdir -p "$WWW"
cat > "${WWW}/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>VirtShield - Backup Service (VM2)</title>
</head>
<body>
  <h1>VirtShield Backup Node (VM2)</h1>
  <p>Failover active. VM1 has been isolated. Mitigation pipeline running.</p>
  <p>Air Force Institute of Technology | FYP 2026 | U22CYS1103</p>
</body>
</html>
HTMLEOF

cat > /etc/nginx/sites-available/virtshield <<NGEOF
server {
    listen ${NGINX_PORT};
    server_name ${VM_IP};
    root ${WWW};
    index index.html;
    access_log /var/log/nginx/virtshield-access.log;
    error_log  /var/log/nginx/virtshield-error.log;
    location / { try_files \$uri \$uri/ =404; }
    location /health {
        access_log off;
        return 200 '{"vm":"vm2","role":"backup","status":"up"}';
        add_header Content-Type application/json;
    }
}
NGEOF

ln -sf /etc/nginx/sites-available/virtshield /etc/nginx/sites-enabled/virtshield
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl restart nginx
echo "[OK] Nginx configured on port ${NGINX_PORT}"

# 4. Python agent dependencies
pip3 install --quiet psutil flask flask-cors python-json-logger
echo "[OK] Python packages installed"

# 5. Firewall
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow ${NGINX_PORT}/tcp comment "HTTP web service"
ufw allow from "${CONTROLLER_IP}" to any port 9102 comment "VirtShield controller"
ufw --force enable
echo "[OK] UFW firewall configured"

# 6. Monitor agent - expose /metrics on :9102
AGENT_DIR="/opt/virtshield"
mkdir -p "$AGENT_DIR"

cat > "${AGENT_DIR}/agent.py" <<'PYEOF'
#!/usr/bin/env python3
"""
VirtShield VM2 Monitor Agent
Exposes /metrics (JSON) and /health on port 9102.
"""
import time, json, psutil
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = 9102

def collect_metrics():
    cpu  = psutil.cpu_percent(interval=0.5)
    net  = psutil.net_io_counters()
    mem  = psutil.virtual_memory()
    return {
        "ts":        time.time(),
        "vm":        "vm2",
        "role":      "backup",
        "ip":        "192.168.100.20",
        "cpu_pct":   cpu,
        "mem_pct":   mem.percent,
        "net_in_mb": round(net.bytes_recv / 1e6, 2),
        "status":    "standby"
    }

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path in ("/metrics", "/health"):
            data = json.dumps(collect_metrics()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    print(f"[VirtShield] VM2 agent listening on :{PORT}")
    HTTPServer(("", PORT), Handler).serve_forever()
PYEOF

chmod +x "${AGENT_DIR}/agent.py"

cat > /etc/systemd/system/virtshield-agent.service <<SVCEOF
[Unit]
Description=VirtShield VM2 Monitor Agent
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${AGENT_DIR}/agent.py
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable virtshield-agent
systemctl start virtshield-agent
echo "[OK] VirtShield agent service started on :9102"

# 7. Verify
echo ""
echo "=== VM2 Setup Complete ==="
echo "  IP          : ${VM_IP}"
echo "  Role        : Hot-standby / Failover"
echo "  Web service : http://${VM_IP}:${NGINX_PORT}"
echo "  Agent API   : http://${VM_IP}:9102/metrics"
curl -s "http://localhost:${NGINX_PORT}/health" && echo "  [OK] Nginx health OK"
curl -s "http://localhost:9102/health" | python3 -m json.tool && echo "  [OK] Agent OK"
echo "[$(date)] === Setup Finished ==="
