const select = (selector) => document.querySelector(selector);

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function formatBytes(bytes) {
  const value = Number(bytes) || 0;
  if (value < 1024) return `${value} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let converted = value / 1024;
  let index = 0;
  while (converted >= 1024 && index < units.length - 1) {
    converted /= 1024;
    index += 1;
  }
  return `${converted >= 10 ? converted.toFixed(0) : converted.toFixed(1)} ${units[index]}`;
}

function formatTimestamp(timestamp) {
  return new Intl.DateTimeFormat("vi-VN", { hour: "2-digit", minute: "2-digit", second: "2-digit" }).format(new Date(timestamp));
}

function valuePreview(value) {
  if (typeof value !== "string") return JSON.stringify(value, null, 2);
  try {
    return JSON.stringify(JSON.parse(value), null, 2);
  } catch {
    return value;
  }
}

export function renderMeta(meta, mode) {
  select("#key-prefix").textContent = `${meta.keyPrefix}*`;
  select("#key-name").value = meta.keyPrefix;
  select("#write-mode-tag").textContent = meta.writeEnabled ? "Demo writes on" : "Read only";
  select("#write-mode-tag").classList.toggle("is-healthy", meta.writeEnabled);
  select("#new-key-button").disabled = !meta.writeEnabled;
  select("#seed-button").disabled = !meta.writeEnabled;
  select("#failover-button").disabled = mode !== "sentinel"
    || !meta.writeEnabled
    || !meta.failoverEnabled
    || !meta.sentinelConfigured;
  select("#failover-button").title = !meta.sentinelConfigured
    ? "Thiết lập SENTINEL_PASSWORD để kết nối an toàn tới Sentinel"
    : !meta.failoverEnabled
      ? "Bật CONSOLE_FAILOVER_ENABLED=true để cho phép thao tác này"
      : "";
  select("#tool-links").innerHTML = Object.entries(meta.tools)
    .map(([name, url]) => `<a class="tool-link" href="${escapeHtml(url)}" target="_blank" rel="noreferrer">${escapeHtml(name)}</a>`)
    .join("");
}

export function renderLoading(mode) {
  select("#connection-status").className = "connection-pill";
  select("#connection-status span:last-child").textContent = `Đang đọc ${mode}`;
  select("#refresh-button").disabled = true;
}

export function renderStatus(status, history) {
  const summary = status.summary;
  const stateCard = select(".metric-card--state");
  const connection = select("#connection-status");
  stateCard.className = `metric-card metric-card--state is-${status.state}`;
  connection.className = `connection-pill ${status.state === "healthy" ? "is-online" : "is-error"}`;
  connection.querySelector("span:last-child").textContent = status.state === "healthy" ? "Redis online" : "Redis degraded";
  select("#last-updated").textContent = `Đồng bộ ${formatTimestamp(status.timestamp)}`;
  select("#metric-state").textContent = status.state === "healthy" ? "Healthy" : "Degraded";
  select("#metric-state-detail").textContent = status.mode === "cluster" ? "Cluster state và node links" : `Master ${status.currentMaster}`;
  select("#metric-nodes").textContent = `${summary.healthyNodes}/${summary.totalNodes}`;
  select("#metric-nodes-detail").textContent = `${summary.masters} master · ${summary.replicas} replica`;
  select("#metric-memory").textContent = formatBytes(summary.memoryBytes);
  select("#metric-clients").textContent = new Intl.NumberFormat("vi-VN").format(summary.clients);
  select("#metric-ops").textContent = new Intl.NumberFormat("vi-VN").format(summary.opsPerSecond);

  if (status.mode === "cluster") {
    select("#metric-nodes-label").textContent = "Nodes";
    select("#metric-coverage-label").textContent = "Slot coverage";
    select("#metric-coverage").textContent = `${summary.coveredSlots}`;
    select("#metric-coverage-detail").textContent = `trên ${summary.totalSlots.toLocaleString("vi-VN")} slots`;
    select("#topology-title").textContent = "Cluster map";
    select("#topology-tag").textContent = `${summary.clusterSize} shards`;
  } else {
    select("#metric-nodes-label").textContent = "Data nodes";
    select("#metric-coverage-label").textContent = "Sentinel quorum";
    select("#metric-coverage").textContent = `${summary.activeSentinels}/${summary.totalSentinels}`;
    select("#metric-coverage-detail").textContent = `quorum yêu cầu ${status.quorum}`;
    select("#topology-title").textContent = "Replication map";
    select("#topology-tag").textContent = status.masterName;
  }
  select("#topology-tag").className = `tag ${status.state === "healthy" ? "is-healthy" : "is-warning"}`;
  select("#refresh-button").disabled = false;
  renderNodes(status.nodes);
  renderSentinels(status);
  renderChart(history);
  hideNotice();
}

export function renderUnavailable(error, mode) {
  const stateCard = select(".metric-card--state");
  const connection = select("#connection-status");
  stateCard.className = "metric-card metric-card--state is-offline";
  connection.className = "connection-pill is-error";
  connection.querySelector("span:last-child").textContent = `${mode} offline`;
  select("#metric-state").textContent = "Offline";
  select("#metric-state-detail").textContent = "Backend vẫn hoạt động";
  for (const id of ["#metric-nodes", "#metric-coverage", "#metric-memory", "#metric-clients", "#metric-ops"]) select(id).textContent = "—";
  select("#node-grid").innerHTML = `<div class="empty-state"><span class="empty-symbol" aria-hidden="true">×</span><h3>Chưa kết nối được ${escapeHtml(mode)}</h3><p>${escapeHtml(error.message)}</p></div>`;
  select("#refresh-button").disabled = false;
  const configurationMessage = error.code === "REDIS_NOT_CONFIGURED"
    ? "Thiết lập REDIS_PASSWORD rồi chạy Console qua Docker Compose."
    : error.code === "SENTINEL_NOT_CONFIGURED"
      ? "Thiết lập SENTINEL_PASSWORD để Console xác thực với Sentinel."
      : "Hãy kiểm tra các container và mạng redisnet, sau đó bấm Làm mới.";
  showNotice("Redis chưa sẵn sàng", configurationMessage);
}

function renderNodes(nodes) {
  if (!nodes?.length) {
    select("#node-grid").innerHTML = '<div class="empty-inline">Không tìm thấy node.</div>';
    return;
  }
  const sorted = [...nodes].sort((a, b) => (a.role === "master" ? -1 : 1) - (b.role === "master" ? -1 : 1));
  select("#node-grid").innerHTML = sorted.map((node) => {
    const slots = node.slots?.length ? node.slots.join(", ") : node.masterLinkStatus ? `master link: ${node.masterLinkStatus}` : "no slot assignment";
    return `<article class="node-card ${node.role === "master" ? "is-master" : ""} ${node.reachable === false || node.healthy === false ? "is-offline" : ""}">
      <div class="node-card-head"><span class="node-name">${escapeHtml(node.label || node.host)}</span><span class="role-badge">${escapeHtml(node.role)}</span></div>
      <div class="node-stats"><div><span>Memory</span><strong>${escapeHtml(node.memoryHuman || formatBytes(node.memoryBytes))}</strong></div><div><span>Clients</span><strong>${Number(node.clients || 0).toLocaleString("vi-VN")}</strong></div></div>
      <div class="node-slots" title="${escapeHtml(slots)}">${escapeHtml(slots)}</div>
    </article>`;
  }).join("");
}

function renderSentinels(status) {
  const panel = select("#sentinel-panel");
  panel.hidden = status.mode !== "sentinel";
  if (status.mode !== "sentinel") return;
  select("#sentinel-master").textContent = `master ${status.currentMaster}`;
  select("#sentinel-grid").innerHTML = status.sentinels.map((sentinel) => `<article class="sentinel-card">
    <div class="sentinel-card-head"><strong>${escapeHtml(sentinel.label)}</strong><i class="health-dot ${sentinel.healthy ? "is-healthy" : ""}" aria-label="${sentinel.healthy ? "healthy" : "offline"}"></i></div>
    <span>${escapeHtml(`${sentinel.host}:${sentinel.port}`)}</span>
  </article>`).join("");
}

function renderChart(history) {
  if (!history.length) return;
  const width = 180;
  const height = 34;
  const max = Math.max(...history, 1);
  const points = history.map((value, index) => {
    const x = history.length === 1 ? width : (index / (history.length - 1)) * width;
    const y = height - (value / max) * (height - 5);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");
  select("#ops-chart").innerHTML = `<path class="chart-fill" d="M ${points.replaceAll(" ", " L ")} L ${width},${height} L 0,${height} Z"></path><path d="M ${points.replaceAll(" ", " L ")}"></path>`;
}

export function renderKeys(keys, selectedKey) {
  select("#key-count").textContent = `${keys.length} keys`;
  select("#key-list").innerHTML = keys.length
    ? keys.map((key) => `<button class="key-list-button ${key === selectedKey ? "is-active" : ""}" type="button" role="option" aria-selected="${key === selectedKey}" data-key="${escapeHtml(key)}">${escapeHtml(key)}</button>`).join("")
    : '<div class="empty-inline">Chưa có key demo. Hãy dùng Seed demo data.</div>';
}

export function renderKeyDetail(detail, writeEnabled) {
  if (!detail) {
    select("#key-detail").innerHTML = '<div class="empty-state empty-state--compact"><span class="empty-symbol" aria-hidden="true">{ }</span><h3>Chọn một key để xem dữ liệu</h3><p>Value, kiểu dữ liệu và TTL sẽ xuất hiện tại đây.</p></div>';
    return;
  }
  const ttl = detail.ttlMs < 0 ? "không hết hạn" : `${Math.ceil(detail.ttlMs / 1000)}s`;
  select("#key-detail").innerHTML = `<div class="key-detail-head"><div><h3 class="key-detail-name">${escapeHtml(detail.key)}</h3><div class="key-meta"><span>${escapeHtml(detail.type)}</span><span>TTL ${escapeHtml(ttl)}</span></div></div>${writeEnabled ? '<button class="text-button" type="button" id="delete-key-button">Xóa key</button>' : ""}</div><pre class="key-value">${escapeHtml(valuePreview(detail.value))}</pre>`;
}

export function renderAudit(entries) {
  select("#event-list").innerHTML = entries.length
    ? entries.map((entry) => `<li class="event-item"><span class="event-action">${escapeHtml(entry.action)}</span><span class="event-target">${escapeHtml(entry.target)}</span><time class="event-time">${escapeHtml(formatTimestamp(entry.timestamp))} · ${escapeHtml(entry.detail)}</time></li>`).join("")
    : '<li class="empty-inline">Chưa có thao tác ghi.</li>';
}

export function showToast(message, isError = false) {
  const toast = select("#toast");
  toast.textContent = message;
  toast.className = `toast ${isError ? "is-error" : ""}`;
  toast.hidden = false;
  clearTimeout(showToast.timeout);
  showToast.timeout = setTimeout(() => { toast.hidden = true; }, 4200);
}

function showNotice(title, message) {
  select("#notice-title").textContent = title;
  select("#notice-message").textContent = message;
  select("#notice").hidden = false;
}

function hideNotice() {
  select("#notice").hidden = true;
}
