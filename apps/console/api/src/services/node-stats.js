import { parseInfo } from "../lib/parsers.js";
import { withRedisNode } from "../lib/redis.js";

function numeric(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

export async function getNodeStats(node) {
  return withRedisNode(node, async (client) => {
    const [pong, rawInfo] = await Promise.all([client.ping(), client.info()]);
    const info = parseInfo(rawInfo);
    return {
      reachable: pong === "PONG",
      redisVersion: info.redis_version ?? "unknown",
      role: info.role ?? node.role ?? "unknown",
      memoryBytes: numeric(info.used_memory),
      memoryHuman: info.used_memory_human ?? "0B",
      clients: numeric(info.connected_clients),
      opsPerSecond: numeric(info.instantaneous_ops_per_sec),
      totalCommands: numeric(info.total_commands_processed),
      keyspaceHits: numeric(info.keyspace_hits),
      keyspaceMisses: numeric(info.keyspace_misses),
      replicationOffset: numeric(info.master_repl_offset ?? info.slave_repl_offset),
      masterLinkStatus: info.master_link_status ?? null,
      uptimeSeconds: numeric(info.uptime_in_seconds),
    };
  });
}

export async function enrichNodes(nodes) {
  return Promise.all(
    nodes.map(async (node) => {
      try {
        return { ...node, ...(await getNodeStats(node)) };
      } catch (error) {
        return { ...node, reachable: false, error: error.message };
      }
    }),
  );
}

export function summarizeNodes(nodes) {
  const hits = nodes.reduce((sum, node) => sum + (node.keyspaceHits ?? 0), 0);
  const misses = nodes.reduce((sum, node) => sum + (node.keyspaceMisses ?? 0), 0);
  const attempts = hits + misses;

  return {
    totalNodes: nodes.length,
    healthyNodes: nodes.filter((node) => node.healthy !== false && node.reachable !== false).length,
    masters: nodes.filter((node) => node.role === "master").length,
    replicas: nodes.filter((node) => node.role === "replica" || node.role === "slave").length,
    memoryBytes: nodes.reduce((sum, node) => sum + (node.memoryBytes ?? 0), 0),
    clients: nodes.reduce((sum, node) => sum + (node.clients ?? 0), 0),
    opsPerSecond: nodes.reduce((sum, node) => sum + (node.opsPerSecond ?? 0), 0),
    hitRate: attempts ? Math.round((hits / attempts) * 1000) / 10 : 0,
  };
}
