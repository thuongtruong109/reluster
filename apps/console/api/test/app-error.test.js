import assert from "node:assert/strict";
import test from "node:test";

import { requireSentinelPassword } from "../src/lib/app-error.js";

test("requireSentinelPassword accepts a configured credential", () => {
  assert.doesNotThrow(() => requireSentinelPassword("sentinel-secret"));
});

test("requireSentinelPassword rejects an empty credential", () => {
  assert.throws(
    () => requireSentinelPassword(""),
    (error) => error.status === 503 && error.code === "SENTINEL_NOT_CONFIGURED",
  );
});
