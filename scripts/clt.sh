#!/usr/bin/env bash
set -euo pipefail

: "${CLUSTER_PASS:=${REDIS_PASSWORD:?REDIS_PASSWORD must be set}}"

CLUSTER_PORT=6379
TOTAL_MASTERS=3
TOTAL_REPLICAS=3
TOTAL_NODES=$((TOTAL_MASTERS + TOTAL_REPLICAS))

CLUSTER_NODES=()
for i in $(seq 1 $TOTAL_NODES); do
  CLUSTER_NODES+=("node-$i")
done

function wait_for_cluster() {
  echo "⏳ Waiting for Redis Cluster to be ready..."
  sleep 20

  for node in "${CLUSTER_NODES[@]}"; do
    echo "- Checking $node..."
    local deadline=$((SECONDS + 60))
    local reply
    while true; do
      reply=$(docker exec -e REDISCLI_AUTH="$CLUSTER_PASS" "$node" redis-cli -p "$CLUSTER_PORT" ping 2>/dev/null || true)
      if [[ "$reply" == "PONG" ]]; then
        break
      fi
      if (( SECONDS >= deadline )); then
        echo "❌ Timed out waiting for $node"
        exit 1
      fi
      sleep 2
    done
  done

  if docker exec -e REDISCLI_AUTH="$CLUSTER_PASS" node-1 redis-cli cluster info | grep -q "cluster_state:ok"; then
    echo "✅ Cluster state OK"
  else
    echo "❌ Cluster not healthy"
    exit 1
  fi
}

function validate_config() {
  local config="configs/cluster/node.conf"
  if [ ! -f "$config" ]; then
    echo "❌ Missing configuration file: $config"
    exit 1
  fi
  echo "✅ All configuration files present"
}

function cluster_security_scan() {
  echo "🔐 Running cluster security checks..."

  TRIVY_OUTPUT="${GITHUB_WORKSPACE:-.}/trivy-cluster-results.sarif"
  if [ -f "$TRIVY_OUTPUT" ]; then
    echo "🛡️ Trivy SARIF report found at $TRIVY_OUTPUT"
  else
    echo "⚠️ Trivy report not found, skipping config scan"
  fi

  echo "📡 Checking open ports..."
  for node in "${CLUSTER_NODES[@]}"; do
    if docker exec "$node" sh -c "nc -z localhost $CLUSTER_PORT" >/dev/null 2>&1; then
      echo "✅ $node port $CLUSTER_PORT is open"
    fi
  done

  echo "🔑 Checking password requirement..."
  local unauthenticated_reply
  local authenticated_reply
  unauthenticated_reply=$(docker exec node-1 redis-cli ping 2>/dev/null || true)
  authenticated_reply=$(docker exec -e REDISCLI_AUTH="$CLUSTER_PASS" node-1 redis-cli ping 2>/dev/null || true)

  if [[ "$unauthenticated_reply" != NOAUTH* ]]; then
    echo "❌ Cluster allows unauthenticated access!"
    exit 1
  fi

  if [[ "$authenticated_reply" != "PONG" ]]; then
    echo "❌ Cluster rejected the configured REDIS_PASSWORD"
    exit 1
  fi

  echo "✅ Cluster rejects unauthenticated access"

  echo "✅ Security scan passed"
}

function show_status() {
  echo "📌 Cluster status:"
  docker exec node-1 redis-cli -a "$CLUSTER_PASS" -p $CLUSTER_PORT cluster nodes \
    | awk '{
        if ($3 ~ /master/) {
          printf("🟢 MASTER  %s  %s  slots:%s\n", $2, $1, $9);
        } else if ($3 ~ /slave/) {
          printf("🔵 REPLICA %s  %s  replicates:%s\n", $2, $1, $4);
        }
      }'
}

function monitor_cluster() {
    CLUSTER_STATE=$(docker exec node-1 redis-cli -a "$CLUSTER_PASS" -p $CLUSTER_PORT cluster info | grep cluster_state | cut -d: -f2)
    if [ "$CLUSTER_STATE" != "ok" ]; then
        echo "❌ Cluster state not OK: $CLUSTER_STATE"
        exit 1
    fi

    echo "📌 Redis Cluster Advanced Monitoring"
    echo "-----------------------------------"

    echo "📄 Cluster Info:"
    docker exec node-1 redis-cli -a "$CLUSTER_PASS" -p $CLUSTER_PORT cluster info
    echo ""

    echo "📄 Cluster Nodes:"
    docker exec node-1 redis-cli -a "$CLUSTER_PASS" -p $CLUSTER_PORT cluster nodes
    echo "-----------------------------------"

    TOTAL_MEMORY=0
    printf "%-12s %-8s %-12s %-12s %-10s %-15s\n" "NODE" "ROLE" "USED_MEM" "USED_BYTES" "LATENCY(ms)" "SLOWLOG_COUNT"

    for NODE in "${CLUSTER_NODES[@]}"; do
        ROLE_RAW=$(docker exec "$NODE" redis-cli -a "$CLUSTER_PASS" -p $CLUSTER_PORT INFO replication | grep 'role:' | cut -d: -f2 | tr -d '\r')
        if [ "$ROLE_RAW" == "master" ]; then
            ROLE="\e[32mMASTER\e[0m"
        else
            ROLE="\e[34mREPLICA\e[0m"
        fi

        USED_BYTES=$(docker exec "$NODE" redis-cli -a "$CLUSTER_PASS" -p $CLUSTER_PORT INFO memory | grep 'used_memory:' | head -n1 | cut -d: -f2)
        USED_H=$(docker exec "$NODE" redis-cli -a "$CLUSTER_PASS" -p $CLUSTER_PORT INFO memory | grep 'used_memory_human:' | cut -d: -f2 | tr -d '\r')
        TOTAL_MEMORY=$((TOTAL_MEMORY + USED_BYTES))

        LATENCY=$(docker exec "$NODE" redis-cli -a "$CLUSTER_PASS" -p $CLUSTER_PORT --latency 0.5 -c -n 5 2>/dev/null | awk '/avg/ {print $2}')

        SLOW_COUNT=$(docker exec "$NODE" redis-cli -a "$CLUSTER_PASS" -p $CLUSTER_PORT SLOWLOG LEN)

        printf "%-12s %-8b %-12s %-12s %-10s %-15s\n" "$NODE" "$ROLE" "$USED_H" "$USED_BYTES" "$LATENCY" "$SLOW_COUNT"
    done

    echo "-----------------------------------"
    echo "💾 Total used memory in cluster: $TOTAL_MEMORY bytes"
    echo ""
    echo "🔎 Top 10 slowlog entries per node (ID, Timestamp, Command):"
    for NODE in "${CLUSTER_NODES[@]}"; do
        echo "Node: $NODE"
        docker exec "$NODE" redis-cli -a "$CLUSTER_PASS" -p $CLUSTER_PORT SLOWLOG GET 10 | \
        awk 'NR % 3 == 1 {printf "ID: %s, Timestamp: ", $2} NR % 3 == 2 {print $0} NR % 3 == 0 {print "Command: "$0"\n"}'
        echo ""
    done
}

case "${1:-}" in
  ready)
    wait_for_cluster
    ;;
  validate)
    validate_config
    ;;
  scan)
    cluster_security_scan
    ;;
  status)
    show_status
    ;;
  monitor)
    monitor_cluster
    ;;
  all|"")
    wait_for_cluster
    validate_config
    cluster_security_scan
    monitor_cluster
    ;;
  *)
    echo "Usage: $0 {ready|validate|scan|status|monitor|all}"
    exit 1
    ;;
esac
