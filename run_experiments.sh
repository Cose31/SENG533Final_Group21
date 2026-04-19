
#!/bin/bash

# ===== CONFIG =====
TEASTORE_DIR="$HOME/TeaStore"
COMPOSE_FILE="$TEASTORE_DIR/examples/docker/docker-compose_default.yaml"

SCRIPT_DIR="$HOME/scripts"
RESULTS_DIR="$SCRIPT_DIR/results"

WORKLOADS=("trans" "browse" "mixed")
VUS_LEVELS=(50)
REPEATS=3
DURATION="2m"

mkdir -p $RESULTS_DIR

# ===== FUNCTION: WAIT FOR TEASTORE =====
wait_for_teastore() {
  echo "Waiting for TeaStore..."
  until curl -s http://localhost:8080/tools.descartes.teastore.webui/ | grep -q "TeaStore"; do
    sleep 60
  done
}

# ===== FUNCTION: RUN SINGLE EXPERIMENT =====
run_experiment() {
  workload=$1
  vus=$2
  run_id=$3

  OUTPUT_DIR="$RESULTS_DIR/workload=${workload}_vus=${vus}_run=${run_id}_$(date +%H%M%S)"
  mkdir -p $OUTPUT_DIR

  echo "======================================"
  echo "Running: $workload | VUS=$vus | Run=$run_id"
  echo "Output: $OUTPUT_DIR"
  echo "======================================"

  # --- Reset system ---
  sudo docker-compose -f $COMPOSE_FILE down -v --remove-orphans
  sudo docker system prune -f

  # --- Start system ---
  sudo docker-compose -f $COMPOSE_FILE up -d
  
  sleep 120 # allow warmup to occur

  wait_for_teastore

  # --- Save metadata ---
  echo "workload=$workload" > $OUTPUT_DIR/metadata.txt
  echo "vus=$vus" >> $OUTPUT_DIR/metadata.txt
  echo "run=$run_id" >> $OUTPUT_DIR/metadata.txt
  echo "duration=$DURATION" >> $OUTPUT_DIR/metadata.txt
  echo "timestamp=$(date)" >> $OUTPUT_DIR/metadata.txt

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

  # --- Run k6 ---
  K6_SCRIPT="$SCRIPT_DIR/${workload}.js"

  if [ ! -f "$K6_SCRIPT" ]; then
    echo "ERROR: Missing script $K6_SCRIPT"
    kill $STATS_PID
    exit 1
  fi

  k6 run \
    -e VUS=$vus \
    -e DURATION=$DURATION \
    --summary-export=$OUTPUT_DIR/k6_summary.json \
    $K6_SCRIPT > $OUTPUT_DIR/k6_output.txt

  # --- Stop stats ---
  kill $STATS_PID

  # --- Final snapshot ---
  docker stats --no-stream \
    --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" \
    > $OUTPUT_DIR/docker_stats_final.txt

  echo "Completed: $workload | VUS=$vus | Run=$run_id"
}

# ===== MAIN LOOP =====
for workload in "${WORKLOADS[@]}"; do
  for vus in "${VUS_LEVELS[@]}"; do
    for run in $(seq 1 $REPEATS); do
      run_experiment $workload $vus $run
    done
  done
done

echo "===== ALL EXPERIMENTS COMPLETE ====="
