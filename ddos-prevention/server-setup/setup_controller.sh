#!/bin/bash
# =============================================================
#  Controller Node Setup — Run on VM4 (Controller)
#  FYP: Prevention of DDoS Attacks with Virtualization
#  Author: Oladeji Ibrahim Olaleye | U22CYS1103
# =============================================================
set -e
echo "[INFO] Setting up Controller VM (VM4)..."

apt-get update -y
apt-get install -y python3 python3-pip iproute2 iptables curl net-tools

pip3 install flask psutil requests --break-system-packages 2>/dev/null || \
    pip3 install flask psutil requests

# Copy scripts to /opt
mkdir -p /opt/ddos-prevention/{monitor,mitigation,dashboard}

echo "[INFO] Controller VM setup complete."
echo "       Copy project files to /opt/ddos-prevention/"
echo "       Then run: python3 /opt/ddos-prevention/monitor/monitor.py"
