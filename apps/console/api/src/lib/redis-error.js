import { AppError } from "./app-error.js";

const retryableErrors = Object.freeze({
  NOREPLICAS: {
    code: "WRITE_DURABILITY_UNAVAILABLE",
    message: "Redis tạm từ chối ghi vì không có đủ replica khỏe trong giới hạn lag.",
    reason: "replica-quorum",
  },
  MASTERDOWN: {
    code: "MASTER_UNAVAILABLE",
    message: "Redis master đang không khả dụng hoặc đang failover. Hãy thử lại sau.",
    reason: "master-failover",
  },
  READONLY: {
    code: "WRITE_TARGET_READONLY",
    message: "Topology Redis vừa thay đổi và kết nối đang trỏ tới replica. Hãy thử lại sau.",
    reason: "stale-topology",
  },
  CLUSTERDOWN: {
    code: "CLUSTER_UNAVAILABLE",
    message: "Redis Cluster đang không đủ điều kiện phục vụ yêu cầu. Hãy thử lại sau.",
    reason: "cluster-down",
  },
});

export function mapRedisError(error, mode) {
  if (error instanceof AppError) return error;

  const redisCode = String(error?.message ?? "").trim().split(/\s+/, 1)[0].toUpperCase();
  const mapping = Object.hasOwn(retryableErrors, redisCode) ? retryableErrors[redisCode] : null;
  if (mapping) {
    return new AppError(503, mapping.code, mapping.message, {
      retryable: true,
      reason: mapping.reason,
    });
  }

  return new AppError(
    503,
    "REDIS_UNAVAILABLE",
    `Không thể kết nối Redis ${mode}.`,
    { retryable: true, reason: "connection" },
  );
}
