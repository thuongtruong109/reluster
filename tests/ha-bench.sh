#!/usr/bin/env bash
set -euo pipefail

HA_PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export HA_PROJECT_DIR
# shellcheck source=scripts/lib/ha-compose.sh
source "$HA_PROJECT_DIR/scripts/lib/ha-compose.sh"

MASTER_NAME="redis-master"
SENTINEL_NAME="sentinel_1"

: "${MASTER_PASS:=${REDIS_PASSWORD:?REDIS_PASSWORD must be set}}"
: "${SENTINEL_PASSWORD:?SENTINEL_PASSWORD must be set}"

function sentinel_cli() {
  local container="$1"
  shift
  ha_exec "$container" env REDISCLI_AUTH="$SENTINEL_PASSWORD" redis-cli -p 26379 "$@"
}

function wait_for_replication() {
  echo "⏳ Waiting for Redis replication to be ready..."
  sleep 20
  ha_exec "$MASTER_NAME" redis-cli -a "$MASTER_PASS" PING

  for i in 1 2 3; do
    ha_exec "slave_$i" redis-cli -a "$MASTER_PASS" PING
  done

  for i in 1 2 3; do
    sentinel_cli "sentinel_$i" PING
  done
  echo "✅ Replication is ready"
}

function benchmark_master() {
  echo "🚀 Benchmark master (write)..."
  redis-benchmark -h 127.0.0.1 -p 6379 -a "$MASTER_PASS" -t set -n 100000 -c 50 -q
}

function benchmark_slave() {
  echo "📖 Benchmark slave_1 (read)..."
  redis-benchmark -h 127.0.0.1 -p 6380 -a "$MASTER_PASS" -t get -n 100000 -c 50 -q
}

function benchmark_failover() {
  echo "🔥 Running failover benchmark..."
  redis-benchmark -h 127.0.0.1 -p 6379 -a "$MASTER_PASS" -t set -n 1000000 -c 50 -q &
  BENCH_PID=$!

  sleep 5
  echo "🛑 Stopping master..."
  ha_compose stop "$MASTER_NAME"

  echo "⏳ Waiting for failover..."
  sleep 15

  NEW_MASTER_IP=$(sentinel_cli "$SENTINEL_NAME" SENTINEL get-master-addr-by-name mymaster | sed -n '1p')
  echo "✅ New master elected: $NEW_MASTER_IP"

  echo "🚀 Benchmark new master..."
  ha_exec "$SENTINEL_NAME" redis-benchmark -h "$NEW_MASTER_IP" -p 6379 -a "$MASTER_PASS" -t set -n 100000 -c 50 -q

  wait "$BENCH_PID" || true
}

case "${1:-}" in
  check)
    wait_for_replication
    ;;
  master)
    benchmark_master
    ;;
  slave)
    benchmark_slave
    ;;
  failover)
    benchmark_failover
    ;;
  all|"")
    wait_for_replication
    benchmark_master
    benchmark_slave
    benchmark_failover
    ;;
  *)
    echo "Usage: $0 {check|master|slave|failover|all}"
    exit 1
    ;;
esac
