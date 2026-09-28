#!/usr/bin/env bash
set -euo pipefail

HA_MASTER_NAME="redis-master"
CONTAINERS=(redis-master slave_1 slave_2 slave_3 sentinel_1 sentinel_2 sentinel_3)
REDIS_PORTS=(6379 6380 26379)

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
: "${SENTINEL_PASSWORD:?SENTINEL_PASSWORD must be set}"

function sentinel_cli() {
  local container="$1"
  shift
  docker exec -e REDISCLI_AUTH="$SENTINEL_PASSWORD" "$container" redis-cli -p 26379 "$@"
}

function wait_for_redis() {
  local container="$1"
  local deadline=$((SECONDS + 60))
  local reply

  while true; do
    reply=$(docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$container" redis-cli ping 2>/dev/null || true)
    if [[ "$reply" == "PONG" ]]; then
      return 0
    fi

    if (( SECONDS >= deadline )); then
      echo "❌ Timed out waiting for $container"
      return 1
    fi
    sleep 2
  done
}

function wait_for_sentinel() {
  local container="$1"
  local deadline=$((SECONDS + 60))
  local reply

  while true; do
    reply=$(sentinel_cli "$container" ping 2>/dev/null || true)
    if [[ "$reply" == "PONG" ]]; then
      return 0
    fi

    if (( SECONDS >= deadline )); then
      echo "❌ Timed out waiting for $container"
      return 1
    fi
    sleep 2
  done
}

function wait_for_replication() {
  echo "⏳ Waiting for Redis Replication to be ready..."
  sleep 20

  wait_for_redis "$HA_MASTER_NAME"

  for i in 1 2 3; do
    wait_for_redis "slave_$i"
  done

  for i in 1 2 3; do
    wait_for_sentinel "sentinel_$i"
  done

  echo "✅ Replication is ready"
}

function validate_config() {
  for config in configs/ha/replica/redis.conf configs/ha/role-discovery.sh configs/ha/sentinel/sentinel.conf; do
    if [ ! -f "$config" ]; then
      echo "❌ Missing configuration file: $config"
      exit 1
    fi
  done
  echo "✅ All configuration files present"
}

function replication_security_scan() {
  echo "🔐 Running security checks..."

  TRIVY_OUTPUT="${GITHUB_WORKSPACE:-.}/trivy-results.sarif"
  if [ -f "$TRIVY_OUTPUT" ]; then
    echo "🛡️ Trivy SARIF report found at $TRIVY_OUTPUT"
  else
    echo "⚠️ Trivy report not found, skipping config scan"
  fi

  echo "📡 Checking open ports in containers..."
  for container in "${CONTAINERS[@]}"; do
    echo "- Checking container $container..."
    for port in "${REDIS_PORTS[@]}"; do
      if docker exec "$container" sh -c "nc -z localhost $port" >/dev/null 2>&1; then
        echo "✅ $container port $port is open"
      fi
    done
  done

  echo "🔑 Checking password requirement on $HA_MASTER_NAME..."
  local unauthenticated_reply
  local authenticated_reply
  unauthenticated_reply=$(docker exec "$HA_MASTER_NAME" redis-cli ping 2>/dev/null || true)
  authenticated_reply=$(docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$HA_MASTER_NAME" redis-cli ping 2>/dev/null || true)

  if [[ "$unauthenticated_reply" != NOAUTH* ]]; then
    echo "❌ Redis master allows unauthenticated access!"
    exit 1
  fi

  if [[ "$authenticated_reply" != "PONG" ]]; then
    echo "❌ Redis master rejected the configured REDIS_PASSWORD"
    exit 1
  fi

  echo "✅ Redis master rejects unauthenticated access"

  echo "🔑 Checking password requirement on Sentinel..."
  local sentinel_unauthenticated_reply
  local sentinel_authenticated_reply
  sentinel_unauthenticated_reply=$(docker exec sentinel_1 redis-cli -p 26379 ping 2>/dev/null || true)
  sentinel_authenticated_reply=$(sentinel_cli sentinel_1 ping 2>/dev/null || true)

  if [[ "$sentinel_unauthenticated_reply" != NOAUTH* ]]; then
    echo "❌ Sentinel allows unauthenticated access!"
    exit 1
  fi

  if [[ "$sentinel_authenticated_reply" != "PONG" ]]; then
    echo "❌ Sentinel rejected the configured SENTINEL_PASSWORD"
    exit 1
  fi

  echo "✅ Sentinel rejects unauthenticated access"

  echo "✅ Security scan passed"
}

case "${1:-}" in
  ready)
    wait_for_replication
    ;;
  validate)
    validate_config
    ;;
  scan)
    replication_security_scan
    ;;
  all|"")
    wait_for_replication
    validate_config
    replication_security_scan
    ;;
  *)
    echo "Usage: $0 {ready|validate|scan|all}"
    exit 1
    ;;
esac
