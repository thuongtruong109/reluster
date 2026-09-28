#!/usr/bin/env sh

configure_write_durability() {
    REDIS_MIN_REPLICAS_TO_WRITE=${REDIS_MIN_REPLICAS_TO_WRITE:-1}
    REDIS_MIN_REPLICAS_MAX_LAG=${REDIS_MIN_REPLICAS_MAX_LAG:-10}

    case "$REDIS_MIN_REPLICAS_TO_WRITE" in
        ''|*[!0-9]*)
            echo "REDIS_MIN_REPLICAS_TO_WRITE must be a non-negative integer" >&2
            exit 1
            ;;
    esac

    case "$REDIS_MIN_REPLICAS_MAX_LAG" in
        ''|*[!0-9]*)
            echo "REDIS_MIN_REPLICAS_MAX_LAG must be a non-negative integer" >&2
            exit 1
            ;;
    esac

    export REDIS_MIN_REPLICAS_TO_WRITE REDIS_MIN_REPLICAS_MAX_LAG
}
