import assert from "node:assert/strict";
import test from "node:test";

import { AppError } from "../src/lib/app-error.js";
import { mapRedisError } from "../src/lib/redis-error.js";

test("mapRedisError exposes write durability rejection as retryable", () => {
  const result = mapRedisError(new Error("NOREPLICAS Not enough good replicas to write."), "sentinel");

  assert.equal(result.status, 503);
  assert.equal(result.code, "WRITE_DURABILITY_UNAVAILABLE");
  assert.deepEqual(result.details, { retryable: true, reason: "replica-quorum" });
});

test("mapRedisError maps failover and stale topology failures", () => {
  assert.equal(mapRedisError(new Error("MASTERDOWN Link with MASTER is down"), "sentinel").code, "MASTER_UNAVAILABLE");
  assert.equal(mapRedisError(new Error("READONLY You can't write against a read only replica."), "sentinel").code, "WRITE_TARGET_READONLY");
  assert.equal(mapRedisError(new Error("CLUSTERDOWN The cluster is down"), "cluster").code, "CLUSTER_UNAVAILABLE");
});

test("mapRedisError preserves application errors", () => {
  const input = new AppError(400, "INVALID_INPUT", "Invalid input");
  assert.equal(mapRedisError(input, "cluster"), input);
});
