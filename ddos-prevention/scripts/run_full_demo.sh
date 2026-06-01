#!/usr/bin/env bash
# =============================================================================
# VirtShield - Full Experiment Orchestrator
# Author : Oladeji Ibrahim Olaleye | U22CYS1103
# Purpose: Runs BOTH baseline (no mitigation) and mitigated (full pipeline)
#          test scenarios back-to-back, captures results to CSV,
#          and prints a side-by-side comparison summary.
#
# Usage  : sudo bash run_full_demo.sh [--baseline-only] [--mitigated-only]
# Run on : VM4 (Controller) - 192.168.100.40
# Prereq : SSH key-based auth configured for vm1, vm2, vm3
# =============================================================================
set -euo pipefail

# --- Configuration -----------------------------------------------------------
VM1_IP="192.168.100.10"   # Target web server
VM2_IP="192.168.100.20"   # Backup / failover node
VM3_IP="192.168.100.30"   # Traffic generator
VM4_IP="192.168.100.40"   # Controller (this machine)
SSH_USER="virtshield"
TEST_DURATION=60           # seconds per scenario
MONITOR_INTERVAL=2         # polling interval in seconds
RESULTS_DIR="/opt/virtshield/results"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOGFILE="${RESULTS_DIR}/run_${TIMESTAMP}.log"

# --- Argument parsing --------------------------------------------------------
RUN_BASELINE=true
RUN_MITIGATED=true
for arg in "$@"; do
  case $arg in
    --baseline-only)  RUN_MITIGATED=false ;;
    --mitigated-only) RUN_BASELINE=false  ;;
  esac
done

mkdir -p "$RESULTS_DIR"
exec > >(tee -a "$LOGFILE") 2>&1

