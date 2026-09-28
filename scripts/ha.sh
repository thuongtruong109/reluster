#!/usr/bin/env bash
set -euo pipefail

HA_PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export HA_PROJECT_DIR
# shellcheck source=scripts/lib/ha-compose.sh
source "$HA_PROJECT_DIR/scripts/lib/ha-compose.sh"
# shellcheck source=configs/common/write-durability.sh
source "$HA_PROJECT_DIR/configs/common/write-durability.sh"

HA_MASTER_SERVICE="redis-master"
HA_SERVICES=(redis-master slave_1 slave_2 slave_3 sentinel_1 sentinel_2 sentinel_3)
REDIS_PORTS=(6379 6380 26379)

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
: "${SENTINEL_PASSWORD:?SENTINEL_PASSWORD must be set}"
configure_write_durability

function sentinel_cli() {
  local container="$1"
  shift
  ha_exec "$container" env REDISCLI_AUTH="$SENTINEL_PASSWORD" redis-cli -p 26379 "$@"
}

function wait_for_redis() {
  local container="$1"
  local deadline=$((SECONDS + 60))
  local reply

  while true; do
    reply=$(ha_exec "$container" env REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping 2>/dev/null || true)
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

function wait_for_write_capacity() {
  if (( REDIS_MIN_REPLICAS_TO_WRITE == 0 )); then
    return 0
  fi

  local deadline=$((SECONDS + 60))
  local master_address
  local master_host
  local master_port
  local replication_info
  local good_replicas

  while true; do
    master_address=$(sentinel_cli sentinel_1 --raw SENTINEL get-master-addr-by-name mymaster 2>/dev/null || true)
    master_host=$(sed -n '1p' <<< "$master_address" | tr -d '\r')
    master_port=$(sed -n '2p' <<< "$master_address" | tr -d '\r')

    if [[ -n "$master_host" && "$master_port" =~ ^[0-9]+$ ]]; then
      replication_info=$(ha_exec "$HA_MASTER_SERVICE" env REDISCLI_AUTH="$REDIS_PASSWORD" \
        redis-cli -h "$master_host" -p "$master_port" INFO replication 2>/dev/null || true)
      good_replicas=$(awk -F'[:,=]' -v max_lag="$REDIS_MIN_REPLICAS_MAX_LAG" '
        /^slave[0-9]+:/ {
          state = ""; lag = max_lag + 1
          for (i = 2; i <= NF; i += 2) {
            if ($i == "state") state = $(i + 1)
            if ($i == "lag") lag = $(i + 1)
          }
          if (state == "online" && lag <= max_lag) good++
        }
        END { print good + 0 }
      ' <<< "$replication_info")

      if (( good_replicas >= REDIS_MIN_REPLICAS_TO_WRITE )); then
        echo "✅ Write safety ready: $good_replicas replica(s) within ${REDIS_MIN_REPLICAS_MAX_LAG}s lag"
        return 0
      fi
    fi

    if (( SECONDS >= deadline )); then
      echo "❌ Timed out waiting for write durability quorum"
      return 1
    fi
    sleep 2
  done
}

function wait_for_replication() {
  echo "⏳ Waiting for Redis Replication to be ready..."
  sleep 20

  wait_for_redis "$HA_MASTER_SERVICE"

  for i in 1 2 3; do
    wait_for_redis "slave_$i"
  done

  for i in 1 2 3; do
    wait_for_sentinel "sentinel_$i"
  done

  wait_for_write_capacity

  echo "✅ Replication is ready"
}

function validate_config() {
  for config in configs/common/write-durability.sh configs/ha/replica/redis.conf configs/ha/role-discovery.sh configs/ha/sentinel/sentinel.conf; do
    if [ ! -f "$HA_PROJECT_DIR/$config" ]; then
      echo "❌ Missing configuration file: $config"
      exit 1
    fi
  done

  if grep -Eq 'container_name:|ipv4_address:|^[[:space:]]+-?[[:space:]]*subnet:' "$HA_PROJECT_DIR/docker-compose.ha.yml"; then
    echo "❌ HA Compose must use service discovery instead of fixed container names, IPs, or subnets"
    exit 1
  fi

  if ! grep -q '^sentinel resolve-hostnames yes' "$HA_PROJECT_DIR/configs/ha/sentinel/sentinel.conf"; then
    echo "❌ Sentinel hostname discovery is not enabled"
    exit 1
  fi

  if ! grep -q '^min-replicas-to-write ' "$HA_PROJECT_DIR/configs/ha/replica/redis.conf" \
    || ! grep -q '^min-replicas-max-lag ' "$HA_PROJECT_DIR/configs/ha/replica/redis.conf"; then
    echo "❌ HA write durability policy is missing"
    exit 1
  fi
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

  echo "📡 Checking open ports in services..."
  for service in "${HA_SERVICES[@]}"; do
    echo "- Checking service $service..."
    for port in "${REDIS_PORTS[@]}"; do
      if ha_exec "$service" sh -c "nc -z localhost $port" >/dev/null 2>&1; then
        echo "✅ $service port $port is open"
      fi
    done
  done

  echo "🔑 Checking password requirement on $HA_MASTER_SERVICE..."
  local unauthenticated_reply
  local authenticated_reply
  unauthenticated_reply=$(ha_exec "$HA_MASTER_SERVICE" redis-cli ping 2>/dev/null || true)
  authenticated_reply=$(ha_exec "$HA_MASTER_SERVICE" env REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping 2>/dev/null || true)

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
  sentinel_unauthenticated_reply=$(ha_exec sentinel_1 redis-cli -p 26379 ping 2>/dev/null || true)
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
