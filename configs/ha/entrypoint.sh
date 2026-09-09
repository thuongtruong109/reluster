#!/usr/bin/env sh
set -eu

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
: "${REDIS_MASTER_HOST:?REDIS_MASTER_HOST must be set}"
: "${REDIS_CONFIG_TEMPLATE:?REDIS_CONFIG_TEMPLATE must be set}"
: "${REDIS_CONFIG_FILE:?REDIS_CONFIG_FILE must be set}"

mkdir -p "$(dirname "$REDIS_CONFIG_FILE")"
umask 077

# Limit substitution to values expected by the Redis configuration templates.
envsubst '${REDIS_PASSWORD} ${REDIS_MASTER_HOST}' < "$REDIS_CONFIG_TEMPLATE" > "$REDIS_CONFIG_FILE"

if [ "$(id -u)" = "0" ]; then
    chown redis:redis "$REDIS_CONFIG_FILE"
fi

# Preserve the official image's privilege drop and signal-handling behavior.
exec docker-entrypoint.sh "$@"
