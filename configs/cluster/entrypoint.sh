#!/usr/bin/env sh
set -eu

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"

# If REDIS_HOST is not set, use the current container's hostname.
if [ -z "${REDIS_HOST:-}" ]; then
    REDIS_HOST=$(hostname)
fi

# Redis 7.2 requires cluster-announce-ip to be a numeric IP address.
resolved_redis_host=$(getent ahostsv4 "$REDIS_HOST" | awk 'NR == 1 { print $1 }')
if [ -z "$resolved_redis_host" ]; then
    echo "Unable to resolve REDIS_HOST '$REDIS_HOST' to an IPv4 address" >&2
    exit 1
fi
REDIS_HOST="$resolved_redis_host"

export REDIS_HOST

umask 077
envsubst '${REDIS_PASSWORD} ${REDIS_HOST}' < /etc/redis/node.conf > /etc/redis/redis.conf

if [ "$(id -u)" = "0" ]; then
    chown redis:redis /etc/redis/redis.conf
fi

exec docker-entrypoint.sh redis-server /etc/redis/redis.conf
