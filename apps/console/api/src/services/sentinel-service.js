import { config } from "../config.js";
import { AppError, requireSentinelPassword } from "../lib/app-error.js";
import { parseSentinelPairs } from "../lib/parsers.js";
import { withRedisNode } from "../lib/redis.js";
import { enrichNodes, summarizeNodes } from "./node-stats.js";

async function querySentinel(node) {
  try {
    return await withRedisNode(
      node,
      async (client) => {
        const [pong, masterAddress] = await Promise.all([
          client.ping(),
          client.call("SENTINEL", "GET-MASTER-ADDR-BY-NAME", config.sentinelMasterName),
        ]);
        return {
          ...node,
          label: node.host,
          healthy: pong === "PONG",
          masterAddress: Array.isArray(masterAddress) ? masterAddress.join(":") : null,
        };
      },
      { password: config.sentinelPassword },
    );
  } catch (error) {
    return { ...node, label: node.host, healthy: false, error: error.message };
  }
}

export async function getSentinelStatus() {
  requireSentinelPassword(config.sentinelPassword);
  const sentinels = await Promise.all(config.sentinelNodes.map(querySentinel));
  const activeSentinel = sentinels.find((sentinel) => sentinel.healthy);
  if (!activeSentinel) {
    throw new AppError(503, "SENTINEL_UNAVAILABLE", "Không thể kết nối bất kỳ Sentinel nào.");
  }

  return withRedisNode(
    activeSentinel,
    async (client) => {
      const [rawMaster, rawReplicas, rawPeers] = await Promise.all([
        client.call("SENTINEL", "MASTER", config.sentinelMasterName),
        client.call("SENTINEL", "REPLICAS", config.sentinelMasterName),
        client.call("SENTINEL", "SENTINELS", config.sentinelMasterName),
      ]);
      const master = parseSentinelPairs(rawMaster);
      const replicaRows = rawReplicas.map(parseSentinelPairs);
      const nodes = await enrichNodes([
        {
          id: `master-${master.ip}-${master.port}`,
          host: master.ip,
          port: Number(master.port),
          label: master.name || "master",
          role: "master",
          healthy: !master.flags?.includes("down"),
          flags: master.flags?.split(",") ?? [],
        },
        ...replicaRows.map((replica, index) => ({
          id: `replica-${replica.ip}-${replica.port}`,
          host: replica.ip,
          port: Number(replica.port),
          label: replica.name || `replica-${index + 1}`,
          role: "replica",
          healthy: !replica.flags?.includes("down") && replica["master-link-status"] !== "err",
          flags: replica.flags?.split(",") ?? [],
          masterLinkStatus: replica["master-link-status"] ?? null,
        })),
      ]);
      const summary = summarizeNodes(nodes);
      const peerCount = rawPeers.length;

      return {
        mode: "sentinel",
        state: nodes[0]?.reachable && sentinels.filter((entry) => entry.healthy).length >= Number(master.quorum || 1)
          ? "healthy"
          : "degraded",
        timestamp: new Date().toISOString(),
        masterName: config.sentinelMasterName,
        quorum: Number(master.quorum || 1),
        currentMaster: `${master.ip}:${master.port}`,
        summary: {
          ...summary,
          activeSentinels: sentinels.filter((entry) => entry.healthy).length,
          totalSentinels: Math.max(sentinels.length, peerCount + 1),
        },
        nodes,
        sentinels,
      };
    },
    { password: config.sentinelPassword },
  );
}

export async function requestFailover() {
  requireSentinelPassword(config.sentinelPassword);
  const sentinels = await Promise.all(config.sentinelNodes.map(querySentinel));
  const activeSentinel = sentinels.find((sentinel) => sentinel.healthy);
  if (!activeSentinel) throw new AppError(503, "SENTINEL_UNAVAILABLE", "Không có Sentinel hoạt động.");

  return withRedisNode(
    activeSentinel,
    (client) => client.call("SENTINEL", "FAILOVER", config.sentinelMasterName),
    { password: config.sentinelPassword },
  );
}
