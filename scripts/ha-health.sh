#!/bin/bash

set -euo pipefail

HA_PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export HA_PROJECT_DIR
# shellcheck source=scripts/lib/ha-compose.sh
source "$HA_PROJECT_DIR/scripts/lib/ha-compose.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

MASTER_HOST="${REDIS_MASTER_SERVICE:-redis-master}"
MASTER_PORT="6379"
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
: "${SENTINEL_PASSWORD:?SENTINEL_PASSWORD must be set}"
MASTER_PASS="$REDIS_PASSWORD"
SENTINEL_PASS="$SENTINEL_PASSWORD"

SLAVE_HOSTS=("slave_1" "slave_2" "slave_3")
SLAVE_PORTS=("6379" "6379" "6379")
SLAVE_PASS="$REDIS_PASSWORD"

SENTINEL_HOSTS=("sentinel_1" "sentinel_2" "sentinel_3")
SENTINEL_PORTS=("26379" "26379" "26379")

MASTER_NAME="mymaster"
LOG_FILE="/tmp/redis_health_check.log"
METRICS_FILE="/tmp/redis_metrics.json"

sentinel_cli() {
    local container="$1"
    shift
    ha_exec "$container" env REDISCLI_AUTH="$SENTINEL_PASS" redis-cli "$@"
}

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

check_redis_connection() {
    local host="$1"
    local port="$2"
    local password="$3"
    local name="$4"

    local reply
    reply=$(ha_exec redis-master env REDISCLI_AUTH="$password" redis-cli -h "$host" -p "$port" ping 2>/dev/null || true)
    if [ "$reply" = "PONG" ]; then
        print_status "OK" "$name connection successful"
        return 0
    else
        print_status "ERROR" "$name connection failed"
        return 1
    fi
}

get_current_master() {
    for i in "${!SENTINEL_HOSTS[@]}"; do
        local sentinel_host="${SENTINEL_HOSTS[$i]}"
        local sentinel_port="${SENTINEL_PORTS[$i]}"
        local sentinel_num=$((i + 1))

        local sentinel_reply
        sentinel_reply=$(sentinel_cli "sentinel_$sentinel_num" -h "$sentinel_host" -p "$sentinel_port" ping 2>/dev/null || true)
        if [ "$sentinel_reply" = "PONG" ]; then
            local master_addr
            master_addr=$(sentinel_cli "sentinel_$sentinel_num" -p "$sentinel_port" sentinel get-master-addr-by-name "$MASTER_NAME" 2>/dev/null)
            if [ -n "$master_addr" ]; then
                # master_addr is "host\nport"
                local current_master_host=$(echo "$master_addr" | head -n1)
                local current_master_port=$(echo "$master_addr" | tail -n1)
                echo "$current_master_host:$current_master_port"
                return 0
            fi
        fi
    done
    echo ""
    return 1
}

check_replication() {
    log "Checking replication status..."

    local current_master
    current_master=$(get_current_master)
    if [ -z "$current_master" ]; then
        print_status "ERROR" "Unable to determine current master from Sentinel"
        return 1
    fi

    local current_master_host="${current_master%:*}"
    local current_master_port="${current_master#*:}"

    print_status "OK" "Current master identified: $current_master_host:$current_master_port"

    local test_key="health_check_$(date +%s)"
    local test_value="health_check_value_$(date +%s)"

    local write_reply
    write_reply=$(ha_exec redis-master env REDISCLI_AUTH="$MASTER_PASS" redis-cli -h "$current_master_host" -p "$current_master_port" set "$test_key" "$test_value" 2>/dev/null || true)
    if [ "$write_reply" != "OK" ]; then
        print_status "ERROR" "Failed to write test key to current master"
        return 1
    fi

    sleep 2

    local failed_slaves=0
    for i in "${!SLAVE_HOSTS[@]}"; do
        local slave_num=$((i + 1))

        local replicated_value
        replicated_value=$(ha_exec "slave_$slave_num" redis-cli -a "$SLAVE_PASS" get "$test_key" 2>/dev/null || echo "ERROR")

        if [ "$replicated_value" = "$test_value" ]; then
            print_status "OK" "Replication working on slave_$slave_num"
        else
            print_status "ERROR" "Replication failed on slave_$slave_num (got: $replicated_value)"
            ((failed_slaves++))
        fi
    done

    ha_exec redis-master redis-cli -h "$current_master_host" -p "$current_master_port" -a "$MASTER_PASS" del "$test_key" &>/dev/null

    if [ $failed_slaves -eq 0 ]; then
        print_status "OK" "All slaves are properly replicating"
        return 0
    else
        print_status "ERROR" "$failed_slaves slaves failed replication test"
        return 1
    fi
}

