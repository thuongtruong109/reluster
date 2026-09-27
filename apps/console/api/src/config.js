function parseNodes(value, fallback) {
  return (value || fallback)
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => {
      const separator = entry.lastIndexOf(":");
      if (separator < 1) throw new Error(`Invalid Redis endpoint: ${entry}`);
      return {
        host: entry.slice(0, separator),
        port: Number.parseInt(entry.slice(separator + 1), 10),
      };
    });
}

function readBoolean(value, fallback = false) {
  if (value === undefined) return fallback;
  return value.toLowerCase() === "true";
}

export const config = Object.freeze({
  port: Number.parseInt(process.env.CONSOLE_PORT ?? "8080", 10),
  redisPassword: process.env.REDIS_PASSWORD ?? "",
  clusterNodes: parseNodes(
    process.env.CONSOLE_CLUSTER_NODES,
    "node-1:6379,node-2:6379,node-3:6379,node-4:6379,node-5:6379,node-6:6379",
  ),
  sentinelNodes: parseNodes(
    process.env.CONSOLE_SENTINEL_NODES,
    "sentinel_1:26379,sentinel_2:26379,sentinel_3:26379",
  ),
  sentinelMasterName: process.env.CONSOLE_SENTINEL_MASTER ?? "mymaster",
  keyPrefix: process.env.CONSOLE_KEY_PREFIX?.trim() || "demo:",
  writeEnabled: readBoolean(process.env.CONSOLE_WRITE_ENABLED, true),
  failoverEnabled: readBoolean(process.env.CONSOLE_FAILOVER_ENABLED, false),
  requestTimeoutMs: Number.parseInt(process.env.CONSOLE_REQUEST_TIMEOUT_MS ?? "2500", 10),
  refreshIntervalMs: Number.parseInt(process.env.CONSOLE_REFRESH_INTERVAL_MS ?? "5000", 10),
  maxKeys: Number.parseInt(process.env.CONSOLE_MAX_KEYS ?? "100", 10),
});

export function publicConfig() {
  return {
    keyPrefix: config.keyPrefix,
    writeEnabled: config.writeEnabled,
    failoverEnabled: config.failoverEnabled,
    redisConfigured: Boolean(config.redisPassword),
    refreshIntervalMs: config.refreshIntervalMs,
    tools: {
      commander: process.env.CONSOLE_COMMANDER_URL ?? "http://localhost:8081",
      prometheus: process.env.CONSOLE_PROMETHEUS_URL ?? "http://localhost:9090",
      grafana: process.env.CONSOLE_GRAFANA_URL ?? "http://localhost:3000",
    },
  };
}
