# Reluster Console

Reluster Console is a local control plane for the Docker-based Redis Cluster and
Sentinel labs. The browser talks only to the Console API; Redis credentials and
RESP connections stay inside the `redisnet` Docker network.

## Features

- Cluster state, node roles, slot coverage, memory, clients, and throughput
- Sentinel quorum, current master, replicas, and observer health
- Key discovery and previews for the bounded `demo:*` namespace
- Safe string-key create/update/delete and sample-data seeding
- Opt-in Sentinel failover with explicit typed confirmation
- In-memory audit trail for write actions
- Links to Redis Commander, Prometheus, and Grafana

## Structure

```text
apps/console/
├── api/       Express API and Redis integrations
└── web/       Dependency-free responsive dashboard
```

## Run

Start either Redis mode first, then start the Console:

```bash
make clt && make clt-init
make console
```

or:

```bash
make ha
make console
```

Open <http://localhost:8080>. Set `CONSOLE_FAILOVER_ENABLED=true` in `.env` only
when the failover demo is required. Writes are restricted to the configured
`CONSOLE_KEY_PREFIX`, which defaults to `demo:`.

Older HA containers may still use Compose's `reluster_redisnet` network. Either
recreate them with `make ha` or temporarily set `REDIS_NETWORK=reluster_redisnet`
before starting the Console.

## Local API development

```bash
cd apps/console/api
npm install
npm run dev
```

Local API development needs endpoints resolvable from the host. Running the
packaged Console through Docker Compose is the supported integration path.
