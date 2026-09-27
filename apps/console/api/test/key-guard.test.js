import assert from "node:assert/strict";
import test from "node:test";
import { assertDemoKey } from "../src/services/key-service.js";

test("assertDemoKey accepts the configured demo namespace", () => {
  assert.doesNotThrow(() => assertDemoKey("demo:session:1"));
});

test("assertDemoKey rejects keys outside the demo namespace", () => {
  assert.throws(() => assertDemoKey("production:session:1"), /demo:/);
});
