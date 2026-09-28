export function parseInfo(raw = "") {
  const result = {};

  for (const line of raw.split(/\r?\n/)) {
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf(":");
    if (separator < 1) continue;
    result[line.slice(0, separator)] = line.slice(separator + 1);
  }

  return result;
}

export function parseClusterNodes(raw = "") {
  return raw
    .trim()
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => {
      const fields = line.trim().split(/\s+/);
      const [networkAddress, announcedHostname] = fields[1].split(",");
      const endpoint = networkAddress.split("@")[0];
      const separator = endpoint.lastIndexOf(":");
      const flags = fields[2].split(",");
      const role = flags.includes("master") ? "master" : "replica";
      const slotTokens = fields.slice(8).filter((token) => !token.startsWith("["));

      return {
        id: fields[0],
        host: endpoint.slice(0, separator),
        port: Number.parseInt(endpoint.slice(separator + 1), 10),
        label: announcedHostname || endpoint.slice(0, separator),
        flags,
        role,
        masterId: fields[3] === "-" ? null : fields[3],
        linkState: fields[7],
        healthy: fields[7] === "connected" && !flags.some((flag) => flag === "fail" || flag === "fail?"),
        slots: role === "master" ? slotTokens : [],
      };
    });
}

export function parseSentinelPairs(value = []) {
  const result = {};
  for (let index = 0; index < value.length; index += 2) {
    result[String(value[index])] = value[index + 1] == null ? "" : String(value[index + 1]);
  }
  return result;
}

export function countCoveredSlots(nodes) {
  let total = 0;
  for (const node of nodes.filter((entry) => entry.role === "master")) {
    for (const slot of node.slots) {
      const [start, end = start] = slot.split("-").map(Number);
      if (Number.isFinite(start) && Number.isFinite(end)) total += end - start + 1;
    }
  }
  return total;
}
