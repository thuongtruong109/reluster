#!/usr/bin/env sh
set -eu

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
: "${SENTINEL_PASSWORD:?SENTINEL_PASSWORD must be set}"
: "${REDIS_MASTER_HOST:?REDIS_MASTER_HOST must be set}"
: "${REDIS_CONFIG_TEMPLATE:?REDIS_CONFIG_TEMPLATE must be set}"
: "${REDIS_CONFIG_FILE:?REDIS_CONFIG_FILE must be set}"

mkdir -p "$(dirname "$REDIS_CONFIG_FILE")"
umask 077

# Limit substitution to values expected by the Redis configuration templates.
envsubst '${REDIS_PASSWORD} ${SENTINEL_PASSWORD} ${REDIS_MASTER_HOST} ${REDIS_NODE_HOST} ${SENTINEL_ANNOUNCE_HOST}' < "$REDIS_CONFIG_TEMPLATE" > "$REDIS_CONFIG_FILE"

if [ -n "${REDIS_BOOTSTRAP_ROLE:-}" ]; then
    : "${REDIS_NODE_HOST:?REDIS_NODE_HOST must be set for a Redis data node}"

    REDIS_SENTINEL_HOSTS=${REDIS_SENTINEL_HOSTS:-sentinel_1:26379,sentinel_2:26379,sentinel_3:26379}
    REDIS_SENTINEL_MASTER_NAME=${REDIS_SENTINEL_MASTER_NAME:-mymaster}
    REDIS_SENTINEL_DISCOVERY_TIMEOUT=${REDIS_SENTINEL_DISCOVERY_TIMEOUT:-15}
    REDIS_BOOTSTRAP_MARKER=${REDIS_BOOTSTRAP_MARKER:-/data/.reluster-ha-bootstrapped}

    case "$REDIS_BOOTSTRAP_ROLE" in
        master|replica) ;;
        *)
            echo "Invalid REDIS_BOOTSTRAP_ROLE: $REDIS_BOOTSTRAP_ROLE" >&2
            exit 1
            ;;
    esac

    . /usr/local/lib/reluster/role-discovery.sh

    sentinel_master=""
    discovery_deadline=$(($(date +%s) + REDIS_SENTINEL_DISCOVERY_TIMEOUT))

    while [ -z "$sentinel_master" ]; do
        sentinel_master=$(discover_sentinel_master \
            "$REDIS_SENTINEL_HOSTS" \
            "$REDIS_SENTINEL_MASTER_NAME" \
            "$SENTINEL_PASSWORD" || true)

        if [ -n "$sentinel_master" ] || [ "$(date +%s)" -ge "$discovery_deadline" ]; then
            break
        fi
        sleep 1
    done

    if [ -n "$sentinel_master" ]; then
        current_master_host=${sentinel_master% *}
        current_master_port=${sentinel_master##* }

        if host_is_local_node "$current_master_host" "$REDIS_NODE_HOST"; then
            echo "Starting $REDIS_NODE_HOST as the Sentinel-elected master"
        else
            echo "Starting $REDIS_NODE_HOST as a replica of $current_master_host:$current_master_port"
            append_replica_role "$REDIS_CONFIG_FILE" "$current_master_host" "$current_master_port"
        fi
    elif [ -e "$REDIS_BOOTSTRAP_MARKER" ]; then
        echo "Sentinel discovery failed for an initialized HA node; refusing an unsafe standalone start" >&2
        exit 1
    elif [ "$REDIS_BOOTSTRAP_ROLE" = "replica" ]; then
        echo "Sentinel is not ready; bootstrapping $REDIS_NODE_HOST as a replica of $REDIS_MASTER_HOST:6379"
        append_replica_role "$REDIS_CONFIG_FILE" "$REDIS_MASTER_HOST" 6379
    else
        echo "Sentinel is not ready; bootstrapping $REDIS_NODE_HOST as the initial master"
    fi

    mkdir -p "$(dirname "$REDIS_BOOTSTRAP_MARKER")"
    touch "$REDIS_BOOTSTRAP_MARKER"
fi

if [ "$(id -u)" = "0" ]; then
    chown redis:redis "$REDIS_CONFIG_FILE"
    if [ -n "${REDIS_BOOTSTRAP_MARKER:-}" ]; then
        chown redis:redis "$REDIS_BOOTSTRAP_MARKER"
    fi
fi

# Preserve the official image's privilege drop and signal-handling behavior.
exec docker-entrypoint.sh "$@"
