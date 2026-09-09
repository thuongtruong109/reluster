#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
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

info "\n=== Step 1: Show current master ==="
docker_exec $SENTINEL redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster || error "Failed to get master!"

info "\n=== Step 2: Stop master ==="
docker stop $MASTER || error "Failed to stop master!"
sleep 10

info "\n=== Step 3: Show new master after failover ==="
docker_exec $SENTINEL redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster || error "Failed to get new master!"

info "\n=== Step 4: Check role of replica ==="
docker_exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$REPLICA" redis-cli INFO replication | grep role || error "Failed to get replica role!"

info "\n=== Step 5: Restart old master ==="
docker start $MASTER || error "Failed to start master!"
sleep 5

info "\n=== Step 6: Check cluster again ==="
docker_exec $SENTINEL redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster || error "Failed to get master!"
docker_exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$MASTER" redis-cli INFO replication | grep role || error "Failed to get master role!"

success "\n=== DONE: Sentinel failover test completed! ===\n"
