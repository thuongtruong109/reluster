import { config } from "../config.js";
import { countCoveredSlots, parseClusterNodes, parseInfo } from "../lib/parsers.js";
import { withFirstAvailableNode } from "../lib/redis.js";
import { enrichNodes, summarizeNodes } from "./node-stats.js";

export async function getClusterStatus() {
  return withFirstAvailableNode(
    config.clusterNodes,
    async (client, source) => {
      const [rawClusterInfo, rawNodes] = await Promise.all([
        client.call("CLUSTER", "INFO"),
        client.call("CLUSTER", "NODES"),
      ]);
      const clusterInfo = parseInfo(rawClusterInfo);
      const nodes = await enrichNodes(parseClusterNodes(rawNodes));
      const summary = summarizeNodes(nodes);
      const coveredSlots = Number(clusterInfo.cluster_slots_assigned) || countCoveredSlots(nodes);

      return {
        mode: "cluster",
        state: clusterInfo.cluster_state === "ok" ? "healthy" : "degraded",
        source: `${source.host}:${source.port}`,
        timestamp: new Date().toISOString(),
        summary: {
          ...summary,
          coveredSlots,
          totalSlots: 16384,
          knownNodes: Number(clusterInfo.cluster_known_nodes) || nodes.length,
          clusterSize: Number(clusterInfo.cluster_size) || summary.masters,
        },
        nodes,
      };
    },
    "Redis Cluster",
  );
}
