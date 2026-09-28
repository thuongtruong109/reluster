ifneq (,$(wildcard .env))
include .env
endif

export REDIS_PASSWORD
export SENTINEL_PASSWORD
export GRAFANA_ADMIN_PASSWORD
.PHONY: format validate console console-logs commander commander-ha commander-clt ha ha-recreate ha-cli ha-ready ha-scan ha-master ha-slave ha-test-failover ha-test ha-bench ha-backup ha-health clt clt-cli clt-init clt-ready clt-monitor clt-scan clt-test clt-bench clt-rollback clt-scale clt-health clean ci

HA_COMPOSE_FILE = docker-compose.ha.yml
CLT_COMPOSE_FILE = docker-compose.cluster.yml
TOOL_COMPOSE_FILE = docker-compose.tool.yml

CLT_BENCH_DIR=benchmark-results
CLT_BENCH_IMAGE=thuongtruong1009/reluster-bench:latest
REDIS_NETWORK=redisnet

COMMANDER_HA_HOSTS = master:redis-master:6379:0:$(REDIS_PASSWORD),slave1:slave_1:6379:0:$(REDIS_PASSWORD),slave2:slave_2:6379:0:$(REDIS_PASSWORD),slave3:slave_3:6379:0:$(REDIS_PASSWORD)
COMMANDER_CLUSTER_HOSTS = node1:node-1:6379:0:$(REDIS_PASSWORD),node2:node-2:6379:0:$(REDIS_PASSWORD),node3:node-3:6379:0:$(REDIS_PASSWORD),node4:node-4:6379:0:$(REDIS_PASSWORD),node5:node-5:6379:0:$(REDIS_PASSWORD),node6:node-6:6379:0:$(REDIS_PASSWORD)

LOG_DIR=monitor-logs

format:
	@dos2unix Makefile
	@sed -i 's/\r$$//' Makefile configs/ha/entrypoint.sh configs/ha/role-discovery.sh configs/ha/sentinel/sentinel.conf configs/ha/replica/redis.conf configs/cluster/node.conf

validate:
	docker compose -f $(HA_COMPOSE_FILE) config --quiet
	docker compose -f $(CLT_COMPOSE_FILE) config --quiet

	chmod +x scripts/ha.sh
	bash scripts/ha.sh validate

	chmod +x scripts/clt.sh
	bash scripts/clt.sh validate

ha:
	docker compose -f $(HA_COMPOSE_FILE) up -d --build

ha-recreate:
	docker compose -f $(HA_COMPOSE_FILE) up -d --build --force-recreate

ha-cli:
	docker exec -it -e REDISCLI_AUTH="$${REDIS_PASSWORD}" redis-master redis-cli -p 6379

ha-ready:
	chmod +x scripts/ha.sh
	bash scripts/ha.sh ready

ha-scan:
	chmod +x scripts/ha.sh
	bash scripts/ha.sh scan

ha-master:
	docker exec -it -e REDISCLI_AUTH="$${SENTINEL_PASSWORD}" sentinel_1 redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

ha-slave:
	docker exec -it -e REDISCLI_AUTH="$${REDIS_PASSWORD}" slave_1 redis-cli info replication

ha-test-failover:
	chmod +x tests/ha-failover.sh
	bash ./tests/ha-failover.sh

ha-test:
	chmod +x tests/ha.sh
	bash ./tests/ha.sh

# current only support on CI
ha-bench:
	chmod +x tests/ha-bench.sh
	MASTER_PASS="$${REDIS_PASSWORD}" bash tests/ha-bench.sh all

ha-backup:
	chmod +x scripts/ha-backup.sh
	bash ./scripts/ha-backup.sh

ha-health:
	@echo "Flags: --basic, --full --report, --load-test, --metrics-only, --help"
	chmod +x scripts/ha-health.sh
	bash ./scripts/ha-health.sh --basic

clt:
	docker compose -f $(CLT_COMPOSE_FILE) up -d --build --force-recreate node-1 node-2 node-3 node-4 node-5 node-6

clt-cli:
	docker exec -it $$(docker ps -qf "name=node-1") redis-cli -c -p 6379 -a $(REDIS_PASSWORD)

clt-init:
	chmod +x scripts/clt-scale.sh
	CLUSTER_PASS=$(REDIS_PASSWORD) bash ./scripts/clt-scale.sh init

clt-ready:
	chmod +x scripts/clt.sh
	CLUSTER_PASS=$(REDIS_PASSWORD) bash ./scripts/clt.sh ready

clt-monitor:
	chmod +x scripts/clt.sh
	CLUSTER_PASS=$(REDIS_PASSWORD) bash ./scripts/clt.sh status
	CLUSTER_PASS=$(REDIS_PASSWORD) bash ./scripts/clt.sh monitor

