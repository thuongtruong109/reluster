import assert from "node:assert/strict";
import test from "node:test";
import { countCoveredSlots, parseClusterNodes, parseInfo, parseSentinelPairs } from "../src/lib/parsers.js";

test("parseInfo converts Redis INFO lines to fields", () => {
  assert.deepEqual(parseInfo("# Memory\r\nused_memory:1024\r\nrole:master\r\n"), {
    used_memory: "1024",
    role: "master",
  });
});

test("parseClusterNodes extracts role, health and slots", () => {
  const raw = [
    "abc node-1:6379@16379,node-1 myself,master - 0 1 1 connected 0-5460",
    "def node-4:6379@16379,node-4 slave abc 0 1 1 connected",
  ].join("\n");
  const nodes = parseClusterNodes(raw);
  assert.equal(nodes[0].label, "node-1");
  assert.equal(nodes[0].role, "master");
  assert.equal(nodes[1].masterId, "abc");
  assert.equal(countCoveredSlots(nodes), 5461);
});

test("parseSentinelPairs converts flat Sentinel rows", () => {
  assert.deepEqual(parseSentinelPairs(["name", "mymaster", "quorum", "2"]), {
    name: "mymaster",
    quorum: "2",
  });
});
