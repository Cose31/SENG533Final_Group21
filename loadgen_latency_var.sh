#!/bin/bash
# ===== CONFIG =====
TEASTORE_DIR="$HOME/TeaStore"
COMPOSE_FILE="$TEASTORE_DIR/examples/docker/docker-compose_kieker.yaml"
SCRIPT_DIR="$HOME/scripts"
RESULTS_DIR="$SCRIPT_DIR/latency_var_results"

# httploadgenerator config
HLG_JAR="$SCRIPT_DIR/httploadgenerator.jar"
HLG_AGENT_IP="10.1.3.143"
HLG_AGENT_PORT="24226"
HLG_ARRIVAL_CSV="$TEASTORE_DIR/examples/httploadgenerator/increasingLowIntensity.csv"
HLG_LUA_SCRIPT="$TEASTORE_DIR/examples/httploadgenerator/teastore_browse.lua"
HLG_THREADS=128

LATENCY_MODES=(0 50 100)
REPEATS=1
NET_IFACE="ens3"

mkdir -p $RESULTS_DIR

# ===== WAIT FOR TEASTORE =====
wait_for_teastore() {
  echo "Waiting for TeaStore..."
  until curl -s http://localhost:8080/tools.descartes.teastore.webui/ | grep -q "TeaStore"; do
    sleep 5
  done
  echo "TeaStore is up."
}

# ===== WAIT FOR HLG AGENT =====
wait_for_hlg_agent() {
  echo "Waiting for httploadgenerator agent at $HLG_AGENT_IP:$HLG_AGENT_PORT..."
  #until nc -z $HLG_AGENT_IP $HLG_AGENT_PORT 2>/dev/null; do
   # sleep 3
  #done
  echo "Agent is reachable."
}

# ===== APPLY LATENCY =====
apply_latency() {
  local latency_ms=$1
  sudo tc qdisc del dev $NET_IFACE root 2>/dev/null || true

  if [ "$latency_ms" -eq 0 ]; then
    echo "No latency applied (0ms baseline)"
    return
  fi

  echo "Applying ${latency_ms}ms latency on $NET_IFACE..."
  sudo tc qdisc add dev $NET_IFACE root netem delay ${latency_ms}ms
  sudo tc qdisc show dev $NET_IFACE
}

# ===== CLEAR LATENCY =====
clear_latency() {
  echo "Clearing tc latency rules..."
  sudo tc qdisc del dev $NET_IFACE root 2>/dev/null || true
}

# ===== RUN SINGLE EXPERIMENT =====
run_experiment() {
  latency_ms=$1
  run_id=$2
  OUTPUT_DIR="$RESULTS_DIR/latency=${latency_ms}ms_run=${run_id}_$(date +%H%M%S)"
  mkdir -p $OUTPUT_DIR

  HLG_OUTPUT_CSV="$OUTPUT_DIR/hlg_results.csv"

  echo "======================================"
  echo "Latency: ${latency_ms}ms | Run: $run_id"
  echo "Output: $OUTPUT_DIR"
  echo "======================================"

  # --- Reset system ---
  clear_latency
  sudo docker-compose -f $COMPOSE_FILE down -v --remove-orphans
  sudo docker system prune -f

  # --- Start system ---
  sudo docker-compose -f $COMPOSE_FILE up -d
  sleep 180
  wait_for_teastore

  # --- Apply latency AFTER startup, BEFORE load ---
  apply_latency $latency_ms

  # --- Save metadata ---
  {
    echo "latency_ms=$latency_ms"
    echo "hlg_agent=$HLG_AGENT_IP"
    echo "hlg_threads=$HLG_THREADS"
    echo "hlg_arrival_csv=$HLG_ARRIVAL_CSV"
    echo "hlg_lua=$HLG_LUA_SCRIPT"
    echo "net_iface=$NET_IFACE"
  } > $OUTPUT_DIR/metadata.txt

  # --- Save tc state ---
  sudo tc qdisc show dev $NET_IFACE > $OUTPUT_DIR/tc_rules.txt

  # --- Check agent is up ---
  wait_for_hlg_agent

  # --- Start docker stats ---
  (
    while true; do
      docker stats --no-stream \
        --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" \
        >> $OUTPUT_DIR/docker_stats.csv
      sleep 1
    done
  ) &
  STATS_PID=$!

  # --- Run httploadgenerator director ---
  echo "Starting httploadgenerator director..."
  touch $OUTPUT_DIR/hlg_results.csv
  cd $OUTPUT_DIR


  java -jar $HLG_JAR director \
    -s $HLG_AGENT_IP \
    -p $HLG_AGENT_PORT \
    -a $HLG_ARRIVAL_CSV \
    -l $HLG_LUA_SCRIPT \
    -o hlg_results.csv \
    -t $HLG_THREADS \
    -u 5000 \
    2>&1 | tee $OUTPUT_DIR/hlg_director.log
  HLG_EXIT=${PIPESTATUS[0]}
  cd - > /dev/null

  # --- Move HLG results from arrival CSV directory to output dir ---
  HLG_ARRIVAL_DIR=$(dirname $HLG_ARRIVAL_CSV)
  if [ -f "$HLG_ARRIVAL_DIR/hlg_results.csv" ]; then
    mv "$HLG_ARRIVAL_DIR/hlg_results.csv" "$OUTPUT_DIR/hlg_results.csv"
    echo "HLG results moved to $OUTPUT_DIR"
  else
    echo "WARNING: HLG output CSV not found at $HLG_ARRIVAL_DIR/hlg_results.csv"
  fi

  # timeout returns 124 if it killed the process, treat that as normal
  if [ $HLG_EXIT -ne 0 ] && [ $HLG_EXIT -ne 124 ]; then
    echo "WARNING: httploadgenerator exited with code $HLG_EXIT"
    echo "hlg_exit_code=$HLG_EXIT" >> $OUTPUT_DIR/metadata.txt
  fi

  # --- Stop docker stats ---
  kill $STATS_PID
  wait $STATS_PID 2>/dev/null

  # --- Copy Kieker logs ---
  docker cp docker_webui_1:/kieker/logs $OUTPUT_DIR/kieker_webui_logs || true

  # --- Final docker stats snapshot ---
  docker stats --no-stream \
    --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" \
    > $OUTPUT_DIR/docker_stats_final.txt

  # --- Clean up latency after experiment ---
  clear_latency

  echo "Completed latency=${latency_ms}ms run=$run_id"
}

# ===== MAIN LOOP =====
for latency in "${LATENCY_MODES[@]}"; do
  for run in $(seq 1 $REPEATS); do
    run_experiment $latency $run
  done
done

echo "===== LATENCY EXPERIMENT COMPLETE ====="