check_sentinel_status() {
    log "Checking Sentinel status..."

    local failed_sentinels=0
    for i in "${!SENTINEL_HOSTS[@]}"; do
        local sentinel_host="${SENTINEL_HOSTS[$i]}"
        local sentinel_port="${SENTINEL_PORTS[$i]}"
        local sentinel_num=$((i + 1))

        local sentinel_reply
        sentinel_reply=$(sentinel_cli "sentinel_$sentinel_num" -h "$sentinel_host" -p "$sentinel_port" ping 2>/dev/null || true)
        if [ "$sentinel_reply" = "PONG" ]; then
            print_status "OK" "Sentinel_$sentinel_num is responding"

            local master_info
            master_info=$(sentinel_cli "sentinel_$sentinel_num" -p 26379 sentinel get-master-addr-by-name "$MASTER_NAME" 2>/dev/null || echo "ERROR")

            local reported_master_host
            local reported_master_port
            reported_master_host=$(echo "$master_info" | head -n1)
            reported_master_port=$(echo "$master_info" | tail -n1)
            if [ -n "$reported_master_host" ] && [[ "$reported_master_port" =~ ^[0-9]+$ ]]; then
                print_status "OK" "Sentinel_$sentinel_num identifies $reported_master_host:$reported_master_port as master"
            else
                print_status "WARN" "Sentinel_$sentinel_num master discovery issue"
                ((failed_sentinels++))
            fi
        else
            print_status "ERROR" "Sentinel_$sentinel_num is not responding"
            ((failed_sentinels++))
        fi
    done

    if [ $failed_sentinels -eq 0 ]; then
        print_status "OK" "All sentinels are healthy"
        return 0
    else
        print_status "WARN" "$failed_sentinels sentinels have issues"
        return 1
    fi
}

