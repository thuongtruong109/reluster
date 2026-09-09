#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NODES=("node-1" "node-2" "node-3" "node-4" "node-5" "node-6")
REDIS_PORT=6379
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
CLUSTER_PASS="${CLUSTER_PASS:-$REDIS_PASSWORD}"

LOG_FILE="/tmp/redis_cluster_health.log"
METRICS_FILE="/tmp/redis_cluster_metrics.json"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

print_status() {
    local status="$1"
    local message="$2"
    if [ "$status" = "OK" ]; then
        echo -e "${GREEN}✅ $message${NC}"
        log "OK: $message"
    elif [ "$status" = "WARN" ]; then
        echo -e "${YELLOW}⚠️  $message${NC}"
        log "WARN: $message"
    else
        echo -e "${RED}❌ $message${NC}"
        log "ERROR: $message"
    fi
}

check_container_health() {
    log "Checking container health..."
    local overall_status=0
    for node in "${NODES[@]}"; do
        if docker ps --filter "name=$node" --filter "status=running" | grep -q "$node"; then
            print_status "OK" "Container $node is running"
        else
            print_status "ERROR" "Container $node is not running"
            overall_status=1
        fi
    done
    return $overall_status
}

check_redis_connection() {
    log "Checking Redis connections..."
    local overall_status=0
    for node in "${NODES[@]}"; do
        local reply
        reply=$(docker exec -e REDISCLI_AUTH="$CLUSTER_PASS" "$node" redis-cli -p "$REDIS_PORT" PING 2>/dev/null || true)
        if [ "$reply" = "PONG" ]; then
            print_status "OK" "Redis node $node responds"
        else
            print_status "ERROR" "Redis node $node not responding"
            overall_status=1
        fi
    done
    return $overall_status
}

check_cluster_state() {
    log "Checking cluster state..."
    local cluster_state
    cluster_state=$(docker exec "${NODES[0]}" redis-cli -a "$CLUSTER_PASS" -p $REDIS_PORT cluster info | grep cluster_state | cut -d: -f2 | tr -d '\r')
    if [ "$cluster_state" = "ok" ]; then
        print_status "OK" "Cluster state is OK"
        return 0
    else
        print_status "ERROR" "Cluster state is NOT OK"
        return 1
    fi
}

check_slots_coverage() {
    log "Checking slots coverage..."
    local uncovered
    uncovered=$(docker exec "${NODES[0]}" redis-cli -a "$CLUSTER_PASS" -p $REDIS_PORT cluster check "${NODES[0]}:$REDIS_PORT" | grep "not covered" || true)
    if [ -z "$uncovered" ]; then
        print_status "OK" "All 16384 slots are covered"
        return 0
    else
        print_status "ERROR" "Some slots are not covered!"
        return 1
    fi
}

collect_metrics() {
    log "Collecting metrics..."
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local metrics="{\"timestamp\": \"$timestamp\", \"nodes\": {"

    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local clients=$(docker exec "$node" redis-cli -a "$CLUSTER_PASS" info clients | grep "connected_clients" | cut -d: -f2 | tr -d '\r')
        local mem=$(docker exec "$node" redis-cli -a "$CLUSTER_PASS" info memory | grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
        if [ $i -gt 0 ]; then
            metrics="$metrics, "
        fi
        metrics="$metrics\"$node\": {\"connected_clients\": $clients, \"used_memory\": \"$mem\"}"
    done
    metrics="$metrics}}"

    echo "$metrics" > "$METRICS_FILE"
    print_status "OK" "Metrics collected and saved to $METRICS_FILE"
}

main() {
    > "$LOG_FILE"
    echo -e "${BLUE}🏥 Redis Cluster Health Check Starting...${NC}"

    local overall_status=0

    check_container_health || overall_status=1
    check_redis_connection || overall_status=1
    check_cluster_state || overall_status=1
    check_slots_coverage || overall_status=1
    collect_metrics

    if [ $overall_status -eq 0 ]; then
        print_status "OK" "All health checks passed"
    else
        print_status "ERROR" "Some health checks failed - check logs for details"
    fi

    echo -e "\n${BLUE}📝 Logs saved to: $LOG_FILE${NC}"
    exit $overall_status
}

main "$@"
