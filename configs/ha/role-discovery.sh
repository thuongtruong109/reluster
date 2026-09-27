#!/usr/bin/env sh

# This file is sourced by the Redis entrypoint. Keep it POSIX-compatible because
# the official Redis image uses Alpine's /bin/sh.

discover_sentinel_master() {
    sentinel_hosts=$1
    master_name=$2
    previous_ifs=$IFS
    IFS=','

    for endpoint in $sentinel_hosts; do
        sentinel_host=${endpoint%:*}
        sentinel_port=${endpoint##*:}

        if [ "$sentinel_host" = "$sentinel_port" ]; then
            sentinel_port=26379
        fi

        master_address=$(redis-cli \
            -h "$sentinel_host" \
            -p "$sentinel_port" \
            --raw \
            SENTINEL get-master-addr-by-name "$master_name" 2>/dev/null || true)

        master_host=$(printf '%s\n' "$master_address" | sed -n '1p' | tr -d '\r')
        master_port=$(printf '%s\n' "$master_address" | sed -n '2p' | tr -d '\r')

        case "$master_port" in
            ''|*[!0-9]*) ;;
            *)
                if [ -n "$master_host" ]; then
                    IFS=$previous_ifs
                    printf '%s %s\n' "$master_host" "$master_port"
                    return 0
                fi
                ;;
        esac
    done

    IFS=$previous_ifs
    return 1
}

host_is_local_node() {
    candidate=$1
    configured_node_host=$2

    if [ "$candidate" = "$configured_node_host" ] || [ "$candidate" = "$(hostname)" ]; then
        return 0
    fi

    for local_address in $(hostname -i 2>/dev/null || true); do
        if [ "$candidate" = "$local_address" ]; then
            return 0
        fi
    done

    return 1
}

append_replica_role() {
    config_file=$1
    master_host=$2
    master_port=$3

    printf '\n# Resolved from Sentinel at container startup.\nreplicaof %s %s\n' \
        "$master_host" "$master_port" >> "$config_file"
}
