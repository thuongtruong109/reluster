export class ApiError extends Error {
  constructor(message, code, status, details) {
    super(message);
    this.name = "ApiError";
    this.code = code;
    this.status = status;
    this.details = details;
  }
}

async function request(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      Accept: "application/json",
      ...(options.body ? { "Content-Type": "application/json" } : {}),
      ...options.headers,
    },
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new ApiError(
      payload.error?.message ?? `HTTP ${response.status}`,
      payload.error?.code ?? "REQUEST_FAILED",
      response.status,
      payload.error?.details,
    );
  }
  return payload;
}

function modeQuery(mode, extra = "") {
  return `?mode=${encodeURIComponent(mode)}${extra}`;
}

export const getMeta = () => request("/api/meta");
export const getStatus = (mode) => request(`/api/status/${mode}`);
export const getAudit = () => request("/api/audit?limit=30");
export const listKeys = (mode, search = "") => request(`/api/keys${modeQuery(mode, `&search=${encodeURIComponent(search)}`)}`);
export const getKey = (mode, key) => request(`/api/keys/${encodeURIComponent(key)}${modeQuery(mode)}`);
export const putKey = (mode, key, value, ttlSeconds) => request(`/api/keys/${encodeURIComponent(key)}${modeQuery(mode)}`, {
  method: "PUT",
  body: JSON.stringify({ value, ttlSeconds }),
});
export const deleteKey = (mode, key) => request(`/api/keys/${encodeURIComponent(key)}${modeQuery(mode)}`, { method: "DELETE" });
export const seedDemoData = (mode) => request(`/api/demo/seed${modeQuery(mode)}`, { method: "POST", body: "{}" });
export const requestFailover = () => request("/api/sentinel/failover", {
  method: "POST",
  body: JSON.stringify({ confirm: "FAILOVER" }),
});
