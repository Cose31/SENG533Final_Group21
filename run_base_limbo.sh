#!/bin/bash
# ===== CONFIG =====
TEASTORE_DIR="$HOME/TeaStore"
COMPOSE_FILE="$TEASTORE_DIR/examples/docker/docker-compose_default.yaml"
SCRIPT_DIR="$HOME/scripts"
RESULTS_DIR="$SCRIPT_DIR/limbo_baseline_results"

# httploadgenerator config
HLG_JAR="$SCRIPT_DIR/httploadgenerator.jar"
HLG_AGENT_IP="10.1.3.143"
HLG_AGENT_PORT="24226"
HLG_TIMEOUT=10000
TOTAL_DURATION=130

# Workload profiles: name|arrival_csv|lua_script
WORKLOAD_PROFILES=(
  #"browse_low|$TEASTORE_DIR/examples/httploadgenerator/increasingLowIntensity.csv|$TEASTORE_DIR/examples/httploadgenerator/teastore_browse.lua"
  #"browse_med|$TEASTORE_DIR/examples/httploadgenerator/increasingMedIntensity.csv|$TEASTORE_DIR/examples/httploadgenerator/teastore_browse.lua"
  #"browse_high|$TEASTORE_DIR/examples/httploadgenerator/increasingHighIntensity.csv|$TEASTORE_DIR/examples/httploadgenerator/teastore_browse.lua"
  #"buy_low|$TEASTORE_DIR/examples/httploadgenerator/increasingLowIntensity.csv|$TEASTORE_DIR/examples/httploadgenerator/teastore_buy.lua"
  #"buy_med|$TEASTORE_DIR/examples/httploadgenerator/increasingMedIntensity.csv|$TEASTORE_DIR/examples/httploadgenerator/teastore_buy.lua"
  "buy_high|$TEASTORE_DIR/examples/httploadgenerator/increasingHighIntensity.csv|$TEASTORE_DIR/examples/httploadgenerator/teastore_buy.lua"
)

THREAD_LEVELS=(256)
REPEATS=1

mkdir -p $RESULTS_DIR

# ===== CLEANUP TRAP =====
cleanup() {
  echo "Cleaning up..."
  kill $STATS_PID 2>/dev/null
  wait $STATS_PID 2>/dev/null
  pkill -f "docker stats" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ===== WAIT FOR TEASTORE =====
wait_for_teastore() {
  echo "Waiting for TeaStore..."
  until curl -s --max-time 5 http://localhost:8080/tools.descartes.teastore.webui/ | grep -q "TeaStore"; do
    sleep 10
  done
  echo "TeaStore is up."
}

# ===== RUN SINGLE EXPERIMENT =====
run_experiment() {
  local profile_name=$1
  local arrival_csv=$2
  local lua_script=$3
  local threads=$4
  local run_id=$5

  OUTPUT_DIR="$RESULTS_DIR/profile=${profile_name}_threads=${threads}_run=${run_id}_$(date +%H%M%S)"
  mkdir -p $OUTPUT_DIR

  echo "======================================"
  echo "Profile: $profile_name | Threads: $threads | Run: $run_id"
  echo "Arrival: $arrival_csv"
  echo "Lua:     $lua_script"
  echo "Output:  $OUTPUT_DIR"
  echo "======================================"

  # --- Validate files exist ---
  if [ ! -f "$arrival_csv" ]; then
    echo "ERROR: Arrival CSV not found: $arrival_csv"
    return 1
  fi
  if [ ! -f "$lua_script" ]; then
    echo "ERROR: Lua script not found: $lua_script"
    return 1
  fi

  # --- Reset system ---
  sudo docker-compose -f $COMPOSE_FILE down --remove-orphans
  sudo docker system prune -f

  # --- Start system ---
  sudo docker-compose -f $COMPOSE_FILE up -d
  sleep 120
  wait_for_teastore

  # --- Save metadata ---
  {
    echo "profile=$profile_name"
    echo "arrival_csv=$arrival_csv"
    echo "lua_script=$lua_script"
    echo "threads=$threads"
    echo "run=$run_id"
    echo "total_duration=${TOTAL_DURATION}s"
    echo "timestamp=$(date)"
    echo "hlg_agent=$HLG_AGENT_IP:$HLG_AGENT_PORT"
  } > $OUTPUT_DIR/metadata.txt

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

  # --- Run HLG ---
  echo "Starting httploadgenerator director (threads=$threads)..."
  touch $OUTPUT_DIR/hlg_results.csv
  cd $OUTPUT_DIR

  java -jar $HLG_JAR director \
    -s $HLG_AGENT_IP \
    -p $HLG_AGENT_PORT \
    -a $arrival_csv \
    -l $lua_script \
    -o hlg_results.csv \
    -t $threads \
    -u $HLG_TIMEOUT \
    2>&1 | tee $OUTPUT_DIR/hlg_director.log
  HLG_EXIT=${PIPESTATUS[0]}
  cd - > /dev/null

  # --- Stop docker stats ---
  kill $STATS_PID
  wait $STATS_PID 2>/dev/null
  sleep 2

  # --- Move HLG CSV ---
  HLG_ARRIVAL_DIR=$(dirname $arrival_csv)
  if [ -f "$HLG_ARRIVAL_DIR/hlg_results.csv" ]; then
    mv "$HLG_ARRIVAL_DIR/hlg_results.csv" "$OUTPUT_DIR/hlg_results.csv"
    echo "HLG results moved to $OUTPUT_DIR"
  else
    echo "WARNING: HLG CSV not found at $HLG_ARRIVAL_DIR/hlg_results.csv"
  fi
  
  # timeout returns 124 if it killed the process, treat that as normal
  if [ $HLG_EXIT -ne 0 ] && [ $HLG_EXIT -ne 124 ]; then
    echo "WARNING: httploadgenerator exited with code $HLG_EXIT"
    echo "hlg_exit_code=$HLG_EXIT" >> $OUTPUT_DIR/metadata.txt
  fi

  # --- Final docker stats snapshot ---
  docker stats --no-stream \
    --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" \
    > $OUTPUT_DIR/docker_stats_final.txt

  echo "Completed: profile=$profile_name threads=$threads run=$run_id"
  echo ""
}

# ===== MAIN LOOP =====
echo "===== STARTING WORKLOAD EXPERIMENTS ====="
echo "Profiles: ${#WORKLOAD_PROFILES[@]}"
echo "Thread levels: ${THREAD_LEVELS[@]}"
echo "Repeats: $REPEATS"
echo "Total experiments: $((${#WORKLOAD_PROFILES[@]} * ${#THREAD_LEVELS[@]} * REPEATS))"
echo ""
echo "PRE-FLIGHT: Ensure HLG agent is running on $HLG_AGENT_IP:$HLG_AGENT_PORT"
echo "  ssh ubuntu@$HLG_AGENT_IP"
echo "  java -jar httploadgenerator.jar loadgenerator"
echo ""
sleep 10

for profile in "${WORKLOAD_PROFILES[@]}"; do
  IFS='|' read -r name arrival lua <<< "$profile"
  for threads in "${THREAD_LEVELS[@]}"; do
    for run in $(seq 1 $REPEATS); do
      run_experiment "$name" "$arrival" "$lua" "$threads" "$run"
    done
  done
done

echo "===== ALL WORKLOAD EXPERIMENTS COMPLETE ====="
