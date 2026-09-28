#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
: "${SENTINEL_PASSWORD:?SENTINEL_PASSWORD must be set}"
SENTINEL=sentinel_1
REPLICA=slave_1
MASTER=redis-master

function info() {
    echo -e "${YELLOW}$1${NC}"
}

function success() {
    echo -e "${GREEN}$1${NC}"
}

function error() {
    echo -e "${RED}$1${NC}"
}

# auto detect tty
function docker_exec() {
    if [ -t 1 ]; then
        docker exec -it "$@"
    else
        docker exec "$@"
    fi
}

function sentinel_exec() {
    docker_exec -e REDISCLI_AUTH="$SENTINEL_PASSWORD" "$SENTINEL" redis-cli -p 26379 "$@"
}

info "\n=== Step 1: Show current master ==="
sentinel_exec SENTINEL get-master-addr-by-name mymaster || error "Failed to get master!"

info "\n=== Step 2: Stop master ==="
docker stop $MASTER || error "Failed to stop master!"
sleep 10

info "\n=== Step 3: Show new master after failover ==="
sentinel_exec SENTINEL get-master-addr-by-name mymaster || error "Failed to get new master!"

info "\n=== Step 4: Check role of replica ==="
docker_exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$REPLICA" redis-cli INFO replication | grep role || error "Failed to get replica role!"

info "\n=== Step 5: Restart old master ==="
docker start $MASTER || error "Failed to start master!"

info "\n=== Step 6: Verify old master follows the Sentinel-elected master ==="
MASTER_ADDRESS=$(sentinel_exec --raw SENTINEL get-master-addr-by-name mymaster)
EXPECTED_MASTER_HOST=$(printf '%s\n' "$MASTER_ADDRESS" | sed -n '1p' | tr -d '\r')

REJOINED=false
for _ in $(seq 1 60); do
    REPLICATION_INFO=$(docker_exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$MASTER" redis-cli INFO replication 2>/dev/null || true)
    ROLE=$(printf '%s\n' "$REPLICATION_INFO" | grep '^role:' | cut -d: -f2 | tr -d '[:space:]' || true)
    FOLLOWING_HOST=$(printf '%s\n' "$REPLICATION_INFO" | grep '^master_host:' | cut -d: -f2 | tr -d '[:space:]' || true)
    LINK_STATUS=$(printf '%s\n' "$REPLICATION_INFO" | grep '^master_link_status:' | cut -d: -f2 | tr -d '[:space:]' || true)

    if [ "$ROLE" = "slave" ] && [ "$FOLLOWING_HOST" = "$EXPECTED_MASTER_HOST" ] && [ "$LINK_STATUS" = "up" ]; then
        REJOINED=true
        break
    fi
    sleep 2
done

if [ "$REJOINED" != "true" ]; then
    error "Old master did not rejoin $EXPECTED_MASTER_HOST as a healthy replica"
    printf '%s\n' "$REPLICATION_INFO"
    exit 1
fi

success "Old master rejoined $EXPECTED_MASTER_HOST as a healthy replica"

success "\n=== DONE: Sentinel failover test completed! ===\n"
