#!/bin/bash
# =============================================================
#  Web Server Setup — Run on VM1 (Target) and VM2 (Backup)
#  FYP: Design of a VM Isolation and Failover Mechanism for
#       Maintaining Service Availability During DDoS Attacks
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
    SERVER_SHORT="VM1 — Target"
    VM_IP="192.168.100.10"
else
    SERVER_NAME="Backup Web Server (VM2)"
    SERVER_SHORT="VM2 — Backup"
    VM_IP="192.168.100.20"
fi

# ── 5. Create web page (always shows ONLINE + demo/live badge) ──
mkdir -p /var/www/html
cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>VirtShield — SERVER_NAME_PLACEHOLDER</title>
  <style>
    :root {
      --bg: #0d0f14;
      --surface: #161a23;
      --border: #252b38;
      --text: #e8eaf0;
      --muted: #7a8099;
      --faint: #3a3f52;
      --green: #27c27a;
      --green-soft: #0d2e1e;
      --red: #e05c4b;
      --red-soft: #2a1510;
      --amber: #d4a017;
      --amber-soft: #251e08;
      --blue: #4a9ecf;
      --blue-soft: #0d1e2e;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body { height: 100%; }
    body {
      font-family: 'DM Sans', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: var(--bg);
      color: var(--text);
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
    }

    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 36px 44px;
      max-width: 480px;
      width: 92vw;
      text-align: center;
      box-shadow: 0 8px 40px rgba(0,0,0,.45);
    }

    /* ── Environment badge (DEMO / LIVE) ── */
    .env-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 14px;
      border-radius: 20px;
      font-size: 0.7rem;
      font-weight: 700;
      letter-spacing: .1em;
      text-transform: uppercase;
      margin-bottom: 22px;
    }
    .env-badge.demo {
      background: var(--amber-soft);
      border: 1px solid var(--amber);
      color: var(--amber);
    }
    .env-badge.live {
      background: var(--blue-soft);
      border: 1px solid var(--blue);
      color: var(--blue);
    }
    .env-dot {
      width: 7px; height: 7px;
      border-radius: 50%;
      background: currentColor;
      animation: pulse 2s infinite;
    }
    @keyframes pulse {
      0%,100% { opacity:1; transform:scale(1); }
      50%      { opacity:.5; transform:scale(.8); }
    }

    /* ── Status pill ── */
    .status-pill {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 6px 18px;
      border-radius: 24px;
      font-size: 0.78rem;
      font-weight: 700;
      letter-spacing: .06em;
      text-transform: uppercase;
      margin-bottom: 24px;
      transition: all .3s;
    }
    .status-pill.online {
      background: var(--green-soft);
      border: 1px solid var(--green);
      color: var(--green);
    }
    .status-pill.offline {
      background: var(--red-soft);
      border: 1px solid var(--red);
      color: var(--red);
    }
    .status-dot {
      width: 8px; height: 8px;
      border-radius: 50%;
      background: currentColor;
    }
    .status-dot.blink { animation: blink 1s infinite; }
    @keyframes blink {
      0%,100% { opacity:1; }
      50%      { opacity:.25; }
    }

    /* ── Server name ── */
    .server-name {
      font-size: 1.45rem;
      font-weight: 700;
      color: var(--text);
      margin-bottom: 4px;
      letter-spacing: -.01em;
    }
    .server-role {
      font-size: 0.82rem;
      color: var(--muted);
      margin-bottom: 28px;
    }

    /* ── Metric row ── */
    .metrics {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 10px;
      margin-bottom: 24px;
    }
    .metric {
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 12px 10px;
    }
    .metric-label {
      font-size: 0.65rem;
      font-weight: 600;
      color: var(--muted);
      text-transform: uppercase;
      letter-spacing: .07em;
      margin-bottom: 4px;
    }
    .metric-value {
      font-size: 1.1rem;
      font-weight: 700;
      color: var(--text);
      font-variant-numeric: tabular-nums;
    }
    .metric-value.green { color: var(--green); }
    .metric-value.red   { color: var(--red); }

    /* ── Divider ── */
    .divider {
      height: 1px;
      background: var(--border);
      margin: 20px 0;
    }

    /* ── Footer info ── */
    .footer-info {
      font-size: 0.72rem;
      color: var(--faint);
      line-height: 1.7;
    }
    .footer-info strong { color: var(--muted); }

    /* ── Uptime ticker ── */
    .uptime-row {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      font-size: 0.75rem;
      color: var(--muted);
      margin-top: 16px;
    }
    #uptime-clock {
      font-variant-numeric: tabular-nums;
      color: var(--text);
      font-weight: 600;
    }
  </style>
