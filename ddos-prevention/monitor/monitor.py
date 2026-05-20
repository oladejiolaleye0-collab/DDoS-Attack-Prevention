#!/usr/bin/env python3
"""
=============================================================
  Monitoring & Detection Module — Controller Node (VM4)
  FYP: Prevention of DDoS Attacks with Virtualization
  Author: Oladeji Ibrahim Olaleye | U22CYS1103
=============================================================
Run on: Controller VM (VM4)
Usage : python3 monitor.py
Exposes: REST API on port 5001 for dashboard consumption
"""

import os
import time
import json
import threading
import subprocess
import socket
from datetime import datetime
from collections import deque
from flask import Flask, jsonify
import psutil

# ─────────────────────────────────────────────
#  Configuration
# ─────────────────────────────────────────────
TARGET_IP       = os.getenv("TARGET_IP",  "192.168.100.10")   # VM1
BACKUP_IP       = os.getenv("BACKUP_IP",  "192.168.100.20")   # VM2
CONTROLLER_IP   = os.getenv("CTRL_IP",    "192.168.100.40")   # VM4 (self)
TARGET_PORT     = int(os.getenv("TARGET_PORT", "80"))

# Detection thresholds
CPU_THRESHOLD       = float(os.getenv("CPU_THRESH",   "80.0"))   # %
NET_THRESHOLD_MBPS  = float(os.getenv("NET_THRESH",   "50.0"))   # Mbps inbound
TRIGGER_WINDOW_SEC  = int(os.getenv("TRIGGER_WIN",    "10"))     # seconds both must be above
POLL_INTERVAL_SEC   = float(os.getenv("POLL_INTERVAL", "2.0"))   # collection interval

# Mitigation callback (import from mitigation module)
MITIGATION_SCRIPT = os.path.join(os.path.dirname(__file__), "../mitigation/mitigate.py")

# Shared state
state = {
    "attack_detected": False,
    "mitigation_active": False,
    "failover_done": False,
    "downtime_start": None,
    "downtime_end": None,
    "detection_time": None,
    "mitigation_start_time": None,
    "mitigation_end_time": None,
    "current_active_vm": "target",  # 'target' or 'backup'
}

# Rolling history buffers (last 60 samples → ~2 min at 2s poll)
HISTORY_LEN = 300
cpu_history  = deque(maxlen=HISTORY_LEN)
net_history  = deque(maxlen=HISTORY_LEN)
avail_history= deque(maxlen=HISTORY_LEN)
events       = deque(maxlen=100)
above_cpu_since  = None
above_net_since  = None
mitigation_lock  = threading.Lock()

app = Flask(__name__)


