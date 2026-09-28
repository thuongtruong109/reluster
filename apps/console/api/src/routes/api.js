import { Router } from "express";
import { config, publicConfig } from "../config.js";
import { addAuditEntry, getAuditEntries } from "../lib/audit.js";
import { AppError } from "../lib/app-error.js";
import { getClusterStatus } from "../services/cluster-service.js";
import { deleteKey, getKey, listKeys, putStringKey, seedDemoData } from "../services/key-service.js";
import { getSentinelStatus, requestFailover } from "../services/sentinel-service.js";

export const apiRouter = Router();

function modeFrom(request) {
  const mode = request.query.mode ?? request.params.mode;
  if (mode !== "cluster" && mode !== "sentinel") {
    throw new AppError(400, "INVALID_MODE", "Mode phải là cluster hoặc sentinel.");
  }
  return mode;
}

function sameOriginMutation(request, _response, next) {
  const origin = request.get("origin");
  if (origin) {
    try {
      if (new URL(origin).host !== request.get("host")) {
        return next(new AppError(403, "ORIGIN_REJECTED", "Yêu cầu khác origin đã bị từ chối."));
      }
    } catch {
      return next(new AppError(403, "ORIGIN_REJECTED", "Origin không hợp lệ."));
    }
  }
  next();
}

apiRouter.get("/health", (_request, response) => {
  response.json({
    ok: true,
    service: "reluster-console",
    redisConfigured: Boolean(config.redisPassword),
    sentinelConfigured: Boolean(config.sentinelPassword),
    writeEnabled: config.writeEnabled,
    timestamp: new Date().toISOString(),
  });
});

apiRouter.get("/meta", (_request, response) => response.json(publicConfig()));

apiRouter.get("/status/:mode", async (request, response) => {
  const mode = modeFrom(request);
  response.json(mode === "cluster" ? await getClusterStatus() : await getSentinelStatus());
});

apiRouter.get("/keys", async (request, response) => {
  response.json(await listKeys(modeFrom(request), request.query.search));
});

apiRouter.get("/keys/:key", async (request, response) => {
  response.json(await getKey(modeFrom(request), request.params.key));
});

apiRouter.put("/keys/:key", sameOriginMutation, async (request, response) => {
  const mode = modeFrom(request);
  const result = await putStringKey(mode, request.params.key, request.body.value, request.body.ttlSeconds);
  addAuditEntry("key.put", request.params.key, "success", mode);
  response.json(result);
});

apiRouter.delete("/keys/:key", sameOriginMutation, async (request, response) => {
  const mode = modeFrom(request);
  const result = await deleteKey(mode, request.params.key);
  addAuditEntry("key.delete", request.params.key, "success", mode);
  response.json(result);
});

apiRouter.post("/demo/seed", sameOriginMutation, async (request, response) => {
  const mode = modeFrom(request);
  const result = await seedDemoData(mode);
  addAuditEntry("demo.seed", `${result.created} keys`, "success", mode);
  response.json(result);
});

apiRouter.post("/sentinel/failover", sameOriginMutation, async (request, response) => {
  if (!config.writeEnabled) {
    throw new AppError(403, "WRITES_DISABLED", "Console đang ở chế độ chỉ đọc.");
  }
  if (!config.failoverEnabled) {
    throw new AppError(403, "FAILOVER_DISABLED", "Failover chưa được bật trong cấu hình Console.");
  }
  if (request.body.confirm !== "FAILOVER") {
    throw new AppError(400, "CONFIRMATION_REQUIRED", "Nhập FAILOVER để xác nhận.");
  }
  const result = await requestFailover();
  addAuditEntry("sentinel.failover", config.sentinelMasterName, "requested", String(result));
  response.status(202).json({ accepted: result === "OK", masterName: config.sentinelMasterName });
});

apiRouter.get("/audit", (request, response) => {
  response.json({ entries: getAuditEntries(Number(request.query.limit) || 30) });
});
