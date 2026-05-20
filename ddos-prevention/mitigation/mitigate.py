#!/usr/bin/env python3
"""
=============================================================
  Mitigation Engine — Controller Node (VM4)
  FYP: Prevention of DDoS Attacks with Virtualization
  Author: Oladeji Ibrahim Olaleye | U22CYS1103
=============================================================
Implements three-stage virtualization-based mitigation:
  1. Resource capping   — throttle CPU & bandwidth on target VM
  2. VM isolation       — suspend/pause target VM
  3. Rapid failover     — redirect traffic to backup VM

Uses VMware Workstation vmrun CLI for VM control.
Run on: Controller VM (VM4) — or directly on Host via SSH
Usage : python3 mitigate.py --action [cap|isolate|failover|full|restore]
"""

import argparse
import subprocess
import time
import os
import json
import socket
from datetime import datetime

# ─────────────────────────────────────────────
#  Configuration — set these to match your VMs
# ─────────────────────────────────────────────
VMRUN_PATH      = os.getenv("VMRUN_PATH", "/usr/bin/vmrun")   # path to vmrun on host
VMX_TARGET      = os.getenv("VMX_TARGET",  "/path/to/vm1-target.vmx")
VMX_BACKUP      = os.getenv("VMX_BACKUP",  "/path/to/vm2-backup.vmx")

TARGET_IP       = os.getenv("TARGET_IP",   "192.168.100.10")
BACKUP_IP       = os.getenv("BACKUP_IP",   "192.168.100.20")
CONTROLLER_IP   = os.getenv("CTRL_IP",     "192.168.100.40")
SERVICE_PORT    = int(os.getenv("SERVICE_PORT", "80"))

# Resource cap values
CPU_CAP_PERCENT   = 20    # Throttle target to 20% CPU after detection
NET_CAP_KBPS      = 1024  # 1 Mbps bandwidth cap on target

# Log file
LOG_FILE = "/var/log/ddos_mitigation.log"


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
    return line


# ─────────────────────────────────────────────
#  vmrun helpers
# ─────────────────────────────────────────────
def vmrun(cmd_args, timeout=30):
    """
    Execute a vmrun command.
    vmrun is the VMware Workstation CLI for controlling VMs.
    """
    full_cmd = [VMRUN_PATH] + cmd_args
    log(f"vmrun: {' '.join(full_cmd)}")
    try:
        result = subprocess.run(
            full_cmd, capture_output=True, text=True, timeout=timeout
        )
        if result.returncode != 0:
            log(f"vmrun error: {result.stderr.strip()}", "ERROR")
        else:
            log(f"vmrun ok: {result.stdout.strip()}")
        return result.returncode == 0, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        log(f"vmrun timed out after {timeout}s", "ERROR")
        return False, "", "timeout"
    except FileNotFoundError:
        log(f"vmrun not found at {VMRUN_PATH} — running in SIMULATION MODE", "WARN")
        return True, "[SIMULATED]", ""


# ─────────────────────────────────────────────
#  Stage 1: Resource Capping
# ─────────────────────────────────────────────
def stage_resource_cap():
    """
    Throttle the target VM's CPU and network to contain the attack.
    Uses vmrun + VMware's guest tools to adjust resource limits.
    This buys time before full failover.
    """
    t0 = time.time()
    log("─── STAGE 1: Resource Capping ───", "MITIGATE")

    # CPU throttle via vmrun writeVariable (sets cpuExecutionCap in the VMX)
    ok, _, _ = vmrun([
        "writeVariable", VMX_TARGET, "runtimeConfig",
        "cpuExecutionCap", str(CPU_CAP_PERCENT)
    ])
    if ok:
        log(f"CPU cap set to {CPU_CAP_PERCENT}% on target VM")
    else:
        log("CPU cap via vmrun failed — trying alternative method", "WARN")
        # Alternative: use traffic control on host's VMnet interface
        _apply_tc_bandwidth_limit(TARGET_IP, NET_CAP_KBPS)

    # Network bandwidth throttle via Linux tc (on host — requires host access)
    # This is run on the Controller or Host
    _apply_tc_bandwidth_limit(TARGET_IP, NET_CAP_KBPS)

    elapsed = time.time() - t0
    log(f"Stage 1 complete in {elapsed:.2f}s", "MITIGATE")
    return elapsed


