#!/bin/bash

# ===== CONFIG =====
TEASTORE_DIR="$HOME/TeaStore"
COMPOSE_FILE="$TEASTORE_DIR/examples/docker/docker-compose_kieker.yaml"

SCRIPT_DIR="$HOME/scripts"
RESULTS_DIR="$SCRIPT_DIR/db_var_results"

K6_SCRIPT="$SCRIPT_DIR/mixed.js"

DB_MODES=("normal_db" "large")
REPEATS=3
VUS=10
DURATION="2m"

mkdir -p $RESULTS_DIR

# ===== WAIT FOR TEASTORE =====
wait_for_teastore() {
  echo "Waiting for TeaStore..."
  until curl -s http://localhost:8080/tools.descartes.teastore.webui/ | grep -q "TeaStore"; do
    sleep 5
  done
}

# ===== POPULATE DB =====
populate_db() {
  echo "Populating DB with 100k products..."

  docker cp $SCRIPT_DIR/populate_products.sql docker_db_1:/populate.sql
  
  docker exec -i docker_db_1 \
    mysql -u root -prootpassword teadb < populate_products.sql
   
  PRODUCT_COUNT=$(docker exec docker_db_1 mysql -u root -prootpassword teadb -N -s -e "SELECT COUNT(*) FROM PERSISTENCEPRODUCT;")

  echo "DB population complete"
  echo "actual_db_count=$PRODUCT_COUNT"
  echo "actual_db_count=$PRODUCT_COUNT" >> $OUTPUT_DIR/metadata.txt
}

# ===== RUN SINGLE EXPERIMENT =====
run_experiment() {
  db_mode=$1
  run_id=$2

  OUTPUT_DIR="$RESULTS_DIR/db=${db_mode}_run=${run_id}_$(date +%H%M%S)"
  mkdir -p $OUTPUT_DIR

  echo "======================================"
  echo "DB Mode: $db_mode | Run: $run_id"
  echo "Output: $OUTPUT_DIR"
  echo "======================================"

  # --- Reset system ---
  sudo docker-compose -f $COMPOSE_FILE down -v --remove-orphans
  sudo docker system prune -f

  # --- Start system ---
  sudo docker-compose -f $COMPOSE_FILE up -d

  sleep 180 # warmup period
  wait_for_teastore

  # --- Populate DB if needed ---
  if [ "$db_mode" == "large" ]; then
    populate_db
  fi

  # --- Save metadata ---
  echo "db_mode=$db_mode" > $OUTPUT_DIR/metadata.txt
  echo "vus=$VUS" >> $OUTPUT_DIR/metadata.txt
  echo "duration=$DURATION" >> $OUTPUT_DIR/metadata.txt
  echo "run=$run_id" >> $OUTPUT_DIR/metadata.txt
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
  echo "Running k6 mixed workload..."

  k6 run \
    -e VUS=$VUS \
    -e DURATION=$DURATION \
    --summary-export=$OUTPUT_DIR/k6_summary.json \
    $K6_SCRIPT > $OUTPUT_DIR/k6_output.txt

  # --- Stop stats ---
  kill $STATS_PID
  
  # docker keiker logs if exists
  docker cp docker_webui_1:/kieker/logs $OUTPUT_DIR/kieker_webui_logs || true

  # --- Final snapshot ---
  docker stats --no-stream \
    --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" \
    > $OUTPUT_DIR/docker_stats_final.txt

  echo "Completed DB=$db_mode Run=$run_id"
}

# ===== MAIN LOOP =====
for db in "${DB_MODES[@]}"; do
  for run in $(seq 1 $REPEATS); do
    run_experiment $db $run
  done
done

echo "===== DB EXPERIMENT COMPLETE =====" 
