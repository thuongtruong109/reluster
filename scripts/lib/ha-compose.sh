#!/usr/bin/env sh

# Shared Docker Compose accessors for HA scripts. Callers set HA_PROJECT_DIR so
# service operations keep working when Compose generates or replaces containers.
: "${HA_PROJECT_DIR:?HA_PROJECT_DIR must point to the repository root}"
HA_COMPOSE_FILE=${HA_COMPOSE_FILE:-$HA_PROJECT_DIR/docker-compose.ha.yml}

ha_compose() {
    docker compose --project-directory "$HA_PROJECT_DIR" -f "$HA_COMPOSE_FILE" "$@"
}

ha_exec() {
    _ha_service=$1
    shift
    ha_compose exec -T "$_ha_service" "$@"
}

ha_service_running() {
    _ha_service=$1
    ha_compose ps --status running --services | grep -Fx "$_ha_service" >/dev/null
}
