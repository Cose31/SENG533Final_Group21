#!/bin/bash

# ===== CONFIG =====
# Using absolute paths is good, but let's ensure they are consistent
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEASTORE_DIR="$HOME/TeaStore"
COMPOSE_FILE="$TEASTORE_DIR/examples/docker/docker-compose_default.yaml"
K6_SCRIPT="baseline.js"
OUTPUT_DIR="$SCRIPT_DIR/baseline_results_$(date +%Y%m%d_%H%M%S)"
DURATION=120

mkdir -p $OUTPUT_DIR

echo "===== Resetting TeaStore (fresh DB) ====="

sudo docker-compose -f $COMPOSE_FILE down -v --remove-orphans
sudo docker system prune -f

echo "===== Starting TeaStore ====="
sudo docker-compose -f $COMPOSE_FILE up -d

echo "===== Waiting for TeaStore to fully initialize ====="
until curl -s http://localhost:8080/tools.descartes.teastore.webui/ | grep -q "TeaStore"; do
  echo "Waiting..."
  sleep 5
done

echo "===== Starting Docker stats collection ====="

(
  while true; do
    sudo docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" \
      >> $OUTPUT_DIR/docker_stats_live.csv
    sleep 1
  done
) &
STATS_PID=$!

echo "===== Running k6 test ====="

k6 run \
  --duration ${DURATION}s \
  --summary-export=$OUTPUT_DIR/k6_summary.json \
  $K6_SCRIPT > $OUTPUT_DIR/k6_output.txt

echo "===== Stopping Docker stats collection ====="
kill $STATS_PID

echo "===== Final Docker snapshot ====="
sudo docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" \
  > $OUTPUT_DIR/docker_stats_final.txt

echo "===== Done ====="
echo "Results saved in: $OUTPUT_DIR"

