# Prevention of DDoS Attacks with Virtualization
**FYP — Oladeji Ibrahim Olaleye | U22CYS1103**  
Air Force Institute of Technology, Kaduna | Department of Cyber Security

---

## System Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  VMware Workstation — Host-Only Network (VMnet1: 192.168.100.0/24)
│                                                              │
│   ┌──────────────┐      ┌──────────────┐                   │
│   │  VM1 TARGET  │      │  VM2 BACKUP  │                   │
│   │ 192.168.100.10│      │192.168.100.20│                   │
│   │  nginx:80    │ ───▶ │  nginx:80    │  (failover target) │
│   │  agent:5002  │      │  agent:5002  │                   │
│   └──────────────┘      └──────────────┘                   │
│          ▲  attack              ▲ failover                  │
│          │                      │                           │
│   ┌──────────────┐      ┌──────────────┐                   │
│   │  VM3 ATTACK  │      │ VM4 CONTROLLER│                  │
│   │192.168.100.30│      │192.168.100.40│                   │
│   │  Scapy/Python│      │  monitor.py  │                   │
│   │  attack_sim  │      │  mitigate.py │                   │
│   └──────────────┘      │  dashboard   │                   │
│                          │  Flask :5001 │                   │
│                          └──────────────┘                   │
└──────────────────────────────────────────────────────────────┘
```

---

## Quick Start — Step by Step

### Step 1: VM Creation in VMware Workstation

Create 4 Debian Server VMs. For each VM:
- **OS**: Debian 12 (Bookworm) — 64-bit
- **RAM**: 2 GB each (minimum), 3 GB recommended for VM1 and VM4
- **Disk**: 20 GB each
- **Network**: Set adapter to **Host-Only (VMnet1)** — NOT NAT or Bridged

| VM  | Role        | IP Address       | RAM  |
|-----|-------------|-----------------|------|
| VM1 | Target      | 192.168.100.10  | 2 GB |
| VM2 | Backup      | 192.168.100.20  | 2 GB |
| VM3 | Attacker    | 192.168.100.30  | 1 GB |
| VM4 | Controller  | 192.168.100.40  | 2 GB |

---

### Step 2: Configure Static IPs (run on each VM)

```bash
# On VM1 (Target):
sudo bash network_config.sh target

# On VM2 (Backup):
sudo bash network_config.sh backup

# On VM3 (Attacker):
sudo bash network_config.sh attacker

# On VM4 (Controller):
sudo bash network_config.sh controller
```

Verify connectivity:
```bash
# From VM4:
ping -c 3 192.168.100.10   # Target
ping -c 3 192.168.100.20   # Backup
ping -c 3 192.168.100.30   # Attacker
```

---

### Step 3: Install Dependencies

**VM1 and VM2 (Web Servers)**:
```bash
# Copy setup script, then:
sudo bash setup_web_server.sh target    # on VM1
sudo bash setup_web_server.sh backup    # on VM2

# Copy monitor agent to each:
sudo cp monitor_agent.py /opt/monitor_agent.py
sudo systemctl start monitor-agent
```

**VM3 (Attack Node)**:
```bash
sudo bash setup_attack_node.sh
sudo cp attack_simulator.py /opt/ddos-prevention/attack/
```

**VM4 (Controller)**:
```bash
sudo bash setup_controller.sh
# Copy all project files:
sudo cp -r ddos-prevention/ /opt/ddos-prevention/
```

---

### Step 4: Configure vmrun Paths

Edit `/opt/ddos-prevention/mitigation/mitigate.py` and update these variables to match your system:

```python
VMRUN_PATH = "/usr/lib/vmware/bin/vmrun"         # or wherever vmrun is installed
VMX_TARGET = "/path/to/your/vm1-target.vmx"      # full path to VM1's .vmx file
VMX_BACKUP = "/path/to/your/vm2-backup.vmx"      # full path to VM2's .vmx file
```

Find your VMX paths:
```bash
# On Windows host: usually in Documents/Virtual Machines/
# On Linux host:
find ~/ -name "*.vmx" 2>/dev/null
```

---

### Step 5: Verify Everything Works

```bash
# On VM4 — test that monitor agent is reachable:
curl http://192.168.100.10:5002/metrics    # VM1 agent
curl http://192.168.100.20:5002/metrics    # VM2 agent

# Test web server:
curl http://192.168.100.10/health

