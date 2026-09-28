#!/bin/sh
set -e

HA_PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export HA_PROJECT_DIR
# shellcheck source=scripts/lib/ha-compose.sh
. "$HA_PROJECT_DIR/scripts/lib/ha-compose.sh"

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
: "${SENTINEL_PASSWORD:?SENTINEL_PASSWORD must be set}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }

redis_cli() {
  CONTAINER=$1
  shift
  ha_exec "$CONTAINER" env REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli "$@"
}

sentinel_cli() {
  CONTAINER=$1
  shift
  ha_exec "$CONTAINER" env REDISCLI_AUTH="$SENTINEL_PASSWORD" redis-cli -p 26379 "$@"
}

wait_for_ready() {
  CONTAINER=$1
  PORT=$2
  log "⏳ Waiting for $CONTAINER to be ready on port $PORT..."
  for _ in $(seq 1 60); do
    if ha_service_running "$CONTAINER"; then
      case "$CONTAINER" in
        sentinel_*) PONG=$(sentinel_cli "$CONTAINER" ping 2>/dev/null || true) ;;
        *) PONG=$(redis_cli "$CONTAINER" -p "$PORT" ping 2>/dev/null || true) ;;
      esac
      if [ "$PONG" = "PONG" ]; then
        case "$CONTAINER" in
          sentinel_*)
            log "✅ $CONTAINER is ready"
            return 0
            ;;
        esac

        ROLE=$(redis_cli "$CONTAINER" -p "$PORT" info replication | grep "^role:" | cut -d: -f2 | tr -d '[:space:]' || true)
        if [ "$ROLE" = "slave" ]; then
          MASTER_HOST=$(redis_cli "$CONTAINER" -p "$PORT" info replication | grep "^master_host:" | cut -d: -f2 | tr -d '[:space:]' || true)
          if [ -n "$MASTER_HOST" ] && [ "$MASTER_HOST" != "?" ]; then
            log "✅ $CONTAINER is ready (role=slave, master=$MASTER_HOST)"
            return 0
          fi
        else
          log "✅ $CONTAINER is ready (role=$ROLE)"
          return 0
        fi
      fi
    fi
    sleep 2
  done
  log "❌ $CONTAINER did not become ready"
  ha_compose logs "$CONTAINER" || true
  exit 1
}

# --- Wait all services ready ---
wait_for_ready redis-master 6379
wait_for_ready slave_1 6379
wait_for_ready slave_2 6379
wait_for_ready slave_3 6379
wait_for_ready sentinel_1 26379
wait_for_ready sentinel_2 26379
wait_for_ready sentinel_3 26379

# --- Test master write ---
log "Testing master set/get..."
success=0
for host in redis-master slave_1 slave_2 slave_3; do
  if redis_cli "$host" set testkey testvalue 2>&1 | grep -vq "READONLY"; then
    VALUE=$(redis_cli "$host" get testkey)
    if [ "$VALUE" = "testvalue" ]; then
      NEW_MASTER=$host
      success=1
      break
    fi
  fi
done
if [ $success -ne 1 ]; then
  log "❌ No writable master found at test start"
  exit 1
fi
log "✅ Detected current master: $NEW_MASTER"

# --- Check replication ---
log "Testing replication to slaves..."
for host in slave_1 slave_2 slave_3; do
  replicated=0
  for _ in $(seq 1 20); do
    VALUE=$(redis_cli "$host" get testkey || true)
    if [ "$VALUE" = "testvalue" ]; then
      replicated=1
      break
    fi
    log "⏳ Waiting for replication to $host..."
    sleep 1
  done
  if [ $replicated -ne 1 ]; then
    log "❌ Replication to $host failed"
    exit 1
  fi
done
log "✅ Replication verified"

log "Simulating master failure..."
ha_compose stop redis-master

log "Triggering manual failover..."
sentinel_cli sentinel_1 sentinel failover mymaster || true

# --- Detect new master ---
NEW_MASTER=""
for _ in $(seq 1 60); do
  for host in slave_1 slave_2 slave_3; do
    ROLE=$(redis_cli "$host" info replication | grep "^role:" | cut -d: -f2 | tr -d '[:space:]' || true)
    if [ "$ROLE" = "master" ]; then
      NEW_MASTER=$host
      break 2
    fi
  done
  log "⏳ Waiting for Sentinel to promote a new master..."
  sleep 2
done

if [ -z "$NEW_MASTER" ]; then
  log "❌ Failover failed: no new master detected"
  sentinel_cli sentinel_1 sentinel master mymaster || true
  sentinel_cli sentinel_1 sentinel slaves mymaster || true
  exit 1
fi
log "✅ New master is $NEW_MASTER"

