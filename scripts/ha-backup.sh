#!/bin/bash

set -euo pipefail

HA_PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export HA_PROJECT_DIR
# shellcheck source=scripts/lib/ha-compose.sh
source "$HA_PROJECT_DIR/scripts/lib/ha-compose.sh"

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"

ORIGINAL_SERVICE="redis-master"
BACKUP_CONTAINER="redis-backup"
BACKUP_DIR="./backups"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")

mkdir -p "$BACKUP_DIR"

KEY_COUNT=$(ha_exec "$ORIGINAL_SERVICE" env REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli dbsize)
if [ "$KEY_COUNT" -eq 0 ]; then
  echo "No keys found in Redis. Backup aborted."
  exit 1
fi

ha_exec "$ORIGINAL_SERVICE" env REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli BGSAVE

echo "Waiting for BGSAVE to finish..."
while true; do
  STATUS=$(ha_exec "$ORIGINAL_SERVICE" env REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli info persistence | grep rdb_bgsave_in_progress | awk -F: '{print $2}' | tr -d '\r')
  if [ "$STATUS" = "0" ]; then
    break
  fi
  sleep 1
done

ha_exec "$ORIGINAL_SERVICE" sh -c "ls -lh /data/dump.rdb"

sleep 2

ha_exec "$ORIGINAL_SERVICE" sh -c "ls -lh /data/dump.rdb"

echo "Backup path: $BACKUP_DIR/dump_$DATE.rdb"
ha_compose cp "$ORIGINAL_SERVICE:/data/dump.rdb" "$BACKUP_DIR/dump_$DATE.rdb"

cp "$BACKUP_DIR/dump_$DATE.rdb" "$BACKUP_DIR/dump.rdb"

find "$BACKUP_DIR" -type f -mtime +7 -delete

echo "Backup completed: $BACKUP_DIR/dump_$DATE.rdb"

echo "Restoring from backup..."

docker rm -f "$BACKUP_CONTAINER" 2>/dev/null || true

if command -v cygpath >/dev/null 2>&1; then
  BACKUP_ABS_PATH=$(cygpath -w "$(realpath "$BACKUP_DIR")" | sed 's|\\|/|g')
else
  BACKUP_ABS_PATH=$(realpath "$BACKUP_DIR")
fi

docker run -d --name "$BACKUP_CONTAINER" -p 6383:6379 -v "${BACKUP_ABS_PATH}:/data" redis:7.2 --requirepass "$REDIS_PASSWORD"

echo "Loading RDB into new container..."
sleep 5

if ! docker ps --format '{{.Names}}' | grep -q "^${BACKUP_CONTAINER}$"; then
  echo "Redis restore container failed to start."
  docker logs "$BACKUP_CONTAINER"
  exit 1
fi

echo "Keys in restored container:"
# docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$BACKUP_CONTAINER" redis-cli keys '*'
# docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$BACKUP_CONTAINER" redis-cli scan 0

KEYS=$(docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$BACKUP_CONTAINER" redis-cli keys '*')
if [ -z "$KEYS" ]; then
  echo "No keys found in restored container. Possible restore failure."
  docker logs "$BACKUP_CONTAINER"
  exit 1
else
  echo "$KEYS"
fi

echo "Redis restore log:"
docker logs "$BACKUP_CONTAINER" | grep DB