</head>
<body>
  <div class="card">

    <!-- Environment badge: auto-detected from hostname -->
    <div class="env-badge" id="env-badge">
      <span class="env-dot"></span>
      <span id="env-label">Detecting…</span>
    </div>

    <!-- Live status pill -->
    <div class="status-pill online" id="status-pill">
      <span class="status-dot" id="status-dot"></span>
      <span id="status-text">ONLINE</span>
    </div>

    <div class="server-name">SERVER_SHORT_PLACEHOLDER</div>
    <div class="server-role">SERVER_NAME_PLACEHOLDER · VirtShield FYP</div>

    <!-- Live resource metrics (polled from monitor agent) -->
    <div class="metrics">
      <div class="metric">
        <div class="metric-label">IP Address</div>
        <div class="metric-value" id="m-ip">VM_IP_PLACEHOLDER</div>
      </div>
      <div class="metric">
        <div class="metric-label">Port</div>
        <div class="metric-value">80 / TCP</div>
      </div>
      <div class="metric">
        <div class="metric-label">CPU Usage</div>
        <div class="metric-value" id="m-cpu">—</div>
      </div>
      <div class="metric">
        <div class="metric-label">Network In</div>
        <div class="metric-value" id="m-net">—</div>
      </div>
    </div>

    <div class="divider"></div>

    <div class="footer-info">
      <strong>Design of a VM Isolation and Failover Mechanism</strong><br>
      for Maintaining Service Availability During DDoS Attacks<br>
      <strong>Oladeji Ibrahim Olaleye</strong> · U22CYS1103<br>
      Air Force Institute of Technology, Kaduna · FYP 2026
    </div>

    <div class="uptime-row">
      <span>Page uptime:</span>
      <span id="uptime-clock">00:00:00</span>
      &nbsp;·&nbsp;
      <span>Auto-refreshing metrics</span>
    </div>

  </div>

  <script>
    // ── Environment detection ─────────────────────────────
    // Detect demo vs live by trying to reach the monitor agent.
    // If agent responds → LIVE environment; if not → DEMO.
    const AGENT_URL = 'http://' + location.hostname + ':5002/metrics';
    const badge   = document.getElementById('env-badge');
    const envLabel = document.getElementById('env-label');

    async function detectEnv() {
      try {
        const r = await fetch(AGENT_URL, { signal: AbortSignal.timeout(1500) });
        if (r.ok) {
          badge.className = 'env-badge live';
          envLabel.textContent = 'LIVE';
          return true;
        }
      } catch (_) {}
      badge.className = 'env-badge demo';
      envLabel.textContent = 'DEMO';
      return false;
    }

    // ── Metrics polling ───────────────────────────────────
    const pill = document.getElementById('status-pill');
    const dot  = document.getElementById('status-dot');
    const stxt = document.getElementById('status-text');

    function setOnline() {
      pill.className = 'status-pill online';
      dot.className  = 'status-dot';
      stxt.textContent = 'ONLINE';
    }
    function setOffline() {
      pill.className = 'status-pill offline';
      dot.className  = 'status-dot blink';
      stxt.textContent = 'OFFLINE';
    }

    function colourMetric(id, value, warnThreshold) {
      const el = document.getElementById(id);
      if (!el) return;
      el.textContent = value;
      if (warnThreshold !== null && parseFloat(value) >= warnThreshold) {
        el.className = 'metric-value red';
      } else {
        el.className = 'metric-value green';
      }
    }

    async function pollMetrics() {
      try {
        const r = await fetch(AGENT_URL, { signal: AbortSignal.timeout(1800) });
        if (!r.ok) throw new Error('bad status');
        const d = await r.json();
        setOnline();
        colourMetric('m-cpu', (d.cpu_percent ?? '—').toFixed ? d.cpu_percent.toFixed(1) + '%' : '—', 80);
        colourMetric('m-net', (d.net_mbps   ?? '—').toFixed ? d.net_mbps.toFixed(1) + ' Mbps' : '—', 50);
        // Ensure env badge stays LIVE
        if (badge.className !== 'env-badge live') {
          badge.className = 'env-badge live';
          envLabel.textContent = 'LIVE';
        }
      } catch (_) {
        // Page itself is being served (you're reading this), so service is UP
        // even if the agent isn't reachable — keep ONLINE pill.
        setOnline();
        document.getElementById('m-cpu').textContent = '—';
        document.getElementById('m-net').textContent = '—';
      }
    }

    // ── Page uptime clock ─────────────────────────────────
    const startedAt = Date.now();
    function uptimeTick() {
      const s = Math.floor((Date.now() - startedAt) / 1000);
      const h = String(Math.floor(s / 3600)).padStart(2, '0');
      const m = String(Math.floor((s % 3600) / 60)).padStart(2, '0');
      const sec = String(s % 60).padStart(2, '0');
      document.getElementById('uptime-clock').textContent = h + ':' + m + ':' + sec;
    }
    setInterval(uptimeTick, 1000);

    // ── Init ──────────────────────────────────────────────
    // The status pill starts as ONLINE immediately because if this page
    // is loading, nginx is serving it — so the server IS online.
    setOnline();
    detectEnv();
    pollMetrics();
    setInterval(pollMetrics, 3000);  // refresh every 3 s
  </script>
</body>
</html>
HTMLEOF

# Replace placeholders with actual values
sed -i "s|SERVER_NAME_PLACEHOLDER|${SERVER_NAME}|g"  /var/www/html/index.html
sed -i "s|SERVER_SHORT_PLACEHOLDER|${SERVER_SHORT}|g" /var/www/html/index.html
sed -i "s|VM_IP_PLACEHOLDER|${VM_IP}|g"              /var/www/html/index.html

# ── 6. Configure nginx ────────────────────────────────────────
cat > /etc/nginx/sites-available/default << NGINXEOF
server {
    listen 80 default_server;
    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /health {
        return 200 '{"status":"ok","server":"${ROLE}","ip":"${VM_IP}"}';
        add_header Content-Type application/json;
        add_header Access-Control-Allow-Origin *;
    }
}
NGINXEOF

nginx -t && systemctl restart nginx && systemctl enable nginx
echo "[OK] nginx configured and started on port 80"

# ── 7. Set up Monitor Agent as systemd service ───────────────
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
echo "  Index : Always shows ONLINE badge + DEMO/LIVE env badge"
echo "═══════════════════════════════════════════════"