SENTINEL_MASTER_ADDRESS=$(sentinel_cli sentinel_1 --raw SENTINEL get-master-addr-by-name mymaster)
NEW_MASTER_HOST=$(printf '%s\n' "$SENTINEL_MASTER_ADDRESS" | sed -n '1p' | tr -d '\r')
NEW_MASTER_PORT=$(printf '%s\n' "$SENTINEL_MASTER_ADDRESS" | sed -n '2p' | tr -d '\r')
if [ -z "$NEW_MASTER_HOST" ] || [ -z "$NEW_MASTER_PORT" ]; then
  log "❌ Sentinel did not return the promoted master address"
  exit 1
fi
log "✅ Sentinel reports the new master at $NEW_MASTER_HOST:$NEW_MASTER_PORT"

# --- Ensure all slaves are replicating from new master ---
for host in slave_1 slave_2 slave_3; do
  if [ "$host" != "$NEW_MASTER" ]; then
    linked=0
    for _ in $(seq 1 60); do
      ROLE=$(redis_cli "$host" info replication | grep "^role:" | cut -d: -f2 | tr -d '[:space:]' || true)
      LINK_STATUS=$(redis_cli "$host" info replication | grep "^master_link_status:" | cut -d: -f2 | tr -d '[:space:]' || true)
      if [ "$ROLE" = "slave" ] && [ "$LINK_STATUS" = "up" ]; then
        log "✅ $host is following $NEW_MASTER with replication up"
        linked=1
        break
      fi
      log "⏳ Waiting for $host to follow $NEW_MASTER (role=$ROLE, link=$LINK_STATUS)..."
      sleep 1
    done
    if [ $linked -ne 1 ]; then
      log "❌ $host did not attach to $NEW_MASTER properly"
      redis_cli "$host" info replication || true
      exit 1
    fi
  fi
done

# --- Test write on new master ---
log "Testing set/get on new master..."
redis_cli "$NEW_MASTER" set failoverkey failovervalue
VALUE=$(redis_cli "$NEW_MASTER" get failoverkey)
if [ "$VALUE" != "failovervalue" ]; then
  log "❌ New master set/get failed"
  exit 1
fi

# --- Verify replication of failoverkey ---
for host in slave_1 slave_2 slave_3; do
  if [ "$host" != "$NEW_MASTER" ]; then
    replicated=0
    for _ in $(seq 1 60); do
      VALUE=$(redis_cli "$host" get failoverkey || true)
      if [ "$VALUE" = "failovervalue" ]; then
        log "✅ $host successfully replicated failoverkey from $NEW_MASTER"
        replicated=1
        break
      fi
      log "⏳ Waiting for replication to $host after failover..."
      sleep 1
    done
    if [ $replicated -ne 1 ]; then
      log "❌ Replication to $host after failover failed"
      redis_cli "$host" info replication || true
      exit 1
    fi
  fi
done
log "✅ Replication after failover verified"

log "Restarting old master..."
ha_compose start redis-master

# --- Ensure old master rejoins the exact Sentinel-elected master as a slave ---
joined=0
for _ in $(seq 1 60); do
  ROLE=$(redis_cli redis-master info replication | grep "^role:" | cut -d: -f2 | tr -d '[:space:]' || true)
  FOLLOWING_HOST=$(redis_cli redis-master info replication | grep "^master_host:" | cut -d: -f2 | tr -d '[:space:]' || true)
  LINK_STATUS=$(redis_cli redis-master info replication | grep "^master_link_status:" | cut -d: -f2 | tr -d '[:space:]' || true)
  if [ "$ROLE" = "slave" ] && [ "$FOLLOWING_HOST" = "$NEW_MASTER_HOST" ] && [ "$LINK_STATUS" = "up" ]; then
    log "✅ Old master rejoined as a slave of $NEW_MASTER_HOST:$NEW_MASTER_PORT"
    joined=1
    break
  fi
  log "⏳ Waiting for old master to follow $NEW_MASTER_HOST (role=$ROLE, master=$FOLLOWING_HOST, link=$LINK_STATUS)..."
  sleep 2
done

if [ $joined -ne 1 ]; then
  log "❌ Old master did not rejoin as slave"
  redis_cli redis-master info replication || true
  exit 1
fi

VALUE=$(redis_cli redis-master get failoverkey || true)
if [ "$VALUE" != "failovervalue" ]; then
  log "❌ Old master rejoined but did not synchronize data from the promoted master"
  exit 1
fi
log "✅ Old master synchronized writes made during the failover"

redis_cli "$NEW_MASTER" del testkey failoverkey >/dev/null
log "✅ Removed failover test keys"

log "🎉 All integration tests passed"
exit 0