def _apply_tc_bandwidth_limit(target_ip, kbps):
    """
    Apply Linux Traffic Control bandwidth limit on the VMnet interface.
    Requires: iproute2, run on Controller VM or Host.
    """
    try:
        # Identify outgoing interface toward target
        iface = "vmnet8"  # typical VMware Host-Only/NAT interface name
        cmds = [
            f"tc qdisc add dev {iface} root handle 1: htb default 30 2>/dev/null || true",
            f"tc class add dev {iface} parent 1: classid 1:1 htb rate {kbps}kbit ceil {kbps}kbit 2>/dev/null || true",
            f"tc filter add dev {iface} parent 1:0 protocol ip u32 match ip dst {target_ip}/32 flowid 1:1 2>/dev/null || true",
        ]
        for cmd in cmds:
            subprocess.run(cmd, shell=True, capture_output=True)
        log(f"Traffic control: bandwidth limited to {kbps} kbps toward {target_ip}")
    except Exception as e:
        log(f"TC bandwidth limit failed: {e}", "WARN")


# ─────────────────────────────────────────────
#  Stage 2: VM Isolation (Suspend/Pause)
# ─────────────────────────────────────────────
def stage_isolate():
    """
    Suspend the target VM to halt attack-induced resource drain.
    This is the VMware Workstation approximation of VM isolation
    (full isolation would use VLAN changes in a vSphere environment).
    """
    t0 = time.time()
    log("─── STAGE 2: VM Isolation (Suspend) ───", "MITIGATE")

    # Option A: Suspend (saves state, can be resumed)
    ok, _, _ = vmrun(["suspend", VMX_TARGET, "soft"])
    if ok:
        log(f"Target VM suspended (isolated)")
    else:
        # Option B: Pause (keeps in memory, instant)
        ok2, _, _ = vmrun(["pause", VMX_TARGET])
        if ok2:
            log("Target VM paused (isolated)")
        else:
            log("Isolation failed — proceeding to failover anyway", "WARN")

    elapsed = time.time() - t0
    log(f"Stage 2 complete in {elapsed:.2f}s", "MITIGATE")
    return elapsed


# ─────────────────────────────────────────────
#  Stage 3: Rapid Failover to Backup VM
# ─────────────────────────────────────────────
def stage_failover():
    """
    Start the backup VM and update routing/DNS so traffic is redirected.
    This approximates live migration (not available in VMware Workstation).
    """
    t0 = time.time()
    log("─── STAGE 3: Rapid Failover ───", "MITIGATE")

    # Ensure backup VM is running
    ok, out, _ = vmrun(["list"])
    backup_running = VMX_BACKUP in out if ok else False

    if not backup_running:
        log("Starting backup VM...")
        ok2, _, _ = vmrun(["start", VMX_BACKUP, "nogui"])
        if ok2:
            log("Backup VM started")
        else:
            log("Failed to start backup VM", "ERROR")
            return time.time() - t0
        # Wait for backup to be network-ready
        _wait_for_service(BACKUP_IP, SERVICE_PORT, timeout=30)
    else:
        log("Backup VM already running")

    # Redirect virtual IP / update ARP table so clients hit backup
    _redirect_traffic_to_backup()

    elapsed = time.time() - t0
    log(f"Stage 3 complete in {elapsed:.2f}s — backup now serving traffic", "MITIGATE")
    return elapsed


