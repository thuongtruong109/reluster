const entries = [];
const maximumEntries = 100;

export function addAuditEntry(action, target, outcome = "success", detail = "") {
  entries.unshift({
    id: crypto.randomUUID(),
    action,
    target,
    outcome,
    detail,
    timestamp: new Date().toISOString(),
  });

  if (entries.length > maximumEntries) entries.length = maximumEntries;
  return entries[0];
}

export function getAuditEntries(limit = 30) {
  return entries.slice(0, Math.max(1, Math.min(limit, maximumEntries)));
}