log()   { echo "[$(date '+%H:%M:%S')] $*"; }
remote(){ ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@$1" "$2"; }

# =============================================================================
# HELPER: collect one metric sample from a VM
# Returns: cpu_pct,net_mbps,http_up (1=up 0=down)
# =============================================================================
get_metrics() {
  local ip=$1
  local cpu net_in up
  cpu=$(remote "$ip" \
    "python3 -c 'import psutil; print(psutil.cpu_percent(0.3))'" 2>/dev/null || echo 0)
  net_in=$(remote "$ip" \
    "python3 -c \
      'import psutil,time; b=psutil.net_io_counters().bytes_recv; \
       time.sleep(1); \
       print(round((psutil.net_io_counters().bytes_recv-b)/1e5,2))'" \
    2>/dev/null || echo 0)
  up=$(curl -sf --max-time 2 "http://${ip}/health" >/dev/null 2>&1 && echo 1 || echo 0)
  echo "${cpu},${net_in},${up}"
}

# =============================================================================
# SCENARIO A - Baseline (no mitigation response)
# =============================================================================
run_baseline() {
  log "==== SCENARIO A: Baseline (no mitigation) ===="
  local csv="${RESULTS_DIR}/baseline_${TIMESTAMP}.csv"
  echo "elapsed_s,cpu_pct,net_mbps,http_up,downtime_s" > "$csv"

  log "Restarting VM1 web service..."
  remote "$VM1_IP" "sudo systemctl restart nginx" 2>/dev/null || true
  sleep 2

  log "Launching traffic generation from VM3 (${TEST_DURATION}s)..."
  remote "$VM3_IP" \
    "nohup sudo python3 /opt/virtshield/traffic_generator.py \
      --target ${VM1_IP} --mode syn_flood --duration ${TEST_DURATION} \
      > /tmp/tgen.log 2>&1 &" 2>/dev/null || true

  local start downtime=0 step=0
  start=$(date +%s)

  while [ $step -lt $(( TEST_DURATION / MONITOR_INTERVAL + 5 )) ]; do
    local snap; snap=$(get_metrics "$VM1_IP")
    local cpu net_in up
    IFS=',' read -r cpu net_in up <<< "$snap"
    local elapsed=$(( $(date +%s) - start ))
    [ "$up" -eq 0 ] && downtime=$(( downtime + MONITOR_INTERVAL ))
    echo "${elapsed},${cpu},${net_in},${up},${downtime}" >> "$csv"
    log "  t=${elapsed}s  CPU=${cpu}%  Net=${net_in} Mbps  Up=${up}  Down=${downtime}s"
    sleep "$MONITOR_INTERVAL"
    step=$(( step + 1 ))
  done

  remote "$VM3_IP" "sudo pkill -f traffic_generator.py" 2>/dev/null || true
  log "Traffic generator stopped."

  # Parse summary
  local p_cpu p_net t_down up_obs total_obs avail
  p_cpu=$(awk -F',' 'NR>1{if($2>m)m=$2}END{print m+0}' "$csv")
  p_net=$(awk -F',' 'NR>1{if($3>m)m=$3}END{print m+0}' "$csv")
  t_down=$(tail -1 "$csv" | cut -d',' -f5)
  total_obs=$(( $(wc -l < "$csv") - 1 ))
  up_obs=$(awk -F',' 'NR>1&&$4==1{c++}END{print c+0}' "$csv")
  avail=$(awk "BEGIN{printf \"%.1f\",($up_obs/$total_obs)*100}")

  log "--- Baseline Summary ---"
  log "  Peak CPU:     ${p_cpu}%"
  log "  Peak Network: ${p_net} Mbps"
  log "  Total Down:   ${t_down}s"
  log "  Availability: ${avail}%"
  log "  Results file: $csv"

  BASELINE_RESULTS="${p_cpu}|${p_net}|${t_down}|${avail}"
}

# =============================================================================
# SCENARIO B - Mitigated (full 3-stage pipeline active)
# =============================================================================
run_mitigated() {
  log "==== SCENARIO B: Mitigated (full pipeline) ===="
  local csv="${RESULTS_DIR}/mitigated_${TIMESTAMP}.csv"
  echo "elapsed_s,cpu_pct,net_mbps,http_up,downtime_s,active_vm" > "$csv"

  log "Resetting VMs..."
  remote "$VM1_IP" "sudo systemctl restart nginx" 2>/dev/null || true
  remote "$VM2_IP" "sudo systemctl restart nginx" 2>/dev/null || true
  sleep 2

  log "Starting mitigation monitor on VM4..."
  nohup sudo python3 /opt/virtshield/mitigate.py \
    --target-ip "$VM1_IP" --backup-ip "$VM2_IP" \
    --cpu-threshold 80 --net-threshold 50 \
    --log-file "${RESULTS_DIR}/pipeline_${TIMESTAMP}.json" \
    > /tmp/mitigate.log 2>&1 &

  log "Launching traffic generation from VM3 (${TEST_DURATION}s)..."
  remote "$VM3_IP" \
    "nohup sudo python3 /opt/virtshield/traffic_generator.py \
      --target ${VM1_IP} --mode syn_flood --duration ${TEST_DURATION} \
      > /tmp/tgen.log 2>&1 &" 2>/dev/null || true

  local start downtime=0 step=0 active_vm="vm1"
  local ttm=-1 ttm_set=false
  start=$(date +%s)

  while [ $step -lt $(( TEST_DURATION / MONITOR_INTERVAL + 15 )) ]; do
    local elapsed=$(( $(date +%s) - start ))
    local snap; snap=$(get_metrics "$VM1_IP")
    local cpu net_in up
    IFS=',' read -r cpu net_in up <<< "$snap"

    # Check if VM2 has taken over
    local vm2_up
    vm2_up=$(curl -sf --max-time 2 "http://${VM2_IP}/health" >/dev/null 2>&1 && echo 1 || echo 0)
    if [ "$vm2_up" -eq 1 ] && [ "$active_vm" = "vm1" ] && [ "$up" -eq 0 ]; then
      active_vm="vm2"
      if [ "$ttm_set" = false ]; then
        ttm=$elapsed; ttm_set=true
        log "  [FAILOVER] VM2 serving traffic - TTM = ${ttm}s"
      fi
    fi

    [ "$up" -eq 0 ] && [ "$active_vm" = "vm1" ] && downtime=$(( downtime + MONITOR_INTERVAL ))

    echo "${elapsed},${cpu},${net_in},${up},${downtime},${active_vm}" >> "$csv"
    log "  t=${elapsed}s  CPU=${cpu}%  Net=${net_in} Mbps  Up=${up}  Down=${downtime}s  VM=${active_vm}"
    sleep "$MONITOR_INTERVAL"
    step=$(( step + 1 ))
    # Early exit once stable on VM2
    [ $elapsed -gt $(( TEST_DURATION + 10 )) ] && [ "$active_vm" = "vm2" ] && break
  done

  remote "$VM3_IP" "sudo pkill -f traffic_generator.py" 2>/dev/null || true
  sudo pkill -f mitigate.py 2>/dev/null || true
  log "Traffic generation and mitigation agent stopped."

  local p_cpu p_net t_down avail up_obs total_obs
  p_cpu=$(awk -F',' 'NR>1{if($2>m)m=$2}END{print m+0}' "$csv")
  p_net=$(awk -F',' 'NR>1{if($3>m)m=$3}END{print m+0}' "$csv")
  t_down=$(tail -1 "$csv" | cut -d',' -f5)
  total_obs=$(( $(wc -l < "$csv") - 1 ))
  up_obs=$(awk -F',' 'NR>1&&$4==1{c++}END{print c+0}' "$csv")
  avail=$(awk "BEGIN{printf \"%.1f\",($up_obs/$total_obs)*100}")

  log "--- Mitigated Summary ---"
  log "  Peak CPU:        ${p_cpu}%"
  log "  Peak Network:    ${p_net} Mbps"
  log "  Total Down:      ${t_down}s"
  log "  Availability:    ${avail}%"
  log "  Time-to-Mitigate:${ttm}s"
  log "  Results file:    $csv"

  MITIGATED_RESULTS="${p_cpu}|${p_net}|${t_down}|${avail}|${ttm}"
}

# =============================================================================
# SUMMARY TABLE
# =============================================================================
print_summary() {
  log ""
  log "================================================================"
  log "  VIRTSHIELD EXPERIMENT - RESULTS SUMMARY"
  log "================================================================"
  printf "%-24s %-18s %-18s\n" "Metric" "Baseline" "Mitigated"
  printf "%s\n" "----------------------------------------------------------------"
  IFS='|' read -r b_cpu b_net b_down b_avail <<< "$BASELINE_RESULTS"
  IFS='|' read -r m_cpu m_net m_down m_avail m_ttm <<< "$MITIGATED_RESULTS"
  printf "%-24s %-18s %-18s\n" "Peak CPU (%)"          "${b_cpu}"   "${m_cpu}"
  printf "%-24s %-18s %-18s\n" "Peak Network (Mbps)"   "${b_net}"   "${m_net}"
  printf "%-24s %-18s %-18s\n" "Total Downtime (s)"    "${b_down}"  "${m_down}"
  printf "%-24s %-18s %-18s\n" "Availability (%)"      "${b_avail}" "${m_avail}"
  printf "%-24s %-18s %-18s\n" "Time-to-Mitigate (s)"  "N/A"        "${m_ttm}"
  local target_met
  target_met=$([ "${m_down}" -lt 30 ] 2>/dev/null && echo "Yes" || echo "No")
  printf "%-24s %-18s %-18s\n" "Target (<30s down) met" "No"        "${target_met}"
  log "================================================================"
  log "  Logs    : $LOGFILE"
  log "  Results : $RESULTS_DIR"
  log "================================================================"
}

# =============================================================================
# MAIN
# =============================================================================
log "VirtShield Experiment Runner | Duration: ${TEST_DURATION}s | Interval: ${MONITOR_INTERVAL}s"

BASELINE_RESULTS="N/A|N/A|N/A|N/A"
MITIGATED_RESULTS="N/A|N/A|N/A|N/A|N/A"

if [ "$RUN_BASELINE" = true ]; then
  run_baseline
  log "Cooling down 15s before next scenario..."
  sleep 15
fi

if [ "$RUN_MITIGATED" = true ]; then
  run_mitigated
fi

if [ "$RUN_BASELINE" = true ] && [ "$RUN_MITIGATED" = true ]; then
  print_summary
fi

log "All done."