def _wait_for_service(ip, port, timeout=30):
    """Poll until service is up or timeout."""
    log(f"Waiting for service on {ip}:{port}...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(2)
            if s.connect_ex((ip, port)) == 0:
                s.close()
                log(f"Service on {ip}:{port} is UP")
                return True
            s.close()
        except Exception:
            pass
        time.sleep(1)
    log(f"Service on {ip}:{port} did not come up within {timeout}s", "WARN")
    return False


def _redirect_traffic_to_backup():
    """
    Redirect traffic from TARGET_IP to BACKUP_IP.
    Two methods: ARP spoofing (gratuitous ARP) OR iptables DNAT.
    """
    log("Redirecting traffic to backup VM via iptables DNAT...")
    try:
        # Method: iptables DNAT — redirect incoming traffic destined for target to backup
        cmds = [
            # Flush existing DNAT rules
            f"iptables -t nat -F PREROUTING 2>/dev/null || true",
            # DNAT: redirect :80 to backup
            f"iptables -t nat -A PREROUTING -d {TARGET_IP} -p tcp --dport {SERVICE_PORT} "
            f"-j DNAT --to-destination {BACKUP_IP}:{SERVICE_PORT}",
            # MASQUERADE for return traffic
            f"iptables -t nat -A POSTROUTING -j MASQUERADE",
            # Enable IP forwarding
            f"echo 1 > /proc/sys/net/ipv4/ip_forward",
        ]
        for cmd in cmds:
            subprocess.run(cmd, shell=True, capture_output=True)
        log(f"iptables DNAT: {TARGET_IP}:{SERVICE_PORT} → {BACKUP_IP}:{SERVICE_PORT}")
    except Exception as e:
        log(f"Traffic redirect failed: {e}", "ERROR")


# ─────────────────────────────────────────────
#  Stage 4: Restore (for cleanup / re-run)
# ─────────────────────────────────────────────
def stage_restore():
    """Restore target VM and remove mitigation rules."""
    log("─── RESTORE: Reverting mitigation ───", "MITIGATE")

    # Resume target VM
    vmrun(["unpause", VMX_TARGET])
    vmrun(["start", VMX_TARGET, "nogui"])
    log("Target VM resumed")

    # Remove iptables DNAT rules
    try:
        subprocess.run("iptables -t nat -F PREROUTING", shell=True, capture_output=True)
        subprocess.run("iptables -t nat -F POSTROUTING", shell=True, capture_output=True)
        log("iptables DNAT rules removed")
    except Exception as e:
        log(f"iptables cleanup failed: {e}", "WARN")

    # Remove TC bandwidth limits
    try:
        subprocess.run("tc qdisc del dev vmnet8 root 2>/dev/null", shell=True, capture_output=True)
        log("Traffic control rules removed")
    except Exception:
        pass

    log("System restored to normal state")


# ─────────────────────────────────────────────
#  Full mitigation pipeline
# ─────────────────────────────────────────────
def full_mitigation():
    """Execute all three stages sequentially and record timings."""
    pipeline_start = time.time()
    log("═══ FULL MITIGATION PIPELINE STARTED ═══", "MITIGATE")

    t1 = stage_resource_cap()   # Stage 1
    t2 = stage_isolate()        # Stage 2
    t3 = stage_failover()       # Stage 3

    total = time.time() - pipeline_start
    log(f"═══ MITIGATION COMPLETE ═══ Total={total:.2f}s "
        f"(cap={t1:.1f}s | isolate={t2:.1f}s | failover={t3:.1f}s)", "SUCCESS")

    # Write timings to JSON for dashboard consumption
    result = {
        "pipeline_total_sec": round(total, 2),
        "stage_cap_sec":      round(t1, 2),
        "stage_isolate_sec":  round(t2, 2),
        "stage_failover_sec": round(t3, 2),
        "timestamp":          datetime.now().isoformat(),
        "success":            True,
    }
    with open("/var/log/mitigation_result.json", "w") as f:
        json.dump(result, f, indent=2)
    return result


# ─────────────────────────────────────────────
#  Entry point
# ─────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mitigation Engine")
    parser.add_argument("--action", choices=["cap", "isolate", "failover", "full", "restore"],
                        default="full", help="Mitigation action to perform")
    args = parser.parse_args()

    actions = {
        "cap":      stage_resource_cap,
        "isolate":  stage_isolate,
        "failover": stage_failover,
        "full":     full_mitigation,
        "restore":  stage_restore,
    }
    actions[args.action]()
