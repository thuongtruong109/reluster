#!/bin/bash
set -euo pipefail

MAX_RETRY=${MAX_RETRY:-3}
STATE_FILE=".rollback-state.json"
LOG_FILE="/tmp/redis_cluster_rollback.log"
HEALTH_LOG="/tmp/redis_cluster_health.log"

mkdir -p /tmp
touch "$LOG_FILE"

# fallback state management nếu không có jq
init_state() {
  if [ ! -f "$STATE_FILE" ]; then
    python3 - <<EOF
import json
with open("${STATE_FILE}", "w") as f:
    json.dump({}, f)
EOF
  fi
}

get_retry_count() {
  local node=$1
  python3 - "$node" "$STATE_FILE" <<EOF
import json,sys
node=sys.argv[1]
f=sys.argv[2]
data=json.load(open(f))
print(data.get(node,0))
EOF
}

increment_retry_count() {
  local node=$1
  python3 - "$node" "$STATE_FILE" <<EOF
import json,sys
node=sys.argv[1]; f=sys.argv[2]
data=json.load(open(f))
data[node] = data.get(node,0)+1
json.dump(data,open(f,"w"))
EOF
}

wait_node_ready() {
  local node=$1
  for _ in {1..10}; do
    local reply
    reply=$(docker exec -e REDISCLI_AUTH="$CLUSTER_PASS" "$node" redis-cli ping 2>/dev/null || true)
    if [[ "$reply" == "PONG" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

rollback_node() {
  local node=$1
  local retry_count=$(get_retry_count "$node")

  echo "[INFO] Rollback node $node (retry $retry_count/$MAX_RETRY)" | tee -a "$LOG_FILE"

  if (( retry_count >= MAX_RETRY )); then
    echo "[WARN] Node $node reached max retry limit ($MAX_RETRY). Skipping rollback." | tee -a "$LOG_FILE"
    return
  fi

  docker stop "$node" || true
  docker rm "$node" || true
  docker compose -f docker-compose.cluster.yml up -d "$node"

  if wait_node_ready "$node"; then
    if docker exec node-1 redis-cli -a "$CLUSTER_PASS" --cluster add-node "$node:6379" node-1:6379 --cluster-yes; then
      docker exec node-1 redis-cli -a "$CLUSTER_PASS" --cluster rebalance node-1:6379 --cluster-use-empty-masters --cluster-yes
      echo "[OK] Node $node rollback successfully." | tee -a "$LOG_FILE"
      python3 - "$node" "$STATE_FILE" <<EOF
import json,sys
node=sys.argv[1]; f=sys.argv[2]
data=json.load(open(f))
if node in data: del data[node]
json.dump(data,open(f,"w"))
EOF
    else
      echo "[ERROR] Rollback failed for $node" | tee -a "$LOG_FILE"
      increment_retry_count "$node"
    fi
  else
    echo "[ERROR] Node $node did not become ready in time" | tee -a "$LOG_FILE"
    increment_retry_count "$node"
  fi
}

main() {
  init_state

  if [ ! -f "$HEALTH_LOG" ]; then
    echo "❌ Health log not found at $HEALTH_LOG"
    exit 1
  fi

  DOWN_NODES=$(grep "Redis node .* not responding" "$HEALTH_LOG" | awk '{print $4}' | tr '\n' ' ' || true)

  if [ -z "$DOWN_NODES" ]; then
    echo "✅ No nodes to rollback."
    exit 0
  fi

  echo "🔄 Found down nodes: $DOWN_NODES"
  for node in $DOWN_NODES; do
    rollback_node "$node"
  done
}

main "$@"
