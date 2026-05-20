#!/usr/bin/env python3
"""
=============================================================
  Monitor Agent — runs on TARGET VM (VM1) and BACKUP VM (VM2)
  Exposes local CPU/Net metrics via HTTP so Controller can poll
  FYP: Prevention of DDoS Attacks with Virtualization
  Author: Oladeji Ibrahim Olaleye | U22CYS1103
=============================================================
Usage: python3 monitor_agent.py
       (runs on port 5002 of each server VM)
"""

import time
import psutil
from flask import Flask, jsonify

app = Flask(__name__)

_prev_net = None
_prev_time = None


def get_net_mbps():
    global _prev_net, _prev_time
    now = time.time()
    cur = psutil.net_io_counters()
    if _prev_net is None:
        _prev_net = cur
        _prev_time = now
        return 0.0
    dt = now - _prev_time
    if dt < 0.1:
        return 0.0
    mbps = ((cur.bytes_recv - _prev_net.bytes_recv) * 8) / (dt * 1_000_000)
    _prev_net = cur
    _prev_time = now
    return round(max(mbps, 0.0), 2)


@app.route("/metrics")
def metrics():
    return jsonify({
        "cpu_percent": psutil.cpu_percent(interval=0.5),
        "mem_percent": psutil.virtual_memory().percent,
        "net_mbps":    get_net_mbps(),
        "net_bytes_recv": psutil.net_io_counters().bytes_recv,
        "net_bytes_sent": psutil.net_io_counters().bytes_sent,
        "connections":    len(psutil.net_connections()),
    })


@app.route("/health")
def health():
    return jsonify({"status": "up"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5002, debug=False)
