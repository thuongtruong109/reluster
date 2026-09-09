#!/usr/bin/env bash
set -euo pipefail

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"

function redis_cli() {
  local container="$1"
  shift
  docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$container" redis-cli "$@"
}

function read_from_replica() {
  local container="$1"
  local key="$2"
  printf 'READONLY\nGET %s\n' "$key" \
    | docker exec -i -e REDISCLI_AUTH="$REDIS_PASSWORD" "$container" redis-cli --raw \
    | tail -n 1
}

echo "🚀 Redis Cluster Test Suite"

echo -e "\n[TEST 1] Cluster health check"
redis_cli node-1 -c cluster info | grep cluster_state

echo -e "\n[TEST 2] Key distribution"
redis_cli node-1 -c set foo bar
val=$(redis_cli node-1 -c get foo)
echo "foo=$val"

echo -e "\n[TEST 3] Insert multiple keys"
for i in $(seq 1 10); do
  redis_cli node-1 -c set "key$i" "val$i" >/dev/null
done
slot=$(redis_cli node-1 -c cluster keyslot key5)
echo "key5 in slot $slot"
redis_cli node-1 -c cluster getkeysinslot "$slot" 10

echo -e "\n[TEST 4] Replica sync"
redis_cli node-1 -c set sync-test 123
replica_node=""
for _ in $(seq 1 10); do
  for candidate in node-4 node-5 node-6; do
    replica_val=$(read_from_replica "$candidate" sync-test 2>/dev/null || true)
    if [ "$replica_val" = "123" ]; then
      replica_node="$candidate"
      break 2
    fi
  done
  sleep 1
done

if [ -z "$replica_node" ]; then
  echo "Replica sync failed: no replica returned the expected value" >&2
  exit 1
fi
echo "Replica $replica_node value: 123"

echo -e "\n[TEST 5] Failover (stop node-1)"
docker stop node-1
sleep 8
redis_cli node-2 cluster nodes | grep master
docker start node-1
sleep 5

echo -e "\n[TEST 6] Rejoin node-1"
redis_cli node-1 cluster info | grep cluster_state

echo -e "\n[TEST 7] Persistence after restart"
redis_cli node-2 -c set persist-key hello
docker restart node-2
sleep 5
val=$(redis_cli node-2 -c get persist-key)
echo "persist-key=$val"

echo -e "\n✅ All tests completed!"
