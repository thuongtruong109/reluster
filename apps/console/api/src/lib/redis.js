import Redis from "ioredis";
import { config } from "../config.js";
import { AppError, requireRedisPassword, requireSentinelPassword } from "./app-error.js";
import { mapRedisError } from "./redis-error.js";

function baseOptions() {
  requireRedisPassword(config.redisPassword);
  return {
    password: config.redisPassword,
    lazyConnect: true,
    enableOfflineQueue: false,
    connectTimeout: config.requestTimeoutMs,
    commandTimeout: config.requestTimeoutMs,
    maxRetriesPerRequest: 1,
    retryStrategy: () => null,
  };
}

function muteExpectedConnectionErrors(client) {
  client.on("error", () => {});
  return client;
}

export async function withRedisNode(node, callback, options = {}) {
  const client = muteExpectedConnectionErrors(
    new Redis({ ...baseOptions(), ...options, host: node.host, port: node.port }),
  );

  try {
    await client.connect();
    return await callback(client);
  } finally {
    client.disconnect(false);
  }
}

export async function withFirstAvailableNode(nodes, callback, label = "Redis") {
  const failures = [];

  for (const node of nodes) {
    try {
      return await withRedisNode(node, (client) => callback(client, node));
    } catch (error) {
      failures.push(`${node.host}:${node.port} (${error.message})`);
    }
  }

  throw new AppError(503, "REDIS_UNAVAILABLE", `Không thể kết nối ${label}.`, failures);
}

export async function withModeClient(mode, callback) {
  requireRedisPassword(config.redisPassword);
  let client;

  if (mode === "cluster") {
    client = muteExpectedConnectionErrors(
      new Redis.Cluster(config.clusterNodes, {
        lazyConnect: true,
        clusterRetryStrategy: () => null,
        slotsRefreshTimeout: config.requestTimeoutMs,
        redisOptions: baseOptions(),
      }),
    );
  } else if (mode === "sentinel") {
    requireSentinelPassword(config.sentinelPassword);
    client = muteExpectedConnectionErrors(
      new Redis({
        ...baseOptions(),
        sentinels: config.sentinelNodes,
        sentinelPassword: config.sentinelPassword,
        name: config.sentinelMasterName,
        role: "master",
      }),
    );
  } else {
    throw new AppError(400, "INVALID_MODE", "Mode phải là cluster hoặc sentinel.");
  }

  try {
    await client.connect();
    return await callback(client);
  } catch (error) {
    throw mapRedisError(error, mode);
  } finally {
    client.disconnect(false);
  }
}
