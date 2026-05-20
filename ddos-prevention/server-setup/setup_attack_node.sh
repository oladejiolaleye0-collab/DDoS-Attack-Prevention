#!/bin/bash
# =============================================================
#  Attack Node Setup — Run on VM3 (Attacker)
#  FYP: Prevention of DDoS Attacks with Virtualization
#  Author: Oladeji Ibrahim Olaleye | U22CYS1103
# =============================================================
set -e
echo "[INFO] Setting up Attack Node (VM3)..."

apt-get update -y
apt-get install -y python3 python3-pip python3-scapy \
                   hping3 nmap tcpdump net-tools curl

# Install Python dependencies
pip3 install scapy requests --break-system-packages 2>/dev/null || \
    pip3 install scapy requests

echo "[INFO] Attack node ready."
echo "       Copy attack_simulator.py to this VM."
echo "       Run: sudo python3 attack_simulator.py --target <TARGET_IP>"
