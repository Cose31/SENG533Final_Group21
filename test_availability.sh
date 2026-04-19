#!/bin/bash
# ===== CONFIG =====
TEASTORE_DIR="$HOME/TeaStore"
COMPOSE_FILE="$TEASTORE_DIR/examples/docker/docker-compose_kieker.yaml"
SCRIPT_DIR="$HOME/scripts"
RESULTS_DIR="$SCRIPT_DIR/fault_injection_results"

# httploadgenerator config
HLG_JAR="$SCRIPT_DIR/httploadgenerator.jar"
HLG_AGENT_IP="10.1.3.143"
HLG_AGENT_PORT="24226"
HLG_ARRIVAL_CSV="$TEASTORE_DIR/examples/httploadgenerator/increasingLowIntensity.csv"
HLG_LUA_SCRIPT="$TEASTORE_DIR/examples/httploadgenerator/teastore_browse.lua"
HLG_THREADS=64
HLG_TIMEOUT=5000

NET_IFACE="ens3"

# Fault scenarios: name|type|target|parameter
# Types: stop, db_stop, multi_stop, throttle_cpu, throttle_mem
FAULT_SCENARIOS=(
  #"single_service_auth|stop|docker_auth_1|"
  #"single_service_image|stop|docker_image_1|"
  #"single_service_recommender|stop|docker_recommender_1|"
  #"database_down|db_stop|docker_db_1|"
  #"compound_auth_image|multi_stop|docker_auth_1,docker_image_1|"
  #"compound_auth_recommender|multi_stop|docker_auth_1,docker_recommender_1|"
  #"resource_cpu_webui|throttle_cpu|docker_webui_1|0.3"
  #"resource_mem_webui|throttle_mem|docker_webui_1|256m"
  "resource_cpu_db|throttle_cpu|docker_db_1|0.3"
)

REPEATS=1

# Fault injection timing (seconds into the run)
FAULT_INJECT_AT=15    # inject fault this many seconds after load starts
FAULT_DURATION=10    # how long to keep fault active
TOTAL_DURATION=130    # total experiment duration

mkdir -p $RESULTS_DIR

# ===== CLEANUP TRAP =====
cleanup() {
  echo "Cleaning up..."
  kill $STATS_PID 2>/dev/null
  wait $STATS_PID 2>/dev/null
  pkill -f "docker stats" 2>/dev/null || true
  clear_latency 2>/dev/null || true
  # restore any throttled containers
  docker update --cpus="" --memory="" --memory-swap="" docker_webui_1 2>/dev/null || true
  docker update --cpus="" --memory="" --memory-swap="" docker_db_1 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ===== WAIT FOR TEASTORE =====
wait_for_teastore() {
  echo "Waiting for TeaStore..."
  until curl -s --max-time 5 http://localhost:8080/tools.descartes.teastore.webui/ | grep -q "TeaStore"; do
    sleep 5
  done
  echo "TeaStore is up."
}

# ===== CLEAR LATENCY =====
clear_latency() {
  sudo tc qdisc del dev $NET_IFACE root 2>/dev/null || true
}

# ===== AVAILABILITY MONITOR =====
# Continuously probes TeaStore and logs availability + response time
start_availability_monitor() {
  local output_file=$1
  echo "timestamp,status,response_time_ms,http_code" > $output_file
  (
    while true; do
      ts=$(date +%s%3N)
      result=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
        --max-time 5 http://localhost:8080/tools.descartes.teastore.webui/ 2>/dev/null)
      http_code=$(echo $result | awk '{print $1}')
      response_ms=$(echo $result | awk '{printf "%.0f", $2 * 1000}')

      if [ "$http_code" = "200" ]; then
        status="up"
      elif [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
        status="down"
      else
        status="degraded"
      fi

      echo "$ts,$status,$response_ms,$http_code" >> $output_file
      sleep 1
    done
  ) &
  AVAIL_PID=$!
}

stop_availability_monitor() {
  kill $AVAIL_PID 2>/dev/null
  wait $AVAIL_PID 2>/dev/null
}

# ===== FAULT INJECTION =====
inject_fault() {
  local fault_type=$1
  local target=$2
  local param=$3
  local output_dir=$4

  FAULT_START_TS=$(date +%s%3N)
  echo "fault_start_ts=$FAULT_START_TS" >> $output_dir/metadata.txt
  echo "--- Injecting fault: type=$fault_type target=$target param=$param ---"

  case $fault_type in
    stop)
      docker stop $target
      echo "Stopped container: $target"
      ;;

    db_stop)
      docker stop $target
      echo "Stopped database: $target"
      ;;

    multi_stop)
      IFS=',' read -ra targets <<< "$target"
      for t in "${targets[@]}"; do
        docker stop $t
        echo "Stopped container: $t"
      done
      ;;

    throttle_cpu)
      docker update --cpus="$param" $target
      echo "CPU throttled $target to $param cores"
      ;;

    throttle_mem)
      docker update --memory="$param" --memory-swap="$param" $target
      echo "Memory throttled $target to $param"
      ;;

    net_latency)
      sudo tc qdisc add dev $NET_IFACE root netem delay ${param}ms
      echo "Network latency of ${param}ms applied"
      ;;
  esac
}