clt-scan:
	chmod +x scripts/clt.sh
	CLUSTER_PASS=$(REDIS_PASSWORD) bash scripts/clt.sh scan

clt-test:
	chmod +x tests/clt.sh
	bash ./tests/clt.sh

clt-bench:
	mkdir -p $(CLT_BENCH_DIR)
	chmod 777 $(CLT_BENCH_DIR)
	docker build -f configs/cluster/Dockerfile.bench -t $(CLT_BENCH_IMAGE) .
	docker run --rm \
		--network $(REDIS_NETWORK) \
		-v $$(pwd)/$(CLT_BENCH_DIR):/results \
		-e REDIS_PASSWORD=$${REDIS_PASSWORD} \
		-e REDIS_HOST=node-1 \
		$(CLT_BENCH_IMAGE)

clt-rollback:
	chmod +x scripts/clt-rollback.sh
	CLUSTER_PASS=$(REDIS_PASSWORD) bash ./scripts/clt-rollback.sh

clt-scale:
	docker-compose -f $(CLT_COMPOSE_FILE) up -d node-7
	chmod +x scripts/clt-scale.sh
	CLUSTER_PASS=$(REDIS_PASSWORD) bash ./scripts/clt-scale.sh add node-7
	CLUSTER_PASS=$(REDIS_PASSWORD) bash ./scripts/clt-scale.sh remove node-6
	CLUSTER_PASS=$(REDIS_PASSWORD) bash ./scripts/clt-scale.sh rebalance

clt-health:
	chmod +x scripts/clt-health.sh
	set +e
	bash ./scripts/clt-health.sh --report

clean:
	docker compose -f $(CLT_COMPOSE_FILE) down -v
	docker compose -f $(HA_COMPOSE_FILE) down -v
	docker compose -f $(TOOL_COMPOSE_FILE) down -v
	docker volume prune -f
	rm -rf $(CLT_BENCH_DIR)
	rm -rf $(LOG_DIR)

# 	Flags: -j <job_name>
ci:
	act -W .github/workflows/ci.yml --rm --pull=false --secret DOCKER_USERNAME= --secret DOCKER_PASSWORD=

commander:
	@if [ -z "$$REDIS_PASSWORD" ]; then \
		echo "❌ REDIS_PASSWORD is not set."; \
		exit 1; \
	fi
	@if [ -z "$$COMMANDER_REDIS_HOSTS" ]; then \
		echo "❌ COMMANDER_REDIS_HOSTS is not set."; \
		exit 1; \
	fi
	docker compose -f $(TOOL_COMPOSE_FILE) up -d --force-recreate commander

commander-ha: export COMMANDER_REDIS_HOSTS = $(COMMANDER_HA_HOSTS)
commander-ha: commander

commander-clt: export COMMANDER_REDIS_HOSTS = $(COMMANDER_CLUSTER_HOSTS)
commander-clt: commander

monitor:
	@if [ -z "$$GRAFANA_ADMIN_PASSWORD" ]; then \
		echo "❌ GRAFANA_ADMIN_PASSWORD is not set."; \
		exit 1; \
	fi
	docker compose -f $(TOOL_COMPOSE_FILE) up -d --force-recreate exporter prometheus grafana

monitor-health:
	chmod +x scripts/monitor.sh
	LOG_DIR=$(LOG_DIR) bash ./scripts/monitor.sh

console:
	@if [ -z "$$REDIS_PASSWORD" ]; then \
		echo "❌ REDIS_PASSWORD is not set."; \
		exit 1; \
	fi
	docker compose -f $(TOOL_COMPOSE_FILE) up -d --build --force-recreate console
	@echo "Reluster Console: http://localhost:$${CONSOLE_PORT:-8080}"

console-logs:
	docker compose -f $(TOOL_COMPOSE_FILE) logs -f console

demo-ping:
# 	docker compose -f docker-compose.cluster.dev.yml up -d --build --force-recreate node-1 node-2 node-3 node-4 node-5 node-6
# 	docker exec -it node-1 redis-cli -a $(REDIS_PASSWORD) --cluster create 127.0.0.1:6379 127.0.0.1:6380 127.0.0.1:6381 127.0.0.1:6382 127.0.0.1:6383 127.0.0.1:6384 --cluster-replicas 1 --cluster-yes

# 	docker run --rm -it --network host redis:7.2 \
# 		redis-cli -a "$$REDIS_PASSWORD" --cluster create \
# 		127.0.0.1:6379 \
# 		127.0.0.1:6380 \
# 		127.0.0.1:6381 \
# 		127.0.0.1:6382 \
# 		127.0.0.1:6383 \
# 		127.0.0.1:6384 \
# 		--cluster-replicas 1 --cluster-yes

	cd examples/ping && npm run dev