# ─────────────────────────────────────────────
#  Logging helpers
# ─────────────────────────────────────────────
def log(msg, level="INFO"):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] [{level}] {msg}"
    print(line)
    events.appendleft({"ts": ts, "level": level, "msg": msg})
    try:
        with open("/var/log/ddos_monitor.log", "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


# ─────────────────────────────────────────────
#  Network metric helpers
# ─────────────────────────────────────────────
def get_net_mbps(iface="eth0"):
    """Return inbound Mbps on iface since last call (delta)."""
    try:
        stats1 = psutil.net_io_counters(pernic=True).get(iface)
        if not stats1:
            # Try any interface
            all_stats = psutil.net_io_counters(pernic=True)
            iface = [k for k in all_stats if k != "lo"][0]
            stats1 = all_stats[iface]
        time.sleep(1)
        stats2 = psutil.net_io_counters(pernic=True).get(iface, None)
        if stats2 is None:
            return 0.0
        bytes_recv_delta = stats2.bytes_recv - stats1.bytes_recv
        return (bytes_recv_delta * 8) / 1_000_000  # bits → Mbps
    except Exception:
        return 0.0


def check_service_up(ip, port, timeout=2):
    """Returns True if the HTTP service on ip:port is reachable."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        result = s.connect_ex((ip, port))
        s.close()
        return result == 0
    except Exception:
        return False


def get_cpu_of_target():
    """
    SSH-less approximation: since Controller VM can't directly call psutil
    on a remote VM without an agent, we use the ping round-trip time as a
    proxy for load. In production, deploy a lightweight agent on each VM.
    For demo: Controller runs psutil on itself OR you deploy monitor_agent.py
    on each VM and collect via HTTP.
    """
    # Try to fetch from target agent (monitor_agent.py must run on VM1)
    try:
        import urllib.request
        url = f"http://{TARGET_IP}:5002/metrics"
        with urllib.request.urlopen(url, timeout=2) as resp:
            data = json.loads(resp.read())
            return data.get("cpu_percent", 0.0), data.get("net_mbps", 0.0)
    except Exception:
        return None, None


# ─────────────────────────────────────────────
#  Trigger mitigation
# ─────────────────────────────────────────────
def trigger_mitigation():
    with mitigation_lock:
        if state["mitigation_active"]:
            return
        state["mitigation_active"] = True
        state["mitigation_start_time"] = datetime.now().isoformat()
    log("ATTACK CONFIRMED — triggering mitigation pipeline", "ALERT")
    try:
        result = subprocess.run(
            ["python3", MITIGATION_SCRIPT, "--action", "full"],
            capture_output=True, text=True, timeout=60
        )
        log(f"Mitigation output: {result.stdout.strip()}", "INFO")
        if result.returncode == 0:
            state["mitigation_end_time"] = datetime.now().isoformat()
            state["failover_done"] = True
            state["current_active_vm"] = "backup"
            log("Mitigation complete — backup VM now serving traffic", "SUCCESS")
        else:
            log(f"Mitigation error: {result.stderr.strip()}", "ERROR")
    except Exception as e:
        log(f"Failed to trigger mitigation: {e}", "ERROR")


# ─────────────────────────────────────────────
#  Core monitoring loop
# ─────────────────────────────────────────────
def monitoring_loop():
    global above_cpu_since, above_net_since
    log(f"Monitoring loop started | target={TARGET_IP}:{TARGET_PORT}")
    log(f"Thresholds: CPU>{CPU_THRESHOLD}% | Net>{NET_THRESHOLD_MBPS}Mbps "
        f"sustained for {TRIGGER_WINDOW_SEC}s")

    while True:
        ts = datetime.now().isoformat()
        now = time.time()

        # ── Collect metrics ──────────────────────────────
        cpu_pct, net_mbps = get_cpu_of_target()

        # Fallback: if no remote agent, monitor local CPU (for demo on single machine)
        if cpu_pct is None:
            cpu_pct = psutil.cpu_percent(interval=None)
            net_mbps = get_net_mbps()

        service_up = check_service_up(TARGET_IP, TARGET_PORT)

        cpu_history.appendleft({"ts": ts, "value": round(cpu_pct, 1)})
        net_history.appendleft({"ts": ts, "value": round(net_mbps, 2)})
        avail_history.appendleft({"ts": ts, "value": 1 if service_up else 0})

        # ── Downtime tracking ────────────────────────────
        if not service_up and state["downtime_start"] is None and not state["failover_done"]:
            state["downtime_start"] = ts
            log(f"Service UNAVAILABLE detected @ {ts}", "WARN")
        elif service_up and state["downtime_start"] and state["downtime_end"] is None:
            state["downtime_end"] = ts
            log(f"Service RESTORED @ {ts}", "INFO")

        # ── Threshold breach tracking ────────────────────
        if cpu_pct > CPU_THRESHOLD:
            if above_cpu_since is None:
                above_cpu_since = now
        else:
            above_cpu_since = None

        if net_mbps > NET_THRESHOLD_MBPS:
            if above_net_since is None:
                above_net_since = now
        else:
            above_net_since = None

        # ── Combined trigger ─────────────────────────────
        if (above_cpu_since and above_net_since and
                not state["attack_detected"] and not state["mitigation_active"]):
            cpu_duration = now - above_cpu_since
            net_duration = now - above_net_since
            if cpu_duration >= TRIGGER_WINDOW_SEC and net_duration >= 5:
                state["attack_detected"] = True
                state["detection_time"] = ts
                log(f"ATTACK DETECTED | cpu={cpu_pct:.1f}% for {cpu_duration:.0f}s | "
                    f"net={net_mbps:.1f}Mbps for {net_duration:.0f}s", "ALERT")
                t = threading.Thread(target=trigger_mitigation, daemon=True)
                t.start()

        time.sleep(POLL_INTERVAL_SEC)


# ─────────────────────────────────────────────
#  Flask REST API (consumed by dashboard)
# ─────────────────────────────────────────────
@app.route("/api/state")
def api_state():
    return jsonify(state)


@app.route("/api/metrics")
def api_metrics():
    return jsonify({
        "cpu":         list(cpu_history)[:60],
        "net":         list(net_history)[:60],
        "availability":list(avail_history)[:60],
        "thresholds": {
            "cpu": CPU_THRESHOLD,
            "net": NET_THRESHOLD_MBPS,
        }
    })


@app.route("/api/events")
def api_events():
    return jsonify(list(events))


@app.route("/api/summary")
def api_summary():
    downtime_sec = None
    if state["downtime_start"] and state["downtime_end"]:
        try:
            t1 = datetime.fromisoformat(state["downtime_start"])
            t2 = datetime.fromisoformat(state["downtime_end"])
            downtime_sec = (t2 - t1).total_seconds()
        except Exception:
            pass

    mitigation_time_sec = None
    if state["detection_time"] and state["mitigation_end_time"]:
        try:
            t1 = datetime.fromisoformat(state["detection_time"])
            t2 = datetime.fromisoformat(state["mitigation_end_time"])
            mitigation_time_sec = (t2 - t1).total_seconds()
        except Exception:
            pass

    availability_pct = None
    if avail_history:
        vals = [x["value"] for x in avail_history]
        availability_pct = round(sum(vals) / len(vals) * 100, 1)

    return jsonify({
        "downtime_seconds":       downtime_sec,
        "time_to_mitigation_sec": mitigation_time_sec,
        "service_availability_pct": availability_pct,
        "attack_detected":        state["attack_detected"],
        "mitigation_active":      state["mitigation_active"],
        "failover_done":          state["failover_done"],
        "current_active_vm":      state["current_active_vm"],
    })


@app.route("/api/reset", methods=["POST"])
def api_reset():
    """Reset state for a new test run."""
    global above_cpu_since, above_net_since
    state.update({
        "attack_detected": False,
        "mitigation_active": False,
        "failover_done": False,
        "downtime_start": None,
        "downtime_end": None,
        "detection_time": None,
        "mitigation_start_time": None,
        "mitigation_end_time": None,
        "current_active_vm": "target",
    })
    cpu_history.clear()
    net_history.clear()
    avail_history.clear()
    events.clear()
    above_cpu_since = None
    above_net_since = None
    log("State reset for new test run", "INFO")
    return jsonify({"status": "reset"})


# ─────────────────────────────────────────────
#  Entry point
# ─────────────────────────────────────────────
if __name__ == "__main__":
    # Start monitoring in background thread
    mon_thread = threading.Thread(target=monitoring_loop, daemon=True)
    mon_thread.start()
    # Start Flask API
    app.run(host="0.0.0.0", port=5001, debug=False)
