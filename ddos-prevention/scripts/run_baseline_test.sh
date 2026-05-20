#!/bin/bash
# =============================================================
#  Baseline Test Runner — Runs WITHOUT mitigation
#  Run on: Controller VM (VM4)
#  FYP: Prevention of DDoS Attacks with Virtualization
# =============================================================
# Usage: sudo bash run_baseline_test.sh
#
# What it does:
#   1. Verifies target VM1 is reachable
#   2. Starts availability polling (writes to CSV)
#   3. Signals attacker VM3 to start attack via SSH
#   4. Records metrics for 120 seconds
#   5. Saves results to /var/log/baseline_results.json

TARGET_IP="192.168.100.10"
ATTACK_IP="192.168.100.30"
TARGET_PORT=80
DURATION=120
LOG_DIR="/var/log/ddos-tests"
RESULT_FILE="$LOG_DIR/baseline_results.json"
AVAIL_CSV="$LOG_DIR/baseline_availability.csv"

mkdir -p "$LOG_DIR"

echo "════════════════════════════════════════════════"
echo "  BASELINE TEST (No Mitigation)"
echo "  Target: $TARGET_IP | Duration: ${DURATION}s"
echo "════════════════════════════════════════════════"

# ── Pre-check ────────────────────────────────────────────────
echo "[1/5] Checking target service..."
if ! curl -s --max-time 3 "http://$TARGET_IP" > /dev/null; then
    echo "[ERROR] Target VM1 ($TARGET_IP) is not reachable. Ensure nginx is running."
    exit 1
fi
echo "[OK]   Target is UP"

# ── Start availability polling ────────────────────────────────
echo "[2/5] Starting availability logger..."
echo "timestamp,status,response_ms" > "$AVAIL_CSV"

availability_logger() {
    while true; do
        TS=$(date +"%Y-%m-%dT%H:%M:%S")
        START=$(date +%s%N)
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://$TARGET_IP/health" 2>/dev/null)
        END=$(date +%s%N)
        MS=$(( (END - START) / 1000000 ))
        if [ "$STATUS" = "200" ]; then
            echo "$TS,UP,$MS" >> "$AVAIL_CSV"
        else
            echo "$TS,DOWN,$MS" >> "$AVAIL_CSV"
        fi
        sleep 1
    done
}
availability_logger &
AVAIL_PID=$!

# ── Start attack via SSH on VM3 ───────────────────────────────
echo "[3/5] Launching attack from VM3 ($ATTACK_IP)..."
ssh -o StrictHostKeyChecking=no root@$ATTACK_IP \
    "sudo python3 /opt/ddos-prevention/attack/attack_simulator.py \
     --target $TARGET_IP --mode mixed --threads 4 --rate 1000 \
     --duration $DURATION > /var/log/attack.log 2>&1 &"
ATTACK_LAUNCHED=$?

if [ $ATTACK_LAUNCHED -eq 0 ]; then
    echo "[OK]   Attack launched on VM3"
else
    echo "[WARN] Could not SSH to VM3 — start attack manually:"
    echo "       sudo python3 attack_simulator.py --target $TARGET_IP --duration $DURATION"
fi

# ── Wait for test duration ────────────────────────────────────
echo "[4/5] Test running for ${DURATION}s... (monitor the dashboard)"
sleep "$DURATION"

# ── Stop attack ───────────────────────────────────────────────
ssh -o StrictHostKeyChecking=no root@$ATTACK_IP "pkill -f attack_simulator.py 2>/dev/null" || true
kill $AVAIL_PID 2>/dev/null

# ── Compute results ───────────────────────────────────────────
echo "[5/5] Computing results..."

TOTAL=$(wc -l < "$AVAIL_CSV")
TOTAL=$((TOTAL - 1))  # subtract header
UP_COUNT=$(grep -c ",UP," "$AVAIL_CSV" 2>/dev/null || echo 0)
DOWN_COUNT=$(grep -c ",DOWN," "$AVAIL_CSV" 2>/dev/null || echo 0)
AVAIL_PCT=$(awk "BEGIN{printf \"%.1f\", $UP_COUNT / ($TOTAL) * 100}" 2>/dev/null || echo "0")

# Find first/last DOWN to compute downtime span
FIRST_DOWN=$(grep ",DOWN," "$AVAIL_CSV" | head -1 | cut -d',' -f1)
LAST_DOWN=$(grep ",DOWN," "$AVAIL_CSV"  | tail -1 | cut -d',' -f1)

python3 - <<PYEOF
import json, csv
from datetime import datetime

rows = []
with open("$AVAIL_CSV") as f:
    reader = csv.DictReader(f)
    for row in reader:
        rows.append(row)

# Compute downtime spans
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

if in_down and down_start:
    downtime_sec += (datetime.fromisoformat(rows[-1]['timestamp']) - down_start).total_seconds()

total = len(rows)
up    = sum(1 for r in rows if r['status'] == 'UP')
ms_vals = [float(r['response_ms']) for r in rows if r['status'] == 'UP' and float(r['response_ms']) < 5000]
avg_ms = sum(ms_vals)/len(ms_vals) if ms_vals else 0
peak_ms= max(ms_vals) if ms_vals else 0

result = {
    "scenario": "baseline",
    "total_samples":      total,
    "up_count":           up,
    "down_count":         total - up,
    "availability_pct":   round(up/total*100, 1) if total else 0,
    "downtime_seconds":   round(downtime_sec, 1),
    "avg_response_ms":    round(avg_ms, 1),
    "peak_response_ms":   round(peak_ms, 1),
    "target_met":         downtime_sec < 30,
    "test_duration_sec":  $DURATION,
}

with open("$RESULT_FILE", "w") as f:
    json.dump(result, f, indent=2)

print(f"""
  ┌─────────────────────────────────────────────┐
  │  BASELINE RESULTS                           │
  │  Availability : {result['availability_pct']}%                     │
  │  Downtime     : {result['downtime_seconds']}s                    │
  │  Avg Response : {result['avg_response_ms']}ms                   │
  │  Target met   : {'✓ YES' if result['target_met'] else '✗ NO (<30s downtime)'}              │
  └─────────────────────────────────────────────┘
""")
PYEOF

echo "[DONE] Results saved to $RESULT_FILE"
echo "       Availability CSV: $AVAIL_CSV"