# ===== FAULT RECOVERY =====
recover_fault() {
  local fault_type=$1
  local target=$2
  local output_dir=$3

  echo "--- Recovering from fault: type=$fault_type target=$target ---"

  case $fault_type in
    stop|db_stop)
      docker start $target
      echo "Restarted container: $target"
      ;;

    multi_stop)
      IFS=',' read -ra targets <<< "$target"
      for t in "${targets[@]}"; do
        docker start $t
        echo "Restarted container: $t"
      done
      ;;

    throttle_cpu)
      docker update --cpus="" $target
      echo "CPU throttle removed from $target"
      ;;

    throttle_mem)
      docker update --memory="" --memory-swap="" $target
      echo "Memory throttle removed from $target"
      ;;

    net_latency)
      clear_latency
      echo "Network latency cleared"
      ;;
  esac

  FAULT_END_TS=$(date +%s%3N)
  echo "fault_end_ts=$FAULT_END_TS" >> $output_dir/metadata.txt
}

# ===== COMPUTE RECOVERY TIME =====
compute_recovery_time() {
  local avail_file=$1
  local fault_end_ts=$2
  local output_dir=$3

  echo "Computing recovery time..."

  # Find first timestamp after fault recovery where status returns to 'up'
  recovery_ts=$(awk -F',' -v ts="$fault_end_ts" '
    NR>1 && $1 > ts && $2=="up" {print $1; exit}
  ' $avail_file)

  if [ -n "$recovery_ts" ]; then
    recovery_time_ms=$((recovery_ts - fault_end_ts))
    echo "Recovery time: ${recovery_time_ms}ms"
    echo "recovery_time_ms=$recovery_time_ms" >> $output_dir/metadata.txt
    echo "recovery_ts=$recovery_ts" >> $output_dir/metadata.txt
  else
    echo "WARNING: System did not recover during experiment window"
    echo "recovery_time_ms=NEVER" >> $output_dir/metadata.txt
  fi
}

# ===== RUN SINGLE EXPERIMENT =====
run_experiment() {
  local scenario_name=$1
  local fault_type=$2
  local fault_target=$3
  local fault_param=$4
  local run_id=$5

  OUTPUT_DIR="$RESULTS_DIR/${scenario_name}_run=${run_id}_$(date +%H%M%S)"
  mkdir -p $OUTPUT_DIR

  echo "======================================"
  echo "Scenario: $scenario_name | Run: $run_id"
  echo "Fault: type=$fault_type target=$fault_target param=$fault_param"
  echo "Output: $OUTPUT_DIR"
  echo "======================================"

  # --- Reset system ---
  sudo docker-compose -f $COMPOSE_FILE down --remove-orphans
  sudo docker system prune -f

  # --- Start system ---
  sudo docker-compose -f $COMPOSE_FILE up -d
  sleep 180
  wait_for_teastore

  # --- Save metadata ---
  {
    echo "scenario=$scenario_name"
    echo "fault_type=$fault_type"
    echo "fault_target=$fault_target"
    echo "fault_param=$fault_param"
    echo "fault_inject_at=${FAULT_INJECT_AT}s"
    echo "fault_duration=${FAULT_DURATION}s"
    echo "total_duration=${TOTAL_DURATION}s"
    echo "hlg_threads=$HLG_THREADS"
  } > $OUTPUT_DIR/metadata.txt

  # --- Start availability monitor ---
  start_availability_monitor $OUTPUT_DIR/availability.csv

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

  # --- Start HLG in background ---
  echo "Starting httploadgenerator director..."
  touch $OUTPUT_DIR/hlg_results.csv
  (
    cd $OUTPUT_DIR
    java -jar $HLG_JAR director \
      -s $HLG_AGENT_IP \
      -p $HLG_AGENT_PORT \
      -a $HLG_ARRIVAL_CSV \
      -l $HLG_LUA_SCRIPT \
      -o hlg_results.csv \
      -t $HLG_THREADS \
      -u $HLG_TIMEOUT \
      2>&1 | tee $OUTPUT_DIR/hlg_director.log 
  ) &
  HLG_PID=$!
  echo "HLG started with PID $HLG_PID"

  # --- Fault injection timer ---
  (
    sleep $FAULT_INJECT_AT
    inject_fault $fault_type "$fault_target" "$fault_param" $OUTPUT_DIR
    sleep $FAULT_DURATION
    recover_fault $fault_type "$fault_target" $OUTPUT_DIR
  ) &
  FAULT_PID=$!

  # --- Wait for HLG to finish ---
  wait $HLG_PID
  HLG_EXIT=$?

  # --- Clean up background processes ---
  kill $FAULT_PID 2>/dev/null
  wait $FAULT_PID 2>/dev/null
  cd - > /dev/null

  # --- Stop monitors ---
  stop_availability_monitor
  kill $STATS_PID
  wait $STATS_PID 2>/dev/null
  sleep 2

  # --- Move HLG CSV ---
  HLG_ARRIVAL_DIR=$(dirname $HLG_ARRIVAL_CSV)
  if [ -f "$HLG_ARRIVAL_DIR/hlg_results.csv" ]; then
    mv "$HLG_ARRIVAL_DIR/hlg_results.csv" "$OUTPUT_DIR/hlg_results.csv"
    echo "HLG results moved to $OUTPUT_DIR"
  else
    echo "WARNING: HLG CSV not found, parsing from log..."
  fi

  # --- Compute recovery time ---
  FAULT_END_TS=$(grep "fault_end_ts" $OUTPUT_DIR/metadata.txt | cut -d'=' -f2)
  if [ -n "$FAULT_END_TS" ]; then
    compute_recovery_time $OUTPUT_DIR/availability.csv $FAULT_END_TS $OUTPUT_DIR
  fi

  # --- Summarize availability ---
  echo "Summarizing availability..."
  awk -F',' 'NR>1 {
    total++
    if ($2=="up") up++
    else if ($2=="down") down++
    else degraded++
  } END {
    printf "availability=%.2f%%\n", (up/total)*100
    printf "up_count=%d\n", up
    printf "down_count=%d\n", down
    printf "degraded_count=%d\n", degraded
    printf "total_probes=%d\n", total
  }' $OUTPUT_DIR/availability.csv | tee -a $OUTPUT_DIR/metadata.txt

  # --- Final docker stats ---
  docker stats --no-stream \
    --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" \
    > $OUTPUT_DIR/docker_stats_final.txt

  # --- Copy Kieker logs ---
  docker cp docker_webui_1:/kieker/logs $OUTPUT_DIR/kieker_webui_logs || true

  echo "Completed scenario=$scenario_name run=$run_id"
}

# ===== MAIN LOOP =====
for scenario in "${FAULT_SCENARIOS[@]}"; do
  IFS='|' read -r name type target param <<< "$scenario"
  for run in $(seq 1 $REPEATS); do
    run_experiment "$name" "$type" "$target" "$param" "$run"
  done
done

echo "===== FAULT INJECTION EXPERIMENT COMPLETE ====="