check_memory_usage() {
    log "Checking memory usage..."

    local master_memory
    master_memory=$(ha_exec redis-master redis-cli -a "$MASTER_PASS" info memory | grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
    print_status "OK" "Master memory usage: $master_memory"

    for i in "${!SLAVE_HOSTS[@]}"; do
        local slave_num=$((i + 1))
        local slave_memory
        slave_memory=$(ha_exec "slave_$slave_num" redis-cli -a "$SLAVE_PASS" info memory | grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
        print_status "OK" "Slave_$slave_num memory usage: $slave_memory"
    done
}

check_replication_lag() {
    log "Checking replication lag..."

    for i in "${!SLAVE_HOSTS[@]}"; do
        local slave_num=$((i + 1))
        local lag_info
        lag_info=$(ha_exec "slave_$slave_num" redis-cli -a "$SLAVE_PASS" info replication | grep "master_last_io_seconds_ago" | cut -d: -f2 | tr -d '\r')

        if [ -n "$lag_info" ] && [ "$lag_info" -lt 10 ]; then
            print_status "OK" "Slave_$slave_num replication lag: ${lag_info}s"
        else
            print_status "WARN" "Slave_$slave_num replication lag: ${lag_info}s (high)"
        fi
    done
}

check_container_health() {
    log "Checking service health..."

    local services=("redis-master" "slave_1" "slave_2" "slave_3" "sentinel_1" "sentinel_2" "sentinel_3")
    local overall_status=0

    for service in "${services[@]}"; do
        if ha_service_running "$service"; then
            print_status "OK" "Service $service is running"
        else
            print_status "ERROR" "Service $service is not running"
            overall_status=1
        fi
    done

    return "$overall_status"
}

collect_metrics() {
    log "Collecting metrics..."

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local metrics="{\"timestamp\": \"$timestamp\", \"services\": {"

    local master_connected_clients
    master_connected_clients=$(ha_exec redis-master redis-cli -a "$MASTER_PASS" info clients | grep "connected_clients" | cut -d: -f2 | tr -d '\r')

    local master_total_commands
    master_total_commands=$(ha_exec redis-master redis-cli -a "$MASTER_PASS" info stats | grep "total_commands_processed" | cut -d: -f2 | tr -d '\r')

    metrics="$metrics\"master\": {\"connected_clients\": $master_connected_clients, \"total_commands\": $master_total_commands}"

    metrics="$metrics, \"slaves\": ["
    for i in "${!SLAVE_HOSTS[@]}"; do
        local slave_num=$((i + 1))
        local slave_connected_clients
        slave_connected_clients=$(ha_exec "slave_$slave_num" redis-cli -a "$SLAVE_PASS" info clients | grep "connected_clients" | cut -d: -f2 | tr -d '\r')

        if [ $i -gt 0 ]; then
            metrics="$metrics, "
        fi
        metrics="$metrics{\"slave_$slave_num\": {\"connected_clients\": $slave_connected_clients}}"
    done
    metrics="$metrics]"

    metrics="$metrics}}"

    echo "$metrics" > "$METRICS_FILE"
    print_status "OK" "Metrics collected and saved to $METRICS_FILE"
}

perform_load_test() {
    log "Performing basic load test..."

    local current_master
    current_master=$(get_current_master)
    if [ -z "$current_master" ]; then
        print_status "ERROR" "Unable to determine current master for load test"
        return 1
    fi

    local current_master_host="${current_master%:*}"
    local current_master_port="${current_master#*:}"

    local start_time=$(date +%s)

    for i in {1..1000}; do
        ha_exec redis-master redis-cli -h "$current_master_host" -p "$current_master_port" -a "$MASTER_PASS" set "load_test_key_$i" "load_test_value_$i" &>/dev/null
    done

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local ops_per_second=$((1000 / duration))

    print_status "OK" "Load test completed: $ops_per_second ops/sec"

    # Cleanup
    ha_exec redis-master redis-cli -h "$current_master_host" -p "$current_master_port" -a "$MASTER_PASS" eval "for _,k in ipairs(redis.call('keys', 'load_test_key_*')) do redis.call('del', k) end" 0 &>/dev/null

    if [ $ops_per_second -gt 100 ]; then
        print_status "OK" "Performance is acceptable"
    else
        print_status "WARN" "Performance is below expected threshold"
    fi
}

cleanup_old_logs() {
    find /tmp -name "redis_health_check*.log" -type f -mtime +7 -delete 2>/dev/null || true
    find /tmp -name "redis_metrics*.json" -type f -mtime +7 -delete 2>/dev/null || true
}

generate_report() {
    local report_file="/tmp/redis_health_report_$(date +%Y%m%d_%H%M%S).txt"

    cat << EOF > "$report_file"
Redis Cluster Health Report
==========================
Generated: $(date)
Log file: $LOG_FILE
Metrics file: $METRICS_FILE

Summary:
- Master Status: $(check_redis_connection "$MASTER_HOST" "$MASTER_PORT" "$MASTER_PASS" "Master" && echo "OK" || echo "ERROR")
- Container Status: $(check_container_health && echo "OK" || echo "ERROR")

See detailed logs in: $LOG_FILE
EOF

    echo -e "\n${BLUE}📊 Health report generated: $report_file${NC}"
}

show_usage() {
    cat << EOF
Redis Cluster Health Check Script

Usage: $0 [OPTIONS]

OPTIONS:
    --basic         Run basic health checks only
    --full          Run comprehensive health checks (default)
    --load-test     Include load testing
    --metrics-only  Only collect metrics
    --report        Generate detailed report
    --help          Show this help message

EXAMPLES:
    $0                    # Run full health check
    $0 --basic           # Run basic checks only
    $0 --load-test       # Include performance testing
    $0 --metrics-only    # Just collect metrics

EOF
}

main() {
    local mode="full"
    local include_load_test=false
    local metrics_only=false
    local generate_report_flag=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --basic)
                mode="basic"
                shift
                ;;
            --full)
                mode="full"
                shift
                ;;
            --load-test)
                include_load_test=true
                shift
                ;;
            --metrics-only)
                metrics_only=true
                shift
                ;;
            --report)
                generate_report_flag=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    cleanup_old_logs
    > "$LOG_FILE"

    echo -e "${BLUE}🏥 Redis Cluster Health Check Starting...${NC}"
    log "Health check started with mode: $mode"

    if [ "$metrics_only" = true ]; then
        collect_metrics
        exit 0
    fi

    local overall_status=0

    echo -e "\n${BLUE}🔍 Basic Health Checks${NC}"
    check_container_health || overall_status=1
    check_redis_connection "$MASTER_HOST" "$MASTER_PORT" "$MASTER_PASS" "Master" || overall_status=1

    for i in "${!SLAVE_HOSTS[@]}"; do
        local slave_num=$((i + 1))
        check_redis_connection "${SLAVE_HOSTS[$i]}" "${SLAVE_PORTS[$i]}" "$SLAVE_PASS" "Slave_$slave_num" || overall_status=1
    done

    if [ "$mode" = "full" ]; then
        echo -e "\n${BLUE}🔄 Replication Checks${NC}"
        check_replication || overall_status=1
        check_replication_lag

        echo -e "\n${BLUE}👁️  Sentinel Checks${NC}"
        check_sentinel_status || overall_status=1

        echo -e "\n${BLUE}📊 System Metrics${NC}"
        check_memory_usage
        collect_metrics
    fi

    if [ "$include_load_test" = true ]; then
        echo -e "\n${BLUE}⚡ Performance Testing${NC}"
        perform_load_test
    fi

    if [ "$generate_report_flag" = true ]; then
        generate_report
    fi

    echo -e "\n${BLUE}📋 Health Check Summary${NC}"
    if [ $overall_status -eq 0 ]; then
        print_status "OK" "All health checks passed"
        echo -e "${GREEN}🎉 Redis cluster is healthy!${NC}"
    else
        print_status "ERROR" "Some health checks failed"
        echo -e "${RED}⚠️  Redis cluster has issues - check the logs!${NC}"
    fi

    echo -e "\n${BLUE}📝 Logs saved to: $LOG_FILE${NC}"
    exit $overall_status
}

main "$@"
