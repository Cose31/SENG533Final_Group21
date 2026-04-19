#!/bin/bash
# ===== CONFIG =====
TEASTORE_DIR="$HOME/TeaStore"
COMPOSE_FILE="$TEASTORE_DIR/examples/docker/docker-compose_kieker.yaml"
SCRIPT_DIR="$HOME/scripts"
RESULTS_DIR="$SCRIPT_DIR/db_var_results"

# httploadgenerator config
HLG_JAR="$SCRIPT_DIR/httploadgenerator.jar"
HLG_AGENT_IP="10.1.3.143"
HLG_AGENT_PORT="24226"          # default agent port, change if needed
HLG_ARRIVAL_CSV="$TEASTORE_DIR/examples/httploadgenerator/increasingLowIntensity.csv"
HLG_LUA_SCRIPT="$TEASTORE_DIR/examples/httploadgenerator/teastore_browse.lua"
HLG_THREADS=64

DB_MODES=("normal_db")
REPEATS=1

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

# ===== POPULATE DB =====
populate_db() {
  echo "Populating DB with 100k products..."
  docker cp $SCRIPT_DIR/populate_products.sql docker_db_1:/populate.sql
  docker exec -i docker_db_1 \
    mysql -u root -prootpassword teadb < populate_products.sql
  PRODUCT_COUNT=$(docker exec docker_db_1 mysql -u root -prootpassword teadb -N -s -e \
    "SELECT COUNT(*) FROM PERSISTENCEPRODUCT;")
  echo "DB population complete — actual_db_count=$PRODUCT_COUNT"
  echo "actual_db_count=$PRODUCT_COUNT" >> $OUTPUT_DIR/metadata.txt
}

# ===== RUN SINGLE EXPERIMENT =====
run_experiment() {
  db_mode=$1
  run_id=$2
  OUTPUT_DIR="$RESULTS_DIR/db=${db_mode}_run=${run_id}_$(date +%H%M%S)"
  mkdir -p $OUTPUT_DIR

  HLG_OUTPUT_CSV="$OUTPUT_DIR/hlg_results.csv"

  echo "======================================"
  echo "DB Mode: $db_mode | Run: $run_id"
  echo "Output: $OUTPUT_DIR"
  echo "======================================"

  # --- Reset system ---
  sudo docker-compose -f $COMPOSE_FILE down -v --remove-orphans
  sudo docker system prune -f

  # --- Start system ---
  sudo docker-compose -f $COMPOSE_FILE up -d
  sleep 120  # warmup period
  wait_for_teastore

  # --- Populate DB if needed ---
  if [ "$db_mode" == "large" ]; then
    populate_db
  fi

  # --- Save metadata ---
  {
    echo "db_mode=$db_mode"
    echo "hlg_agent=$HLG_AGENT_IP"
    echo "hlg_threads=$HLG_THREADS"
    echo "hlg_arrival_csv=$HLG_ARRIVAL_CSV"
    echo "hlg_lua=$HLG_LUA_SCRIPT"
  } > $OUTPUT_DIR/metadata.txt

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

  echo "Completed DB=$db_mode Run=$run_id"
}

# ===== MAIN LOOP =====
for db in "${DB_MODES[@]}"; do
  for run in $(seq 1 $REPEATS); do
    run_experiment $db $run
  done
done

echo "===== DB EXPERIMENT COMPLETE ====="
