#!/bin/bash
# =============================================================
#  Mitigated Test Runner — Runs WITH full mitigation active
#  Run on: Controller VM (VM4)
#  FYP: Prevention of DDoS Attacks with Virtualization
# =============================================================
TARGET_IP="192.168.100.10"
BACKUP_IP="192.168.100.20"
ATTACK_IP="192.168.100.30"
TARGET_PORT=80
DURATION=120
LOG_DIR="/var/log/ddos-tests"
RESULT_FILE="$LOG_DIR/mitigated_results.json"
AVAIL_CSV="$LOG_DIR/mitigated_availability.csv"

mkdir -p "$LOG_DIR"

echo "════════════════════════════════════════════════"
echo "  MITIGATED TEST (Full virtualization defence)"
echo "  Target: $TARGET_IP | Backup: $BACKUP_IP"
echo "  Duration: ${DURATION}s"
echo "════════════════════════════════════════════════"

# ── Ensure clean state ────────────────────────────────────────
echo "[1/6] Resetting mitigation state..."
curl -s -X POST http://localhost:5001/api/reset > /dev/null 2>&1 || true
# Restore target VM if suspended
python3 /opt/ddos-prevention/mitigation/mitigate.py --action restore 2>/dev/null || true
sleep 3

# ── Pre-check ────────────────────────────────────────────────
echo "[2/6] Checking target service..."
if ! curl -s --max-time 3 "http://$TARGET_IP" > /dev/null; then
    echo "[ERROR] Target VM1 is not reachable."
    exit 1
fi
echo "[OK]   Target is UP"

# ── Start monitor daemon ──────────────────────────────────────
echo "[3/6] Starting monitor & detection module..."
pkill -f "monitor.py" 2>/dev/null || true
python3 /opt/ddos-prevention/monitor/monitor.py &
MONITOR_PID=$!
sleep 2
echo "[OK]   Monitor running (PID $MONITOR_PID)"

# ── Availability polling (polls whichever VM is active) ──────
echo "[4/6] Starting availability logger (follows failover)..."
echo "timestamp,status,response_ms,active_vm" > "$AVAIL_CSV"

availability_logger_mitigated() {
    ACTIVE="$TARGET_IP"
    while true; do
        TS=$(date +"%Y-%m-%dT%H:%M:%S")
        START=$(date +%s%N)
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://$ACTIVE/health" 2>/dev/null)
        END=$(date +%s%N)
        MS=$(( (END - START) / 1000000 ))

        # Check if mitigation switched to backup
        CURRENT_VM=$(curl -s --max-time 1 http://localhost:5001/api/state 2>/dev/null | \
                     python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('current_active_vm','target'))" 2>/dev/null || echo "target")
        if [ "$CURRENT_VM" = "backup" ]; then
            ACTIVE="$BACKUP_IP"
        fi

        if [ "$STATUS" = "200" ]; then
            echo "$TS,UP,$MS,$ACTIVE" >> "$AVAIL_CSV"
        else
            echo "$TS,DOWN,$MS,$ACTIVE" >> "$AVAIL_CSV"
        fi
        sleep 1
    done
}
availability_logger_mitigated &
AVAIL_PID=$!

# ── Launch attack ─────────────────────────────────────────────
echo "[5/6] Launching attack from VM3..."
ssh -o StrictHostKeyChecking=no root@$ATTACK_IP \
    "sudo python3 /opt/ddos-prevention/attack/attack_simulator.py \
     --target $TARGET_IP --mode mixed --threads 4 --rate 1000 \
     --duration $DURATION > /var/log/attack.log 2>&1 &" || \
    echo "[WARN] Could not SSH to VM3 — start attack manually"

echo "      Monitor will auto-trigger mitigation when thresholds are breached."
echo "      Watch the dashboard at http://192.168.100.40:5001 (or open index.html)"

sleep "$DURATION"

# ── Stop ─────────────────────────────────────────────────────
ssh -o StrictHostKeyChecking=no root@$ATTACK_IP "pkill -f attack_simulator.py 2>/dev/null" || true
kill $AVAIL_PID 2>/dev/null
kill $MONITOR_PID 2>/dev/null

# ── Fetch timing results from monitor API ────────────────────
echo "[6/6] Computing results..."
SUMMARY=$(curl -s http://localhost:5001/api/summary 2>/dev/null || echo '{}')

python3 - <<PYEOF
import json, csv
from datetime import datetime

summary = json.loads('$SUMMARY' or '{}')

rows = []
with open("$AVAIL_CSV") as f:
    reader = csv.DictReader(f)
    for row in reader:
        rows.append(row)

downtime_sec = 0
in_down = False
down_start = None
for r in rows:
    if r['status'] == 'DOWN':
        if not in_down:
            down_start = datetime.fromisoformat(r['timestamp'])
            in_down = True
    else:
        if in_down and down_start:
            downtime_sec += (datetime.fromisoformat(r['timestamp']) - down_start).total_seconds()
            in_down = False

total = len(rows)
up    = sum(1 for r in rows if r['status'] == 'UP')
ms_v  = [float(r['response_ms']) for r in rows if r['status'] == 'UP' and float(r['response_ms']) < 5000]
avg_ms= sum(ms_v)/len(ms_v) if ms_v else 0

result = {
    "scenario":               "mitigated",
    "total_samples":          total,
    "up_count":               up,
    "down_count":             total - up,
    "availability_pct":       round(up/total*100, 1) if total else 0,
    "downtime_seconds":       round(downtime_sec, 1),
    "avg_response_ms":        round(avg_ms, 1),
    "time_to_mitigation_sec": summary.get("time_to_mitigation_sec"),
    "failover_done":          summary.get("failover_done", False),
    "target_met":             downtime_sec < 30,
    "test_duration_sec":      $DURATION,
}

with open("$RESULT_FILE", "w") as f:
    json.dump(result, f, indent=2)

print(f"""
  ┌─────────────────────────────────────────────┐
  │  MITIGATED RESULTS                          │
  │  Availability : {result['availability_pct']}%                     │
  │  Downtime     : {result['downtime_seconds']}s                    │
  │  Avg Response : {result['avg_response_ms']}ms                   │
  │  TTM          : {result['time_to_mitigation_sec']}s              │
  │  Failover     : {'YES' if result['failover_done'] else 'NO'}                        │
  │  Target met   : {'✓ YES' if result['target_met'] else '✗ NO (<30s)'}              │
  └─────────────────────────────────────────────┘
""")
PYEOF

echo "[DONE] Results saved to $RESULT_FILE"
