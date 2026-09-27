import * as api from "./api.js";
import { renderAudit, renderKeyDetail, renderKeys, renderLoading, renderMeta, renderStatus, renderUnavailable, showToast } from "./render.js";
import { registerRelusterTools } from "./webmcp.js";

const state = {
  mode: localStorage.getItem("reluster-mode") === "sentinel" ? "sentinel" : "cluster",
  meta: null,
  status: null,
  keys: [],
  selectedKey: null,
  detail: null,
  history: { cluster: [], sentinel: [] },
  refreshTimer: null,
  searchTimer: null,
};

const element = (selector) => document.querySelector(selector);

async function loadStatus() {
  renderLoading(state.mode);
  try {
    const status = await api.getStatus(state.mode);
    state.status = status;
    const history = state.history[state.mode];
    history.push(status.summary.opsPerSecond);
    if (history.length > 24) history.shift();
    renderStatus(status, history);
    return status;
  } catch (error) {
    state.status = null;
    renderUnavailable(error, state.mode);
    throw error;
  }
}

async function loadKeys() {
  try {
    const result = await api.listKeys(state.mode, element("#key-search").value);
    state.keys = result.keys;
    if (state.selectedKey && !state.keys.includes(state.selectedKey)) {
      state.selectedKey = null;
      state.detail = null;
    }
    renderKeys(state.keys, state.selectedKey);
    renderKeyDetail(state.detail, state.meta.writeEnabled);
  } catch {
    state.keys = [];
    state.selectedKey = null;
    state.detail = null;
    renderKeys([], null);
    renderKeyDetail(null, state.meta.writeEnabled);
  }
}

async function loadAudit() {
  const result = await api.getAudit();
  renderAudit(result.entries);
}

async function refreshAll({ quiet = false } = {}) {
  const results = await Promise.allSettled([loadStatus(), loadKeys(), loadAudit()]);
  const statusResult = results[0];
  if (!quiet && statusResult.status === "rejected") showToast(statusResult.reason.message, true);
  return statusResult.status === "fulfilled" ? statusResult.value : null;
}

function applyMode(mode) {
  state.mode = mode;
  state.selectedKey = null;
  state.detail = null;
  localStorage.setItem("reluster-mode", mode);
  document.querySelectorAll("[data-mode]").forEach((button) => {
    const active = button.dataset.mode === mode;
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-pressed", String(active));
  });
  element("#sentinel-panel").hidden = mode !== "sentinel";
  if (state.meta) renderMeta(state.meta, mode);
}

async function selectKey(key) {
  state.selectedKey = key;
  renderKeys(state.keys, key);
  try {
    state.detail = await api.getKey(state.mode, key);
    renderKeyDetail(state.detail, state.meta.writeEnabled);
  } catch (error) {
    showToast(error.message, true);
    await loadKeys();
  }
}

async function seed(mode = state.mode) {
  if (mode !== state.mode) applyMode(mode);
  const result = await api.seedDemoData(state.mode);
  showToast(`Đã tạo ${result.created} demo keys trong ${state.mode}.`);
  await Promise.all([loadKeys(), loadStatus(), loadAudit()]);
  return { mode: state.mode, created: result.created, keys: result.keys };
}

function restartTimer() {
  clearInterval(state.refreshTimer);
  if (element("#auto-refresh").checked) {
    state.refreshTimer = setInterval(() => {
      if (document.visibilityState === "visible") void loadStatus().catch(() => {});
    }, state.meta.refreshIntervalMs);
  }
}

document.querySelectorAll("[data-mode]").forEach((button) => {
  button.addEventListener("click", () => {
    if (button.dataset.mode === state.mode) return;
    applyMode(button.dataset.mode);
    void refreshAll();
  });
});
element("#refresh-button").addEventListener("click", () => void refreshAll());
element("#auto-refresh").addEventListener("change", restartTimer);
element("#seed-button").addEventListener("click", () => {
  void seed().catch((error) => showToast(error.message, true));
});
element("#new-key-button").addEventListener("click", () => element("#key-dialog").showModal());
element("#failover-button").addEventListener("click", () => element("#failover-dialog").showModal());

document.querySelectorAll("[data-close-dialog]").forEach((button) => {
  button.addEventListener("click", () => element(`#${button.dataset.closeDialog}`).close());
});

element("#key-search").addEventListener("input", () => {
  clearTimeout(state.searchTimer);
  state.searchTimer = setTimeout(() => void loadKeys(), 250);
});

element("#key-list").addEventListener("click", (event) => {
  const button = event.target.closest("[data-key]");
  if (button) void selectKey(button.dataset.key);
});

element("#key-detail").addEventListener("click", (event) => {
  if (event.target.id !== "delete-key-button" || !state.selectedKey) return;
  if (!window.confirm(`Xóa ${state.selectedKey}? Thao tác này không thể hoàn tác.`)) return;
  void api.deleteKey(state.mode, state.selectedKey).then(async () => {
    showToast(`Đã xóa ${state.selectedKey}.`);
    state.selectedKey = null;
    state.detail = null;
    await Promise.all([loadKeys(), loadStatus(), loadAudit()]);
  }).catch((error) => showToast(error.message, true));
});

element("#key-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const key = element("#key-name").value.trim();
  const value = element("#key-value").value;
  const ttl = Number(element("#key-ttl").value);
  void api.putKey(state.mode, key, value, ttl).then(async () => {
    element("#key-dialog").close();
    showToast(`Đã lưu ${key}.`);
    await Promise.all([loadKeys(), loadStatus(), loadAudit()]);
    await selectKey(key);
  }).catch((error) => showToast(error.message, true));
});

element("#failover-form").addEventListener("submit", (event) => {
  event.preventDefault();
  if (element("#failover-confirm").value !== "FAILOVER") {
    showToast("Hãy nhập chính xác FAILOVER để xác nhận.", true);
    return;
  }
  void api.requestFailover().then(() => {
    element("#failover-dialog").close();
    element("#failover-confirm").value = "";
    showToast("Sentinel đã nhận yêu cầu failover.");
    setTimeout(() => void refreshAll({ quiet: true }), 2500);
  }).catch((error) => showToast(error.message, true));
});

async function initialize() {
  try {
    state.meta = await api.getMeta();
    applyMode(state.mode);
    renderMeta(state.meta, state.mode);
    restartTimer();
    registerRelusterTools({
      refresh: async (mode) => {
        applyMode(mode);
        const status = await refreshAll({ quiet: true });
        if (!status) throw new Error(`Redis ${mode} không khả dụng.`);
        return { mode, state: status.state, summary: status.summary };
      },
      seed,
    });
    await refreshAll({ quiet: true });
  } catch (error) {
    renderUnavailable(error, state.mode);
    showToast(error.message, true);
  }
}

void initialize();