# Test vmrun:
vmrun list                                  # lists running VMs
```

---

## Running the Experiments

### Baseline Test (No Mitigation)

```bash
# On VM4:
sudo bash /opt/ddos-prevention/scripts/run_baseline_test.sh
```

This will:
1. Start availability polling of VM1
2. Launch attack from VM3 (SYN + UDP + HTTP flood)
3. Record metrics for 120 seconds (no mitigation triggers)
4. Output results to `/var/log/ddos-tests/baseline_results.json`

**Expected outcome**: Service down for 60–120 seconds. Target (< 30s) NOT met.

---

### Mitigated Test (Full Defence)

```bash
# On VM4:
sudo bash /opt/ddos-prevention/scripts/run_mitigated_test.sh
```

This will:
1. Start monitor module (threshold detection active)
2. Start availability polling that follows failover
3. Launch the same attack from VM3
4. Monitor auto-triggers: cap → isolate → failover within ~15–25s
5. Output results to `/var/log/ddos-tests/mitigated_results.json`

**Expected outcome**: Service down for < 30 seconds. Target MET.

---

## Dashboard

### Option A — Standalone (no live backend needed)
Just open `dashboard/index.html` in a browser on the host machine.  
Use the simulation buttons to demonstrate both scenarios to supervisors.

### Option B — Live (real metrics from Controller VM)
```bash
# On VM4:
python3 /opt/ddos-prevention/monitor/monitor.py
# Dashboard API available at: http://192.168.100.40:5001
```
Open `dashboard/index.html` — it will poll the API automatically.

---

## Project File Structure

```
ddos-prevention/
├── attack/
│   └── attack_simulator.py     — TCP SYN + UDP + HTTP flood (runs on VM3)
├── monitor/
│   ├── monitor.py              — Detection engine + REST API (runs on VM4)
│   └── monitor_agent.py        — Lightweight metrics agent (runs on VM1 & VM2)
├── mitigation/
│   └── mitigate.py             — 3-stage mitigation: cap → isolate → failover (VM4)
├── dashboard/
│   └── index.html              — Real-time monitoring dashboard (host browser)
├── server-setup/
│   ├── setup_web_server.sh     — Install nginx + agent (VM1 & VM2)
│   ├── setup_attack_node.sh    — Install Scapy tools (VM3)
│   └── setup_controller.sh     — Install Python deps (VM4)
├── scripts/
│   ├── network_config.sh       — Set static IPs on each VM
│   ├── run_baseline_test.sh    — Run baseline experiment
│   └── run_mitigated_test.sh   — Run mitigated experiment
└── README.md                   — This file
```

---

## Mitigation Pipeline (Stage by Stage)

```
Attack Detected (CPU > 80% for 10s AND Net > 50 Mbps for 5s)
         │
         ▼
  Stage 1: Resource Capping          (~2–3 seconds)
  • vmrun: set cpuExecutionCap = 20%
  • iptables/tc: bandwidth limit on VM1 interface

         │
         ▼
  Stage 2: VM Isolation               (~2–4 seconds)
  • vmrun suspend VM1 (saves state, removes from network)
  • Prevents attack traffic from consuming further resources

         │
         ▼
  Stage 3: Rapid Failover             (~8–15 seconds)
  • vmrun start VM2 (backup)
  • Wait for VM2 service to come up
  • iptables DNAT: redirect :80 from TARGET_IP → BACKUP_IP
  • Service restored via VM2

Total pipeline time: ~14–22 seconds → downtime < 30s target ✓
```

---

## Evaluation Metrics

| Metric | Baseline | Mitigated | Target |
|--------|----------|-----------|--------|
| Total Downtime | 60–120s | < 30s | < 30s ✓ |
| Service Availability | ~20–40% | ~90–97% | High |
| Peak CPU (target) | ~95–99% | ~20% (capped) | — |
| Time to Mitigation | N/A | ~14–22s | — |
| Failover Success | No | Yes | Yes |

---

## What to Show Supervisors

### 1. Dashboard Demo (recommend opening on projector)
- Open `dashboard/index.html` in Chrome/Firefox
- Click **Load Baseline Results** → shows attack with no mitigation, long downtime
- Click **Reset Demo**
- Click **Load Mitigated Results** → shows attack detected + automated mitigation + downtime < 30s
- The comparison table updates automatically

### 2. Live Demo (if asked)
- Start monitor on VM4: `python3 monitor.py`
- Start attack from VM3: `sudo python3 attack_simulator.py --target 192.168.100.10`
- Watch dashboard update in real time

### 3. Backend Code
- Show `monitor.py` for detection logic (threshold-based rules)
- Show `mitigate.py` for the three-stage pipeline
- Show `attack_simulator.py` for traffic generation
- Show `run_baseline_test.sh` / `run_mitigated_test.sh` for experiment design

---

## Author

**Oladeji Ibrahim Olaleye** | U22CYS1103  
Department of Cyber Security, Faculty of Computing  
Air Force Institute of Technology, Kaduna  
Supervisor: Mr. Abdulrahman A. Tunde
