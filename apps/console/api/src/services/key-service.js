import { config } from "../config.js";
import { AppError } from "../lib/app-error.js";
import { withModeClient } from "../lib/redis.js";

function escapeRedisGlob(value) {
  return value.replace(/[\\*?\[\]]/g, "\\$&");
}

export function assertDemoKey(key) {
  if (typeof key !== "string" || !key.startsWith(config.keyPrefix)) {
    throw new AppError(400, "KEY_OUTSIDE_NAMESPACE", `Chỉ được thao tác key bắt đầu bằng ${config.keyPrefix}`);
  }
  if (key.length > 200) throw new AppError(400, "KEY_TOO_LONG", "Tên key không được vượt quá 200 ký tự.");
}

function assertWritesEnabled() {
  if (!config.writeEnabled) {
    throw new AppError(403, "WRITES_DISABLED", "Console đang ở chế độ chỉ đọc.");
  }
}

async function scanClient(client, pattern, limit) {
  let cursor = "0";
  const keys = [];
  do {
    const [nextCursor, batch] = await client.scan(cursor, "MATCH", pattern, "COUNT", 100);
    cursor = nextCursor;
    keys.push(...batch);
  } while (cursor !== "0" && keys.length < limit);
  return keys.slice(0, limit);
}

export async function listKeys(mode, search = "") {
  const normalizedSearch = String(search).trim().slice(0, 80);
  const pattern = `${config.keyPrefix}${escapeRedisGlob(normalizedSearch)}*`;

  return withModeClient(mode, async (client) => {
    let keys;
    if (mode === "cluster") {
      const batches = await Promise.all(
        client.nodes("master").map((node) => scanClient(node, pattern, config.maxKeys)),
      );
      keys = [...new Set(batches.flat())].slice(0, config.maxKeys);
    } else {
      keys = await scanClient(client, pattern, config.maxKeys);
    }

    return { keys: keys.sort(), truncated: keys.length >= config.maxKeys, prefix: config.keyPrefix };
  });
}

async function readPreview(client, key, type) {
  if (type === "string") return client.get(key);
  if (type === "hash") {
    const [, values] = await client.hscan(key, "0", "COUNT", 50);
    return Object.fromEntries(Array.from({ length: values.length / 2 }, (_, index) => [values[index * 2], values[index * 2 + 1]]));
  }
  if (type === "list") return client.lrange(key, 0, 49);
  if (type === "set") return (await client.sscan(key, "0", "COUNT", 50))[1];
  if (type === "zset") return client.zrange(key, 0, 49, "WITHSCORES");
  if (type === "stream") return client.xrange(key, "-", "+", "COUNT", 20);
  return `Không hỗ trợ preview cho kiểu ${type}`;
}

export async function getKey(mode, key) {
  assertDemoKey(key);
  return withModeClient(mode, async (client) => {
    const type = await client.type(key);
    if (type === "none") throw new AppError(404, "KEY_NOT_FOUND", "Key không còn tồn tại.");
    const [ttlMs, value] = await Promise.all([client.pttl(key), readPreview(client, key, type)]);
    return { key, type, ttlMs, value };
  });
}

export async function putStringKey(mode, key, value, ttlSeconds = 0) {
  assertWritesEnabled();
  assertDemoKey(key);
  if (typeof value !== "string") throw new AppError(400, "INVALID_VALUE", "Value phải là chuỗi.");
  if (Buffer.byteLength(value, "utf8") > 16_384) {
    throw new AppError(400, "VALUE_TOO_LARGE", "Value không được vượt quá 16 KB.");
  }
  const ttl = Number(ttlSeconds);
  if (!Number.isInteger(ttl) || ttl < 0 || ttl > 86_400) {
    throw new AppError(400, "INVALID_TTL", "TTL phải từ 0 đến 86400 giây.");
  }

  return withModeClient(mode, async (client) => {
    const result = ttl > 0 ? await client.set(key, value, "EX", ttl) : await client.set(key, value);
    return { key, result, ttlSeconds: ttl };
  });
}

export async function deleteKey(mode, key) {
  assertWritesEnabled();
  assertDemoKey(key);
  return withModeClient(mode, async (client) => ({ key, deleted: await client.del(key) }));
}

export async function seedDemoData(mode) {
  assertWritesEnabled();
  const now = new Date();
  const samples = [
    ["demo:session:1001", JSON.stringify({ user: "linh", plan: "pro", active: true }), 3600],
    ["demo:session:1002", JSON.stringify({ user: "minh", plan: "starter", active: true }), 1800],
    ["demo:feature:realtime-dashboard", "enabled", 0],
    ["demo:counter:page-views", String(Math.floor(1500 + Math.random() * 500)), 0],
    ["demo:cache:latest-report", JSON.stringify({ generatedAt: now.toISOString(), status: "ready" }), 600],
    ["demo:queue:pending", String(Math.floor(2 + Math.random() * 8)), 120],
  ];

  return withModeClient(mode, async (client) => {
    for (const [key, value, ttl] of samples) {
      if (ttl > 0) await client.set(key, value, "EX", ttl);
      else await client.set(key, value);
    }
    return { created: samples.length, keys: samples.map(([key]) => key) };
  });
}
